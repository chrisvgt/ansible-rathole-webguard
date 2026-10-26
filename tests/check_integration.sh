#!/usr/bin/env bash
# Full run of site.yml against a server and a client container (Debian 12 with
# systemd, own network), then checks from the outside: site through the tunnel,
# CrowdSec bouncer, firewall, Caddy sandbox. A second run must change nothing,
# a check-mode run must pass, and turning the firewall off must remove it.
# Needs Docker with --privileged, network access and community.docker.
set -euo pipefail

cd "$(dirname "$0")/.."
image=webguard-integration:debian12
net=webguard-it
server=it-server
client=it-client

cleanup() {
  docker exec "$server" swapoff /swap/swapfile >/dev/null 2>&1 || true
  docker rm -f "$server" "$client" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
cleanup # Leftovers of an aborted run
logs=$(mktemp -d)
trap 'cleanup; rm -rf "$logs" 2>/dev/null || true' EXIT # The swap file belongs to root

# Debian with systemd and what Ansible needs (built once, reused)
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker rm -f it-build >/dev/null 2>&1 || true
  docker run --name it-build debian:12 sh -c \
    'apt-get update -qq && apt-get install -y -qq --no-install-recommends systemd systemd-sysv python3 python3-apt sudo ca-certificates curl >/dev/null'
  docker commit it-build "$image" >/dev/null
  docker rm it-build >/dev/null
fi

# Swap needs a real filesystem (not overlayfs) and changes the host kernel, so
# it is only tested in CI, where the host is a throwaway VM
extra=()
mounts=()
if [[ -n ${CI:-} ]]; then
  mkdir -p "$logs/swap"
  mounts=(-v "$logs/swap:/swap")
  # Only the server has the mount
  extra=(-e '{"system_swap_enabled": "{{ inventory_hostname == \"it-server\" }}"}'
    -e system_swap_file=/swap/swapfile -e system_swap_size=64M)
fi

docker network create "$net" >/dev/null
docker run -d --name "$server" --hostname "$server" --network "$net" --privileged \
  --tmpfs /run --tmpfs /run/lock ${mounts[@]+"${mounts[@]}"} "$image" /lib/systemd/systemd >/dev/null
docker run -d --name "$client" --hostname "$client" --network "$net" --privileged \
  --tmpfs /run --tmpfs /run/lock "$image" /lib/systemd/systemd >/dev/null
for host in "$server" "$client"; do
  for _ in $(seq 60); do
    state=$(docker exec "$host" systemctl is-system-running 2>/dev/null || true)
    [[ $state == running || $state == degraded ]] && break
    sleep 1
  done
done

# The service behind the tunnel, on the client
docker cp tests/integration/app.py "$client:/opt/app.py"
docker exec "$client" systemd-run --unit it-app python3 /opt/app.py >/dev/null

playbook() {
  ANSIBLE_ROLES_PATH="$PWD/roles" ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i tests/integration/hosts.ini site.yml ${extra[@]+"${extra[@]}"} "$@"
}
on() { docker exec "$1" bash -c "$2"; }
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else
    echo "FAIL $1"
    fail=1
  fi
}

echo "== first run"
if ! playbook | tee "$logs/run1.log"; then
  echo "FAIL first run (ansible-playbook exit code ${PIPESTATUS[0]})"
  exit 1
fi

server_ip=$(ip_of "$server")
client_ip=$(ip_of "$client")
https() { on "$client" "curl -sk --max-time 5 --resolve web.test:443:$server_ip $* https://web.test/"; }

# Shown when the site does not answer through the tunnel
diagnose() {
  echo "--- diagnostics"
  echo "HTTP status: $(https -o /dev/null -w '%{http_code}' || true)"
  echo "server, Rathole port on 127.0.0.1:18080:"
  on "$server" 'curl -s --max-time 3 http://127.0.0.1:18080/' || true
  echo "client, app on 127.0.0.1:8080:"
  on "$client" 'curl -s --max-time 3 http://127.0.0.1:8080/; systemctl is-active it-app' || true
  on "$server" 'journalctl -u rathole --no-pager -n 15' || true
  on "$client" 'journalctl -u rathole --no-pager -n 15' || true
  on "$server" 'tail -n 3 /var/log/caddy/*.access.log' || true
  echo "---"
}

