#!/usr/bin/env python3
"""Write a value into Owl's (Memos) generalSetting.additionalScript field.

This follows the non-merging-PATCH pattern already documented in SETUP.md
(the Owl and per-instance-theming sections): PATCH /api/v1/instance/settings/
GENERAL does NOT do a true partial merge — sending only the field you want
to change blanks every other GENERAL field (disallowUserRegistration,
disallowPasswordAuth, customProfile) back to its zero value. So this always
fetches the full current object first, changes only additionalScript in the
parsed JSON, and PATCHes the complete object back — never a narrow PATCH.

Auth: a Personal Access Token generated in Owl's own web UI (Settings ▸ My
Account ▸ Access Tokens), same mechanism SETUP.md documents for the
additionalStyle theme deploy. Not stored in Pass by this script — pass it
via the OWL_MEMOS_PAT environment variable each time you run this, or export
it yourself from wherever you keep it.

Usage:
    OWL_MEMOS_PAT=... python3 deploy_additional_script.py "<script content>"
"""
import json
import os
import sys
import urllib.request
import urllib.error

# Reached via its public Caddy hostname, not a raw Mac LAN IP — resolves
# to the Pi's LAN IP for LAN clients via the existing NextDNS rewrite (no
# WAN round-trip), same mechanism already used elsewhere in this repo
# (e.g. contact-sync/trivy-scan reaching Apprise via apprise.mathewcsims.uk).
OWL_BASE_URL = os.environ.get("OWL_BASE_URL", "https://owl.mathewcsims.uk")
SETTINGS_PATH = "/api/v1/instance/settings/GENERAL"


def call(method, path, token, body=None):
    url = f"{OWL_BASE_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> HTTP {e.code}: {e.read().decode()}")


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: deploy_additional_script.py '<script content>'")
    script_content = sys.argv[1]

    token = os.environ.get("OWL_MEMOS_PAT")
    if not token:
        sys.exit(
            "OWL_MEMOS_PAT not set — generate one in Owl's web UI "
            "(Settings > My Account > Access Tokens) and export it first."
        )

    current = call("GET", SETTINGS_PATH, token)
    general = current.get("generalSetting", {})

    before_snapshot = {
        "disallowUserRegistration": general.get("disallowUserRegistration"),
        "disallowPasswordAuth": general.get("disallowPasswordAuth"),
        "customProfile": general.get("customProfile"),
        "additionalStyle": general.get("additionalStyle"),
    }

    general["additionalScript"] = script_content
    body = {"name": "instance/settings/GENERAL", "generalSetting": general}

    call("PATCH", SETTINGS_PATH, token, body)

    after = call("GET", SETTINGS_PATH, token)
    after_general = after.get("generalSetting", {})
    after_snapshot = {
        "disallowUserRegistration": after_general.get("disallowUserRegistration"),
        "disallowPasswordAuth": after_general.get("disallowPasswordAuth"),
        "customProfile": after_general.get("customProfile"),
        "additionalStyle": after_general.get("additionalStyle"),
    }

    if before_snapshot != after_snapshot:
        sys.exit(
            "additionalScript was written, but at least one OTHER "
            "GENERAL field changed unexpectedly (the non-merging-PATCH "
            f"gotcha). Before: {before_snapshot}\nAfter: {after_snapshot}"
        )

    if after_general.get("additionalScript") != script_content:
        sys.exit("additionalScript was PATCHed but does not read back as expected.")

    print("additionalScript deployed; all other GENERAL fields unchanged.")


if __name__ == "__main__":
    main()
