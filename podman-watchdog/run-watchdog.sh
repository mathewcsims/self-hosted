#!/bin/sh
# Scheduled entrypoint for the Podman dead-man's-switch — run every 2
# minutes by uk.mathewcsims.podman-watchdog (LaunchAgent).
#
# The push token lives at ~/podman-watchdog/push-token (0600, outside the
# repo), NOT in Pass — unlike every other secret in this stack. Two
# reasons: it's low-sensitivity (a Kuma push token can only trigger
# "up"/"down" pings on one monitor, nothing else — worst case from a leak
# is a false status, not a security incident), and more importantly Pass
# writes need the user's own interactive session (agent PATs, including
# the ones used for every other automated run in this repo, are
# read-only by design — see SETUP.md's agent access model), so a script
# generating a monitor programmatically has nowhere to durably write it
# back to Pass without a human in the loop anyway. Same tradeoff already
# made for the MS Graph refresh-token cache in contact-sync.
set -eu

TOKEN_FILE="$HOME/podman-watchdog/push-token"
if [ ! -s "$TOKEN_FILE" ]; then
    echo "no push token at $TOKEN_FILE — watchdog not configured" >&2
    exit 1
fi

export KUMA_PUSH_TOKEN
KUMA_PUSH_TOKEN=$(cat "$TOKEN_FILE")

exec python3 "$(dirname "$0")/watchdog.py"
