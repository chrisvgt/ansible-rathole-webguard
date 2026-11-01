#!/usr/bin/env bash
# Wrapper around the containerized development environment. Every command
# builds the dev image first, then runs the corresponding tool inside it so
# local runs match CI exactly. The repository is mounted at the same absolute
# path, the host Docker socket is forwarded, and ownership is restored after
# commands that can write into the repository (the container runs as root).
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
IMAGE=${WEBGUARD_DEV_IMAGE:-ansible-rathole-webguard-dev:local}
SOCK=${DOCKER_SOCK:-/var/run/docker.sock}
NET=${WEBGUARD_NETWORK:-webguard-it}

usage() {
  cat <<'EOF'
Usage: scripts/dev.sh <command> [args...]

Commands:
  build        Build the development image
  lint         Run yamllint, ansible-lint and a playbook syntax check
  test         Run the test suite (tests/run.sh)
  pre-commit   Install hooks and run pre-commit over the repository
  all          Run lint, tests and pre-commit in one container
  integration  Run the full integration test (tests/check_integration.sh)
  coverage     Run the task-coverage report (tests/coverage.py)
  playbook     Run scripts/run-playbook.sh inside the container
  shell        Open a bash shell in the container
EOF
}

# Linux only: the image and the same-path mount assume a Linux host daemon.
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "scripts/dev.sh only supports Linux hosts (got $(uname -s))" >&2
  exit 1
fi

# Only a local, rootful Docker daemon is supported.
if [[ -n "${DOCKER_HOST:-}" && "$DOCKER_HOST" != "unix://$SOCK" ]]; then
  echo "scripts/dev.sh requires a local rootful Docker daemon; DOCKER_HOST=$DOCKER_HOST is not supported" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "scripts/dev.sh could not reach the Docker daemon (DOCKER_SOCK=$SOCK${DOCKER_HOST:+, DOCKER_HOST=$DOCKER_HOST})" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi
cmd=$1
shift

build_image() {
  docker build --build-arg PYTHON_VERSION="$(cat "$REPO/.python-version")" \
    --tag "$IMAGE" "$REPO/docker/dev"
}

# Extra docker run options for the current command.
extra=()

# Run one container with the common mounts/environment plus command-specific
# options and any forwarded environment variables.
run_cmd() {
  mkdir -p "$REPO/.tmp"
  local -a argv=(--rm --init)
  argv+=(-v "$REPO:$REPO" -w "$REPO")
  argv+=(-e "TMPDIR=$REPO/.tmp")
  argv+=(-v "$SOCK:/var/run/docker.sock")
  local var
  for var in CI SERVER_OS CLIENT_OS TASK_COVERAGE_FILE ANSIBLE_CALLBACK_PLUGINS ANSIBLE_CALLBACKS_ENABLED GITHUB_ACTIONS GITHUB_TOKEN; do
    if [[ -n "${!var:-}" ]]; then
      argv+=(-e "$var=${!var}")
    fi
  done
  argv+=(${extra[@]+"${extra[@]}"})
  local -a dev_args
  read -r -a dev_args <<<"${DEV_DOCKER_ARGS:-}"
  argv+=(${dev_args[@]+"${dev_args[@]}"})
  argv+=("$IMAGE" "$@")
  docker run "${argv[@]}"
}

# Restore repository ownership after commands that can write into it. Failures
# here must not mask the command's exit status.
restore_owner() {
  docker run --rm -v "$REPO:$REPO" -w "$REPO" "$IMAGE" \
    chown -R "$(id -u):$(id -g)" . || true
}

status=0

case "$cmd" in
  build)
    build_image
    ;;
  lint)
    build_image
    extra=()
    run_cmd bash -c 'yamllint -s . && ansible-lint && ansible-playbook --syntax-check -i localhost, site.yml'
    ;;
  test)
    build_image
    extra=(--cap-add=NET_ADMIN)
    run_cmd ./tests/run.sh
    ;;
  pre-commit)
    build_image
    extra=(-v webguard-dev-pre-commit:/root/.cache/pre-commit)
    run_cmd bash -c 'pre-commit install-hooks && pre-commit run --all-files' || status=$?
    restore_owner
    exit "$status"
    ;;
  all)
    build_image
    extra=(--cap-add=NET_ADMIN -v webguard-dev-pre-commit:/root/.cache/pre-commit)
    run_cmd bash -c 'yamllint -s . && ansible-lint && ansible-playbook --syntax-check -i localhost, site.yml && ./tests/run.sh && pre-commit install-hooks && pre-commit run --all-files' || status=$?
    restore_owner
    exit "$status"
    ;;
  integration)
    build_image
    docker network create "$NET" 2>/dev/null || true
    extra=(--network "$NET" -e "WEBGUARD_NETWORK=$NET" -e "WEBGUARD_KEEP_NETWORK=1")
    run_cmd ./tests/check_integration.sh "$@" || status=$?
    docker network rm "$NET" >/dev/null 2>&1 || true
    restore_owner
    exit "$status"
    ;;
  coverage)
    build_image
    extra=()
    run_cmd python3 tests/coverage.py "$@" || status=$?
    restore_owner
    exit "$status"
    ;;
  playbook)
    build_image
    extra=()
    if [[ -t 0 ]]; then
      extra+=(-it)
    fi
    if [[ -e "$HOME/.ssh" ]]; then
      extra+=(-v "$HOME/.ssh:/root/.ssh:ro")
    fi
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
      extra+=(-v "$SSH_AUTH_SOCK:/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent)
    fi
    run_cmd ./scripts/run-playbook.sh "$@"
    ;;
  shell)
    build_image
    extra=()
    if [[ -t 0 ]]; then
      extra+=(-it)
    fi
    run_cmd bash
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
