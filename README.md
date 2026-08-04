<p align="center">
  <img src="./media/preview.png" alt="better-remnawave-reverse-proxy" width="820" />
</p>

<p align="center">
  <a href="https://www.gnu.org/software/bash/"><img src="https://img.shields.io/badge/Bash-script-3DDC97?logo=gnubash&logoColor=white" alt="Bash" /></a>
  <img src="https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-8b949e?logo=debian&logoColor=white" alt="OS" />
  <img src="https://img.shields.io/badge/stack-NGINX%20%C2%B7%20Caddy%20%C2%B7%20XRAY%20REALITY-2ea043" alt="Stack" />
  <img src="https://img.shields.io/badge/version-3.3.1--better-3DDC97" alt="Version" />
  <img src="https://img.shields.io/badge/Remnawave-panel%203.x-2ea043" alt="Remnawave 3.x" />
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/Mrvibecodic/better-remnawave-reverse-proxy?color=8b949e" alt="License" /></a>
</p>

<p align="center">
  <strong>English</strong> | <a href="/README-RU.md">Русский</a>
</p>

<p align="center">
  An improved fork of <a href="https://github.com/eGamesAPI/remnawave-reverse-proxy">eGamesAPI/remnawave-reverse-proxy</a> —
  focused on <b>reliable installs</b>, <b>clear diagnostics</b> and <b>hardened defaults</b>.
</p>

---

> [!CAUTION]
> **This repository is an educational example for learning NGINX, reverse proxy and network‑security basics. Not for production use. Use at your own risk.**

---

