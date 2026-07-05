#!/bin/sh
# Idempotent — safe to run at boot or interactively. Enables pf only if it
# isn't already (some other macOS component, like Internet Sharing, may
# have already turned it on — don't disturb that), then reloads the main
# ruleset, which pulls in the com.mathewcsims.lan-lockdown anchor.
#
# Run as root (this is what the LaunchDaemon does at boot).

if ! /sbin/pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
    /sbin/pfctl -e 2>&1
fi
/sbin/pfctl -f /etc/pf.conf 2>&1
