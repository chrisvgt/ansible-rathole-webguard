# syntax=docker/dockerfile:1

# The Python version is passed by ./docker.sh from .python-version.
ARG PYTHON_VERSION=3.14

FROM docker:29.9.2-cli AS docker-cli

FROM python:${PYTHON_VERSION}-slim-trixie

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
