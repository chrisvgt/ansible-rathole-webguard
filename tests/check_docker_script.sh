#!/usr/bin/env bash
# ./docker.sh wraps the development image in Docker. Its build and run
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
  PATH="$stub_dir:$PATH" "$repo/docker.sh" "$@"
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

check "build context"          "$repo/docker" build
check "python version"         "--build-arg PYTHON_VERSION=$(cat "$repo/.python-version")" build
check "lint commands"          "yamllint -s . && ansible-lint && ansible-playbook --syntax-check -i localhost, site.yml" lint
check "test command"           "./tests/run.sh" test
check "test NET_ADMIN"         "--cap-add=NET_ADMIN" test
check "test same-path mount"   "-v $repo:$repo" test
check "test TMPDIR"            "TMPDIR=$repo/.tmp" test
check "test socket"            "${DOCKER_SOCK:-/var/run/docker.sock}:/var/run/docker.sock" test
check "pre-commit cache"       "webguard-dev-pre-commit:/root/.cache/pre-commit" pre-commit
WEBGUARD_PRECOMMIT_CACHE=/tmp/pc-cache check "pre-commit cache path" "-v /tmp/pc-cache:/root/.cache/pre-commit" pre-commit
WEBGUARD_PRECOMMIT_CACHE=/tmp/pc-cache check "cache ownership fix" "-v /tmp/pc-cache:/tmp/pc-cache" pre-commit
unset WEBGUARD_PRECOMMIT_CACHE
check "all runs lint"          "yamllint -s . && ansible-lint" all
check "all runs tests"         "./tests/run.sh" all
check "all runs pre-commit"    "pre-commit run --all-files" all
check "shell command"          "bash" shell
check "lint ownership fix"     "chown -R $(id -u):$(id -g)" lint
check "test ownership fix"     "chown -R $(id -u):$(id -g)" test
check "pre-commit ownership"   "chown -R $(id -u):$(id -g)" pre-commit
check "all ownership fix"      "chown -R $(id -u):$(id -g)" all
check "shell ownership fix"    "chown -R $(id -u):$(id -g)" shell

# In a git worktree, .git is a file and its directory must be mounted too.
if [[ -f "$repo/.git" ]]; then
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
  check "worktree git mount"   "-v $common:$common" lint
fi

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
