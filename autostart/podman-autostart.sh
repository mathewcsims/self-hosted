#!/bin/sh
# Started at login by the launchd agent uk.mathewcsims.podman-autostart.
#
# podman-machine on macOS does not auto-start, so nothing comes back after a
# reboot until the VM is started. This:
#   1. starts the podman machine, then
#   2. (belt-and-braces) starts every container with a restart policy.
# Step 2 is usually redundant — the in-VM `podman-restart.service` already
# starts them on VM boot — but it's idempotent and covers edge cases.

export PATH="/opt/podman/bin:/usr/bin:/bin:/usr/sbin:/sbin"
LOG="/Users/mathewcsims/self-hosted/autostart/autostart.log"
MACHINE="podman-machine-default"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') login: starting podman ===" >> "$LOG"

# Start the VM (harmless non-zero if it's already running)
podman machine start "$MACHINE" >> "$LOG" 2>&1 || echo "$(date '+%H:%M:%S') machine start rc=$? (already running?)" >> "$LOG"

# Wait (up to ~2 min) for the podman API to respond
i=0
while [ "$i" -lt 60 ]; do
  podman info >/dev/null 2>&1 && break
  i=$((i + 1)); sleep 2
done

# Safety net: ensure all restart-policy containers are up (idempotent)
podman start --all --filter should-start-on-boot=true >> "$LOG" 2>&1

echo "$(date '+%H:%M:%S') container status:" >> "$LOG"
podman ps --format '{{.Names}}  {{.Status}}' >> "$LOG" 2>&1
echo "=== $(date '+%H:%M:%S') done ===" >> "$LOG"
