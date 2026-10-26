#!/usr/bin/env bash
# Run all test playbooks against the local test inventory.
set -euo pipefail

cd "$(dirname "$0")/.."
export ANSIBLE_ROLES_PATH="$PWD/roles"

for test in tests/test_*.yml; do
  echo "== $test"
  ansible-playbook -i tests/hosts.ini "$test"
done

echo "== no secrets in verbose output"
if ansible-playbook -v -i tests/hosts.ini tests/leak_check.yml 2>&1 | grep -q LEAKCHECK; then
  echo "secret value found in output"
  exit 1
fi

echo "== check mode on a new server"
ansible-playbook --check -i tests/hosts.ini tests/check_mode_server.yml

echo "== site.yml task order"
./tests/check_site_order.sh

echo "== run-playbook.sh options"
./tests/check_run_playbook.sh

# Example files, copied the way the README describes
example_dir=$(mktemp -d)
trap 'rm -rf "$example_dir"' EXIT
mkdir -p "$example_dir/group_vars"
cp inventory.example.ini "$example_dir/inventory.ini"
cp group_vars/all.example.yml "$example_dir/group_vars/all.yml"
cp group_vars/tunnel.example.yml "$example_dir/group_vars/tunnel_home.yml"
echo "== examples"
ansible-playbook -i "$example_dir/inventory.ini" tests/examples.yml -e "repo_dir=$PWD"

echo "== caddy unit in systemd"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  ./tests/check_caddy_systemd.sh
else
  echo "skipped (docker not available)"
fi
