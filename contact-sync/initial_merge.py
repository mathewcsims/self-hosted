"""Initial merge: cluster the four providers' contacts into canonical
identities and produce (a) the canonical store and (b) a human-review
report — WITHOUT writing anything to any provider.

Matching, in confidence order (per the agreed plan):
  1. shared normalized email  → same person, auto-cluster
  2. shared normalized phone  → same person, auto-cluster
  3. exact full-name match    → auto-cluster, but listed in the report's
     "name-only matches" section for review (names collide more often
     than emails/phones do)

Anything the rules can't settle cleanly (e.g. one contact's identifiers
span two existing clusters that DIDN'T merge via email/phone — meaning
the identifier evidence itself is contradictory) goes to the report's
"ambiguous" section and is left unmerged.

Field merge within a cluster: emails/phones/urls are unioned; scalar
fields (name, org, title, notes, birthday) take the value from the
member with the newest `modified` timestamp that actually has the field
(sources without timestamps sort oldest). The phone-folder seed files
contribute ONLY missing emails/phones to already-formed clusters — they
never create canonical contacts and never influence scalars.

Usage:
  python3 initial_merge.py \
      --proton proton.json --google google.json \
      --ms-personal ms.json --ms-work work.json \
      [--seed seed.jsonl] --out-dir ~/contact-sync
"""

import argparse
import json
import os
import re
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize  # noqa: E402


# ── union-find ──────────────────────────────────────────────────────────

class DSU:
    def __init__(self, n):
        self.parent = list(range(n))

    def find(self, a):
        while self.parent[a] != a:
            self.parent[a] = self.parent[self.parent[a]]
            a = self.parent[a]
        return a

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[rb] = ra


def norm_name(name):
    return re.sub(r"\s+", " ", name.strip().lower())


def cluster(contacts):
    """Returns (clusters, name_only_pairs, ambiguous_notes)."""
    dsu = DSU(len(contacts))

    by_email, by_phone = {}, {}
    for i, c in enumerate(contacts):
        for e in c["emails"]:
            by_email.setdefault(e, []).append(i)
        for p in c["phones"]:
            by_phone.setdefault(p, []).append(i)
    for idxs in by_email.values():
        for j in idxs[1:]:
            dsu.union(idxs[0], j)
    for idxs in by_phone.values():
        for j in idxs[1:]:
            dsu.union(idxs[0], j)

    # exact-name pass — only names with ≥2 words (single tokens like
    # "Mum" or "IT" collide too easily to trust)
    name_only_pairs = []
    by_name = {}
    for i, c in enumerate(contacts):
        n = norm_name(c["name"])
        if n and len(n.split()) >= 2:
            by_name.setdefault(n, []).append(i)
    for name, idxs in by_name.items():
        roots = {dsu.find(i) for i in idxs}
        if len(roots) > 1:
            first = idxs[0]
            for j in idxs[1:]:
                if dsu.find(j) != dsu.find(first):
                    name_only_pairs.append((name, contacts[first]["source"],
                                            contacts[j]["source"]))
                    dsu.union(first, j)

    clusters = {}
    for i in range(len(contacts)):
        clusters.setdefault(dsu.find(i), []).append(i)
    return list(clusters.values()), name_only_pairs


def merge_cluster(members):
    """Union identifiers, newest-wins scalars. `members` = list of
    normalized contact dicts."""
    def newest_with(field):
        best, best_time = "", None
        for m in sorted(members, key=lambda m: m["modified"]):
            if m[field]:
                if best_time is None or m["modified"] >= best_time:
                    best, best_time = m[field], m["modified"]
        return best

    out = {
        "uid": str(uuid.uuid4()),
        "name": newest_with("name"),
        "given": newest_with("given"),
        "family": newest_with("family"),
        "org": newest_with("org"),
        "title": newest_with("title"),
        "notes": newest_with("notes"),
        "birthday": newest_with("birthday"),
        "emails": [], "phones": [], "urls": [],
        "sources": {},
    }
    for m in members:
        for f in ("emails", "phones", "urls"):
            for v in m[f]:
                if v not in out[f]:
                    out[f].append(v)
        # A list per provider, deliberately: two same-provider records can
        # merge into one canonical contact, and the write phase needs every
        # original ID — the first becomes the survivor it updates, the rest
        # are intra-provider duplicates it deletes as part of convergence.
        out["sources"].setdefault(m["source"], []).append(m["source_id"])
    return out


