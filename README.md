# nym-node-autoupdate

A small, self-contained, **safe**, role-aware auto-updater for a Nym node under systemd.

It fires on a schedule (a systemd timer, hourly by default) and keeps the node current. For each
component, if a new stable release exists it downloads it, verifies it, swaps the binary, restarts
the service, and **rolls back automatically if the service does not come back healthy**. Between
releases it does nothing. It is designed to never leave a node down.

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
  only **logged, never auto-applied**. The NTM script ships no upstream checksum, so it is pinned to the
  release tag, fetched over HTTPS, and its sha256 logged - the same trust model as fetching it by hand.
  Detected via the `nymtun0` interface.

The script detects the node's role automatically; you do not configure it per role.

## Why it is safe

- **Checksum verified** - the downloaded `nym-node` binary is checked against the SHA-256 published
  in the release's `hashes.json` before it is ever installed; a mismatch aborts with no changes, and
  a missing checksum makes it refuse to install (override with `NYM_ALLOW_UNVERIFIED=1`). Note this is
  an **integrity** check (catches corruption/truncation/partial tampering), not an authenticity one:
  Nym's `nym-binaries-v*` line ships no signatures, so trust still reduces to "GitHub and the nymtech
  release account are uncompromised" - the same assumption as a manual install.
- **Smoke tested** - the new binary must run `--version` successfully before it is installed.
- **Automatic rollback** - after restart it checks the service is `active`, `running`, on the new
  version, and not crash-looping (PID stable across a second window). If any check fails it restores
  the previous binary and restarts. A release that fails is recorded and never retried (until you
  clear it), so it cannot churn-restart your node forever.
- **Backups kept** - the previous binaries are kept under `/var/lib/nym-autoupdate/backups`.
- **Minimal downtime on success** - when the new binary is healthy the only downtime is the
  stop -> copy -> start window (a couple of seconds); all download/verify work happens before the
  service is touched. On a *failed* swap the node is down for roughly `HEALTH_WAIT` (~25s) until the
  health check fails and the rollback restores the old binary - still bounded, but not "a couple of seconds".
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

Remove the schedule (leaves your binary and state untouched):

```bash
sudo /usr/local/sbin/nym-node-autoupdate.sh uninstall
```

## Configuration (environment variables)

| Variable             | Default | Meaning                                                       |
|----------------------|---------|---------------------------------------------------------------|
| `NYM_MIN_AGE_HOURS`  | `2`     | Ignore releases younger than this many hours.                 |
| `NYM_HEALTH_WAIT`    | `25`    | Seconds to wait after restart before the health check.        |
| `NYM_KEEP_BACKUPS`   | `3`     | How many previous binaries to keep.                           |
| `NYM_ASSUME_YES`     | `0`     | `1` skips the interactive confirmation (for batch installs).  |

## State and logs

- Config: `/etc/nym-node-autoupdate.conf` (`UNIT`, `BIN`, `SVC_USER`) - edit by hand any time.
- State: `/var/lib/nym-autoupdate/` (`last_tag`, `failed_tags`, `backups/`).
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

`bash`, `systemd`, `curl`, `jq`, `flock`, `sha256sum` (all present on a standard Debian/Ubuntu
nym-node host). Run as root (needs to replace the binary and restart the service).
