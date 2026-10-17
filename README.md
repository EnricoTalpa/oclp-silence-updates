# OCLP Silence Updates

**Silence — and keep silenced — the macOS "update available" badge and notifications on Macs patched with [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher).**

On an OCLP-patched Mac, the red "1" badge on System Settings and the update notifications are a trap for non-expert users: accepting a casual upgrade can leave a perfectly working system without graphics acceleration or worse. This project removes the badge/notifications at the source, explains **why** (OCLP-aware detection), keeps them away automatically, and can optionally add a **"Silence Update Notifications"** item to the OpenCore Legacy Patcher app itself.

> Non-expert users should never see an upgrade prompt on a Mac whose hardware officially ended support years ago.

## Why this exists

The official [OCLP update guide](https://dortania.github.io/OpenCore-Legacy-Patcher/UPDATE.html) is crystal clear:

- **Minor updates** (13.x → 13.y): only after updating OCLP, rebuilding OpenCore to the internal disk, and reinstalling root patches *after* the update
- **Major upgrades** (Sonoma → Sequoia …): from a USB installer — *"Major upgrades may work using System Settings but this is not recommended"*

Yet macOS keeps pushing the badge and the "Upgrade Now" prompts to everyone. On a 2009 Mac mini running Ventura thanks to OCLP, that prompt is a loaded gun in the hands of a non-technical user.

## How the badge really works (and why naive fixes fail)

The badge regenerates from **independent sources**. Disabling only some of them looks like it works… until it comes back seconds later or after a reboot:

1. Five software-update daemons (`softwareupdated`, `mobile.softwareupdated`, `MobileSoftwareUpdate.*`, `softwareupdate_firstrun_tasks`)
2. Global preferences (`AutomaticCheckEnabled`, `RecommendedUpdates`, `FirstOfferDateDictionary`…)
3. Software-update caches in `/var/db/softwareupdate`
4. Per-user `com.apple.ncprefs.plist` — the badge bit of `SoftwareUpdateNotification` (`flags & ~2`) — plus `AttentionPrefBundleIDs`
5. **The key discovery (v6, April 2026): `~/Library/CoreFollowUp/items.db`** — a separate SQLite database read by `followupd` (and `SoftwareUpdateNotificationManager`) that regenerates the badge **independently of everything above**. This is why "the badge came back after a few seconds or after reboot" with earlier approaches.

This project handles all five, and keeps handling them.

## What you get

### 1. Standalone companion — `resetta_aggiornamenti_bash.sh` (v8)

A single zero-dependency bash script (works on Macs **without Python / Command Line Tools** — common on OCLP Macs). Uses only native macOS tools: `launchctl`, `defaults`, `sqlite3`, `plutil`, `nvram`, `killall`.

| Command | Meaning | Notes |
|---|---|---|
| `status` | read-only report: OCLP detection, daemons, badge, CoreFollowUp, daemon state | no sudo, changes nothing |
| `resetta` (sudo) | full silence: backups + all 5 sources + LaunchDaemon + Desktop launcher | asks confirmation; `--si` skips prompts |
| `ripristina` (sudo) | restore the latest backup (re-enable updates) — **run this before a real, intentional macOS update** | `--si` skips prompts |
| `pausa [days]` (sudo) | suspend the auto-cleaning daemon for N days (default 14) — update window | |
| `attiva` (sudo) | resume auto-cleaning immediately | |

OCLP-aware:

- Detects OpenCore via NVRAM (`opencore-version`, `OCLP-Version`), model via `hw.model`, and prints the **reason** (last officially supported macOS for that model, OCLP update procedure)
- Installs a system **LaunchDaemon** (`it.enrico.resetta-aggiornamenti`, every 30 min, from boot, for **all** users): re-checks and cleans the per-user sources if macOS regenerates them — killing the Dock *only* when something actually changed
- On **non-OCLP Macs the daemon stays asleep** (detects OpenCore, exits without touching anything)
- Every `resetta` creates a full backup (`~/resetta-aggiornamenti-backup/<timestamp>/`) with an auto-generated `RIPRISTINA_TUTTO.sh` restore script
- The script's console UI is Italian (it was built for an Italian fleet); the commands above are the full translation

### 2. Optional: patched OpenCore Legacy Patcher — `fork/`

A minimal patch (3 files) that adds a **"Silence Update Notifications"** button to the OCLP main menu:

- Opens a dialog with OCLP detection, the reason, live status, and **Silenzia / Ripristina** buttons
- Operations run with admin rights through the standard macOS password dialog (`osascript … with administrator privileges`) — no Terminal needed, non-expert friendly
- Ships the companion inside the app and installs it on first use
- **Disables the in-app auto-updater in the fork build** (a source-built app is treated as a nightly and offers the official release — which would silently remove the added menu item)
- `target_arch="x86_64"` in the included patch (built for an Intel 2009 Mac mini; on Apple Silicon change it back to `universal2` in the spec)

```bash
# build the patched OpenCore-Patcher.app (requires Python 3.11 + OCLP requirements)
bash build-fork.sh            # clones OCLP 2.5.1, applies the patch, builds
bash build-fork.sh <tag>      # any other release tag (re-apply on every OCLP release)
```

## Safety

- The approach is **intentionally aggressive**: it disables software-update daemons. Before *intentionally* updating macOS, run `ripristina` (or the Ripristina button) and follow the official OCLP update guide, then silence again after the update.
- Non-OCLP Macs are untouched by the daemon; the companion works there too but the status report will say "native boot" and silencing is optional.
- Tested in the field on: Mac mini 2009 (`Macmini3,1`, Core 2 Duo, non-Metal) — macOS Ventura 13.7.8 via OCLP 2.5.1 / OpenCore 1.0.6 (badge ON → silenced → verified end-to-end, including the app menu button); macOS 26.7.1 non-OCLP host (read-only status).

## History & credits

| Version | Date | What |
|---|---|---|
| v5 | 2026-03-17 | daemons + prefs + cache + ncprefs badge bit |
| v6 | 2026-04-11 | **CoreFollowUp discovery** (`items.db` + `followupd`), full backups + auto-generated restore script |
| v7 | 2026-10-16 | bash edition for Macs without Python3/CLT |
| v8 | 2026-10-17 | OCLP-aware: NVRAM detection + reasons, system LaunchDaemon, pausa/attiva, fork patch with menu item |

- Original problem-solving and scripts: Enrico (EnricoTalpa) — started on a friend's MacBook (v5/v6) and on a 2009 Mac mini media center (v7/v8)
- The CoreFollowUp mechanism was found by observing that every "successful" fix regenerated within seconds on a live system
- **This project builds on [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher)** by Dhinak G, Mykola Grymalyuk and contributors — their project, docs and update guide are the foundation. The fork patch file is provided under their (BSD-style) license with attribution; see `LICENSE`

OCLP itself currently has a hold on new issues and pull requests; a proper upstream PR is planned for when it lifts.

## License

MIT for the original code in this repo (companion script, recipe, docs). The `fork/` patch derives from OpenCore Legacy Patcher and is provided under its license terms, with this acknowledgment:

> This product includes software developed by Dortania and OpenCore Legacy Patcher contributors.

---

## 🇮🇹 Sezione italiana

Il progetto nasce per una flotta di Mac italiani (un Mac mini 2009 "cinema" e un MacBook di famiglia) patchati con OCLP: utenti non esperti che non devono mai vedere il prompt di aggiornamento.

- Script principale: `resetta_aggiornamenti_bash.sh` (v8, solo strumenti nativi, nessuna dipendenza) — comandi: `status`, `resetta`, `ripristina`, `pausa`, `attiva`
- Il companion rileva da solo il boot OpenCore (NVRAM) e il modello, **spiega il motivo** e installa un LaunchDaemon di sistema che ripulisce ogni 30 minuti (dorme sui Mac non-OCLP)
- Patch opzionale dell'app OCLP: pulsante **"Silence Update Notifications"** nel menu principale, con dialogo (rilevamento, motivo, stato) e pulsanti Silenzia/Ripristina con la password di macOS — senza Terminale
- Prima di aggiornare macOS **volontariamente**: `ripristina` → guida ufficiale Dortania → di nuovo `resetta` alla fine
- Installato e collaudato sul campo: Mac-mini-di-Cinema (192.168.88.233) — badge rimosso, daemon attivo, backup con script di ripristino