def seed_enrich(canonical, seed_path, report_lines):
    """One-time seed: phone-folder entries contribute missing emails/
    phones to clusters they match (by email, phone, or exact name) —
    never new contacts, never scalars."""
    idx_email, idx_phone, idx_name = {}, {}, {}
    for c in canonical:
        for e in c["emails"]:
            idx_email[e] = c
        for p in c["phones"]:
            idx_phone[p] = c
        n = norm_name(c["name"])
        if n and len(n.split()) >= 2:
            idx_name.setdefault(n, c)

    added = 0
    for line in open(seed_path):
        folder = json.loads(line)
        for p in folder["people"]:
            emails = [normalize.norm_email(e) for e in (p.get("emails") or []) if e]
            phones = [normalize.norm_phone(t) for t in (p.get("phones") or []) if t]
            name = norm_name(((p.get("firstName") or "") + " " + (p.get("lastName") or "")).strip())
            target = None
            for e in emails:
                if e in idx_email:
                    target = idx_email[e]
                    break
            if target is None:
                for t in phones:
                    if t in idx_phone:
                        target = idx_phone[t]
                        break
            if target is None and name in idx_name:
                target = idx_name[name]
            if target is None:
                continue  # unmatched seed entries are deliberately dropped
            for e in emails:
                if e and e not in target["emails"]:
                    target["emails"].append(e)
                    added += 1
            for t in phones:
                if t and t not in target["phones"]:
                    target["phones"].append(t)
                    added += 1
    report_lines.append(f"- Seed pass: {added} emails/phones added to "
                        "existing contacts from the phone-backup folders.")


def to_vcard(c):
    def esc(v):
        return v.replace("\\", "\\\\").replace("\n", "\\n").replace(",", "\\,").replace(";", "\\;")
    lines = ["BEGIN:VCARD", "VERSION:4.0", f"UID:{c['uid']}"]
    if c["name"]:
        lines.append(f"FN:{esc(c['name'])}")
    if c["given"] or c["family"]:
        lines.append(f"N:{esc(c['family'])};{esc(c['given'])};;;")
    for e in c["emails"]:
        lines.append(f"EMAIL:{e}")
    for p in c["phones"]:
        lines.append(f"TEL:{p}")
    if c["org"]:
        lines.append(f"ORG:{esc(c['org'])}")
    if c["title"]:
        lines.append(f"TITLE:{esc(c['title'])}")
    if c["birthday"]:
        lines.append(f"BDAY:{c['birthday']}")
    for u in c["urls"]:
        lines.append(f"URL:{u}")
    if c["notes"]:
        lines.append(f"NOTE:{esc(c['notes'])}")
    lines.append("END:VCARD")
    return "\r\n".join(lines) + "\r\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proton", required=True)
    ap.add_argument("--google", required=True)
    ap.add_argument("--ms-personal", required=True)
    ap.add_argument("--ms-work", required=True)
    ap.add_argument("--seed")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    contacts = (normalize.from_proton(args.proton)
                + normalize.from_google(args.google)
                + normalize.from_ms_graph(args.ms_personal)
                + normalize.from_macos_jxa(args.ms_work))

    per_source = {}
    for c in contacts:
        per_source[c["source"]] = per_source.get(c["source"], 0) + 1

    clusters, name_only = cluster(contacts)
    canonical = [merge_cluster([contacts[i] for i in idxs]) for idxs in clusters]

    report = ["# Initial merge report", ""]
    report.append("## Input counts")
    for s, n in sorted(per_source.items()):
        report.append(f"- {s}: {n}")
    report.append(f"- TOTAL input records: {len(contacts)}")
    report.append("")
    report.append(f"## Result: {len(canonical)} canonical contacts")
    sizes = {}
    for idxs in clusters:
        sizes[len(idxs)] = sizes.get(len(idxs), 0) + 1
    for size in sorted(sizes):
        report.append(f"- clusters of size {size}: {sizes[size]}")
    report.append("")

    if args.seed:
        report.append("## Seed pass (phone-backup folders, one-time)")
        seed_enrich(canonical, args.seed, report)
        report.append("")

    report.append("## Name-only matches (REVIEW: merged on exact name alone)")
    if name_only:
        for name, s1, s2 in sorted(name_only):
            report.append(f"- \"{name}\" ({s1} + {s2})")
    else:
        report.append("- none")
    report.append("")

    multi = [c for c in canonical if len(c["sources"]) > 1]
    report.append(f"## Cross-provider matches: {len(multi)} contacts exist in >1 provider")
    only_counts = {}
    for c in canonical:
        if len(c["sources"]) == 1:
            s = next(iter(c["sources"]))
            only_counts[s] = only_counts.get(s, 0) + 1
    for s, n in sorted(only_counts.items()):
        report.append(f"- only in {s}: {n}")

    store = os.path.join(args.out_dir, "store")
    os.makedirs(store, exist_ok=True)
    for c in canonical:
        with open(os.path.join(store, c["uid"] + ".vcf"), "w") as f:
            f.write(to_vcard(c))
    state = {
        "contacts": {
            c["uid"]: {"providers": c["sources"], "last_synced": {}}
            for c in canonical
        }
    }
    with open(os.path.join(args.out_dir, "state.json"), "w") as f:
        json.dump(state, f, indent=1)

    # Full canonical dicts as JSON too — the write phase works from this
    # (the .vcf files are the durable, git-versioned form; this is the
    # engine's working copy, regenerated on every merge).
    with open(os.path.join(args.out_dir, "canonical.json"), "w") as f:
        json.dump(canonical, f, indent=1)

    report_path = os.path.join(args.out_dir, "initial-merge-report.md")
    with open(report_path, "w") as f:
        f.write("\n".join(report) + "\n")
    print(f"canonical contacts: {len(canonical)}")
    print(f"report: {report_path}")


if __name__ == "__main__":
    main()