echo "== checks"
check "server services are active" "on $server 'systemctl is-active caddy crowdsec crowdsec-firewall-bouncer rathole'"
check "client tunnel is active" "on $client 'systemctl is-active rathole'"
check "site answers through the tunnel" "https | grep -q 'hello from the client'"
https | grep -q 'hello from the client' || diagnose
check "HSTS is sent" "https -I | grep -qi '^strict-transport-security: max-age=31536000'"
check "no Server header" "! https -I | grep -qi '^server:'"
check "Caddy admin API only on its socket" "on $server 'test -S /run/caddy/admin.sock && ! curl -s --max-time 2 http://localhost:2019/config/'"
check "Caddy sandbox exposure below 2" "on $server \"systemd-analyze security caddy.service | tail -1 | grep -qE 'level for caddy.service: [01]\\.'\""
check "firewall opens the passed-through UDP port" "on $server 'nft list table inet webguard' | grep -q 'udp dport { 443, 51820 }'"
on "$server" "systemd-run --unit it-probe python3 -m http.server 9000" >/dev/null
check "firewall drops other ports" "! on $client 'curl -s --max-time 3 http://$server_ip:9000/'"
check "firewall leaves local access" "on $server 'curl -s --max-time 3 http://127.0.0.1:9000/'"
check "Caddy bouncer is registered" "on $server 'cscli bouncers list -o raw' | grep -q caddy-bouncer"
check "failed login scenario is loaded" "on $server 'cscli scenarios list -o raw' | grep -q local/login-bf"
check "app whitelists are installed" "on $server 'cscli parsers list -o raw' | grep -q crowdsecurity/nextcloud-whitelist"
check "hub updates are scheduled" "on $server 'systemctl is-enabled crowdsec-hubupdate.timer'"
check "blocklist import is scheduled" "on $server 'systemctl list-timers --all' | grep -q blocklist"
if [[ -n ${CI:-} ]]; then
  check "swap file is active" "on $server 'swapon --show=NAME --noheadings' | grep -q /swap/swapfile"
fi

on "$server" "cscli decisions add --ip $client_ip --duration 10m" >/dev/null
sleep 20 # Caddy bouncer polls every 15 s
check "a banned IP is blocked" "! https | grep -q 'hello from the client'"
on "$server" "cscli decisions delete --ip $client_ip" >/dev/null
sleep 20
check "the IP is allowed again after unbanning" "https | grep -q 'hello from the client'"

echo "== second run (nothing may change)"
if ! playbook | tee "$logs/run2.log"; then
  echo "FAIL second run (ansible-playbook exit code ${PIPESTATUS[0]})"
  fail=1
fi
changed=$(grep -E "^it-(server|client) +:" "$logs/run2.log" | grep -oE 'changed=[0-9]+' | cut -d= -f2 | awk '{s += $1} END {print s + 0}')
if [[ $changed -ne 0 ]]; then
  echo "FAIL second run changed $changed task(s):"
  grep -B1 -E '^changed: ' "$logs/run2.log" | grep -E '^TASK' || true
  fail=1
else
  echo "ok   second run changed nothing"
fi

echo "== check mode"
if playbook --check --diff >"$logs/check.log" 2>&1; then echo "ok   --check --diff passes"; else
  echo "FAIL --check --diff"
  grep -E '^(fatal|failed):' -A3 "$logs/check.log" | head -40
  fail=1
fi

echo "== new Caddy bouncer key"
new_key=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
playbook -e "crowdsec_api_key=$new_key" --tags caddy,crowdsec >"$logs/key.log" 2>&1 || {
  tail -30 "$logs/key.log"
  fail=1
}
check "Caddy uses the new key" "on $server 'grep -q \"api_key $new_key\" /etc/caddy/Caddyfile'"
check "the Local API accepts the new key" "on $server \"curl -s -o /dev/null -w '%{http_code}' -I -H 'X-Api-Key: $new_key' http://127.0.0.1:8080/v1/decisions\" | grep -q 200"
check "the site answers with the new key" "https | grep -q 'hello from the client'"

echo "== firewall off"
playbook -e enable_firewall=false --tags firewall >"$logs/off.log" 2>&1 || {
  tail -30 "$logs/off.log"
  fail=1
}
check "turning the firewall off removes it" "! on $server 'nft list tables' | grep -q webguard"
check "the site still answers" "https | grep -q 'hello from the client'"

exit $fail
