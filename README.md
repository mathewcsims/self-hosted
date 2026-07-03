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

## Architecture, in short

```
internet → DrayTek router → Pi (Caddy, terminates HTTPS, routes by hostname)
                                  ├─ cp.mathewcsims.uk                → Mac
                                  ├─ prospect-ukri-tus.mathewcsims.uk → Mac
                                  ├─ vikunja.mathewcsims.uk           → Mac
                                  ├─ dashboard.mathewcsims.uk         → itself (Pi)
                                  └─ speedtest.mathewcsims.uk         → itself (Pi, LAN clients only)
```

Each app is its own `podman-compose`/`docker-compose` project in its own
folder. The Pi is the only thing the router ever forwards traffic to; nothing
on the Mac is ever directly internet-facing. See [SETUP.md](SETUP.md) for the
full diagram, the reasoning behind it, and the general recipe for adding
another app.

## Secrets — this repo holds none

Every real password, API key, and OAuth client secret lives in a **gitignored**
file, never in a tracked one:

| Real (gitignored) | Template (tracked) |
|---|---|
| `copyparty/cfg/accounts.conf` | `accounts.conf.example` |
| `vikunja/.env` | `.env.example` |
| `nimbus/.env` | `.env.example` |
| `speedtest-tracker/.env` | `.env.example` |
| `pi-reverse-proxy/.env` | `.env.example` |

To stand this up from scratch (or recreate a secret file), copy the matching
`.example` file, fill in real values, and see [SETUP.md](SETUP.md) for where
each one needs to live and how to generate strong values.

Runtime data (actual files, notes, databases, sessions) is gitignored too —
this repo is infrastructure-as-code only, never the data the apps hold.

## Layout

```
copyparty/            compose.yaml, config, and data (Mac)
memos-prospect-ukri-tus/  compose.yaml and data (Mac)
vikunja/               compose.yaml and data (Mac)
nimbus/                compose.yaml (Pi — deployed via scp + docker compose)
speedtest-tracker/      compose.yaml (Pi — deployed via scp + docker compose, LAN-only)
pi-reverse-proxy/      Caddy reverse proxy (Pi — deployed via scp + docker compose)
autostart/             launchd auto-start for podman on the Mac
SETUP.md               full setup, deployment, and troubleshooting guide
```
