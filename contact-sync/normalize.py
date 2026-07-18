"""Provider-specific JSON → one common contact shape.

Every spoke's raw pull (Proton vCards, Google People API, MS Graph,
Contacts.app JXA) is reduced to the same dict:

    {
      "source":    "proton" | "google" | "ms_personal" | "ms_work",
      "source_id": provider's own ID for the contact,
      "name":      display name ("" if none),
      "given":     given name ("" if none),
      "family":    family name ("" if none),
      "emails":    [lowercased, deduped],
      "phones":    [E.164-normalized where possible, deduped],
      "org":       organization ("" if none),
      "title":     job title ("" if none),
      "notes":     free-text notes ("" if none),
      "birthday":  "YYYY-MM-DD" or "--MM-DD" or "",
      "urls":      [as-is, deduped],
      "modified":  ISO-8601 UTC timestamp or "" (drives newest-wins),
    }

Stdlib only, matching this repo's other Python (vikunja-webhook-relay).
Phone normalization assumes UK numbers for bare national formats —
07... → +447..., 0044/44-prefixed → +44 — anything else keeps digits
with a leading + if it had one. Good enough for identity-matching; the
original string is what gets written back to providers, never the
normalized form.
"""

import json
import re


def norm_email(e):
    return e.strip().lower()


def norm_phone(p):
    digits = re.sub(r"[^\d+]", "", p)
    if not digits:
        return ""
    if digits.startswith("00"):
        digits = "+" + digits[2:]
    if digits.startswith("07") and len(digits) == 11:
        digits = "+44" + digits[1:]
    elif digits.startswith("0") and not digits.startswith("+"):
        # other UK national formats (landlines)
        digits = "+44" + digits[1:]
    elif not digits.startswith("+") and digits.startswith("44"):
        digits = "+" + digits
    return digits


def _dedupe(seq):
    seen, out = set(), []
    for x in seq:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out


def _blank(source, source_id):
    return {
        "source": source, "source_id": source_id,
        "name": "", "given": "", "family": "",
        "emails": [], "phones": [],
        "org": "", "title": "", "notes": "", "birthday": "",
        "urls": [], "modified": "",
    }


# ── Proton (proton-cli `contacts list` with cards) ──────────────────────

