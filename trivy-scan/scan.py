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

Findings are grouped by what they actually call for, not just severity:
fixable (any severity — bump the pin) and unfixed-critical (no patch
exists yet, so the only option is a mitigation — stays individually
visible, never just a count) get listed out in the notification;
unfixed-high (no fix, lower urgency) is compressed to a per-image count
there but always kept in full in the local report file. Nothing is ever
hidden entirely — the fixed/unfixed split changes emphasis, not
visibility, since an unfixed CVE can still warrant a stopgap mitigation.
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
                # Deliberately NOT filtered out when absent (no --ignore-unfixed
                # at the trivy level) — an unfixed CVE can still have a
                # short-term mitigation (disable a feature, restrict network
                # access, etc.), especially at CRITICAL severity, so it needs
                # to stay visible. What changes below is how it's presented,
                # not whether it's seen at all.
                "fixed_version": v.get("FixedVersion") or None,
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
        # Three buckets, by what action they actually call for — not just
        # severity. A fixable CVE (any severity) means "bump the pin." An
        # unfixed CRITICAL means "no patch exists yet — decide on a
        # mitigation," and needs to stay individually visible, not buried
        # in a count. An unfixed HIGH is background risk with nothing to
        # do about it right now; it's still in the full report, but
        # doesn't need enumerating in the notification every time.
        fixable, unfixed_critical, unfixed_high = [], [], []
        for image, cves in new_findings.items():
            for vid, info in cves.items():
                row = (image, vid, info)
                if info["fixed_version"]:
                    fixable.append(row)
                elif info["severity"] == "CRITICAL":
                    unfixed_critical.append(row)
                else:
                    unfixed_high.append(row)

        total = len(fixable) + len(unfixed_critical) + len(unfixed_high)

        def short(image):
            return image.split("@")[0]

        # Full detail, unbounded, for local review — everything, always.
        report_lines = []
        header = ("Initial baseline scan" if is_first_run
                  else "New findings since the last scan")
        report_lines.append(f"# Trivy: {header} ({total} finding(s))\n")
        for image, cves in sorted(new_findings.items()):
            report_lines.append(f"## {image}")
            for vid, info in sorted(cves.items(), key=lambda kv: (kv[1]["severity"] != "CRITICAL", kv[0])):
                fix = f"fixed in {info['fixed_version']}" if info["fixed_version"] else "no fix yet"
                report_lines.append(f"- `{vid}` ({info['severity']}, {fix}) {info['pkg']}: {info['title']}")
            report_lines.append("")
        REPORT_FILE.write_text("\n".join(report_lines))

        label = "Initial baseline" if is_first_run else "New"

        # unfixed-critical gets its OWN message, sent first and never
        # sharing character budget with the (often much larger) fixable
        # summary — these are the ones that genuinely need a per-item
        # human decision (mitigate now vs accept the risk) since there's
        # no single action that clears them the way a pin bump does. Hit
        # live: with everything in one message, the fixable section alone
        # ate the whole budget and truncated away 28 of 38 critical
        # entries — exactly backwards for what's supposed to be the
        # highest-priority bucket. Lines here drop the CVE title (kept in
        # the full report) to fit more entries per message.
        if unfixed_critical:
            crit_lines = [f"**{label}: {len(unfixed_critical)} CRITICAL finding(s) with "
                          f"no fix yet — review for a mitigation:**\n"]
            for image, vid, info in sorted(unfixed_critical, key=lambda r: r[0]):
                crit_lines.append(f"- `{short(image)}`: `{vid}` ({info['pkg']})")
            crit_lines.append(f"\nFull detail (incl. titles): `{REPORT_FILE}`.")
            crit_body = "\n".join(crit_lines)
            if len(crit_body) > MAX_NOTIFY_CHARS:
                crit_body = crit_body[:MAX_NOTIFY_CHARS] + f"\n… truncated, see `{REPORT_FILE}`."
            notify(f"Trivy: {len(unfixed_critical)} new CRITICAL finding(s), no fix available",
                   crit_body, ntype="failure")

        # Second message: fixable (per-image, not per-CVE — see comment
        # below) + unfixed-high count. Lower urgency than the critical
        # message above, sent separately so it never competes with it.
        summary_lines = [f"**{label}**: {total} finding(s) across {len(new_findings)} "
                         f"image(s) — {len(fixable)} fixable, {len(unfixed_critical)} "
                         f"critical with no fix yet (see separate message), "
                         f"{len(unfixed_high)} high with no fix yet.\n"]

        if fixable:
            # Per-image, not per-CVE: a single pin bump clears every fixable
            # finding on that image at once, so that's the actual unit of
            # action — enumerating each of what can be dozens/hundreds of
            # CVEs per image (hit live: 420 in one run) produces a wall of
            # text nobody will read and blows straight through Discord's
            # size limit for no benefit. The single worst CVE per image is
            # still named, as a concrete "why this matters" anchor.
            summary_lines.append("**Fixable — bump the pin:**")
            by_image = {}
            for image, vid, info in fixable:
                by_image.setdefault(short(image), []).append((vid, info))
            for img, rows in sorted(by_image.items(), key=lambda x: -len(x[1])):
                worst = min(rows, key=lambda r: 0 if r[1]["severity"] == "CRITICAL" else 1)
                summary_lines.append(f"- `{img}`: {len(rows)} finding(s), worst is "
                                     f"`{worst[0]}` ({worst[1]['severity']})")
            summary_lines.append("")

        if unfixed_high:
            by_image = {}
            for image, vid, info in unfixed_high:
                by_image[short(image)] = by_image.get(short(image), 0) + 1
            counts = ", ".join(f"{n} in `{img}`" for img, n in sorted(by_image.items(), key=lambda x: -x[1]))
            summary_lines.append(f"**High, no fix yet** ({len(unfixed_high)} total, no immediate "
                                 f"action possible): {counts}")
            summary_lines.append("")

        summary_lines.append(f"Full detail: `{REPORT_FILE}` on the Mac.")
        if errors:
            summary_lines.append(f"{len(errors)} image(s) failed to scan — see trivy-scan.log.")
        body = "\n".join(summary_lines)
        if len(body) > MAX_NOTIFY_CHARS:
            body = body[:MAX_NOTIFY_CHARS] + f"\n… truncated, see `{REPORT_FILE}`."

        any_fixable_critical = any(i["severity"] == "CRITICAL" for _, _, i in fixable)
        notify(f"Trivy: {total} new vulnerabilit{'y' if total == 1 else 'ies'} found",
               body, ntype="failure" if any_fixable_critical else "warning")
        print(f"notified: {total} new findings ({len(fixable)} fixable, "
              f"{len(unfixed_critical)} unfixed-critical, {len(unfixed_high)} unfixed-high) "
              f"across {len(new_findings)} image(s) — full detail in {REPORT_FILE}")
    else:
        print("no new findings")


if __name__ == "__main__":
    main()
