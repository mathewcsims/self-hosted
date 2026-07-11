#!/bin/sh
# Run daily by reboot-check.timer. Best-effort, no retry — same
# curl-to-Apprise pattern reused everywhere else in this repo
# (vikunja-webhook-relay/relay.py, pi-fail2ban/notify-apprise.sh).
if [ -e /var/run/reboot-required ]; then
    PACKAGES="(package list unavailable)"
    if [ -e /var/run/reboot-required.pkgs ]; then
        PACKAGES=$(sed 's/^/- /' /var/run/reboot-required.pkgs)
    fi
    BODY="unattended-upgrades applied updates that need a reboot to take effect.

**Packages:**
${PACKAGES}"
    curl -fsS --max-time 10 \
        --data-urlencode "title=⚠️ babel needs a reboot" \
        --data-urlencode "type=warning" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=${BODY}" \
        https://apprise.mathewcsims.uk/notify/self-hosted >/dev/null 2>&1 || true
fi
