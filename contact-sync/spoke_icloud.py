"""macOS Contacts.app (iCloud account) spoke — full symmetric spoke, same
contract as spoke_google.py / spoke_proton.py (create/update/delete),
added 2026-07-25 when Mathew asked for his iCloud address book to join
the sync. Unlike the retired ms_work JXA spoke (updates-only), this one
owns the whole address book: canonical fully replaces the fields it owns
on every update (deletes+re-adds collections), same as Google's PATCH.

iCloud was empty when this spoke was added (Contacts.app showed only the
"Me" card) — the first real apply is a genuine bulk-populate of ~1,025
contacts, not a merge of pre-existing data. New Person objects land in
the iCloud account by default (confirmed live: it's the only writable
account on this Mac).

Reads and creates are batched into a single Apple Event each — a
per-contact loop of separate osascript processes was measured at
~270ms/contact for reads (unusable at this scale); reading each property
as one array across the whole `people` collection (`app.people.id()`,
`app.people.firstName()`, etc.) and zipping in JS instead was ~3ms/
contact. Scripts are written to a temp file rather than passed via -e/
argv — the create script embeds the full canonical payload and can run
well past typical argv limits at ~1,025 contacts.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize  # noqa: E402

# Contacts.app's own "Me" card — no scripting API exposes it (no
# `myCard`/"my card" in JXA or classic AppleScript, confirmed live, and
# `sdef` shows no such vocabulary at all in the current dictionary) — this
# ID was identified empirically as the sole pre-existing person before
# this spoke's first populate. MUST stay excluded from every read: the
# very first sync.py run after adding this spoke treated it as a brand
# new unmapped contact (blank name-only) and propagated an empty
# duplicate "Mathew Sims" to every other provider before this exclusion
# was added. If this ID is ever wrong (e.g. after an iCloud account
# reset), a stray near-empty self-contact reappearing across every
# provider is the symptom — update this constant.
ME_CARD_ID = "5B927780-EA47-4B25-8B89-86D9ACD8D393:ABPerson"


def jxa(script, timeout=300):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(script)
        path = f.name
    try:
        r = subprocess.run(["osascript", "-l", "JavaScript", path],
                           capture_output=True, text=True, timeout=timeout)
    finally:
        os.unlink(path)
    if r.returncode != 0:
        raise RuntimeError(f"JXA failed: {r.stderr[-500:]}")
    return r.stdout.strip()


def pull_all(tmp_path):
    out = jxa('''
const app = Application("Contacts");
const ids = app.people.id();
const first = app.people.firstName();
const last = app.people.lastName();
const fullName = app.people.name();
const org = app.people.organization();
const title = app.people.jobTitle();
const note = app.people.note();
const mod = app.people.modificationDate();
const bday = app.people.birthDate();
const emails = app.people.emails.value();
const phones = app.people.phones.value();
const urls = app.people.urls.value();
function fmtBday(d) {
  if (!d) return "";
  const pad = n => String(n).padStart(2, "0");
  const y = d.getFullYear();
  const mmdd = pad(d.getMonth() + 1) + "-" + pad(d.getDate());
  return (y <= 1604 ? "--" : y + "-") + mmdd;
}
const out = ids.map((id, i) => ({
  id, firstName: first[i], lastName: last[i], fullName: fullName[i],
  organization: org[i], jobTitle: title[i], note: note[i],
  modificationDate: mod[i] ? mod[i].toISOString() : null,
  birthday: fmtBday(bday[i]),
  emails: emails[i], phones: phones[i], urls: urls[i],
})).filter(p => p.id !== "''' + ME_CARD_ID + '''");
JSON.stringify(out);
''')
    with open(tmp_path, "w") as f:
        f.write(out)
    os.chmod(tmp_path, 0o600)
    return normalize.from_icloud(tmp_path)


def differs(canon, ic):
    # Compare against the name we'd actually WRITE (_expected_name),
    # not canon["name"] verbatim — canonical has no middle-name field,
    # so a name whose middle word can't be safely recovered (hyphenated
    # names, honorifics, org names — see _expected_name) permanently
    # renders as given+family-only on iCloud. Comparing against the raw
    # canonical name would flag that as an eternal, unfixable "diff"
    # every single day — same class of accepted permanent mismatch as
    # spoke_proton.py's un-clearable notes field.
    expected_name = _expected_name(canon)[3]
    return (
        sorted(canon["emails"]) != sorted(ic["emails"])
        or sorted(canon["phones"]) != sorted(ic["phones"])
        or expected_name != (ic["name"] or "")
        or (canon["org"] or "") != (ic["org"] or "")
        or (canon["title"] or "") != (ic["title"] or "")
        or (canon["notes"] or "") != (ic["notes"] or "")
        or (canon["birthday"] or "") != (ic["birthday"] or "")
    )


def make_plan(canonical_path, out_path, tmp="/tmp/icloud-current.json"):
    current = {c["source_id"]: c for c in pull_all(tmp)}
    canonical = json.load(open(canonical_path))
    plan = {"create": [], "update": [], "delete": [], "unchanged": 0}
    for c in canonical:
        if c.get("excluded"):
            continue  # import-artifact husks etc. — never synced anywhere
        ids = c["sources"].get("icloud", [])
        if not ids:
            plan["create"].append({"uid": c["uid"], "name": c["name"]})
            continue
        survivor = ids[0]
        for dup in ids[1:]:
            plan["delete"].append({"uid": c["uid"], "icloud_id": dup,
                                   "name": c["name"],
                                   "reason": "intra-icloud duplicate merged"})
        if survivor in current and differs(c, current[survivor]):
            plan["update"].append({"uid": c["uid"], "icloud_id": survivor, "name": c["name"]})
        else:
            plan["unchanged"] += 1
    with open(out_path, "w") as f:
        json.dump(plan, f, indent=1)
    os.chmod(out_path, 0o600)
    print(f"plan: create {len(plan['create'])}, update {len(plan['update'])}, "
          f"delete {len(plan['delete'])} (intra-icloud dups), unchanged {plan['unchanged']}")
    return plan


def apply_plan(plan_path, canonical_path, state_path):
    plan = json.load(open(plan_path))
    canonical = {c["uid"]: c for c in json.load(open(canonical_path))}
    state = json.load(open(state_path))

    created = updated = deleted = failed = 0

    if plan["create"]:
        payload = [{"uid": item["uid"], **_fields(canonical[item["uid"]])}
                  for item in plan["create"]]
        script = _CREATE_SCRIPT.replace("__DATA__", json.dumps(payload))
        try:
            result = json.loads(jxa(script))
            for r in result:
                c = canonical[r["uid"]]
                c["sources"]["icloud"] = [r["id"]]
                state["contacts"][c["uid"]]["providers"]["icloud"] = [r["id"]]
                created += 1
        except Exception as e:
            print(f"CREATE BATCH FAILED: {e}", file=sys.stderr)
            failed += len(plan["create"])

    if plan["update"]:
        payload = [{"id": item["icloud_id"], **_fields(canonical[item["uid"]])}
                  for item in plan["update"]]
        script = _UPDATE_SCRIPT.replace("__DATA__", json.dumps(payload))
        try:
            result = json.loads(jxa(script))
            updated += result.get("ok", 0)
            failed += result.get("failed", 0)
            for fid in result.get("failed_ids", []):
                print(f"UPDATE FAILED: icloud id {fid}", file=sys.stderr)
        except Exception as e:
            print(f"UPDATE BATCH FAILED: {e}", file=sys.stderr)
            failed += len(plan["update"])

    if plan["delete"]:
        ids = [item["icloud_id"] for item in plan["delete"]]
        script = _DELETE_SCRIPT.replace("__DATA__", json.dumps(ids))
        try:
            result = json.loads(jxa(script))
            deleted += result.get("ok", 0)
            for item in plan["delete"]:
                c = canonical[item["uid"]]
                c["sources"]["icloud"] = [i for i in c["sources"].get("icloud", [])
                                          if i != item["icloud_id"]]
                state["contacts"][item["uid"]]["providers"]["icloud"] = c["sources"]["icloud"]
        except Exception as e:
            print(f"DELETE BATCH FAILED: {e}", file=sys.stderr)
            failed += len(plan["delete"])

    with open(canonical_path, "w") as f:
        json.dump(list(canonical.values()), f, indent=1)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=1)
    print(f"applied: created {created}, updated {updated}, deleted {deleted}, failed {failed}")


def _expected_name(c):
    """(given, middle, family, expected_full_name) — canonical only
    stores given/family (no middle name field), so a multi-word name
    like "Arts Award College" (given="Arts", family="College") loses
    "Award" if written as firstName+lastName alone. Recover it into
    Contacts.app's middleName when it's unambiguous — i.e. only when
    given+middle+family round-trips back to the original name exactly.
    Hyphenated names ("Jean-Claude"), honorifics ("Dr Niusa Marigheto"),
    and org names all fail that round-trip and correctly fall back to no
    middle name (given+family-only — imperfect but not corrupted, rather
    than garbage like "Jean -Claude Massey" or a doubled trailing word).
    Confirmed live: without this, 33/620 contacts on the first real
    populate round-tripped with a mismatched name; the naive drop-name
    strip corrupted 11 of those further before this round-trip guard."""
    given, family, name = c["given"] or "", c["family"] or "", c["name"] or ""
    middle = ""
    if (given or family) and name:
        rest, prefix_ok, suffix_ok = name, True, True
        if given:
            if rest.startswith(given):
                rest = rest[len(given):]
            else:
                prefix_ok = False
        if family:
            if rest.endswith(family):
                rest = rest[:len(rest) - len(family)]
            else:
                suffix_ok = False
        candidate = rest.strip() if (prefix_ok and suffix_ok) else ""
        if candidate and " ".join(x for x in (given, candidate, family) if x) == name:
            middle = candidate
    elif not given and not family and name:
        given = name  # no given/family split at all — dump whole name into firstName
    expected = " ".join(x for x in (given, middle, family) if x)
    return given, middle, family, expected


def _fields(c):
    given, middle, family, _ = _expected_name(c)
    return {
        "given": given, "middle": middle, "family": family,
        "org": c["org"], "title": c["title"],
        "notes": c["notes"], "emails": c["emails"], "phones": c["phones"],
        "urls": c["urls"], "birthday": c["birthday"],
    }


# birthday: "" (leave unset), "YYYY-MM-DD", or "--MM-DD" (no-year, Apple's
# own 1604 sentinel — see normalize.from_icloud).
_BDAY_JS = '''
function bdayFromStr(s) {
  if (!s) return null;
  const noYear = s.startsWith("--");
  const mmdd = noYear ? s.slice(2) : s.slice(5);
  const m = parseInt(mmdd.slice(0, 2), 10);
  const d = parseInt(mmdd.slice(3, 5), 10);
  const y = noYear ? 1604 : parseInt(s.slice(0, 4), 10);
  return new Date(y, m - 1, d);
}
'''

_CREATE_SCRIPT = _BDAY_JS + '''
const app = Application("Contacts");
const data = __DATA__;
const results = [];
for (const c of data) {
  const p = app.Person({firstName: c.given, lastName: c.family});
  app.people.push(p);
  if (c.middle) p.middleName = c.middle;
  if (c.org) p.organization = c.org;
  if (c.title) p.jobTitle = c.title;
  if (c.notes) p.note = c.notes;
  const b = bdayFromStr(c.birthday);
  if (b) p.birthDate = b;
  for (const e of c.emails) p.emails.push(app.Email({label: "home", value: e}));
  for (const t of c.phones) p.phones.push(app.Phone({label: "mobile", value: t}));
  for (const u of c.urls) p.urls.push(app.Url({label: "homepage", value: u}));
  results.push({uid: c.uid, id: p.id()});
}
app.save();
JSON.stringify(results);
'''

_UPDATE_SCRIPT = _BDAY_JS + '''
const app = Application("Contacts");
const data = __DATA__;
let ok = 0, failed = 0;
const failed_ids = [];
for (const c of data) {
  try {
    const p = app.people.byId(c.id);
    p.firstName = c.given || "";
    p.middleName = c.middle || "";
    p.lastName = c.family || "";
    p.organization = c.org || "";
    p.jobTitle = c.title || "";
    p.note = c.notes || "";
    const b = bdayFromStr(c.birthday);
    if (b) p.birthDate = b;
    const oldEmails = p.emails();
    for (let i = oldEmails.length - 1; i >= 0; i--) app.delete(oldEmails[i]);
    for (const e of c.emails) p.emails.push(app.Email({label: "home", value: e}));
    const oldPhones = p.phones();
    for (let i = oldPhones.length - 1; i >= 0; i--) app.delete(oldPhones[i]);
    for (const t of c.phones) p.phones.push(app.Phone({label: "mobile", value: t}));
    const oldUrls = p.urls();
    for (let i = oldUrls.length - 1; i >= 0; i--) app.delete(oldUrls[i]);
    for (const u of c.urls) p.urls.push(app.Url({label: "homepage", value: u}));
    ok++;
  } catch (e) {
    failed++;
    failed_ids.push(c.id);
  }
}
app.save();
JSON.stringify({ok, failed, failed_ids});
'''

_DELETE_SCRIPT = '''
const app = Application("Contacts");
const ids = __DATA__;
let ok = 0;
for (const id of ids) {
  try {
    app.delete(app.people.byId(id));
    ok++;
  } catch (e) {}
}
app.save();
JSON.stringify({ok});
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["plan", "apply"])
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--out")
    ap.add_argument("--plan")
    ap.add_argument("--state")
    args = ap.parse_args()
    if args.mode == "plan":
        make_plan(args.canonical, args.out or "icloud-plan.json")
    else:
        apply_plan(args.plan, args.canonical, args.state)


if __name__ == "__main__":
    main()
