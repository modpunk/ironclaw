# CHRONICbot RPi4 Provisioning System

**Date:** 2026-02-22
**Status:** Approved
**Approach:** Thin Image + GitHub Release Bootstrap (Option B)

## Overview

CHRONICbot is the product deployment of IronClaw on Raspberry Pi 4 hardware. This design covers how a fresh RPi4 goes from bare hardware to a running CHRONICbot instance with minimal manual intervention.

The name CHRONICbot is inspired by Custom 475 steel alloy — the strongest stainless steel — with constituents mapping to C.R.O.N.I.C:
- **C**hromium (Cr)
- **R**are-earth equivalents (Molybdenum/Cobalt)
- **O**xidation-resistant
- **N**ickel (Ni)
- **I**ron (Fe) base
- **C**obalt (Co)

## Architecture

Two-layer system: a rarely-changing OS image handles hardware config, while software is pulled fresh from GitHub Releases on first boot.

```
DEVELOPMENT (laptop)
    │
    ├── Push code to kingmk3r/ChronicBot
    │
    ▼
GITHUB ACTIONS CI
    │
    ├── release.yml (existing)
    │   ├── Cross-compile ironclaw → aarch64-unknown-linux-gnu
    │   ├── Build WASM channel bundles → wasm32-wasip2
    │   └── Upload to GitHub Release
    │
    ├── image.yml (new)
    │   ├── Build custom RPi OS image via pi-gen
    │   ├── Inject: rpi-always-on.sh, firstboot service, setup script
    │   └── Upload chronicbot-rpi4.img.xz to GitHub Release
    │
    ▼
GITHUB RELEASE (e.g. v0.1.0)
    ├── ironclaw-aarch64-unknown-linux-gnu.tar.gz
    ├── telegram-wasm32-wasip2.tar.gz
    ├── chronicbot-rpi4.img.xz
    ├── chronicbot-setup.sh
    └── checksums.txt
    │
    ▼
FRESH RPI4
    ├── Flash image, configure WiFi via RPi Imager
    ├── Boot → firstboot service downloads latest release
    ├── SSH in → run `chronicbot setup` (interactive credential prompts)
    └── Running CHRONICbot instance
```

## Deployment Paths

### Path 1: Custom Image (recommended)
1. Download `chronicbot-rpi4.img.xz` from GitHub Release
2. Flash to SD card using RPi Imager (configure WiFi at this step)
3. Boot the Pi — firstboot service auto-downloads latest ironclaw
4. SSH in, run `chronicbot setup` to enter secrets
5. Done

### Path 2: Stock RPi OS + curl
1. Flash stock Raspberry Pi OS, configure WiFi
2. SSH in, run: `curl -sSL https://raw.githubusercontent.com/kingmk3r/ChronicBot/main/deploy/chronicbot-setup.sh | sudo bash`
3. Script handles everything: system hardening, download, install, interactive setup
4. Done

## File System Layout

```
/opt/chronicbot/                    # Main install directory
├── bin/
│   └── ironclaw                    # Compiled binary (aarch64)
├── channels/
│   ├── telegram.wasm               # WASM channel plugins
│   ├── telegram.capabilities.json
│   └── ...
├── .env                            # Bootstrap config (DB URL, API keys)
└── version.txt                     # Installed version for update checks

/etc/systemd/system/
├── chronicbot.service              # Main daemon (auto-restart)
├── chronicbot-firstboot.service    # One-shot: download + install on first boot
├── chronicbot-update.service       # Update script runner
├── chronicbot-update.timer         # Daily update check (3am)
├── cpu-performance.service         # Always-on: CPU governor lock
└── eth-no-eee.service              # Always-on: Ethernet EEE off

/etc/
├── ssh/sshd_config.d/99-always-on.conf
├── sysctl.d/99-always-on.conf
├── systemd/logind.conf.d/99-no-sleep.conf
├── NetworkManager/conf.d/99-no-powersave.conf
└── chronicbot/
    └── firstboot.done              # Marker: firstboot already ran

/usr/local/bin/
└── chronicbot                      # Symlink → /opt/chronicbot/bin/ironclaw
```

## RPi Hardware Hardening (rpi-always-on.sh)

The image ships with all power-saving and sleep behaviors disabled:

