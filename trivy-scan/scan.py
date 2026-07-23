"""Weekly vulnerability scan of every pinned image in this repo (Mac + Pi),
run by launchd — see uk.mathewcsims.trivy-scan.plist. Closes a real gap:
every CVE check in this repo up to now (BookStack, Forgejo, nimbus-postgres,
the July 2026 security pass, etc.) has been a one-off manual review during
a session; nothing watched for new CVEs on already-pinned digests in
between.

Image list is derived live from the repo (every `image:` in every
compose.yaml, every `FROM` in every Dockerfile) — not a maintained list
that could drift from what's actually pinned.

State (which CVE IDs have already been seen, per image) lives outside the
repo at ~/trivy-scan-state/, same "scripts tracked, runtime data isn't"
split as contact-sync/. Only NEWLY-seen HIGH/CRITICAL CVEs trigger a
notification — a CVE already known and accepted doesn't re-alert every
week, matching the resend-only-on-change spirit of the rest of this repo's
notification setup, not a wall of repeats.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = Path.home() / "trivy-scan-state"
STATE_FILE = STATE_DIR / "state.json"
REPORT_FILE = STATE_DIR / "latest-report.md"
APPRISE_URL = "https://apprise.mathewcsims.uk/notify/self-hosted"
# Discord embed descriptions cap at 4096 chars; a full per-CVE dump across
# 30+ images blew straight through that on the first run (1433 findings ->
# a 400 from Discord, confirmed live) and took the whole Apprise fan-out
# down with it, including the ntfy copy. The notification is now always a
# short summary; the full per-CVE detail goes to REPORT_FILE instead.
MAX_NOTIFY_CHARS = 3500


def notify(title, body, ntype="info"):
    data = urllib.parse.urlencode({
        "title": title, "body": body, "type": ntype, "format": "markdown",
    }).encode()
    try:
        req = urllib.request.Request(APPRISE_URL, data=data, method="POST")
        urllib.request.urlopen(req, timeout=15)
    except OSError as e:
        print(f"notify failed: {e}", file=sys.stderr)


# .claude/worktrees/ can hold detached-HEAD checkouts from past agent
# sessions (isolation: "worktree") with stale, pre-digest-pin compose
# files that were never cleaned up — found live: a leftover worktree
# added 38 bogus/duplicate images (old tags, dead versions) to the first
# real scan. .git/ itself can also contain compose.yaml blobs in its
# object store on some layouts — excluded on the same principle: only
# scan what's actually deployed, not incidental repo history.
EXCLUDE_DIRS = {".claude", ".git"}


def find_images():
    images = set()
    for pattern, regex in (
        ("**/compose.yaml", re.compile(r"\s*image:\s*(\S+)")),
        ("**/Dockerfile", re.compile(r"FROM\s+(\S+)(?:\s+AS\s+\S+)?")),
    ):
        for path in REPO_ROOT.glob(pattern):
            if EXCLUDE_DIRS & set(path.relative_to(REPO_ROOT).parts):
                continue
            for line in path.read_text().splitlines():
                m = regex.match(line)
                if m:
                    images.add(m.group(1))
    return sorted(images)


def scan(image):
    r = subprocess.run(
        ["trivy", "image", "--severity", "HIGH,CRITICAL", "--format", "json",
         "--quiet", "--timeout", "5m", image],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None, r.stderr.strip()[:300]
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None, "unparseable trivy output"
    found = {}
    for result in data.get("Results", []) or []:
        for v in result.get("Vulnerabilities", []) or []:
            found[v["VulnerabilityID"]] = {
                "severity": v.get("Severity"),
                "pkg": v.get("PkgName"),
                "title": (v.get("Title") or "")[:100],
            }
    return found, None


def main():
    STATE_DIR.mkdir(exist_ok=True)
    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    is_first_run = not state

    images = find_images()
    new_findings = {}
    errors = {}

    for image in images:
        found, err = scan(image)
        if err:
            errors[image] = err
            continue
        prev = set(state.get(image, {}).keys())
        new_ids = set(found.keys()) - prev
        if new_ids:
            new_findings[image] = {vid: found[vid] for vid in new_ids}
        state[image] = found

    STATE_FILE.write_text(json.dumps(state, indent=1))

    if errors:
        print(f"{len(errors)} image(s) failed to scan:", file=sys.stderr)
        for img, err in errors.items():
            print(f"  {img}: {err}", file=sys.stderr)

    if new_findings:
        total = sum(len(cves) for cves in new_findings.values())
        critical_total = sum(
            1 for cves in new_findings.values() for i in cves.values()
            if i["severity"] == "CRITICAL"
        )

        # Full detail, unbounded, for local review.
        report_lines = []
        header = ("Initial baseline scan" if is_first_run
                  else "New findings since the last scan")
        report_lines.append(f"# Trivy: {header} ({total} finding(s))\n")
        for image, cves in sorted(new_findings.items()):
            report_lines.append(f"## {image}")
            for vid, info in sorted(cves.items(), key=lambda kv: (kv[1]["severity"] != "CRITICAL", kv[0])):
                report_lines.append(f"- `{vid}` ({info['severity']}) {info['pkg']}: {info['title']}")
            report_lines.append("")
        REPORT_FILE.write_text("\n".join(report_lines))

        # Short summary only for the notification — per-image counts, capped.
        summary_lines = [f"**{'Initial baseline' if is_first_run else 'New'}**: "
                         f"{total} finding(s), {critical_total} CRITICAL, "
                         f"across {len(new_findings)} image(s).\n"]
        for image, cves in sorted(new_findings.items(),
                                  key=lambda kv: -sum(1 for i in kv[1].values() if i["severity"] == "CRITICAL")):
            crit = sum(1 for i in cves.values() if i["severity"] == "CRITICAL")
            high = len(cves) - crit
            summary_lines.append(f"- `{image.split('@')[0]}`: {crit} critical, {high} high")
        summary_lines.append(f"\nFull detail: `{REPORT_FILE}` on the Mac.")
        if errors:
            summary_lines.append(f"{len(errors)} image(s) failed to scan — see trivy-scan.log.")
        body = "\n".join(summary_lines)
        if len(body) > MAX_NOTIFY_CHARS:
            body = body[:MAX_NOTIFY_CHARS] + f"\n… truncated, see `{REPORT_FILE}`."

        notify(f"Trivy: {total} new vulnerabilit{'y' if total == 1 else 'ies'} found",
               body, ntype="warning")
        print(f"notified: {total} new findings ({critical_total} critical) "
              f"across {len(new_findings)} image(s) — full detail in {REPORT_FILE}")
    else:
        print("no new findings")


if __name__ == "__main__":
    main()
