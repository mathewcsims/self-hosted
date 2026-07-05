# self-hosted

Personal self-hosted infrastructure: a Mac running most apps via `podman
compose`, a Raspberry Pi as the single internet-facing reverse proxy (Caddy,
automatic HTTPS), and a DrayTek Vigor2866 router in front of both.

**Full setup, deployment, and troubleshooting instructions live in
[SETUP.md](SETUP.md).** This file is a short orientation.

## Apps

| App | URL | Runs on |
|-----|-----|---------|
| [copyparty](https://github.com/9001/copyparty) | `cp.mathewcsims.uk` | Mac |
| [Memos](https://github.com/usememos/memos) | `prospect-ukri-tus.mathewcsims.uk` | Mac |
| [Vikunja](https://vikunja.io) | `vikunja.mathewcsims.uk` | Mac |
| [Nimbus](https://github.com/Turbootzz/Nimbus) | `dashboard.mathewcsims.uk` | Pi (deliberately — stays up if the Mac doesn't) |
| [Speedtest Tracker](https://github.com/alexjustesen/speedtest-tracker) | `speedtest.mathewcsims.uk` | Pi (LAN-only — no WAN access at all) |
| [Ghost](https://ghost.org) | `blog.mathewcsims.uk` | Mac (replaces paid Ghost(Pro) hosting) |
| [LittleLink](https://github.com/sethcottle/littlelink) | `mathewcsims.uk` | Mac (bare apex domain — static, no backend) |
| [Karakeep](https://github.com/karakeep-app/karakeep) | `karakeep.mathewcsims.uk` | Mac (migrated from a separate Tailscale-only deployment) |

## Architecture, in short

```
internet → DrayTek router → Pi (Caddy, terminates HTTPS, routes by hostname)
                                  ├─ mathewcsims.uk                   → Mac
                                  ├─ cp.mathewcsims.uk                → Mac
                                  ├─ prospect-ukri-tus.mathewcsims.uk → Mac
                                  ├─ vikunja.mathewcsims.uk           → Mac
                                  ├─ blog.mathewcsims.uk              → Mac
                                  ├─ karakeep.mathewcsims.uk          → Mac
                                  ├─ dashboard.mathewcsims.uk         → itself (Pi)
                                  └─ speedtest.mathewcsims.uk         → itself (Pi, LAN clients only)
```

Each app is its own `podman-compose`/`docker-compose` project in its own
folder. The Pi is the only thing the router ever forwards traffic to; nothing
on the Mac is ever directly internet-facing. See [SETUP.md](SETUP.md) for the
full diagram, the reasoning behind it, and the general recipe for adding
another app.

## Secrets — this repo holds none

Every real password, API key, and OAuth client secret lives in **Proton
Pass** (the "Agent Secrets" vault), one item per app, fetched live at
deploy time — never written to a `.env` file on disk. See
[SETUP.md](SETUP.md)'s "Secrets management" section for the full model
(why, how the agent's read-only access works, and the `scripts/pass-*.sh`
tooling). `.env.example` files still exist per app as a record of which
fields each app's Pass item needs, but there's no real `.env` to copy
anymore — `cp .env.example .env` is no longer the onboarding step it used
to be.

The one exception: `pi-reverse-proxy/.env` holds non-secret configuration
(domain names, the Mac's LAN IP) rather than credentials, so it stays as a
plain gitignored file, not a Pass item.

Runtime data (actual files, notes, databases, sessions) is gitignored too —
this repo is infrastructure-as-code only, never the data the apps hold.

## Layout

```
copyparty/            compose.yaml, config, and data (Mac)
memos-prospect-ukri-tus/  compose.yaml and data (Mac)
vikunja/               compose.yaml and data (Mac)
blog/                  compose.yaml, MySQL, and Ghost content (Mac)
landing-page/          compose.yaml, static site content (Mac, no secrets)
karakeep/              compose.yaml, bookmark/asset data, search index (Mac)
nimbus/                compose.yaml (Pi — deployed via scp + docker compose)
speedtest-tracker/      compose.yaml (Pi — deployed via scp + docker compose, LAN-only)
pi-reverse-proxy/      Caddy reverse proxy (Pi — deployed via scp + docker compose)
autostart/             launchd auto-start for podman on the Mac
scripts/               deploy tooling that fetches secrets from Proton Pass
                       at deploy time — see SETUP.md
SETUP.md               full setup, deployment, and troubleshooting guide
```