| Layer | Setting | Value |
|-------|---------|-------|
| CPU | Governor | `performance` (locked at max freq) |
| CPU | Min frequency | = max frequency (no downclocking) |
| CPU | Dynamic voltage/freq | `force_turbo=1` (disabled) |
| CPU | Thermal soft limit | 70C (raised from 60C) |
| WiFi | Power save | `off` (NetworkManager conf) |
| USB | Autosuspend | `-1` (never) |
| USB | Runtime PM | `on` (always active) |
| Ethernet | EEE | `off` (Energy Efficient Ethernet disabled) |
| Network | TCP keepalive | 60s/10s/6 probes (aggressive) |
| Kernel | laptop_mode | `0` |
| Kernel | Console blank | `0` (never) |
| Kernel | Dirty writeback | 500 centisecs (no power-save batching) |
| systemd | sleep/suspend/hibernate | `masked` |
| systemd | logind idle action | `ignore` / `infinity` |
| HDMI | Blanking/DPMS | Disabled |
| Bluetooth | Service | Disabled |
| SSH | Server keepalive | 30s interval, 5 retries |

Script is idempotent and safe to run multiple times.

## Bootstrap Script (chronicbot-setup.sh)

Single script that handles both firstboot (headless) and manual (interactive) modes:

1. **Detect environment** — RPi check, root check, firstboot marker
2. **System hardening** — Run rpi-always-on.sh (idempotent)
3. **Install dependencies** — PostgreSQL, create chronicbot user + database
4. **Download latest release** — Query GitHub API, download binary + WASM channels, verify SHA256
5. **Install** — Extract to /opt/chronicbot/, create systemd services, symlink
6. **Mark firstboot complete** — Touch /etc/chronicbot/firstboot.done
7. **Interactive setup** (if TTY or --setup flag) — Prompt for API key, Telegram token, agent name, write .env, start service

## Update Mechanism

Daily systemd timer checks GitHub Releases for new versions:

1. Query `https://api.github.com/repos/kingmk3r/ChronicBot/releases/latest`
2. Compare tag against `/opt/chronicbot/version.txt`
3. If new version: download, verify checksums, stop service
4. Swap binaries (keep old as `.old/` for rollback)
5. Start service, health check `localhost:8080/health`
6. If healthy: clean up old files, update version.txt
7. If unhealthy: automatic rollback to previous version

Properties:
- Zero downtime for version checks
- Automatic rollback on bad releases
- Opt-out via `systemctl disable chronicbot-update.timer`

## Main Service (chronicbot.service)

```ini
[Unit]
Description=CHRONICbot AI Assistant
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=chronicbot
Group=chronicbot
WorkingDirectory=/opt/chronicbot
EnvironmentFile=/opt/chronicbot/.env
ExecStart=/opt/chronicbot/bin/ironclaw run
Restart=always
RestartSec=5
WatchdogSec=300

[Install]
WantedBy=multi-user.target
```

## New Files in Repository

```
deploy/
├── chronicbot-setup.sh              # Main bootstrap script
├── rpi-always-on.sh                 # Hardware hardening script
├── chronicbot.service               # systemd unit for main daemon
├── chronicbot-firstboot.service     # systemd oneshot for first-boot
├── chronicbot-update.sh             # Update script
├── chronicbot-update.service        # systemd unit for update
├── chronicbot-update.timer          # Daily update check timer
└── image/
    ├── build-image.sh               # pi-gen wrapper
    └── config                       # pi-gen stage config

.github/workflows/
└── image.yml                        # CI: build RPi image on release
```

## GitHub Release Artifacts

Each tagged release produces:

| Artifact | Source | Purpose |
|----------|--------|---------|
| `ironclaw-aarch64-unknown-linux-gnu.tar.gz` | Existing release.yml | Binary for RPi4 |
| `telegram-wasm32-wasip2.tar.gz` | Existing release.yml | Telegram channel |
| `chronicbot-rpi4.img.xz` | New image.yml | Flashable RPi OS image |
| `chronicbot-setup.sh` | New image.yml | Standalone bootstrap script |
| `checksums.txt` | Both workflows | SHA256 verification |

## Channels Enabled by Default

| Channel | Type | Notes |
|---------|------|-------|
| CLI | Built-in | Always available |
| Telegram | WASM plugin | Requires bot token |
| Web UI | HTTP (port 8080) | Browser interface + API |
| Claude Code | Via HTTP API | Jobs with `mode: "claude_code"` |

## Success Criteria

1. A fresh RPi4 with the custom image reaches a running CHRONICbot in under 10 minutes
2. Stock RPi OS + curl path works identically
3. Updates are automatic with zero manual intervention
4. Bad releases auto-rollback without bricking the device
5. No sleep, power-save, or economy mode can take the device offline
