#!/usr/bin/env bash
# Run all test playbooks against the local test inventory.
set -euo pipefail

cd "$(dirname "$0")/.."
export ANSIBLE_ROLES_PATH="$PWD/roles"

for test in tests/test_*.yml; do
  echo "== $test"
  ansible-playbook -i tests/hosts.ini "$test"
done
