"""Podman-on-Mac dead-man's-switch — added 2026-07-26 after the machine's
virtio block-device worker thread wedged (heavy sustained container disk
I/O — see SETUP.md's Podman Watchdog section for the diagnosis) and every
container silently became unreachable via `podman ps` for ~2 days before
being noticed. That failure mode is exactly why this pings OUT rather
than being polled: Uptime Kuma's other ~24 monitors reach apps over the
network, but the failure here was the Mac's own local Podman socket
hanging — nothing external could have told the difference between "app
down" and "Podman itself wedged" without this.

Run every 2 minutes via launchd (uk.mathewcsims.podman-watchdog). Each
run does ONE bounded-timeout `podman ps` — if it answers in time, pings
Uptime Kuma's push monitor with status=up; if it times out or errors,
pings status=down with the reason. A hard subprocess timeout is
essential: this script exists because `podman ps` can itself hang
indefinitely when the VM is wedged, so it must never block longer than
the interval it's scheduled at.

Secrets: KUMA_PUSH_TOKEN from the "Uptime Kuma" Pass item, sourced by
run-watchdog.sh — never argv, never a file.
"""

import os
import subprocess
import sys
import urllib.parse
import urllib.request

PODMAN_TIMEOUT = 15
PUSH_TIMEOUT = 10
PUSH_BASE = "https://status.mathewcsims.uk/api/push/"


def push(token, status, msg):
    url = PUSH_BASE + token + "?" + urllib.parse.urlencode({"status": status, "msg": msg, "ping": ""})
    try:
        urllib.request.urlopen(url, timeout=PUSH_TIMEOUT)
    except OSError as e:
        # Network to the Pi is down, or Kuma itself is down — nothing more
        # to do; Kuma's own missed-heartbeat detection is the fallback for
        # this specific case (it will flag the monitor as down on its own
        # once enough pings are missed).
        print(f"push failed: {e}", file=sys.stderr)


def main():
    token = os.environ["KUMA_PUSH_TOKEN"]
    try:
        r = subprocess.run(["podman", "ps", "--format", "{{.Names}}"],
                           capture_output=True, text=True, timeout=PODMAN_TIMEOUT)
        if r.returncode == 0:
            n = len(r.stdout.strip().splitlines())
            push(token, "up", f"{n} containers responding")
        else:
            push(token, "down", f"podman ps exited {r.returncode}: {r.stderr[-200:]}")
    except subprocess.TimeoutExpired:
        push(token, "down", f"podman ps did not respond within {PODMAN_TIMEOUT}s — VM likely wedged")
    except Exception as e:
        push(token, "down", f"watchdog error: {e}")


if __name__ == "__main__":
    main()
