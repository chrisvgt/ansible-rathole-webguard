#!/usr/bin/env bash
# Applies the firewall role in a Debian container with systemd and nftables,
# then disables it. The container has its own network namespace, so the host
# firewall is not touched. Needs Docker with --privileged and community.docker.
set -euo pipefail

cd "$(dirname "$0")/.."
image=firewall-systemd-test:debian12
name=firewall-systemd-test

work=$(mktemp -d)
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# Minimal Debian with systemd, nftables and Python for Ansible (no netbase, as
# on minimal server images; built once, reused); host network only for apt
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker rm -f "$name-build" >/dev/null 2>&1 || true
  docker run --name "$name-build" --network host debian:12 sh -c \
    'apt-get update -qq && apt-get install -y -qq --no-install-recommends systemd systemd-sysv nftables python3 python3-apt >/dev/null'
  docker commit "$name-build" "$image" >/dev/null
  docker rm "$name-build" >/dev/null
fi

docker run -d --name "$name" --privileged --network none --tmpfs /run --tmpfs /run/lock "$image" /lib/systemd/systemd >/dev/null
for _ in $(seq 30); do
  state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
  [[ $state == running || $state == degraded ]] && break
  sleep 1
done

# The rules need conntrack from the host kernel (missing e.g. after a kernel
# update without reboot)
probe_rules='table inet probe {
  chain input {
    type filter hook input priority filter;
    ct state established accept
  }
}'
if ! probe=$(docker exec -i "$name" nft -c -f - <<<"$probe_rules" 2>&1); then
  echo "$probe"
  echo "skipped (host kernel cannot load nft_ct; reboot after a kernel update)"
  # Never skip in CI: a skipped test must not look like a passed one
  [[ -z ${CI:-} ]] || exit 1
  exit 0
fi

printf '[fw]\n%s ansible_connection=community.docker.docker ansible_python_interpreter=/usr/bin/python3\n' "$name" >"$work/hosts.ini"
ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook -i "$work/hosts.ini" tests/firewall_systemd.yml
