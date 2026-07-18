"""MS work spoke — macOS Contacts.app via JXA, ASYMMETRIC by design.

The work (UKRI-STFC) Exchange account participates one-way-ish, per the
agreed scope: its own 21 contacts sync outward to every personal
provider, and canonical updates to THOSE contacts sync back in — but
personal contacts are never pushed into the work mailbox (an employer-
controlled system should never receive the personal address book).

So, unlike the other spokes: plan/apply produce updates ONLY for
contacts that already exist in the work account. No creates, no deletes.

Reads are batched (one Apple Event per property across the whole group —
the per-person pattern takes minutes, the batched one seconds; found
empirically). Writes are per-contact, per-field, via a generated JXA
script run through osascript.
"""

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize  # noqa: E402

WORK_GROUP_ID = "40188BA1-460C-455C-947F-3D592947F8EB:ABGroup"


def jxa(script):
    r = subprocess.run(["osascript", "-l", "JavaScript", "-e", script],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError(f"JXA failed: {r.stderr[-300:]}")
    return r.stdout.strip()


def pull(tmp_path):
    out = jxa('''
const app = Application("Contacts");
const group = app.groups.byId("''' + WORK_GROUP_ID + '''");
const out = group.people().map(p => ({
  id: p.id(),
  firstName: p.firstName(), lastName: p.lastName(),
  organization: p.organization(), jobTitle: p.jobTitle(), note: p.note(),
  modificationDate: p.modificationDate() ? p.modificationDate().toISOString() : null,
  emails: p.emails().map(e => ({label: e.label(), value: e.value()})),
  phones: p.phones().map(ph => ({label: ph.label(), value: ph.value()})),
  addresses: []
}));
JSON.stringify(out);
''')
    with open(tmp_path, "w") as f:
        f.write(out)
    os.chmod(tmp_path, 0o600)
    return normalize.from_macos_jxa(tmp_path)


def differs(canon, work):
    # Scalars + identifier sets, same field ownership as other spokes.
    return (
        sorted(canon["emails"]) != sorted(work["emails"])
        or sorted(canon["phones"]) != sorted(work["phones"])
        or (canon["org"] or "") != (work["org"] or "")
        or (canon["title"] or "") != (work["title"] or "")
        or (canon["notes"] or "") != (work["notes"] or "")
    )


def make_plan(canonical_path, out_path, tmp="/tmp/ms-work-current.json"):
    current = {c["source_id"]: c for c in pull(tmp)}
    canonical = json.load(open(canonical_path))
    plan = {"update": [], "unchanged": 0, "note": "asymmetric spoke: updates only, no creates/deletes"}
    for c in canonical:
        ids = c["sources"].get("ms_work", [])
        if not ids:
            continue  # personal-only contact: never pushed into work
        wid = ids[0]
        if wid in current and differs(c, current[wid]):
            plan["update"].append({"uid": c["uid"], "work_id": wid, "name": c["name"]})
        else:
            plan["unchanged"] += 1
    with open(out_path, "w") as f:
        json.dump(plan, f, indent=1)
    os.chmod(out_path, 0o600)
    print(f"plan: update {len(plan['update'])}, unchanged {plan['unchanged']} (no creates/deletes by design)")


def apply_plan(plan_path, canonical_path):
    plan = json.load(open(plan_path))
    canonical = {c["uid"]: c for c in json.load(open(canonical_path))}
    updated = failed = 0
    for item in plan["update"]:
        c = canonical[item["uid"]]
        payload = json.dumps({
            "id": item["work_id"],
            "org": c["org"], "title": c["title"], "notes": c["notes"],
            "emails": c["emails"], "phones": c["phones"],
        })
        script = '''
const app = Application("Contacts");
const data = ''' + payload + ''';
const p = app.people.byId(data.id);
if (data.org) p.organization = data.org;
if (data.title) p.jobTitle = data.title;
if (data.notes) p.note = data.notes;
const have = p.emails().map(e => e.value().toLowerCase());
for (const e of data.emails) {
  if (!have.includes(e.toLowerCase())) {
    p.emails.push(app.Email({label: "work", value: e}));
  }
}
const havePh = p.phones().map(ph => ph.value().replace(/[^\\d+]/g, ""));
for (const t of data.phones) {
  const norm = t.replace(/[^\\d+]/g, "");
  if (!havePh.includes(norm)) {
    p.phones.push(app.Phone({label: "work", value: t}));
  }
}
app.save();
"ok";
'''
        try:
            jxa(script)
            updated += 1
        except RuntimeError as e:
            print(f"UPDATE FAILED {item['name']!r}: {e}", file=sys.stderr)
            failed += 1
    print(f"applied: updated {updated}, failed {failed} (asymmetric — nothing created/deleted)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["plan", "apply"])
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--out")
    ap.add_argument("--plan")
    args = ap.parse_args()
    if args.mode == "plan":
        make_plan(args.canonical, args.out or "ms-work-plan.json")
    else:
        apply_plan(args.plan, args.canonical)


if __name__ == "__main__":
    main()
