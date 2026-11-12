# Changelog

## 1.5.0 - 2026-11-12

The QUIC bridge and the "re-run NTM" notes are picked up again.

- **Bridge releases found again.** nym-bridges changed its tags from `bridge-binaries-v0.1.x` to `v0.2.2`,
  `v0.3.0`, so the updater stopped seeing new bridge releases after 0.1.2. It now takes `v*` tags
  (prereleases are still skipped), so gateways move to 0.3.0.
- **Only the bridge binary is replaced.** QUIC, its port and its key stay as they are, as with the
  official `upgrade-nym-bridge.sh --no-tls-ssh`. TLS and SSH are not switched on: that edits
  `bridges.toml` and the firewall, so run the official script for it.
- **Bridge port check.** After the swap the bridge must listen on every port its config names
  (`nym-bridge --print-ports`, 0.3+), otherwise the old binary is put back.
- **Operator notes found again.** On 2026-10-14 the Nym docs moved from `pages/` to `content/`, so the
  updater could no longer read the operator changelog and decided about NTM on the tunnel self-test
  only. It reads the new path now (the old one stays as a fallback).
- **Waits for late notes.** A release can be installed before its operator notes are written. While
  they are missing and the tunnel works, the NTM decision is checked again every run for up to 48h,
  so a "re-run NTM" note published later is still acted on.

Update with `sudo /usr/local/sbin/nym-node-autoupdate.sh self-update`.

## 1.4.0 - 2026-10-21

Quiet gate: a mixnode is updated only while it is idle. Idea from Andrew in the operators chat.

- **Restart only out of the active set.** Before restarting nym-node on a mixnode the updater reads
  the node's own metrics (`/api/v1/metrics/mixing`). At 10 packets/s or more the node is carrying
  traffic (in the active set it moves thousands per second, out of it about one), so the update
  waits for a later hourly run. This also covers the leftover traffic right after the node leaves
  the set: it waits until that has drained too. The traffic is checked again right before the
  stop, in case the node entered the set while the release was downloading.
- **Bounded wait.** After 48h of waiting for the same release it updates anyway, so a node that
  stays in the set for days does not fall behind forever. Metrics older than 5 minutes or missing
  count as unknown, and unknown never blocks an update.
- **Settings survive a re-install.** `install` writes `QUIET_GATE`, `QUIET_PPS`, `QUIET_MAX_HOURS`
  and `NODE_HTTP` into `/etc/nym-node-autoupdate.conf` and keeps your values.
- **Gateways unchanged.** They always have clients, so the gate is off for them by default.
  `QUIET_GATE=on|off` in `/etc/nym-node-autoupdate.conf` changes that; `QUIET_PPS` and
  `QUIET_MAX_HOURS` tune the threshold and the wait.
- **"Update now" in Nymi skips the gate**: an operator asking for it gets it immediately.
- `status` and `check` show the current traffic and whether the gate would wait.

Update with `sudo /usr/local/sbin/nym-node-autoupdate.sh self-update`.

## 1.3.0 - 2026-10-19

nym-api support. A validator operator's nym-api (validator API / ecash signer) is now updated the
same way as a nym-node:

- **Detected from `nym-api.service`**, like the bridge. A box can run nym-api alone, with no
  nym-node; on a box with both, nym-api is updated right after nym-node in the same run.
- **Same release, checksum and rhythm as nym-node**: the `nym-api` asset of the latest stable
  `nym-binaries-v*` release, SHA-256 from its `hashes.json`, the same 2h soak (`API_MIN_AGE_HOURS`
  in the config to change it) and the same hourly timer. State is kept apart (`api_last_tag`,
  `api_failed_tags`) because nym-api has its own version numbers.
- **Stricter health check.** After the restart the API must answer `/v1/api-status/health` with
  `up`, report the new build in `/v1/api-status/build-information`, and an ecash signer must still
  report `isEcashSigner`, `hasSigningKeys` and not `signerDisabled`. Otherwise it rolls back.
  `chain_status` is not required, so a node still catching up does not roll back a good binary.
