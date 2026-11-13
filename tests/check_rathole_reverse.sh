#!/usr/bin/env bash
# Runs the Rathole release of the role defaults as server and client on
# 127.0.0.1 with the config the role renders, and checks reverse services
# (TCP and UDP) and a forward service through the same noise tunnel.
# Needs network access (GitHub release), python3, curl and unzip.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/^rathole_version: "\(.*\)".*/\1/p' roles/rathole/defaults/main.yml)
case $(uname -m) in
  x86_64) target=x86_64-unknown-linux-gnu ;;
  aarch64) target=aarch64-unknown-linux-musl ;;
  *)
    echo "skipped (no Rathole build for $(uname -m))"
    exit 0
    ;;
esac

work=$(mktemp -d)
pids=()
cleanup() {
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

url=https://github.com/chrisvgt/rathole/releases/download/v$version/rathole-$target.zip
curl -fsSL --retry 3 -o "$work/rathole.zip" "$url"
(cd "$work" && unzip -q rathole.zip && chmod +x rathole)
rathole=$work/rathole
"$rathole" --version | grep -q "v$version"

# Keys from this binary, as the role creates them on the server
keys=$("$rathole" --genkey)
private=$(sed -n '/Private Key:/{n;p}' <<<"$keys")
public=$(sed -n '/Public Key:/{n;p}' <<<"$keys")
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

ansible-playbook -i tests/hosts.ini tests/rathole_reverse_render.yml -e "out_dir=$work" -e "test_port=$port" \
  -e "rathole_noise_private_key=$private" -e "rathole_noise_public_key=$public" \
  -e rathole_default_token=reverse-test-token >"$work/render.log" || {
  cat "$work/render.log"
  exit 1
}

# Services: two on the server side (reverse), one on the client side (forward)
cat >"$work/backends.py" <<'EOF'
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def http(port, text):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = text.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    threading.Thread(target=HTTPServer(("127.0.0.1", port), Handler).serve_forever, daemon=True).start()


def udp_echo(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", port))
    while True:
        data, addr = sock.recvfrom(2048)
        sock.sendto(b"echo " + data, addr)


http(19001, "reverse from the server")
http(19003, "forward from the client")
udp_echo(19002)
EOF
python3 "$work/backends.py" &
pids+=($!)

RUST_LOG=info "$rathole" -s "$work/server.toml" >"$work/server.log" 2>&1 &
pids+=($!)
RUST_LOG=info "$rathole" -c "$work/client.toml" >"$work/client.log" 2>&1 &
pids+=($!)

udp() { # port, message
  python3 - "$1" "$2" <<'EOF'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(2)
sock.sendto(sys.argv[2].encode(), ("127.0.0.1", int(sys.argv[1])))
print(sock.recvfrom(2048)[0].decode())
EOF
}

fail=0
check() { # description, command, expected output
  local out=""
  for _ in $(seq 20); do
    out=$(eval "$2" 2>/dev/null || true)
    [[ $out == "$3" ]] && break
    sleep 0.5
  done
  if [[ $out == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1 (got '$out')"
    fail=1
  fi
}

check "reverse TCP: the client reaches a service of the server" \
  "curl -s --max-time 2 http://127.0.0.1:19101/" "reverse from the server"
check "reverse UDP: the client reaches a service of the server" "udp 19102 ping" "echo ping"
check "forward TCP still works in the same tunnel" \
  "curl -s --max-time 2 http://127.0.0.1:19103/" "forward from the client"
# A client with a wrong token must not reach the server's service
sed -e 's/^default_token = .*/default_token = "wrong-token"/' -e 's/127.0.0.1:19101/127.0.0.1:19201/' \
  -e '/^\[client.services.rev-udp\]/,$d' "$work/client.toml" >"$work/intruder.toml"
RUST_LOG=info "$rathole" -c "$work/intruder.toml" >"$work/intruder.log" 2>&1 &
pids+=($!)
sleep 2
check "reverse TCP with a wrong token gets nothing" \
  "curl -s --max-time 2 http://127.0.0.1:19201/ || echo refused" "refused"
check "the server logs the failed authentication" \
  "grep -c 'failed the authentication' '$work/server.log' | grep -qv '^0$' && echo logged" "logged"

if [[ $fail -ne 0 ]]; then
  echo "--- server.toml (without secrets)"
  grep -v -e token -e key "$work/server.toml"
  echo "--- client.toml (without secrets)"
  grep -v -e token -e key "$work/client.toml"
  echo "--- server log"
  tail -20 "$work/server.log"
  echo "--- client log"
  tail -20 "$work/client.log"
  echo "--- intruder log"
  tail -5 "$work/intruder.log"
fi
exit $fail
