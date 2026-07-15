#!/bin/sh
# One-time setup: creates the "Forgejo Claude Agent" Proton Pass item — a
# SEPARATE item from "Forgejo" (Mathew's own admin credentials), by
# design. This is the credential Claude Code agents running on this Mac
# use to reach Forgejo: a non-admin bot account (`claude-agent`), with a
# repo/issue-scoped API token rather than the account password, and zero
# repo access until explicitly granted per-repo as a collaborator. Keeping
# it a distinct Pass item (not extra fields bolted onto "Forgejo") means
# it can be rotated or revoked independently, and it's obvious at a glance
# what an agent credential can reach versus what the human admin account
# can reach.
#
# This script only generates BOT_PASSWORD (needed to create the account at
# all — never used again after creation, since the token is what agents
# actually authenticate with). The account itself and its scoped token are
# created afterward via `forgejo admin user create` / `generate-access-
# token` — see SETUP.md.
#
# Usage:
#   ./scripts/pass-create-forgejo-agent-secrets.sh
set -eu

BOT_PASSWORD=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')

python3 -c '
import json, sys

password = sys.argv[1]

template = {
    "title": "Forgejo Claude Agent",
    "note": "Non-admin bot account for Claude Code agents on this Mac to use against ~/self-hosted/forgejo/. Scoped API token (BOT_TOKEN), not the admin credentials in the separate \"Forgejo\" item. Zero repo access until added as a collaborator per-repo.",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "BOT_USERNAME", "field_type": "text", "value": "claude-agent"},
            {"field_name": "BOT_PASSWORD", "field_type": "hidden", "value": password},
        ],
    }],
}
json.dump(template, sys.stdout)
' "$BOT_PASSWORD" \
    | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Forgejo Claude Agent\""