- **Never restarted mid DKG ceremony.** Before an update the DKG contract's epoch state is read
  (local LCD first, then api.nymtech.net); anything but `in_progress` / `waiting_initialisation`
  defers the update to the next run.
- **"Update now" from Nymi works for it** like for a node: pair the nym-api box with
  `pair @yourhandle`, and `/update` in the bot lists it.

Update with `sudo /usr/local/sbin/nym-node-autoupdate.sh self-update`. Existing nym-node setups
behave exactly as before.

## 1.2.0 - 2026-10-02

Gateways now update on their own. On 2026-10-02 both of our gateways rolled back a good release:

- **Health check waits for a stable service.** It now requires the service to stay up for 60s
  without a restart, within 180s (`NYM_HEALTH_STABLE`, `NYM_HEALTH_MAX`). Before, it was a single
  check at ~30s. A gateway can exit at startup when a chain RPC call fails ("DKG contract is
  unavailable", RPC 502/timeout). Systemd's `Restart=` then brings it up 30s later, but the old
  check had already rolled back. The old version failed the same way in the same minute, so the
  release was not at fault. Rollback is verified by the same check, so the false "rollback did NOT
  restore a healthy service" alarm is gone too. `NYM_HEALTH_WAIT` is no longer used.
- **Gateways are stopped with SIGKILL.** A gateway nym-node's graceful shutdown stalled for
  3.3-3.8 min on every stop we measured, so each update took the node down for ~4 min. A SIGKILL
  to the running process stops it in ~2s. Mixnodes still stop gracefully (0-5s). Override with
  `NYM_STOP_MODE=graceful|kill`.
- **Nymi gets the real outcome.** A force-update that rolled back used to report "noreleases".
  It now reports `failed` (rolled back, node up), `critical` (rollback unhealthy) or `busy` (an
  hourly run held the lock).

Update with `sudo /usr/local/sbin/nym-node-autoupdate.sh self-update`.

## 1.1.0 - 2026-08-17

- **Pairing to Nymi reworked.** `pair @yourhandle`, run **on the node**, replaces `link @nick`.
  Ownership is now proven by the pairing request arriving from the node's own IP, so knowing a
  node's public IP is no longer enough to claim it. The old `link @nick` still works and does the
  same node-IP-proof binding, so existing setups are not forced to change.
- **`self-update` command.** `sudo nym-node-autoupdate self-update` pulls the latest script from
  GitHub, checks it really is this script and parses cleanly (`bash -n`) before replacing itself,
  keeps a timestamped backup, and no-ops if already current. Run it whenever you want the latest.
- **Version string.** `nym-node-autoupdate version`, and `status` now prints the version.

Existing installs don't need to do anything: force-update on already-paired nodes keeps working.
Update the script only for the renamed command or future changes:
`sudo nym-node-autoupdate self-update`.

## 1.0 - shipped 2026-06 (unversioned base)

The stable base, in production on live nodes:

- Updates **nym-node** (all roles), the **QUIC bridge** (gateways), and the **exit-gateway tunnel
  manager** (exit gateways), hourly via a systemd timer.
- nym-node is **SHA-256 verified** against the release's own hashes and **refuses to install on a
  mismatch** (or on no published checksum, unless `NYM_ALLOW_UNVERIFIED=1`).
- **Soak delay** before adopting a release, **atomic binary swap**, post-restart **health check**,
  automatic **rollback** if the service doesn't come back healthy, and a **lock file**.
- **Nothing fetched from the network is executed**: changelog commands are surfaced for you to
  review and run by hand, never run for you (the old `eval` path was removed entirely).
- `systemctl --user` (non-root) node support; IPv4 fallback for GitHub fetches on boxes with a
  dead IPv6 route.
- Companion Telegram bot (**Nymi**) for update, rollback and crash alerts.
