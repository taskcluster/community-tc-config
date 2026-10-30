# The tools that imageset.sh runs with (see run.sh), so that it doesn't depend
# on how the host is set up. imageset.sh builds it, and rebuilds it each week
# (TOOLS_WEEK), to update the tools. The scripts aren't part of the image: they
# are run from the clone of this repository that imageset.sh mounts.

FROM ubuntu:24.04

LABEL org.mozilla.community-tc-imagesets=true

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg iproute2 lsb-release openssh-client openssl openvpn pass python3 python3-pip socat unzip \
 && rm -rf /var/lib/apt/lists/*

# Changed by imageset.sh each week, so that the tools below are updated
ARG TOOLS_WEEK=unset

RUN set -eux; \
    install -d -m 755 /etc/apt/keyrings; \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/google-cloud.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/azure-cli.list; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends azure-cli gh google-cloud-cli; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip; \
    unzip -q /tmp/awscli.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/aws /tmp/awscli.zip

# What this repository's scripts need (setup.py), so that run.sh's install of
# it is quick, and Playwright, with headless Chromium, for login.mozilla.com's
# Duo prompt (see vpn.py)
RUN pip install --no-cache-dir --break-system-packages \
      playwright 'tc-admin>=5.2.1' 'json-e>=4.7.1' ruamel.yaml requests pytest \
 && playwright install --with-deps --only-shell chromium \
 && rm -rf /var/lib/apt/lists/*
