#!/usr/bin/env bash
# Local checks in the development image: lint, tests and pre-commit run in a
# container, so the host needs only Docker and git. The repository is mounted at
# the same absolute path, the host Docker socket is forwarded, and ownership is
# restored afterwards (the container runs as root). The integration test runs
# in GitHub Actions only.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
IMAGE=${WEBGUARD_DEV_IMAGE:-ansible-rathole-webguard-dev:local}
SOCK=${DOCKER_SOCK:-/var/run/docker.sock}

usage() {
  cat <<'EOF'
Usage: ./docker.sh <command>

Commands:
  build        Build the development image
  lint         Run yamllint, ansible-lint and a playbook syntax check
  test         Run the test suite (tests/run.sh)
  pre-commit   Install hooks and run pre-commit over the repository
  all          Run lint, tests and pre-commit in one container
  shell        Open a bash shell in the container
EOF
}

# Linux only: the image and the same-path mount assume a Linux host daemon.
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "./docker.sh only supports Linux hosts (got $(uname -s))" >&2
  exit 1
fi

# Only a local, rootful Docker daemon is supported.
if [[ -n "${DOCKER_HOST:-}" && "$DOCKER_HOST" != "unix://$SOCK" ]]; then
  echo "./docker.sh requires a local rootful Docker daemon; DOCKER_HOST=$DOCKER_HOST is not supported" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "./docker.sh could not reach the Docker daemon (DOCKER_SOCK=$SOCK${DOCKER_HOST:+, DOCKER_HOST=$DOCKER_HOST})" >&2
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
    --tag "$IMAGE" "$REPO/docker"
}

# Extra docker run options for the current command.
extra=()

# Run one container with the common mounts plus command-specific options.
run_cmd() {
  mkdir -p "$REPO/.tmp"
  local -a argv=(--rm --init)
  argv+=(-v "$REPO:$REPO" -w "$REPO")
  argv+=(-e "TMPDIR=$REPO/.tmp")
  argv+=(-v "$SOCK:/var/run/docker.sock")
  # In a git worktree, .git is a file that points into the main repository's
  # git directory. Mount that directory at the same path so git works inside.
  if [[ -f "$REPO/.git" ]]; then
    local common
    common=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)
    argv+=(-v "$common:$common")
  fi
  argv+=(${extra[@]+"${extra[@]}"})
  argv+=("$IMAGE" "$@")
  docker run "${argv[@]}"
}

# Give the repository back to the host user. Failures here must not mask the
# command's exit status, but they must not stay silent either.
restore_owner() {
  if ! docker run --rm -v "$REPO:$REPO" -w "$REPO" "$IMAGE" \
    chown -R "$(id -u):$(id -g)" .; then
    echo "warning: could not restore repository ownership" >&2
  fi
}

status=0

# The pre-commit cache is a named volume by default; a path (anything with a
# slash) becomes a host directory so CI can share it via actions/cache.
PRECOMMIT_CACHE=${WEBGUARD_PRECOMMIT_CACHE:-webguard-dev-pre-commit}
if [[ "$PRECOMMIT_CACHE" == */* ]]; then
  mkdir -p "$PRECOMMIT_CACHE"
fi
precommit_mount=(-v "$PRECOMMIT_CACHE:/root/.cache/pre-commit")

case "$cmd" in
  build)
    build_image
    ;;
  lint)
    build_image
    extra=()
    run_cmd bash -c 'yamllint -s . && ansible-lint && ansible-playbook --syntax-check -i localhost, site.yml' || status=$?
    restore_owner
    exit "$status"
    ;;
  test)
    build_image
    extra=(--cap-add=NET_ADMIN)
    run_cmd ./tests/run.sh || status=$?
    restore_owner
    exit "$status"
    ;;
  pre-commit)
    build_image
    extra=("${precommit_mount[@]}")
    run_cmd bash -c 'pre-commit install-hooks && pre-commit run --all-files' || status=$?
    restore_owner
    exit "$status"
    ;;
  all)
    build_image
    extra=(--cap-add=NET_ADMIN "${precommit_mount[@]}")
    run_cmd bash -c 'yamllint -s . && ansible-lint && ansible-playbook --syntax-check -i localhost, site.yml && ./tests/run.sh && pre-commit install-hooks && pre-commit run --all-files' || status=$?
    restore_owner
    exit "$status"
    ;;
  shell)
    build_image
    extra=()
    if [[ -t 0 ]]; then
      extra+=(-it)
    fi
    run_cmd bash || status=$?
    restore_owner
    exit "$status"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
