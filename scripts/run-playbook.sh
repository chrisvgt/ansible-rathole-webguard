#!/usr/bin/env bash
# Helper to run the main ansible playbook with sensible defaults.
# Usage:
#   ./scripts/run-playbook.sh            # will prompt for vault password if needed
#   ./scripts/run-playbook.sh --no-vault # run without vault
#   ./scripts/run-playbook.sh --vault-file /path/to/vault_pass.txt
#   ./scripts/run-playbook.sh --inventory custom_inventory.ini

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PLAYBOOK="${PLAYBOOK:-site.yml}"
INVENTORY="${INVENTORY:-inventory.ini}"
VAULT_OPT=""

print_usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --no-vault           Run without passing any vault option
  --vault-file <file>  Use a vault password file (ansible-playbook --vault-password-file)
  --inventory <file>   Specify inventory file (default: inventory.ini)
  --playbook <file>    Specify playbook file (default: site.yml)
  -h|--help            Show this help message

Examples:
  $0
  $0 --vault-file ~/.vault_pass.txt
  $0 --no-vault
  $0 --inventory hosts.ini --playbook site.yml
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-vault)
      VAULT_OPT=""
      NO_VAULT=true
      shift
      ;;
    --vault-file)
      VAULT_FILE="$2"
      if [[ -z "$VAULT_FILE" ]]; then
        echo "--vault-file requires a file path"
        exit 2
      fi
      VAULT_OPT=("--vault-password-file" "$VAULT_FILE")
      shift 2
      ;;
    --inventory)
      INVENTORY="$2"
      shift 2
      ;;
    --playbook)
      PLAYBOOK="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      print_usage
      exit 2
      ;;
  esac
done

cd "$REPO_ROOT"

CMD=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK")
if [[ ${NO_VAULT:-false} == true ]]; then
  echo "Running without Ansible Vault options"
else
  if [[ -n "${VAULT_FILE:-}" ]]; then
    CMD+=("--vault-password-file" "$VAULT_FILE")
  else
    # default: prompt for vault password when needed
    CMD+=("--ask-vault-pass")
  fi
fi

echo "Running: ${CMD[*]}"
exec "${CMD[@]}"
