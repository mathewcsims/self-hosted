#!/bin/sh
# One-time migration helper: reads an app's existing .env file directly and
# creates (or would create) the equivalent "one item per app" custom item in
# Proton Pass, via `pass-cli item create custom --from-template -` (stdin) —
# the JSON template is built in-memory and piped straight in, never written
# to disk as an intermediate file.
#
# Deliberately NOT run by the agent — pass-cli agent PATs are read-only by
# design (Proton Pass's own AI-agent safety model: "AI agents receive
# read-only permissions for assigned vaults and cannot create, edit, or
# modify stored items"), so item creation has to happen under your own
# personal pass-cli session, not the agent one used elsewhere in this repo's
# tooling.
#
# Usage:
#   ./scripts/pass-import-env.sh <app-dir> [item-title]
#
# Example:
#   ./scripts/pass-import-env.sh vikunja
#   ./scripts/pass-import-env.sh speedtest-tracker SpeedtestTracker

set -eu

APP_DIR="${1:?Usage: $0 <app-dir> [item-title]}"
ENV_FILE="$APP_DIR/.env"
ITEM_TITLE="${2:-$(echo "$APP_DIR" | python3 -c 'import sys; print("".join(w.capitalize() for w in sys.stdin.read().strip().split("-")))')}"

if [ ! -f "$ENV_FILE" ]; then
    echo "No .env file at $ENV_FILE" >&2
    exit 1
fi

echo "Importing $ENV_FILE as Pass item \"$ITEM_TITLE\" in vault \"Self-Hosted Secrets\"..."

python3 -c '
import json, re, sys

env_file, title = sys.argv[1], sys.argv[2]
with open(env_file) as f:
    content = f.read()

fields = []
for m in re.finditer(r"^([A-Z_]+)=(.*)$", content, re.MULTILINE):
    fields.append({"field_name": m.group(1), "field_type": "hidden", "value": m.group(2).strip()})

template = {
    "title": title,
    "note": f"self-hosted repo secrets — see ~/self-hosted/{sys.argv[3]}/",
    "sections": [{"section_name": "Secrets", "fields": fields}],
}
json.dump(template, sys.stdout)
' "$ENV_FILE" "$ITEM_TITLE" "$APP_DIR" | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"$ITEM_TITLE\""
