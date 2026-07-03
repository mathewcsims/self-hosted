# Adapted from Ghost's official reference (github.com/TryGhost/ghost-docker,
# tinybird/Dockerfile) — the small helper image used for the one-time
# Tinybird schema sync/deploy steps (see ../compose.yaml's tinybird-sync/
# tinybird-deploy services and ../SETUP.md). Unlike Ghost's own reference,
# this doesn't install the interactive-login wrapper scripts — deploy here
# authenticates with a pre-existing admin token (TB_TOKEN) instead of
# `tb login`'s browser/device-code OAuth flow, which reliably failed to
# complete in this environment (see SETUP.md for why).
FROM python:3.14-slim@sha256:4ed33101ee7ec299041cc41dd268dae17031184be94384b1ce7936dc4e5dead3

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /data/tinybird

RUN curl https://tinybird.co | sh

ENV PATH="/root/.local/bin:$PATH"
