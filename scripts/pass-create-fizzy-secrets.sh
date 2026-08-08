#!/bin/sh
# One-time setup: creates the "Fizzy" Proton Pass item.
#
#   ./scripts/pass-create-fizzy-secrets.sh
#
# Unlike pass-create-ntfy-secrets.sh, the value is GENERATED here rather than
# taken from the environment — SECRET_KEY_BASE isn't chosen inside the app,
# it's just a long unguessable string the app is handed. Rails derives every
# other secret from it (signed/encrypted cookies, Active Record encryption,
# secure link tokens), so rotating it invalidates all sessions and any
# encrypted-at-rest column. Treat it as permanent.
#
# NOT SET HERE: VAPID_PRIVATE_KEY / VAPID_PUBLIC_KEY, which Fizzy uses for
# Web Push. Generating them needs a Rails console inside the running
# container (`bin/rails c` then `WebPush.generate_key`), so it can't be done
# before first boot. Fizzy runs fine without them — push notifications are
# simply unavailable. Add them later if wanted; see fizzy/compose.yaml.
set -eu

SECRET_KEY_BASE=$(openssl rand -hex 64)
export SECRET_KEY_BASE

python3 -c '
import json, os, sys

template = {
    "title": "Fizzy",
    "note": "self-hosted Kanban backlog (37signals Fizzy) — see ~/self-hosted/fizzy/. https://fizzy.mathewcsims.uk (LAN/tailnet only). Single-account mode: signups close automatically once the first account exists. No SMTP configured, so sign-in codes appear in the container log: podman logs fizzy | grep -i code",
    "sections": [{
        "section_name": "Secrets",
        "fields": [
            {"field_name": "SECRET_KEY_BASE", "field_type": "hidden", "value": os.environ["SECRET_KEY_BASE"]},
        ],
    }],
}
json.dump(template, sys.stdout)
' | pass-cli item create custom --vault-name "Self-Hosted Secrets" --from-template - >/dev/null
# Output suppressed: `item create` echoes the created item back, secrets included.

unset SECRET_KEY_BASE

echo "Done. Verify with:"
echo "  pass-cli item view --vault-name \"Self-Hosted Secrets\" --item-title \"Fizzy\""
