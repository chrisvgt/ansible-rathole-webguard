#!/usr/bin/env bash
# Loads the crowdsec role's config into a real CrowdSec in Docker and checks
# hub content, bouncer key check, AppSec, failed login detection, whitelist and
# ban duration. Needs Docker and network access (CrowdSec hub).
set -euo pipefail

cd "$(dirname "$0")/.."
image=crowdsecurity/crowdsec:v1.8.1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ansible-playbook -i localhost, tests/crowdsec_render.yml -e "out_dir=$work/etc" >/dev/null
# Same collections as the role installs
grep -o 'cscli collections install [^ ]*' roles/crowdsec/tasks/main.yml | awk '{print $4}' >"$work/collections.txt"
cp tests/crowdsec_container.sh "$work/"
chmod -R a+rX "$work"

docker pull -q "$image" >/dev/null
# Host network: the container reaches the hub; test ports avoid the defaults
docker run --rm --network host --add-host home.example.test:198.51.100.20 \
  -v "$work:/t:ro" --entrypoint sh "$image" /t/crowdsec_container.sh
