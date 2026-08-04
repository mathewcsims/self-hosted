# self-hosted

Personal self-hosted infrastructure: a Mac running most apps via `podman
compose`, a Raspberry Pi as the single internet-facing reverse proxy (Caddy,
automatic HTTPS) which also hosts several apps itself, an Ubuntu box
(`slartibartfast`) running Immich, and a DrayTek Vigor2866 router
in front of the lot.

**Full setup, deployment, and troubleshooting instructions live in
[SETUP.md](SETUP.md).** This file is a short orientation.

## Apps

| App | URL | Runs on |
|-----|-----|---------|
| [copyparty](https://github.com/9001/copyparty) | `cp.mathewcsims.uk` | Mac |
| [Memos](https://github.com/usememos/memos) | `prospect-ukri-tus.mathewcsims.uk` | Mac |
| [Vikunja](https://vikunja.io) | `vikunja.mathewcsims.uk` | Mac |
| [Ghost](https://ghost.org) | `blog.mathewcsims.uk` | Mac (replaces paid Ghost(Pro) hosting) |
| [LittleLink](https://github.com/sethcottle/littlelink) | `mathewcsims.uk` | Mac (bare apex domain — static, no backend) |
| [Karakeep](https://github.com/karakeep-app/karakeep) | `karakeep.mathewcsims.uk` | Mac (migrated from a separate Tailscale-only deployment) |
| [Apprise API](https://github.com/caronc/apprise-api) | `apprise.mathewcsims.uk` | Pi (LAN-only — generic notification relay to Discord) |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | `status.mathewcsims.uk` | Pi (deliberately — stays up if the Mac doesn't) |
| Vikunja webhook relay (this repo) | `vikunja-relay.mathewcsims.uk` | Pi (LAN-only — bridges Vikunja's webhook events to Apprise) |
| Tailscale webhook relay (this repo) | `tailscale-relay.mathewcsims.uk` | Pi (public — bridges Tailscale's webhook events to Apprise; HMAC-verified) |
| [Kopia](https://kopia.io) | `backup.mathewcsims.uk` | Pi (LAN-only — encrypted, deduplicated backups to Backblaze B2) |
| Owl ([Memos](https://github.com/usememos/memos)) | `owl.mathewcsims.uk` | Mac (personal notes instance, migrated from a Tailscale-only ScaleTail deployment — closed registration, unrelated to the Prospect Memos instance above) |
| [BookStack](https://www.bookstackapp.com) | `author.mathewcsims.uk` | Mac (project wiki for writing projects — LAN-only, no SSO, local admin login) |
| [Forgejo](https://forgejo.org) | `fj.mathewcsims.uk` | Mac (self-hosted git remote + web UI for sensitive personal projects — LAN-only, SQLite, git-over-SSH on port 2222) |
| Contact sync (this repo) | — (no URL; launchd job) | Mac (cross-provider address-book sync: Proton + Google + 2× Microsoft → one canonical store, git-versioned on Forgejo) |
| [ntfy](https://github.com/binwiederhier/ntfy) | `ntfy.mathewcsims.uk` | Pi (self-hosted push notifications — on trial alongside Discord; auth default-deny, fed by Apprise) |
| Trivy scan (this repo) | — (no URL; launchd job) | Mac (weekly vulnerability scan of every pinned image in the repo, notifies on new CVEs) |
| [HealthLog](https://github.com/MBombeck/HealthLog) | `healthlog.mathewcsims.uk` | Mac (self-hosted health tracking: vitals, sleep, mood questionnaires, Samsung Health sync — **medications moved off to [MedTimer](https://github.com/Futsch1/medTimer) 2026-08-04**, see SETUP.md; PolyForm Noncommercial licensed, passkey-only login, registration disabled after initial setup) |
| [chhoto-url](https://github.com/SinTan1729/chhoto-url) | `msims.link` | Pi (self-hosted URL shortener on its own short domain — bare root redirects to `mathewcsims.uk` rather than showing the shortener's own login screen) |
| [Wanderer](https://github.com/open-wanderer/wanderer) | `wanderer.mathewcsims.uk` | Mac (self-hosted GPS trail/cycle-ride log — GPX/FIT/TCX/KML import; Meilisearch + PocketBase sidecars; posts a Memo to Owl on every new ride via a PocketBase-realtime relay) |
| [Immich](https://immich.app) | `immich.mathewcsims.uk` | **slartibartfast** (self-hosted photo/video library with local CLIP semantic search + face recognition — first app on the third host; LAN/tailnet-only, local accounts, no public sharing) |
| [LiteLLM](https://github.com/BerriAI/litellm) | `litellm.possum-prometheus.ts.net` | **slartibartfast** (OpenAI-compatible proxy in front of employer-funded Gemini Enterprise Agent Platform (formerly Vertex AI) — **tailnet-only** via a Tailscale sidecar tagged `personal` — no public hostname, no DNS record, not behind Caddy; ADC auth, no service-account key) |

### Decommissioned

Four apps were torn down on **2026-08-04** for not earning their keep:

- **Marque** — a private, work-focused third Memos instance (2 memos, 1 user).
- **Nimbus** — `dashboard.mathewcsims.uk`, the Pi-resident homelab dashboard.
- **TimeTagger** — `time.mathewcsims.uk`, fronted by oauth2-proxy for
  Infomaniak SSO (zero time records logged).
- **Speedtest Tracker** — `speedtest.mathewcsims.uk`, Pi-resident and
  LAN-only, polling every 15 minutes (3,135 results kept).

Containers, images, volumes, networks, Caddy site blocks, Uptime Kuma
monitors and DNS records are all gone; their compose projects live on only
in git history.

Their data is deliberately **not** gone. A final database dump plus a cold
`tar.gz` of each app's whole data directory sits in `db-dumps/decommissioned/`
on the relevant host — which is itself a Kopia source, so the archives ride
along with every future backup instead of ageing out of a dormant source's
retention. Every archive was restore-tested back out of Backblaze B2 and
matched its source by sha256. Each app's Proton Pass item (OIDC client
secrets, JWT secret, Nimbus's DB password, Speedtest's `APP_KEY`) was kept
for the same reason. The rebuild instructions remain in
[SETUP.md](SETUP.md), retitled as decommissioned rather than deleted.

## Architecture, in short

```
internet → DrayTek router → Pi (Caddy, terminates HTTPS, routes by hostname)
                                  ├─ mathewcsims.uk                   → Mac
                                  ├─ cp.mathewcsims.uk                → Mac
                                  ├─ prospect-ukri-tus.mathewcsims.uk → Mac
                                  ├─ vikunja.mathewcsims.uk           → Mac
                                  ├─ blog.mathewcsims.uk              → Mac
                                  ├─ karakeep.mathewcsims.uk          → Mac
                                  ├─ apprise.mathewcsims.uk           → itself (Pi, LAN clients only)
                                  ├─ status.mathewcsims.uk            → itself (Pi)
                                  ├─ vikunja-relay.mathewcsims.uk     → itself (Pi, LAN clients only)
                                  ├─ backup.mathewcsims.uk            → itself (Pi, LAN clients only)
                                  ├─ owl.mathewcsims.uk               → Mac
                                  ├─ author.mathewcsims.uk            → Mac (LAN clients only)
                                  └─ fj.mathewcsims.uk                → Mac (LAN clients only;
                                                                          git-over-SSH bypasses
                                                                          Caddy entirely, port 2222)
```

Each app is its own `podman-compose`/`docker-compose` project in its own
folder. The Pi is the only thing the router ever forwards traffic to; nothing
on the Mac is ever directly internet-facing. See [SETUP.md](SETUP.md) for the
full diagram, the reasoning behind it, and the general recipe for adding
another app.

## Secrets — this repo holds none

Every real password, API key, and OAuth client secret lives in **Proton
Pass** (the "Self-Hosted Secrets" vault), one item per app, fetched live at
deploy time — never written to a `.env` file on disk. See
[SETUP.md](SETUP.md)'s "Secrets management" section for the full model
(why, how the agent's read-only access works, and the `scripts/pass-*.sh`
tooling). `.env.example` files still exist per app as a record of which
fields each app's Pass item needs, but there's no real `.env` to copy
anymore — `cp .env.example .env` is no longer the onboarding step it used
to be.

Two exceptions: `pi-reverse-proxy/.env` holds non-secret configuration
(domain names, the Mac's LAN IP) rather than credentials, so it stays as a
plain gitignored file, not a Pass item. And the repo-root `.env` holds
`SECRET_ACCESS_TOKEN` — the durable, vault-scoped PAT the deploy tooling
uses to reach every other secret in the first place.

DNS itself is scriptable too: `scripts/dns-digitalocean.sh` and
`scripts/dns-nextdns.sh` manage the registrar's public `A` records and the
NextDNS LAN rewrites respectively, both using API tokens from Pass —
adding a new app's DNS no longer means a manual trip to either dashboard.

Runtime data (actual files, notes, databases, sessions) is gitignored too —
this repo is infrastructure-as-code only, never the data the apps hold.

## Backups

Every app's own data — across all three hosts — gets backed up by
[Kopia](https://kopia.io): encrypted client-side before it ever leaves the
machine, deduplicated so repeat backups only upload what changed, and
scheduled automatically. The Pi runs an always-on Kopia server
(`kopia-server/`) that also hosts a web UI at `backup.mathewcsims.uk`
(LAN-only) for browsing and restoring snapshots from every host. The Mac
(`kopia-mac/`) has no persistent daemon — a launchd job triggers scheduled
snapshots directly, mirroring the pattern `autostart/` already uses for
podman. Backblaze B2 is the actual storage backend; see
[SETUP.md](SETUP.md)'s Kopia section for the full architecture, retention
policy, and how to periodically mirror the whole (already encrypted) B2
bucket onto an offline external drive.

**The whole home directory is backed up, not just the apps.** Since
2026-08-04 `/Users/mathewcsims` is itself a Kopia source — media included —
so nothing on the Mac depends on Time Machine as its only copy. The
per-app sources are kept as well, for obvious granular restore targets;
Kopia dedupes content, so covering them twice costs essentially nothing.
Excluded, deliberately: the NAS mount (not this Mac's data, and where the
Time Machine image lives), Proton Drive's cloud placeholders (128 GB
apparent, 7.9 MB on disk — reading them would hydrate the lot), and ~60 GB
of regenerable machine state (caches, package stores, downloaded models,
podman VM images).

`~/Library` is excluded from that source and its valuable parts backed up
as their own instead — **Thunderbird** (the real mail store), **Application
Support**, **Keychains** and **Preferences**. Full Disk Access was granted
to `kopia` to make those readable at all, but even with it a real snapshot
of `~/Library` hit 803 unreadable paths: 671 of them one per-app file, the
rest Apple's own Siri/Spotlight/HomeKit service state. None is user data,
and the set grows with every app installed, so excluding it wholesale keeps
the nightly run at zero errors — which is what the verifier trusts.

Apple Mail, Messages and the Photos library are excluded **by choice, not
limitation**: none is used. Thunderbird is the mail store here, and
photographs live in Immich, itself a Kopia source.

**Backups are verified, and say so.** A separate nightly job
(`kopia-mac/verify-backups.sh`, 06:00, after all three hosts have finished)
checks the repository rather than trusting any job's own report: every
active source must have a complete snapshot from within the last 30 hours,
with zero errors, whose contents actually resolve in B2. On Sundays it goes
further and re-downloads a sample of real files to prove the bytes come
back, not just the metadata. It then sends **one notification confirming
the backups completed and were verified** — so a silent night is
conspicuous rather than invisible. Which sources count as "active" is read
from Kopia's own policies, so decommissioned apps drop out automatically
and new ones are picked up with no edit here.

This replaced a failure-only model that missed the failures that mattered.
On 2026-08-03 the Mac's run wedged on a NAS source and never exited;
because launchd will not start a job whose previous instance is alive, the
next night's backup never ran, and nothing alerted — it was found by hand
40 hours later. That source (a live 16 TB Time Machine sparsebundle, which
could never be copied consistently over SMB) has been removed, no source
can wedge the job indefinitely any more, and a skipped run now alerts.

## Layout

```
copyparty/            compose.yaml, config, and data (Mac)
memos-prospect-ukri-tus/  compose.yaml and data (Mac)
vikunja/               compose.yaml and data (Mac)
blog/                  compose.yaml, MySQL, and Ghost content (Mac)
landing-page/          compose.yaml, static site content (Mac, no secrets)
karakeep/              compose.yaml, bookmark/asset data, search index (Mac)
apprise/               compose.yaml (Pi — deployed via scp + docker compose, LAN-only)
uptime-kuma/           compose.yaml (Pi — deployed via scp + docker compose)
vikunja-webhook-relay/ compose.yaml + Dockerfile + relay.py (Pi — deployed via scp + docker compose, LAN-only)
kopia-server/          compose.yaml + Dockerfile + entrypoint.sh (Pi — deployed via scp + docker compose, LAN-only)
kopia-mac/             backup.sh + LaunchAgent plist (Mac — scheduled snapshots, no compose project)
owl/                   compose.yaml, logo SVG, and data (Mac — personal Memos instance)
bookstack/             compose.yaml, MariaDB, and config (Mac — project wiki, LAN-only)
.claude/skills/bookstack-api/  Claude Code skill for using BookStack's REST API
forgejo/               compose.yaml and data (Mac — self-hosted git remote, LAN-only)
.claude/skills/forgejo-api/    Claude Code skill for the scoped claude-agent bot account
contact-sync/          cross-provider contact sync engine + launchd job (Mac —
                       data lives at ~/contact-sync, store pushed to Forgejo)
wanderer/              compose.yaml and data (Mac — GPS trail/cycle-ride log)
pi-reverse-proxy/      Caddy reverse proxy (Pi — deployed via scp + docker compose)
autostart/             launchd auto-start for podman on the Mac
scripts/               deploy tooling that fetches secrets from Proton Pass
                       at deploy time — see SETUP.md
pf-lockdown/           macOS pf firewall rules restricting copyparty/Vikunja
                       to LAN-published-port access from the Pi only
SETUP.md               full setup, deployment, and troubleshooting guide
SECURITY.md            how to report a vulnerability
LICENSE                MIT, with a carve-out for the Prospect logo files
```

## License

[MIT](LICENSE), with one carve-out: the Prospect logo files under
`memos-prospect-ukri-tus/` are trademarked third-party assets, used only for
personal branding, not licensed for reuse.
