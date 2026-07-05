#!/bin/sh
# One-time bootstrap, then runs the real server. Idempotent — safe to run
# on every container start.
#
# Repository connect/create and TLS cert generation both need to happen
# exactly once (the first time this bucket/host is ever used) and be
# skipped on every subsequent start, since their state persists in the
# /app/config volume. `kopia repository connect b2` fails if no repository
# exists yet at that bucket, so the first-ever run (this Pi, first boot)
# falls through to `create` instead.
set -eu

CONFIG_DIR=/app/config
CERT_FILE="$CONFIG_DIR/kopia-server.cert"
KEY_FILE="$CONFIG_DIR/kopia-server.key"

if [ ! -f "$CONFIG_DIR/repository.config" ]; then
    echo "No existing repository config — trying to connect to an existing B2 repository..."
    if ! kopia repository connect b2 \
        --bucket="$B2_BUCKET" \
        --key-id="$B2_KEY_ID" \
        --key="$B2_APPLICATION_KEY"; then
        echo "Connect failed — creating a new repository (first-ever run for this bucket)..."
        kopia repository create b2 \
            --bucket="$B2_BUCKET" \
            --key-id="$B2_KEY_ID" \
            --key="$B2_APPLICATION_KEY"

        # This Pi is always-on (unlike the Mac, which only backs up on a
        # launchd schedule), so it's the right host to own maintenance
        # (garbage collection) — see SETUP.md's Kopia section for why this
        # matters in a multi-host repository.
        kopia maintenance set --owner=me

        # Sensible defaults for a personal homelab, adjustable later from
        # the web UI — daily-cadence retention, since sources below snapshot
        # once a day.
        kopia policy set --global \
            --keep-latest=5 \
            --keep-daily=30 \
            --keep-weekly=12 \
            --keep-monthly=24 \
            --keep-annual=3

        for source_path in /data/*/; do
            name=$(basename "$source_path")
            echo "Configuring daily snapshot schedule for $name..."
            kopia policy set "$source_path" --snapshot-interval=24h
            kopia snapshot create "$source_path"
        done
    fi
fi

TLS_ARGS=""
if [ ! -f "$CERT_FILE" ]; then
    TLS_ARGS="--tls-generate-cert"
fi

# shellcheck disable=SC2086
exec kopia server start \
    $TLS_ARGS \
    --tls-cert-file="$CERT_FILE" \
    --tls-key-file="$KEY_FILE" \
    --address=0.0.0.0:51515 \
    --server-username="$WEBUI_USERNAME" \
    --server-password="$WEBUI_PASSWORD" \
    --server-control-username=control \
    --server-control-password="$SERVER_CONTROL_PASSWORD"
