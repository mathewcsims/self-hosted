# Security Policy

This repo is infrastructure-as-code for my own personal self-hosted stack —
not a product, but real, currently-running infrastructure. If you spot
something that looks like a genuine security issue (not just a style
preference or a "you could also do X" suggestion), I'd genuinely appreciate
a private heads-up before it's discussed publicly.

## Reporting a vulnerability

Email **mat@mathewcsims.uk** with a description of the issue and, if
possible, how you found it. Please don't open a public GitHub issue for
anything that could be actively exploited against the live services this
repo describes.

I'll aim to acknowledge within a few days and let you know once it's
addressed. This is a one-person hobby project, not a funded security
program — there's no bounty on offer, just my thanks.

## Scope

**In scope:** anything in this repo that reveals a real weakness in how the
described infrastructure is configured or hardened — e.g. a misconfigured
rate limit, an overly permissive access rule, a pinned dependency with a
disclosed CVE that was missed.

**Out of scope:**
- Actively probing, scanning, or attempting to exploit the live services at
  `*.mathewcsims.uk` or the underlying hosts. Reading the repo and telling
  me what you noticed is welcome; treating the live infrastructure as a
  pentest target is not.
- Vulnerabilities in upstream software itself (report those to the
  relevant upstream project) — unless this repo is using a version that's
  already known-vulnerable, which *is* in scope here.
- Anything requiring physical or network access you wouldn't otherwise have
  (e.g. already being on my LAN).

## Why this exists

Every credential this stack uses lives in a password manager (Proton
Pass), fetched at deploy time — nothing sensitive is tracked in this repo
itself (see `SETUP.md`'s "Secrets management" section). But infrastructure
configuration can still have real mistakes in it, and I'd rather hear
about them from you first.
