#!/bin/sh
# Run daily by reboot-check.timer. Best-effort, no retry — same
# curl-to-Apprise pattern reused everywhere else in this repo
# (vikunja-webhook-relay/relay.py, pi-fail2ban/notify-apprise.sh).
if [ -e /var/run/reboot-required ]; then
    PACKAGES=""
    if [ -e /var/run/reboot-required.pkgs ]; then
        PACKAGES=$(tr '\n' ', ' < /var/run/reboot-required.pkgs)
    fi
    curl -fsS --max-time 10 \
        --data-urlencode "title=babel needs a reboot" \
        --data-urlencode "body=unattended-upgrades applied updates that need a reboot: ${PACKAGES}" \
        https://apprise.mathewcsims.uk/notify/self-hosted >/dev/null 2>&1 || true
fi
