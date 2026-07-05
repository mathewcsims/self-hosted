#!/bin/sh
# Like pass-import-env.sh, but for secrets that are a whole config file
# rather than KEY=value pairs — e.g. copyparty's accounts.conf. Creates a
# single-field custom item holding the entire file's content.
#
# Same read-only-agent caveat as pass-import-env.sh: run this under your
# own personal pass-cli session, not the agent one.
#
# Usage:
#   ./scripts/pass-import-file.sh <local-file> <item-title> <field-name>
#
# Example:
#   ./scripts/pass-import-file.sh copyparty/cfg/accounts.conf Copyparty ACCOUNTS_CONF

set -eu

FILE="${1:?Usage: $0 <local-file> <item-title> <field-name>}"
TITLE="${2:?Usage: $0 <local-file> <item-title> <field-name>}"
FIELD="${3:?Usage: $0 <local-file> <item-title> <field-name>}"

if [ ! -f "$FILE" ]; then
    echo "No file at $FILE" >&2
    exit 1
fi

echo "Importing $FILE as Pass item \"$TITLE\" (field: $FIELD) in vault \"Self-Hosted Secrets\"..."

python3 -c '
import json, sys

path, title, field, source = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()

template = {
    "title": title,
    "note": f"Whole-file secret — see {source}",
    "sections": [{"section_name": "Secrets", "fields": [
        {"field_name": field, "field_type": "hidden", "value": content}
    ]}],
}
json.dump(template, sys.stdout)
' "$FILE" "$TITLE" "$FIELD" "$FILE" | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template -

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"$TITLE\""