def _unfold_vcard(text):
    """RFC 6350 line unfolding: a line starting with space/tab continues
    the previous line."""
    lines = []
    for raw in text.replace("\r\n", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    return lines


def _vcard_props(cards):
    """Flatten a Proton contact's cards (clear-signed + encrypted) into
    [(PROP, params, value)], stripping item-group prefixes."""
    props = []
    for card in cards:
        for line in _unfold_vcard(card):
            if ":" not in line or line.startswith(("BEGIN:", "END:", "VERSION:")):
                continue
            head, value = line.split(":", 1)
            # strip "item1." style group prefix
            head = re.sub(r"^[A-Za-z0-9]+\.", "", head)
            parts = head.split(";")
            props.append((parts[0].upper(), parts[1:], value))
    return props


def _unescape_vcard(v):
    return v.replace("\\n", "\n").replace("\\,", ",").replace("\\;", ";")


def from_proton(path):
    out = []
    for c in json.load(open(path)):
        n = _blank("proton", c["id"])
        n["name"] = c.get("name", "") or ""
        n["emails"] = _dedupe(norm_email(e) for e in c.get("emails", []))
        for prop, params, value in _vcard_props(c.get("cards", [])):
            value = value.strip()
            if not value:
                continue
            if prop == "FN" and not n["name"]:
                n["name"] = _unescape_vcard(value)
            elif prop == "N":
                bits = value.split(";")
                n["family"] = _unescape_vcard(bits[0]) if bits else ""
                n["given"] = _unescape_vcard(bits[1]) if len(bits) > 1 else ""
            elif prop == "EMAIL":
                e = norm_email(value)
                if e not in n["emails"]:
                    n["emails"].append(e)
            elif prop == "TEL":
                n["phones"].append(norm_phone(value))
            elif prop == "ORG":
                n["org"] = n["org"] or _unescape_vcard(value.split(";")[0])
            elif prop == "TITLE":
                n["title"] = n["title"] or _unescape_vcard(value)
            elif prop == "NOTE":
                n["notes"] = n["notes"] or _unescape_vcard(value)
            elif prop == "BDAY":
                n["birthday"] = n["birthday"] or value
            elif prop == "URL":
                n["urls"].append(value)
            elif prop == "REV":
                n["modified"] = value
        n["phones"] = _dedupe(n["phones"])
        n["urls"] = _dedupe(n["urls"])
        out.append(n)
    return out


# ── Google People API ───────────────────────────────────────────────────

def from_google(path):
    out = []
    for p in json.load(open(path)):
        n = _blank("google", p["resourceName"])
        names = p.get("names", [])
        if names:
            n["name"] = names[0].get("displayName", "")
            n["given"] = names[0].get("givenName", "")
            n["family"] = names[0].get("familyName", "")
        n["emails"] = _dedupe(norm_email(e.get("value", "")) for e in p.get("emailAddresses", []))
        n["phones"] = _dedupe(norm_phone(t.get("value", "")) for t in p.get("phoneNumbers", []))
        orgs = p.get("organizations", [])
        if orgs:
            n["org"] = orgs[0].get("name", "")
            n["title"] = orgs[0].get("title", "")
        bios = p.get("biographies", [])
        if bios:
            n["notes"] = bios[0].get("value", "")
        bdays = p.get("birthdays", [])
        if bdays:
            d = bdays[0].get("date", {})
            y, m, day = d.get("year"), d.get("month"), d.get("day")
            if m and day:
                n["birthday"] = (f"{y:04d}-" if y else "--") + f"{m:02d}-{day:02d}"
        n["urls"] = _dedupe(u.get("value", "") for u in p.get("urls", []))
        sources = p.get("metadata", {}).get("sources", [])
        times = [s.get("updateTime", "") for s in sources if s.get("updateTime")]
        n["modified"] = max(times) if times else ""
        out.append(n)
    return out


# ── Microsoft Graph (personal account) ──────────────────────────────────

def from_ms_graph(path):
    out = []
    for c in json.load(open(path)):
        n = _blank("ms_personal", c["id"])
        n["name"] = c.get("displayName", "") or ""
        n["given"] = c.get("givenName", "") or ""
        n["family"] = c.get("surname", "") or ""
        n["emails"] = _dedupe(
            norm_email(e.get("address", "")) for e in c.get("emailAddresses", []))
        phones = (c.get("mobilePhone") and [c["mobilePhone"]] or []) \
            + c.get("homePhones", []) + c.get("businessPhones", [])
        n["phones"] = _dedupe(norm_phone(p) for p in phones)
        n["org"] = c.get("companyName", "") or ""
        n["title"] = c.get("jobTitle", "") or ""
        n["notes"] = c.get("personalNotes", "") or ""
        bday = c.get("birthday")
        if bday:
            n["birthday"] = bday[:10]
        if c.get("businessHomePage"):
            n["urls"] = [c["businessHomePage"]]
        n["modified"] = c.get("lastModifiedDateTime", "") or ""
        out.append(n)
    return out


# ── macOS Contacts.app JXA pull (work Exchange account) ─────────────────

def from_macos_jxa(path):
    out = []
    for c in json.load(open(path)):
        n = _blank("ms_work", c["id"])
        given = c.get("firstName") or ""
        family = c.get("lastName") or ""
        n["given"], n["family"] = given, family
        n["name"] = (given + " " + family).strip()
        n["org"] = c.get("organization") or ""
        n["title"] = c.get("jobTitle") or ""
        n["notes"] = c.get("note") or ""
        n["emails"] = _dedupe(norm_email(e["value"]) for e in c.get("emails", []))
        n["phones"] = _dedupe(norm_phone(p["value"]) for p in c.get("phones", []))
        n["modified"] = c.get("modificationDate") or ""
        out.append(n)
    return out
