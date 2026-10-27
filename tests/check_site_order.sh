#!/usr/bin/env bash
# site.yml must apply global defaults and validate tunnel tuples before any role
# runs, also when only some tags are selected.
set -eu

cd "$(dirname "$0")/.."
fail=0
for tags in all caddy rathole; do
  tasks=$(ansible-playbook -i tests/hosts.ini site.yml --list-tasks --tags "$tags" 2>/dev/null)
  defaults=$({ grep -n "Set defaults for global settings" <<<"$tasks" || true; } | head -1 | cut -d: -f1)
  validate=$({ grep -n "Validate tunnel tuple settings" <<<"$tasks" || true; } | head -1 | cut -d: -f1)
  first_role=$({ grep -nE "^\s+(caddy|crowdsec|crowdsec_import|rathole|system|go_lang|xcaddy) : " <<<"$tasks" || true; } | grep -v "Validate tunnel tuple" | head -1 | cut -d: -f1)
  if [[ -z "$defaults" || -z "$validate" || -z "$first_role" || "$defaults" -gt "$first_role" || "$validate" -gt "$first_role" ]]; then
    echo "FAIL (--tags $tags): defaults=${defaults:-missing} validate=${validate:-missing} first_role=${first_role:-none}"
    fail=1
  fi
done

# Arch Linux removes the modules of the running kernel when it upgrades it: the
# reboot into the new kernel comes before the roles, which need modules (nftables)
tasks=$(ansible-playbook -i tests/hosts.ini site.yml --list-tasks 2>/dev/null)
reboot=$({ grep -n "Reboot into the new kernel (Arch Linux)" <<<"$tasks" || true; } | head -1 | cut -d: -f1)
first_role=$({ grep -nE "^\s+(caddy|crowdsec|crowdsec_import|rathole|system|go_lang|xcaddy|firewall) : " <<<"$tasks" || true; } |
  grep -v "TAGS: \[always\]" | head -1 | cut -d: -f1) # Not the preflight checks
if [[ -z "$reboot" || -z "$first_role" || "$reboot" -gt "$first_role" ]]; then
  echo "FAIL: Arch Linux reboot=${reboot:-missing} first_role=${first_role:-none}"
  fail=1
fi
exit $fail