## 🚀 Quick start

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Mrvibecodic/better-remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)
```

> Debian 11/12/13 and Ubuntu 22.04/24.04 are supported. Run as **root** on a fresh system. You need your own domain.

---

## ✨ What this fork improves

Everything from the original, plus:

| Area | Improvement |
|------|-------------|
| **Compression** | Panel 3.x no longer compresses responses, so the reverse proxy does it: `gzip` (nginx) / `encode` (Caddy) on panel, subscription and selfsteal server blocks. |
| **Your own selfsteal site** | Template choice is now **asked during node install** (it used to force a random one). A new option — *“do not install a template”* — configures the web server and leaves `/var/www/html` for your own files, **deleting nothing** and warning you if the directory is still empty. |
| **Custom Xray core** | Optional alternative core for the node — the script **downloads the pinned release automatically** ([Jolymmiles/Xray-core](https://github.com/Jolymmiles/Xray-core) `v26.7.29`), verifies its SHA256, and mounts it into the node container. Menu item, install prompt, one-click rollback to the bundled core. |
| **Panel 3.x ready** | Tracks Remnawave **3.x**: `backend:3` pinned so panel, node (3.x) and subscription‑page (8.x) stay in sync; `keygen` reads `.response.secretKey`, request bodies match 3.1 DTOs, API tokens use `name` + `expiresInDays`. |
| **Client version gate** | Default inbound ships `minClientVer: "26.3.27"` — the server checks the client's Xray version. See the note below to turn it off. |
| **Install errors** | API calls return proper exit codes and **stop** the install instead of silently continuing with empty values; every failure points to the log. |
| **Separate‑node connection** | Shows **this server's IP** and the exact panel steps, then distinguishes *core is serving* / *up but waiting for config from the panel* / *container crashed (bad SECRET_KEY)* — each with actionable hints. |
| **Security** | Per‑install random `WEBHOOK_SECRET_HEADER` and PostgreSQL password (no shared hardcoded secrets); `chmod 600` on `.env` and `docker-compose.yml`. |
| **Certificate cron** | No more weekly panel downtime — nginx restarts **only on a real renewal** (certbot `renew_hook`). |
| **Dependencies** | Preflight that shows installed versions and offers a single **y/n** to update managed packages + Docker; `openssl` ensured; **arch‑aware** `yq` (amd64/arm64) with download validation; clearer `certbot-dns-gcore` (pip) errors. |
| **Docker pulls** | `docker compose` failures are shown (incl. **Docker Hub rate limits**) instead of going to `/dev/null`; optional **registry‑mirror** prompt routes pulls around limits/blocks. |
| **Any environment** | cron setup is non‑fatal and tries systemd → `service` → `init.d` (supports `cronie`/`crond`), so installs no longer abort on containers without systemd — cert auto‑renewal still set up whenever cron is available. |
| **Robustness** | Stable locale via `LC_ALL`; fixed inherited bugs — WARP config validation before PATCH, selfsteal spinner/exit handling, `exit`→`return` in menu functions, safer IPv6 handling. |

A detailed, itemized changelog is kept by the author together with the project notes.

---

> [!IMPORTANT]
> **`minClientVer` in the default config profile.** The generated inbound sets `minClientVer: "26.3.27"`, so the server verifies the client's Xray version and rejects older clients.
> To disable the check, set the value to `0.0.0` — **removing the field is not enough, the check stays active**:
> ```json
> "realitySettings": { "minClientVer": "0.0.0", ... }
> ```
> Edit it in the panel: *Config profiles → your profile → inbound → `realitySettings`*.

---

## 🎭 Selfsteal site (template)

The node serves a decoy site on the selfsteal domain. During installation (and via menu item
**“Install random template for selfsteal node”**) you can pick:

1. **Simple web templates** · 2. **SNI templates** · 3. **Nothing SNI templates** — ready-made sets downloaded and lightly randomized by the script.
4. **Do not install a template** — the web server is configured and the content is up to you.

Choosing option **4** is the way to use your **own prepared site**: nothing is downloaded and
**nothing is deleted** — just upload your files to `/var/www/html` (mounted read-only into
nginx/Caddy). If the directory is still empty, the script says so explicitly, because until then the
selfsteal domain will return an error.

> [!TIP]
> The ready-made template options wipe `/var/www/html` before copying. If your own site is already
> there, use option 4 so it stays intact.

---

## 🧪 Alternative Xray core (optional)

The node normally runs the Xray core bundled in `remnawave/node`. You can replace it with a build from
[Jolymmiles/Xray-core](https://github.com/Jolymmiles/Xray-core) — useful when you need a newer or patched core.

- Offered during **node installation**, or any time via menu item **“Xray core for the node”**.
- The release is fetched **automatically** onto the server (no manual downloads), matched to the CPU
  architecture (amd64 / arm64 / arm32 / x86), verified against the `.dgst` **SHA256** checksum.
- The binary is installed as `xray-core` next to `docker-compose.yml` (mode `744`) and mounted as
  `./xray-core:/usr/local/bin/xray` in the `remnanode` service.
- Rollback to the image-bundled core is one menu action; status shows which core is active.

> [!NOTE]
> This is a **third-party build** — use it only if you trust the source. The default remains the core shipped with the official node image.

---

## 📦 Pinned stack

| Component | Version |
|-----------|---------|
| Remnawave panel | `remnawave/backend:3` (env: `APP_SECRET`) |
| Remnawave node / subscription page | `:latest` (3.x / 8.x) |
| NGINX | `1.30` (current stable branch) |
| Caddy | `2.11.4` |
| PostgreSQL | `18.3` |
| Valkey | `9.0.3-alpine` |

---

## 🧩 Deployment modes

- **Single server** — panel + XRAY node on one machine (quick start / moderate traffic).
- **Distributed** — **panel server** (management) + **node server** (XRAY with SelfSteal stub for VLESS REALITY).

Architecture: Xray listens on **443**, fronted by NGINX (or Caddy) over a **Unix socket** — minimal TCP overhead, REALITY‑friendly.

### Domains

Prepare three names: **panel**, **subscription page**, **SelfSteal stub** (on the node).
SSL via **Cloudflare API**, **Gcore API** (wildcard, DNS‑01) or **ACME HTTP‑01**.

> Full DNS tables and step‑by‑step deployment from the original project are kept in **[README-upstream.md](./README-upstream.md)**.

---

## 🔐 Security features

- URL‑parameter + cookie gate that hides the panel from scanners and brute‑force.
- UFW firewall rules; NODE_PORT opened **only** for the panel IP (with a warning if UFW is inactive).
- ECDSA certificates with automatic renewal; BBR congestion control.
- Containerised nginx/caddy/Postgres/Valkey — pinned image tags for reproducibility.

---

## 👥 Fork contributors

Thanks to everyone improving this fork:

| Contributor | Contribution |
|-------------|--------------|
| [@Mrvibecodic](https://github.com/Mrvibecodic) | Fork maintainer — error handling, node‑connection UX, security hardening, panel 3.x support |
| [@spectreq666](https://github.com/spectreq666) (Alexey Malinin) | [#1](https://github.com/Mrvibecodic/better-remnawave-reverse-proxy/pull/1) — reverse‑proxy compression (gzip / encode), `APP_SECRET` env for panel 3.x, `minClientVer` in the default profile, localization fixes |

Pull requests are welcome — open an issue or a PR.

---

## 🙌 Credits

Built on top of **[eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy)** — all original work and documentation belong to its authors (kept here as **[README-upstream.md](./README-upstream.md)**). Powered by [Remnawave](https://remna.st) and [XRAY](https://github.com/XTLS/Xray-core).

---

> [!CAUTION]
> **For educational and research purposes only. Bypassing network blocks or censorship may be illegal in your country. The authors take no responsibility for any legal consequences. If unsure whether using this is legal where you are — do not use it.**
