#!/usr/bin/env bash
# scripts/dev.sh wraps the development image in Docker. Its build and run
# commands are asserted against a stub `docker` that only prints its arguments.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd -P)
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

cat >"$stub_dir/docker" <<'STUB'
#!/bin/sh
if [ -n "${STUB_DOCKER_INFO_FAIL:-}" ] && [ "$1" = "info" ]; then
  exit 1
fi
echo "DOCKER $*"
STUB
chmod +x "$stub_dir/docker"

cat >"$stub_dir/uname" <<'STUB'
#!/bin/sh
if [ -n "${STUB_UNAME:-}" ]; then
  echo "$STUB_UNAME"
else
  echo "Linux"
fi
STUB
chmod +x "$stub_dir/uname"

fail=0

run() {
  PATH="$stub_dir:$PATH" ./scripts/dev.sh "$@"
}

check() {
  local desc=$1 expected=$2
  shift 2
  local out
  out=$(run "$@")
  if [[ "$out" != *"$expected"* ]]; then
    echo "FAIL ($desc): output does not contain '$expected'"
    echo "----- output -----"
    echo "$out"
    echo "------------------"
    fail=1
  fi
}

expect_fail() {
  local desc=$1 expected=$2
  shift 2
  local out status=0
  out=$(run "$@" 2>&1) || status=$?
  if [[ $status -eq 0 ]]; then
    echo "FAIL ($desc): expected a non-zero exit, got 0"
    fail=1
  fi
  if [[ "$out" != *"$expected"* ]]; then
    echo "FAIL ($desc): output does not contain '$expected'"
    echo "----- output -----"
    echo "$out"
    echo "------------------"
    fail=1
  fi
}

check "build context"          "docker/dev" build
check "lint commands"          "yamllint -s . && ansible-lint && ansible-playbook --syntax-check -i localhost, site.yml" lint
check "test command"           "./tests/run.sh" test
check "test NET_ADMIN"         "--cap-add=NET_ADMIN" test
check "test same-path mount"   "-v $repo:$repo" test
check "test TMPDIR"            "TMPDIR=$repo/.tmp" test
check "test socket"            "${DOCKER_SOCK:-/var/run/docker.sock}:/var/run/docker.sock" test
check "pre-commit cache"       "webguard-dev-pre-commit:/root/.cache/pre-commit" pre-commit
check "integration network"    "--network webguard-it" integration
check "integration keeps net"  "WEBGUARD_KEEP_NETWORK=1" integration
check "integration network var" "WEBGUARD_NETWORK=webguard-it" integration
check "integration creates"    "network create webguard-it" integration
check "coverage command"       "python3 tests/coverage.py task-coverage.txt --min 90" coverage task-coverage.txt --min 90
check "playbook command"       "./scripts/run-playbook.sh --no-vault" playbook --no-vault
check "shell command"          "bash" shell
check "all runs lint"          "yamllint -s ." all
check "all runs tests"         "./tests/run.sh" all
check "all runs pre-commit"    "pre-commit run --all-files" all
check "ownership fix"          "chown -R $(id -u):$(id -g)" coverage task-coverage.txt

# Environment forwarding when a supported variable is set.
export TASK_COVERAGE_FILE=/tmp/task-coverage.txt
check "CI env forwarded" "-e TASK_COVERAGE_FILE=/tmp/task-coverage.txt" coverage task-coverage.txt
unset TASK_COVERAGE_FILE

# Refuse non-Linux hosts.
STUB_UNAME=Darwin expect_fail "non-Linux host" "Linux" build
# Refuse a remote/rootless Docker daemon.
DOCKER_HOST=tcp://203.0.113.5:2375 expect_fail "remote Docker host" "not supported" build
# Refuse when the daemon is unreachable.
STUB_DOCKER_INFO_FAIL=1 expect_fail "daemon down" "Docker daemon" build

# Unknown command: exit code 2 and a usage message.
status=0
out=$(run bogus 2>&1) || status=$?
if [[ $status -ne 2 ]]; then
  echo "FAIL (unknown command): exit $status, expected 2"
  fail=1
fi
if [[ "$out" != *"Usage"* ]]; then
  echo "FAIL (unknown command): output does not contain 'Usage'"
  echo "----- output -----"
  echo "$out"
  echo "------------------"
  fail=1
fi

exit $fail
