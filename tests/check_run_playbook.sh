#!/usr/bin/env bash
# scripts/run-playbook.sh passes unknown options on to ansible-playbook.
# A stub ansible-playbook prints its arguments instead of running anything.
set -eu

cd "$(dirname "$0")/.."
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
printf '#!/bin/sh\necho "ARGS $*"\n' >"$stub_dir/ansible-playbook"
chmod +x "$stub_dir/ansible-playbook"

fail=0
check() {
  local expected=$1
  shift
  local got
  got=$(PATH="$stub_dir:$PATH" ./scripts/run-playbook.sh "$@" | grep '^ARGS ' || true)
  if [[ "$got" != "ARGS $expected" ]]; then
    echo "FAIL ($*): got '${got:-nothing}', expected 'ARGS $expected'"
    fail=1
  fi
}

check "-i inventory.ini site.yml" --no-vault
check "-i inventory.ini site.yml --ask-vault-pass"
check "-i inventory.ini site.yml --check --diff --limit home" --no-vault --check --diff --limit home
check "-i hosts.ini site.yml --vault-password-file pass.txt --tags caddy" --tags caddy --inventory hosts.ini --vault-file pass.txt
exit $fail
