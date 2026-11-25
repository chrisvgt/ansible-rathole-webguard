# syntax=docker/dockerfile:1

# Base images are pinned by digest; Renovate updates tag and digest.
ARG PYTHON_IMAGE=python:3.15-slim-trixie@sha256:63bb298d2b7b88f176f51b5189f54ce6535c997682ea70885d2132f5d473a8a5

FROM docker:29.10.1-cli@sha256:4e60c31615e83523afbb59773b25d055c0da9edcd5f80a4c6a6eebad49de1a25 AS docker-cli

FROM ${PYTHON_IMAGE}

# ./docker.sh and CI pass .python-version; the build fails when it differs from
# the Python of the pinned image, so the two are bumped together.
ARG PYTHON_VERSION=3.14
RUN case "$(python -V)" in \
      "Python ${PYTHON_VERSION}" | "Python ${PYTHON_VERSION}."*) ;; \
      *) echo "PYTHON_IMAGE ($(python -V)) does not match .python-version (${PYTHON_VERSION})" >&2; exit 1 ;; \
    esac

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        libatomic1 \
        nftables \
        openssh-client \
        sudo \
        unzip \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

# The bind-mounted repository is owned by the host user; the container runs as root.
RUN git config --system --add safe.directory '*'

WORKDIR /work
CMD ["bash"]
