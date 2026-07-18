"""Microsoft Graph spoke (personal account) — plan (dry-run) and apply,
same contract as spoke_google.py.

Auth: MS_CLIENT_ID / MS_REFRESH_TOKEN from the environment (sourced from
the "Contact Sync Microsoft" Pass item by the caller). Public client +
refresh token — no client secret exists for this app registration.

Note: Graph refresh tokens are single-use-ish (a refresh returns a NEW
refresh token). apply/plan print the rotated token to fd 3 if open, so
the caller can update Pass — otherwise the old one usually keeps working
until expiry, but updating keeps us out of the 90-day-expiry trap.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize  # noqa: E402


def get_tokens():
    body = urllib.parse.urlencode({
        "client_id": os.environ["MS_CLIENT_ID"],
        "grant_type": "refresh_token",
        "refresh_token": os.environ["MS_REFRESH_TOKEN"],
        "scope": "Contacts.ReadWrite offline_access",
    }).encode()
    req = urllib.request.Request(
        "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
        data=body, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        tok = json.load(r)
    new_refresh = tok.get("refresh_token", "")
    if new_refresh and new_refresh != os.environ["MS_REFRESH_TOKEN"]:
        try:
            os.write(3, new_refresh.encode())  # caller may capture fd 3 → Pass
        except OSError:
            pass
    return tok["access_token"]


def api(token, method, path, body=None):
    url = "https://graph.microsoft.com/v1.0" + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                text = r.read()
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                retry = int(e.headers.get("Retry-After", 2 ** attempt))
                time.sleep(retry)
                continue
            raise
    raise RuntimeError(f"giving up on {method} {path} after retries")


def pull_all(token):
    contacts, url = [], "/me/contacts?$top=1000"
    while url:
        d = api(token, "GET", url)
        contacts.extend(d.get("value", []))
        nxt = d.get("@odata.nextLink")
        url = nxt.replace("https://graph.microsoft.com/v1.0", "") if nxt else None
    return contacts


# Graph hard caps, hit live during the convergence write: emailAddresses
# max 3 per contact, businessPhones max 2, homePhones max 2. Contacts
# exceeding them hold a truncated view in MS — the full sets live in the
# canonical store and every other provider.
MAX_EMAILS = 3
MAX_BUSINESS = 2
MAX_HOME = 2


def capped(c):
    """The subset of a canonical contact that Graph can actually hold."""
    emails = c["emails"][:MAX_EMAILS]
    phones = list(c["phones"])
    mobile = phones[0] if phones else None
    business = phones[1:1 + MAX_BUSINESS]
    home = phones[1 + MAX_BUSINESS:1 + MAX_BUSINESS + MAX_HOME]
    return emails, mobile, business, home


def to_graph(c):
    """Canonical dict → Graph contact body (core field set)."""
    emails, mobile, business, home = capped(c)
    body = {
        "givenName": c["given"] or None,
        "surname": c["family"] or None,
        "displayName": c["name"] or None,
        "companyName": c["org"] or None,
        "jobTitle": c["title"] or None,
        # Deliberately "" (not dropped) when canonical has no note: a PATCH
        # that omits personalNotes leaves the old provider note in place —
        # cleared junk notes were resurrecting on every plan until this.
        "personalNotes": c["notes"] or "",
        "emailAddresses": [{"address": e, "name": c["name"] or e} for e in emails],
        "mobilePhone": mobile,
        "businessPhones": business,
        "homePhones": home,
    }
    if c["urls"]:
        body["businessHomePage"] = c["urls"][0]
    return {k: v for k, v in body.items() if v is not None}


def differs(canon, ms_norm):
    # Cap-aware: compare what Graph CAN hold against what it DOES hold —
    # otherwise a contact with >3 emails looks perpetually out-of-sync
    # and gets rewritten every run.
    emails, mobile, business, home = capped(canon)
    want_phones = [p for p in [mobile] + business + home if p]
    return (
        sorted(emails) != sorted(ms_norm["emails"])
        or sorted(want_phones) != sorted(ms_norm["phones"])
        or (canon["name"] or "") != (ms_norm["name"] or "")
        or (canon["org"] or "") != (ms_norm["org"] or "")
        or (canon["title"] or "") != (ms_norm["title"] or "")
        or (canon["notes"] or "") != (ms_norm["notes"] or "")
    )


def make_plan(canonical_path, out_path):
    token = get_tokens()
    current_raw = pull_all(token)
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
        json.dump(current_raw, tf)
        tmp = tf.name
    current = {c["source_id"]: c for c in normalize.from_ms_graph(tmp)}
    os.unlink(tmp)

    canonical = json.load(open(canonical_path))
    plan = {"create": [], "update": [], "delete": [], "unchanged": 0}
    for c in canonical:
        if c.get("excluded"):
            continue  # import-artifact husks etc. — never synced anywhere
        ids = c["sources"].get("ms_personal", [])
        if not ids:
            plan["create"].append({"uid": c["uid"], "name": c["name"]})
            continue
        survivor = ids[0]
        for dup in ids[1:]:
            plan["delete"].append({"uid": c["uid"], "ms_id": dup, "name": c["name"],
                                   "reason": "intra-ms duplicate merged"})
        if survivor in current and differs(c, current[survivor]):
            plan["update"].append({"uid": c["uid"], "ms_id": survivor, "name": c["name"]})
        else:
            plan["unchanged"] += 1
    with open(out_path, "w") as f:
        json.dump(plan, f, indent=1)
    os.chmod(out_path, 0o600)
    print(f"plan: create {len(plan['create'])}, update {len(plan['update'])}, "
          f"delete {len(plan['delete'])} (intra-ms dups), unchanged {plan['unchanged']}")


def apply_plan(plan_path, canonical_path, state_path):
    token = get_tokens()
    plan = json.load(open(plan_path))
    canonical = {c["uid"]: c for c in json.load(open(canonical_path))}
    state = json.load(open(state_path))

    created = updated = deleted = failed = 0
    for item in plan["create"]:
        c = canonical[item["uid"]]
        try:
            r = api(token, "POST", "/me/contacts", body=to_graph(c))
            c["sources"]["ms_personal"] = [r["id"]]
            state["contacts"][c["uid"]]["providers"]["ms_personal"] = [r["id"]]
            created += 1
        except urllib.error.HTTPError as e:
            print(f"CREATE FAILED {item['name']!r}: {e.code} {e.read()[:200]}", file=sys.stderr)
            failed += 1
    for item in plan["update"]:
        c = canonical[item["uid"]]
        try:
            api(token, "PATCH", "/me/contacts/" + item["ms_id"], body=to_graph(c))
            updated += 1
        except urllib.error.HTTPError as e:
            print(f"UPDATE FAILED {item['name']!r}: {e.code} {e.read()[:200]}", file=sys.stderr)
            failed += 1
    for item in plan["delete"]:
        try:
            api(token, "DELETE", "/me/contacts/" + item["ms_id"])
            deleted += 1
        except urllib.error.HTTPError as e:
            if e.code == 404:
                deleted += 1  # already gone — same outcome
            else:
                print(f"DELETE FAILED {item['name']!r}: {e.code} {e.read()[:200]}", file=sys.stderr)
                failed += 1
                continue
        c = canonical[item["uid"]]
        c["sources"]["ms_personal"] = [i for i in c["sources"].get("ms_personal", []) if i != item["ms_id"]]
        state["contacts"][item["uid"]]["providers"]["ms_personal"] = c["sources"]["ms_personal"]

    with open(canonical_path, "w") as f:
        json.dump(list(canonical.values()), f, indent=1)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=1)
    print(f"applied: created {created}, updated {updated}, deleted {deleted}, failed {failed}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["plan", "apply"])
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--out")
    ap.add_argument("--plan")
    ap.add_argument("--state")
    args = ap.parse_args()
    if args.mode == "plan":
        make_plan(args.canonical, args.out or "ms-plan.json")
    else:
        apply_plan(args.plan, args.canonical, args.state)


if __name__ == "__main__":
    main()
