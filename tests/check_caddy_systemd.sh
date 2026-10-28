#!/usr/bin/env bash
# Starts the caddy role's systemd unit in a Debian container with systemd and
# checks that Caddy works inside the sandbox. Uses the official Caddy binary of
# caddy_version (no plugins); needs Docker with --privileged.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/^caddy_version: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' roles/caddy/defaults/main.yml)
image=caddy-systemd-test:debian12
name=caddy-systemd-test

work=$(mktemp -d)
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
ansible-playbook -i localhost, tests/caddy_unit_render.yml -e "out_dir=$work" >/dev/null
cp tests/caddy_container.sh "$work/"

# Caddy binary of the role's version
id=$(docker create "caddy:$version")
docker cp -q "$id:/usr/bin/caddy" "$work/caddy" 2>/dev/null
docker rm "$id" >/dev/null
chmod -R a+rX "$work"

# Debian with systemd (built once, reused); host network only for apt
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker rm -f "$name-build" >/dev/null 2>&1 || true
  docker run --name "$name-build" --network host debian:12 sh -c \
    'apt-get update -qq && apt-get install -y -qq --no-install-recommends systemd systemd-sysv curl ca-certificates >/dev/null'
  docker commit "$name-build" "$image" >/dev/null
  docker rm "$name-build" >/dev/null
fi

docker run -d --name "$name" --privileged --network none --tmpfs /run --tmpfs /run/lock \
  -v "$work:/t:ro" "$image" /lib/systemd/systemd >/dev/null
for _ in $(seq 30); do
  state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
  [[ $state == running || $state == degraded ]] && break
  sleep 1
done
docker exec "$name" bash /t/caddy_container.sh
