#!/bin/sh
# Deploy TimeTagger with its secrets fetched live from Proton Pass — same
# "nothing written to disk except at deploy time, via this script" pattern as
# scripts/pass-deploy.sh, but TimeTagger's stack needs one extra step that
# script doesn't do: oauth2-proxy's OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE
# has to be an actual FILE on disk (oauth2-proxy has no equivalent env var —
# confirmed from its source, pkg/apis/options/options.go only defines
# `authenticated-emails-file`), so this writes that file from the Pass
# item's ALLOWED_EMAIL field before bringing the stack up. Same class of
# per-app variant as scripts/pass-deploy-kopia-server.sh.
#
# Usage:
#   ./scripts/pass-deploy-timetagger.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$REPO_ROOT/timetagger"

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"
mkdir -p "$PROTON_PASS_SESSION_DIR"

if ! pass-cli info >/dev/null 2>&1; then
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "No active pass-cli session, and no $REPO_ROOT/.env to auto-login with." >&2
        exit 1
    fi
    echo "No active pass-cli session — logging in with SECRET_ACCESS_TOKEN from .env..."
    set -a
    . "$REPO_ROOT/.env"
    set +a
    export PROTON_PASS_PERSONAL_ACCESS_TOKEN="$SECRET_ACCESS_TOKEN"
    pass-cli login >/dev/null
    unset PROTON_PASS_PERSONAL_ACCESS_TOKEN SECRET_ACCESS_TOKEN
fi

echo "Fetching secrets for \"TimeTagger\" from Proton Pass..."

mkdir -p "$APP_DIR/oauth2-proxy"

EXPORTS=$(PROTON_PASS_AGENT_REASON="Fetching secrets to deploy timetagger" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "TimeTagger" --output json \
    | ALLOWED_EMAIL_FILE="$APP_DIR/oauth2-proxy/authenticated-emails.txt" python3 -c '
import json, os, sys, shlex

d = json.load(sys.stdin)
fields = {}
sections = d["item"]["content"]["content"]["Custom"]["sections"]
for section in sections:
    for f in section["section_fields"]:
        fields[f["name"]] = list(f["content"].values())[0]

allowed_email = fields.pop("ALLOWED_EMAIL")
with open(os.environ["ALLOWED_EMAIL_FILE"], "w") as f:
    f.write(allowed_email.strip() + "\n")
# 0o644, not 0o600: oauth2-proxy runs as a fixed non-root uid (distroless
# "nonroot" convention, uid 65532), and podman-machine rootless remapping
# only maps a container ROOT user to the host user, not a fixed non-root
# uid (see timetagger/compose.yaml file header) - 0600 left this file
# unreadable to that uid, confirmed live via a permission-denied error in
# oauth2-proxy logs. The file holds one email address, not a secret, so
# world-readable on this single-user Mac is a fine trade-off.
os.chmod(os.environ["ALLOWED_EMAIL_FILE"], 0o644)

for name, value in fields.items():
    print(f"export {name}={shlex.quote(value)}")
')

eval "$EXPORTS"

if [ "${OIDC_CLIENT_ID:-}" = "SET_ME_AFTER_IK_AUTH_REGISTRATION" ]; then
    echo "OIDC_CLIENT_ID/SECRET are still placeholders — register an OIDC app" >&2
    echo "in Infomaniak's IK-AUTH first, then set them on the \"TimeTagger\"" >&2
    echo "Pass item (see timetagger/.env.example)." >&2
    exit 1
fi

cd "$APP_DIR"
podman compose up -d
