#!/usr/bin/env bash
# Full run of site.yml against a server and a client container (Debian 12,
# Debian 13 or Arch Linux with systemd, own network), then checks from the
# outside: site through the tunnel, CrowdSec bouncer, firewall, Caddy sandbox.
# A second run must change nothing, a check-mode run must pass, and turning the
# firewall off must remove it.
# The playbook runs like on real hosts: through scripts/run-playbook.sh, over
# SSH with host key checking, as a user with sudo on Debian and as root on Arch
# Linux.
# SERVER_OS and CLIENT_OS choose the system of each host: debian13 (default),
# debian12 or arch.
# Needs Docker with --privileged, network access and ssh.
set -euo pipefail

cd "$(dirname "$0")/.."
server_os=${SERVER_OS:-debian13}
client_os=${CLIENT_OS:-debian13}
# Arch Linux as published, with systemd but without Python, sudo and sshd
# renovate: datasource=docker depName=archlinux versioning=regex:^base-(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$
arch_image=archlinux:base-20261018.0.612668
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

# Debian like a minimal server image: systemd, sshd and sudo, but no Python,
# the playbook installs it itself (built once per release, reused)
debian_image() { # release
  local image=webguard-integration:debian$1-ssh
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker rm -f it-build >/dev/null 2>&1 || true
    docker run --name it-build "debian:$1" sh -c 'apt-get update -qq &&
      apt-get install -y -qq --no-install-recommends systemd systemd-sysv openssh-server sudo >/dev/null &&
      rm -rf /var/lib/apt/lists/*' >&2 || return
    docker commit it-build "$image" >/dev/null || return
    docker rm it-build >/dev/null
  fi
  echo "$image"
}

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

image_for() {
  case $1 in
    debian12 | debian13) debian_image "${1#debian}" ;;
    arch) echo "$arch_image" ;;
    *)
      echo "unknown OS: $1 (debian12, debian13 or arch)" >&2
      exit 2
      ;;
  esac
}
server_image=$(image_for "$server_os")
client_image=$(image_for "$client_os")
echo "== server: $server_os, client: $client_os"

docker network create "$net" >/dev/null
docker run -d --name "$server" --hostname "$server" --network "$net" --privileged \
  --tmpfs /run --tmpfs /run/lock ${mounts[@]+"${mounts[@]}"} "$server_image" /lib/systemd/systemd >/dev/null
docker run -d --name "$client" --hostname "$client" --network "$net" --privileged \
  --tmpfs /run --tmpfs /run/lock "$client_image" /lib/systemd/systemd >/dev/null
for host in "$server" "$client"; do
  for _ in $(seq 60); do
    state=$(docker exec "$host" systemctl is-system-running 2>/dev/null || true)
    [[ $state == running || $state == degraded ]] && break
    sleep 1
  done
done

# Test network only: Arch Linux resolves names with systemd-resolved, which
# does not know Docker's DNS for the container names (it-server)
for pair in "$server:$server_os" "$client:$client_os"; do
  [[ ${pair#*:} == arch ]] || continue
  docker exec "${pair%%:*}" sh -c 'mkdir -p /etc/systemd/resolved.conf.d &&
    printf "[Resolve]\nDNS=127.0.0.11\nResolveUnicastSingleLabel=yes\n" >/etc/systemd/resolved.conf.d/docker.conf &&
    systemctl restart systemd-resolved'
done

on() { docker exec "$1" bash -c "$2"; }
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

# SSH access like on real hosts: a key for this run, a user with sudo on
# Debian and root on Arch Linux. The hosts are reached through an own SSH
# config, so ~/.ssh/config and known_hosts of this computer are not used.
ssh-keygen -q -t ed25519 -N '' -C integration -f "$logs/id_ed25519"
: >"$logs/known_hosts"
: >"$logs/ssh_config"
for pair in "$server:$server_os" "$client:$client_os"; do
  host=${pair%%:*}
  if [[ ${pair#*:} == arch ]]; then
    user=root
    on "$host" 'pacman -Syu --noconfirm --needed openssh >/dev/null && systemctl enable --quiet --now sshd'
  else
    user=ansible
    on "$host" "useradd -m -s /bin/bash $user && echo '$user ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/$user &&
      chmod 0440 /etc/sudoers.d/$user && systemctl enable --quiet --now ssh"
  fi
  home=$(on "$host" "getent passwd $user | cut -d: -f6")
  on "$host" "install -d -m 0700 -o $user -g $user $home/.ssh"
  docker cp "$logs/id_ed25519.pub" "$host:$home/.ssh/authorized_keys"
  on "$host" "chown $user:$user $home/.ssh/authorized_keys && chmod 0600 $home/.ssh/authorized_keys"
  ip=$(ip_of "$host")
  for _ in $(seq 30); do
    keys=$(ssh-keyscan -T 2 "$ip" 2>/dev/null || true)
    [[ -n $keys ]] && break
    sleep 1
  done
  echo "$keys" >>"$logs/known_hosts"
  printf 'Host %s\n  HostName %s\n  User %s\n' "$host" "$ip" "$user" >>"$logs/ssh_config"
done
printf 'Host *\n  IdentityFile %s\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n' \
  "$logs/id_ed25519" "$logs/known_hosts" >>"$logs/ssh_config"

playbook() {
  ANSIBLE_FORCE_COLOR=0 ANSIBLE_SSH_COMMON_ARGS="-F $logs/ssh_config" \
    ./scripts/run-playbook.sh --no-vault --inventory tests/integration/hosts.ini ${extra[@]+"${extra[@]}"} "$@"
}

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
  for host in "$server" "$client"; do
    echo "--- failed units on $host"
    on "$host" 'for unit in $(systemctl list-units --failed --plain --no-legend | cut -d" " -f1); do journalctl -u "$unit" --no-pager -n 20; done' || true
  done
  exit 1
fi

# The service behind the tunnel, on the client. Started after the first run,
# which installs Python; Rathole connects to it on demand.
docker cp tests/integration/app.py "$client:/opt/app.py"
on "$client" 'systemd-run --unit it-app python3 /opt/app.py' >/dev/null
for _ in $(seq 30); do
  on "$client" 'curl -s --max-time 2 http://127.0.0.1:8080/' >/dev/null 2>&1 && break
  sleep 1
done

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
check "blocklist import is scheduled" "on $server 'systemctl is-active crowdsec-blocklist-import.timer'"
check "blocklist import ran successfully" "test \"\$(on $server 'systemctl show -p Result --value crowdsec-blocklist-import.service')\" = success"
on "$server" 'systemctl is-active crowdsec-blocklist-import.timer && test "$(systemctl show -p Result --value crowdsec-blocklist-import.service)" = success' >/dev/null 2>&1 ||
  on "$server" 'systemctl status --no-pager -n 20 crowdsec-blocklist-import.timer crowdsec-blocklist-import.service' || true
# A CrowdSec restart during the import invalidates its login
start_of() { on "$server" "systemctl show -p ExecMainStartTimestampMonotonic --value $1"; }
check "blocklist import started after the last CrowdSec restart" \
  "test \$(start_of crowdsec-blocklist-import.service) -gt \$(start_of crowdsec.service)"
check "blocklist import ran once" \
  "test \$(on $server 'journalctl -u crowdsec-blocklist-import.service --no-pager' | grep -c 'Completed in') -eq 1"
# The installed programs have the versions of the role defaults
default_of() { sed -n "s/^$2: \"v\{0,1\}\([^\"]*\)\".*/\1/p" "roles/$1/defaults/main.yml"; }
has_version() { # host, command, version
  [[ -n $3 ]] && on "$1" "$2" 2>&1 | grep -qE "(^|[^0-9.])v?${3//./\\.}([^0-9.]|$)"
}
version=$(default_of rathole rathole_version)
check "Rathole $version on the server" "has_version $server '/usr/local/bin/rathole --version' $version"
check "Rathole $version on the client" "has_version $client '/usr/local/bin/rathole --version' $version"
version=$(default_of caddy caddy_version)
check "Caddy $version" "has_version $server '/usr/local/bin/caddy version' $version"
version=$(default_of go_lang go_lang_version)
check "Go $version" "has_version $server '/usr/local/go/bin/go version' $version"
version=$(default_of xcaddy xcaddy_version)
check "xcaddy $version" "has_version $server '/usr/local/bin/xcaddy --version' $version"
crowdsec_versions() { # label, CrowdSec version, firewall bouncer version
  check "CrowdSec $2$1" "has_version $server 'crowdsec -version' $2"
  check "CrowdSec firewall bouncer $3$1" "has_version $server 'crowdsec-firewall-bouncer -V' $3"
}
crowdsec_versions "" "$(default_of crowdsec crowdsec_version)" "$(default_of crowdsec crowdsec_firewall_bouncer_version)"
version=$(default_of crowdsec_import crowdsec_import_version)
check "blocklist import $version" \
  "has_version $server '/opt/crowdsec-blocklist-import/bin/crowdsec-blocklist-import --version' $version"
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
# Arch Linux is a rolling release: packages published since the first run are
# a real change of the system upgrade, not of the playbook
changed_tasks() {
  awk '/^(TASK|RUNNING HANDLER) \[/ { task = $0 }
    /^changed: / && task !~ /Upgrade the system \(Arch Linux\)/ { print task }' "$1" | uniq
}
changed=$(changed_tasks "$logs/run2.log" | wc -l)
if [[ $changed -ne 0 ]]; then
  echo "FAIL second run changed $changed task(s):"
  changed_tasks "$logs/run2.log"
  fail=1
else
  echo "ok   second run changed nothing"
fi

echo "== check mode"
# A new ntfy token changes its file, so --diff would show it
if playbook --check --diff -e ntfy_auth_token=LEAKCHECK-NTFY >"$logs/check.log" 2>&1; then echo "ok   --check --diff passes"; else
  echo "FAIL --check --diff"
  grep -E '^(fatal|failed):' -A3 "$logs/check.log" | head -40
  fail=1
fi
check "--diff does not show the ntfy token" "! grep -q LEAKCHECK-NTFY '$logs/check.log'"

# Versions before the role defaults; also available on the APT repository.
# Before the key change: that key is only passed with -e, these runs use the
# stored one.
echo "== CrowdSec version change"
playbook -e crowdsec_version=1.8.0 -e crowdsec_firewall_bouncer_version=0.0.34 --tags crowdsec >"$logs/older.log" 2>&1 || {
  tail -30 "$logs/older.log"
  fail=1
}
crowdsec_versions " after the change to an older version" 1.8.0 0.0.34
playbook --tags crowdsec >"$logs/newer.log" 2>&1 || {
  tail -30 "$logs/newer.log"
  fail=1
}
crowdsec_versions " after the update" "$(default_of crowdsec crowdsec_version)" "$(default_of crowdsec crowdsec_firewall_bouncer_version)"
check "CrowdSec runs after the update" "on $server 'systemctl is-active crowdsec crowdsec-firewall-bouncer'"
check "the site answers after the update" "https | grep -q 'hello from the client'"

echo "== new Caddy bouncer key"
new_key=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
playbook -e "crowdsec_api_key=$new_key" --tags caddy,crowdsec >"$logs/key.log" 2>&1 || {
  tail -30 "$logs/key.log"
  fail=1
}
check "Caddy uses the new key" "on $server 'grep -q \"api_key $new_key\" /etc/caddy/Caddyfile'"
check "the Local API accepts the new key" "on $server \"curl -s -o /dev/null -w '%{http_code}' -I -H 'X-Api-Key: $new_key' http://127.0.0.1:8080/v1/decisions\" | grep -q 200"
check "the site answers with the new key" "https | grep -q 'hello from the client'"

echo "== firewall removed from the running system"
on "$server" 'nft delete table inet webguard'
playbook --tags rathole,firewall >"$logs/reload.log" 2>&1 || {
  tail -30 "$logs/reload.log"
  fail=1
}
check "a removed firewall is loaded again" "on $server 'nft list table inet webguard' >/dev/null"

echo "== firewall off"
playbook -e enable_firewall=false --tags firewall >"$logs/off.log" 2>&1 || {
  tail -30 "$logs/off.log"
  fail=1
}
check "turning the firewall off removes it" "! on $server 'nft list tables' | grep -q webguard"
check "the site still answers" "https | grep -q 'hello from the client'"

exit $fail
