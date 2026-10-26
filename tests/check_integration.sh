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
logs=$(mktemp -d)

cleanup() {
  docker rm -f "$server" "$client" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$logs"
}
trap cleanup EXIT
cleanup

# Debian with systemd and what Ansible needs (built once, reused)
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker rm -f it-build >/dev/null 2>&1 || true
  docker run --name it-build debian:12 sh -c \
    'apt-get update -qq && apt-get install -y -qq --no-install-recommends systemd systemd-sysv python3 python3-apt sudo ca-certificates curl >/dev/null'
  docker commit it-build "$image" >/dev/null
  docker rm it-build >/dev/null
fi

docker network create "$net" >/dev/null
for host in "$server" "$client"; do
  docker run -d --name "$host" --hostname "$host" --network "$net" --privileged \
    --tmpfs /run --tmpfs /run/lock "$image" /lib/systemd/systemd >/dev/null
done
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
    ansible-playbook -i tests/integration/hosts.ini site.yml "$@"
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
playbook | tee "$logs/run1.log"

server_ip=$(ip_of "$server")
client_ip=$(ip_of "$client")
https() { on "$client" "curl -sk --max-time 5 --resolve web.test:443:$server_ip $* https://web.test/"; }

echo "== checks"
check "server services are active" "on $server 'systemctl is-active caddy crowdsec crowdsec-firewall-bouncer rathole'"
check "client tunnel is active" "on $client 'systemctl is-active rathole'"
check "site answers through the tunnel" "https | grep -q 'hello from the client'"
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

on "$server" "cscli decisions add --ip $client_ip --duration 10m" >/dev/null
sleep 20 # Caddy bouncer polls every 15 s
check "a banned IP is blocked" "! https | grep -q 'hello from the client'"
on "$server" "cscli decisions delete --ip $client_ip" >/dev/null
sleep 20
check "the IP is allowed again after unbanning" "https | grep -q 'hello from the client'"

echo "== second run (nothing may change)"
playbook | tee "$logs/run2.log"
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

echo "== firewall off"
playbook -e enable_firewall=false --tags firewall >"$logs/off.log" 2>&1 || {
  tail -30 "$logs/off.log"
  fail=1
}
check "turning the firewall off removes it" "! on $server 'nft list tables' | grep -q webguard"
check "the site still answers" "https | grep -q 'hello from the client'"

exit $fail
