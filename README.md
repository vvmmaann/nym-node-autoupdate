# nym-node-autoupdate

<img align="right" width="120" src="docs/nymi.png" alt="Nymi">

A small, self-contained, **safe**, role-aware auto-updater for a Nym node under systemd.

It fires on a schedule (a systemd timer, hourly by default) and keeps the node current. For each
component, if a new stable release exists it downloads it, verifies it, swaps the binary, restarts
the service, and **rolls back automatically if the service does not come back healthy**. Between
releases it does nothing. It is designed to never leave a node down.

It also pairs with **Nymi**, a Telegram bot that pings you when your node updates, when a release
drops, when stake or stress moves, or when a node goes offline - and lets you force an update on
demand. See [Nymi (Telegram alerts)](#nymi-telegram-alerts) below. **The node never holds a bot token.**

## What it updates

- **`nym-node`** - the single binary that runs in any role (mixnode / entry-gateway / exit-gateway).
  Updating it covers every role; there is no separate "gateway binary". Source:
  `github.com/nymtech/nym` (tags `nym-binaries-v*`), SHA-256 verified against the release `hashes.json`.
- **`nym-bridge`** (the Nym QUIC Bridge) - **gateways only**. It is a separate component with its own
  release line, so the script updates it too, but only when `nym-bridge.service` is present on the host.
  Source: `github.com/nymtech/nym-bridges` (tags `bridge-binaries-v*`). Those releases ship no checksum
  file, so the bridge binary is verified by HTTPS + a smoke test rather than SHA-256, and swapped with
  the same backup/rollback machinery as `nym-node`. A mixnode has no bridge, so this step is skipped.
- **Network Tunnel Manager (NTM)** - **exit gateways only**. This is `network-tunnel-manager.sh`
  (a script, not a binary) that sets up the gateway's iptables / forwarding / tunnel rules. After a
  `nym-node` release the updater reads **only that release's CHANGELOG.md section** as a *signal* - it
  never executes the changelog as instructions. If the section mentions tunnel / ports / firewall /
  wireguard (or if a tunnel self-test fails), it fetches the **tag-matched** NTM from `nymtech/nym`
  (`scripts/nym-node-setup/network-tunnel-manager.sh`), runs its own `apply_iptables_rules*` +
  `remove_duplicate_rules`, and gates the result on a **real egress probe** (a packet sourced from the
  tunnel IP must reach the internet - this catches a broken FORWARD/MASQUERADE, unlike the upstream
  check which always passes). Before applying it **snapshots the live firewall** (`iptables-save`), and
  if the probe fails after apply it **reverts** to the snapshot and re-persists. Exit-policy changes are
  only **logged, never auto-applied**, and the tunnel step is skipped entirely if the firewall cannot
  be snapshotted (no unsafe apply without a revert path). The NTM script ships no upstream checksum, so
  it is pinned to the release's **commit SHA** (immutable), fetched over HTTPS, and run as root - see
  the Trust model section. Detected via the `nymtun0` interface.

- **`nym-api`** (validator API / ecash signer) - **only if `nym-api.service` exists**, with or without
  a nym-node on the same box. Same source, SHA-256 check, soak delay and hourly run as `nym-node`
  (right after it on a box with both). After the restart the API must answer its health endpoint,
  report the new build version, and an ecash signer must still have its keys; otherwise it rolls back.
  It is never restarted while a DKG ceremony is running. Its own state: `api_last_tag`, `api_failed_tags`.

The script detects the node's role automatically; you do not configure it per role.

## Why it is safe

- **Checksum verified** - the downloaded `nym-node` binary is checked against the SHA-256 published
  in the release's `hashes.json` before it is ever installed; a mismatch aborts with no changes, and
  a missing checksum makes it refuse to install (override with `NYM_ALLOW_UNVERIFIED=1`). Note this is
  an **integrity** check (catches corruption/truncation/partial tampering), not an authenticity one:
  Nym's `nym-binaries-v*` line ships no signatures, so trust still reduces to "GitHub and the nymtech
  release account are uncompromised" - the same assumption as a manual install.
- **Smoke tested** - the new binary must run `--version` successfully before it is installed.
- **Automatic rollback** - after restart the service must be on the new version and stay `active`
  for `HEALTH_STABLE` (60s) without a restart, within `HEALTH_MAX` (180s). One crash that systemd's
  own `Restart=` recovers from is tolerated (a gateway can exit at startup on a transient chain RPC
  error, old and new versions alike); a crash loop is not. If the check fails it restores the
  previous binary and verifies it the same way. A release that fails is retried once on a later run,
  then left alone (until you clear it), so it cannot churn-restart your node forever.
- **Backups kept** - the previous binaries are kept under `/var/lib/nym-autoupdate/backups`.
- **Minimal downtime on success** - when the new binary is healthy the only downtime is the
  stop -> copy -> start window (a couple of seconds); all download/verify work happens before the
  service is touched. A gateway nym-node is stopped with SIGKILL, because its graceful shutdown
  stalls for 3-4 minutes (measured on every gateway stop we have); mixnodes stop gracefully.
  On a *failed* swap the node can be down for up to `HEALTH_MAX` (~3 min) until the health check
  gives up and the rollback restores the old binary - bounded, but not "a couple of seconds".
- **Quiet gate (mixnodes)** - a mixnode is restarted only while it carries almost no traffic: out of
  the active set, after the leftover traffic has drained. The node's own metrics
  (`/api/v1/metrics/mixing`) must show fewer than `QUIET_PPS` (10) packets/s; otherwise the update
  waits for a later hourly run. In the active set a mixnode moves thousands of packets/s, out of it
  about one. The traffic is checked again right before the stop, in case an epoch changed during
  the download. Exceptions, on purpose: after `QUIET_MAX_HOURS` (48h) of waiting for the same release
  it updates anyway; if the node gives no fresh metrics the gate does not block; pressing "update
  now" in Nymi skips the gate. Gateways always have clients, so for them the gate is off by default
  (`QUIET_GATE=on` to force it). The settings live in `/etc/nym-node-autoupdate.conf` (the timer
  does not see `NYM_*` variables; `install` writes them into the config and keeps them on re-install).
- **Soak delay** - a release younger than `MIN_AGE_HOURS` (default 2h) is not adopted yet, so brand-new
  releases are given time to settle. This is a delay, not yank-detection: it does not actively check
  whether a release was later pulled or demoted.
- **Single instance** - protected by `flock`, so overlapping runs cannot collide.

## Auto-detection + confirmation

The setup is per-host but you do not type anything by hand. At install time it detects from systemd:

- the unit - works with both `nym-node.service` and the templated `nym-node@<id>.service`
  (your nodes can be named differently on each server);
- the service user (`User=`, defaults to root);
- the binary path (from `ExecStart`, or resolved via `PATH` when the unit calls `nym-node` by name).

It then **shows you what it found and asks you to confirm**, and lets you **correct any field**
if detection got it wrong. Your answers are saved to `/etc/nym-node-autoupdate.conf`, which the
unattended hourly runs read - so there is no re-guessing later, and no surprises.

## Not root?

The updater needs root to replace the binary and manage systemd. If you run it as a non-root
user it **re-runs itself via `sudo`** (you just get a password prompt). When it swaps the binary
it **preserves the existing file's owner and mode**, so setups where `nym-node` is owned by a
dedicated service user keep working.

## Install

Copy the script to the server and run it (interactive):

```bash
chmod +x nym-node-autoupdate.sh
./nym-node-autoupdate.sh            # same as 'install'; will sudo itself if needed
```

It detects your setup, asks you to confirm/correct it, copies itself to
`/usr/local/sbin/nym-node-autoupdate.sh`, and installs + enables a systemd timer that runs hourly
(with up to 20 min random jitter, and `Persistent=true` so a run missed during downtime is caught
up). For unattended/batch installs across many hosts, set `NYM_ASSUME_YES=1` to skip the prompts
and accept the detected values.

See what it detected and the last known state (read-only, no root needed):

```bash
/usr/local/sbin/nym-node-autoupdate.sh status
```

Check by hand whether a newer release is available, **without installing anything**
(read-only, no root needed - safe to run any time):

```bash
/usr/local/sbin/nym-node-autoupdate.sh check
```

Example output:

```
nym-node   : up to date (1.33.0, nym-binaries-v2026.11-xynomizithra)
nym-bridge : UPDATE AVAILABLE -> bridge-binaries-v0.1.3   (last applied bridge-binaries-v0.1.2)
tunnel(NTM): nym-binaries-v2026.11-xynomizithra changelog has no tunnel/port changes
```

Force an update check **and apply** right now (this is what the hourly timer runs):

```bash
sudo /usr/local/sbin/nym-node-autoupdate.sh run
```

Remove the schedule - both the update timer and the Nymi poll timer (leaves your binary and state untouched):

```bash
sudo /usr/local/sbin/nym-node-autoupdate.sh uninstall
```

## Nymi (Telegram alerts)

[**Nymi**](https://t.me/nyminodebot) is a companion Telegram bot that turns this updater into something
you watch from your phone. Link a node and Nymi tells you the moment it updates, rolls back, or goes
offline, plus release / stake / stress alerts and an on-demand `/status`. It also gives you a
`/update` button that force-updates the node **right now** instead of waiting for the hourly timer.
Most of its data comes from the [Nym node checker](https://nymcheckby.unclelem.uk), so Nymi is useful
even on nodes that don't run this updater. Full writeup:
[forum post](https://forum.nym.com/t/nymi-my-auto-updater-my-checker-and-a-3-year-old-mascot-walk-into-a-telegram-bot/2532).

Link this node to your Telegram (fresh installs also ask for your `@nick` at the end and do this for you):

```bash
sudo /usr/local/sbin/nym-node-autoupdate.sh link @yourtelegram
```

then open [@nyminodebot](https://t.me/nyminodebot) and press **Start** - it links the instant you do.

**How it stays safe.** The node **never holds the bot token.** On first link it generates its own
per-node secret (`/var/lib/nym-autoupdate/nymi_secret`, `0600`) and authenticates to the hub with it,
so only your node can drive its own `/update` or report a result - a stranger who knows your node's
public IP cannot. A lightweight ~45s timer (`nym-node-autoupdate-poll.timer`) is what lets the
`/update` button reach the node quickly; it only ever runs the same update the hourly timer would, and
nothing is ever pushed into your node - the node checks in and pulls the request itself.

## Configuration (environment variables)

| Variable             | Default | Meaning                                                       |
|----------------------|---------|---------------------------------------------------------------|
| `NYM_MIN_AGE_HOURS`  | `2`     | Ignore releases younger than this many hours.                 |
| `NYM_HEALTH_STABLE`  | `60`    | Seconds the service must stay up, with no restart, to pass the health check. |
| `NYM_HEALTH_MAX`     | `180`   | Seconds to wait for that before rolling back.                 |
| `NYM_STOP_MODE`      | `auto`  | `auto` = SIGKILL for a gateway nym-node, graceful otherwise; or `graceful` / `kill`. |
| `NYM_KEEP_BACKUPS`   | `3`     | How many previous binaries to keep.                           |
| `NYM_QUIET_GATE`     | `auto`  | `auto` = wait for an idle node on mixnodes only; `on` = on every role; `off` = never wait. Also settable as `QUIET_GATE=` in the config file. |
| `NYM_QUIET_PPS`      | `10`    | Packets/s below which the node counts as idle (`QUIET_PPS=` in the config). |
| `NYM_QUIET_MAX_HOURS`| `48`    | Update anyway after waiting this long for an idle node (`QUIET_MAX_HOURS=` in the config). |
| `NYM_NODE_HTTP`      | `http://127.0.0.1:8080` | Where nym-node's own HTTP API answers (metrics and roles). |
| `NYM_ASSUME_YES`     | `0`     | `1` skips the interactive confirmation (for batch installs).  |
| `NYM_NYMI_NICK`      | -       | Telegram `@nick` to link this node to Nymi during a batch install. |
| `NYM_NYMI_HUB`       | `https://nymcheckby.unclelem.uk/nymi` | Nymi hub endpoint base (advanced; leave as-is). |
| `NYM_API_MIN_AGE_HOURS` | same as `NYM_MIN_AGE_HOURS` | Soak delay for nym-api releases, written to the config at install (`API_MIN_AGE_HOURS`). |
| `NYM_API_UNIT` / `NYM_API_BIN` / `NYM_API_URL` | detected | Override the nym-api unit, binary, or the local URL it answers on (from `bind_address`). |

## State and logs

- Config: `/etc/nym-node-autoupdate.conf` (`UNIT`, `BIN`, `SVC_USER`, `API_UNIT`, `API_BIN`, `API_URL`,
  `API_MIN_AGE_HOURS`) - edit by hand any time.
- State: `/var/lib/nym-autoupdate/` (`last_tag`, `failed_tags`, `api_last_tag`, `api_failed_tags`, `backups/`).
- Logs: `/var/log/nym-autoupdate.log` and the system journal (`journalctl -t nym-autoupdate`).
- To retry a release that previously failed health check here: remove its line from
  `/var/lib/nym-autoupdate/failed_tags`.

## Alternative: cron instead of the systemd timer

If you prefer cron, skip `install` and add this one line (it still uses the script's internal
locking and rollback):

```cron
# /etc/cron.d/nym-node-autoupdate
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 * * * * root /usr/local/sbin/nym-node-autoupdate.sh run >/dev/null 2>&1
```

## Requirements

`bash`, `systemd`, `curl`, `jq`, `flock`, `sha256sum`, `cmp`, `timeout`. `jq` is **not** in a base
Debian/Ubuntu install and `curl` is often absent on minimal images, so install what's missing:

```bash
sudo apt-get install -y curl jq coreutils util-linux
```

The script **hard-fails loudly** (the systemd unit goes red) if a required command is missing, so a
missing dependency can never turn it into a silent no-op. Exit gateways additionally use
`iptables-save`/`iptables-restore` and (ideally) `netfilter-persistent` for the tunnel step; if those
are absent it safely **skips** the tunnel step rather than touching the firewall with no revert path.

Run `run`/`install` as root (it replaces the binary and manages systemd; it will `sudo` itself if
needed). `check`/`status` are read-only and need no root.

## Trust model (be aware before running as root)

- **nym-node** is SHA-256 verified against the release's `hashes.json` and **refuses to install**
  without a checksum. This is integrity, not authenticity (Nym ships no signatures) - trust still
  reduces to "GitHub + the nymtech release account are uncompromised", same as a manual install.
- **nym-bridge** ships no upstream checksum: updates are trusted on HTTPS + GitHub release integrity
  only (verified by a smoke-test, swapped with the same backup/rollback as nym-node).
- **NTM** (exit gateways) is fetched from the nym repo **pinned to the release's commit SHA** (an
  immutable ref, not a mutable tag) and **run as root**. There is no upstream checksum/signature, so
  this trusts the integrity of the nym GitHub org - the same as running their documented tunnel setup
  by hand. Set `NTM_ENABLED=0` (or answer the install prompt) to opt out entirely.
