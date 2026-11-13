# Changelog

## 1.9.3 - 2026-11-13

Roles follow Nym's table (operators docs, Ansible deploy).

- **NTM** runs on exit gateways and on entry gateways with WireGuard, never on mixnodes. The mode
  comes from the node's API on every run (`/api/v1/roles`, `/api/v1/gateway/client-interfaces`), not
  from the `nymtun0` interface. A WireGuard entry gateway is probed on `nymwg`. Nym's NTM needs both
  `nymtun0` and `nymwg`; without both it is not run, and that is reported once. `NTM_ENABLED=0` still
  turns it off. `status`, `check` and `doctor` look at NTM only where it applies.
- **Entry gateway without WireGuard:** where ufw is active, the bridge and Lewes Protocol ports are
  opened in it (4443/tcp, 4443/udp, 4422/tcp, 41264/tcp, 51264/udp), only in the address family that
  has no rule for them. A port a ufw rule closes, or allows only for some sources or an interface, is
  left alone and reported. `UFW_PORTS_ENABLED=0` turns this off.
- **Switches:** only `1` turns `NTM_ENABLED` or `UFW_PORTS_ENABLED` on; any other value is off, as
  `NTM_ENABLED` always worked.
- **Re-install** keeps `NTM_ENABLED=0`, `UFW_PORTS_ENABLED`, `NTM_INPUT_POLICY`, `NODE_HTTP` and the
  Telegram settings from the config. The old config is read the way `run` reads it, only when it is
  root-owned and not writable by others, and each value is checked before it is saved again.
- **Bridge port check** reads `ufw status verbose` where ufw is active (app profiles included, such as
  the one nym-bridge adds); where no ufw rule decides and ufw drops by default, the INPUT rules after
  ufw's decide.

## 1.9.2 - 2026-11-13

- **NTM.** Nothing is applied without a complete firewall snapshot (v4, v6 and the saved rule files). A
  restore that does not fully succeed is reported as critical and keeps the snapshot.
- **Bridge TLS/SSH.**
  - The backup now also covers the bridge binaries, the links in `/usr/local/bin` and the unit
    drop-in. On a failure they come back with `/etc/nym` and the nym-node config.
  - The package installed by the setup script stays registered with dpkg.
  - `Restart=always` is set before the setup script runs, or nothing is changed.
  - An existing unit drop-in is backed up and put back on a failure.
  - `/etc/nym` is restored next to the live one first and swapped in by rename; the live one is
    never deleted before the restored one is in place.
  - After the run, TLS and SSH must answer with the published keys, and the host firewall must let
    their ports in.
- **Firewall checks** (SSH after NTM, the bridge ports after the bridge setup) follow the INPUT rules in
  order for a new connection from any address, the way the firewall decides.
- **Binary rollback** needs the service to stop first, or it is not done (critical alert), and the
  restored binary must be the one running.

## 1.9.1 - 2026-11-13

Simpler: the updater now does what the operator notes say with Nym's own scripts, as an operator
would by hand, instead of its own machinery. Same goal as 1.9.0, about a fifth of the code.

- **NTM (exit gateways).**
  - `network-tunnel-manager.sh` comes from develop, pinned to its commit, and runs
    `complete_networking_configuration`.
  - It runs when the script gets a new commit upstream (2h old) or when the current release's notes
    ask for a re-run.
  - The firewall is snapshotted first. After the run: tunnel egress, nym-node up, SSH let in, every
    port of the script's exit list present (tcp and udp, v4 and v6), rules saved. Otherwise the
    snapshot is restored.
  - Services already listening stay reachable under NTM's inbound drop.
- **Bridge TLS/SSH (gateways with a 0.3+ bridge).**
  - `quic_bridge_deployment.sh` from develop, pinned, runs non-interactively for the installed bridge
    release, after a backup of `/etc/nym` and the nym-node config.
  - After the run: bridge up on every port, QUIC key unchanged, TLS and SSH published, and `transports`
    still QUIC only. Otherwise the backup is restored.
  - After success a drop-in `Restart=always` is added.
- **Removed from 1.9.0:** the own bridge installer (`bridge-plan`), the dead-man timers and recovery
  runs, the INPUT rule evaluator, the retry schedule. A failed NTM or bridge change is not retried
  until upstream changes or "Update now" in Nymi.
- **Kept:** no binary swap if the service did not stop, and after an update a process of the unit
  must run the installed file.
- **Known limits:**
  - A run that dies in the middle of NTM or the bridge script leaves whatever that script left,
    exactly as when run by hand; there is no automatic restore.
  - The bridge script installs the bridge .deb (no upstream checksum) with its side effects.
- **Tested** on an exit gateway that 1.9.0 had not set up (Ubuntu 22.04, 13.11):
  - NTM applied: 8000 tcp/udp in the exit policy for v4 and v6, INPUT DROP, every service reachable
    from outside;
  - the bridge script configured TLS and SSH, serving the published keys from outside, with the QUIC
    key unchanged;
  - a second run changed nothing.

  A host already set up by 1.9.0 (the same state files) has nothing new to do.
- **Not tested:** the failure paths (restore after a failed check), and a real NymVPN client over
  TLS/SSH.

## 1.9.0 - 2026-11-13

The updater now applies what the operator notes ask for on exit gateways: the network setup from the
current NTM, and the bridge TLS/SSH transports. Until 1.8.0 it ran an older NTM from the release tag,
and only five of its subcommands, never the exit policy. So the v2026.22-istanbul notes (NIP-15:
tcp+udp 8000 in the exit policy; re-run the bridge setup) were not applied.

**Exit gateways: NTM**
- NTM comes from `nymtech/nym` develop, as the notes say, pinned to the newest commit that touched it.
  It runs as `complete_networking_configuration`.
- **When it runs:** the script got a new commit upstream and that commit is 2h old; or the current
  release's notes give an explicit NTM instruction. The notes are re-read whenever the notes file gets
  a new commit.
- **Before the run:**
  - a full snapshot: iptables with every table NTM may touch, the rule files, the net sysctls, ufw;
  - a dead-man timer that restores the snapshot if the run dies. No timer, no apply.
- **Checks after the run:**
  - NTM's `check_firewall_setup`;
  - the exit chain closed, with every port of the applied NTM's allowlist for tcp and udp, v4 and v6;
  - SSH and every listening service no less reachable than before, judged by walking the INPUT rules
    in order;
  - tunnel egress, nym-node up, the rules saved for reboot.
- **On failure:** the snapshot is restored, and the same NTM is retried after 6h, 12h, 24h. A change
  that never settled is restored by the next run before anything else.
- **Behaviour change.** NTM's host firewall now drops inbound traffic it does not list
  (`HOST_INPUT_POLICY=DROP`, its default). Where the INPUT policy was ACCEPT, every service already
  listening keeps an ACCEPT at the end of INPUT, so it stays reachable exactly as before.
  `NTM_INPUT_POLICY=KEEP` in the config leaves the policy alone.

**Gateways: bridge TLS/SSH**
- **Like the bridge setup script, without running it or dpkg:**
  - tls_plain tcp/4443 and ssh_plain tcp/4422 are added, the transports the script names on develop;
  - `bridge-cfg` is the bridge release's own asset, checked against the sha256 GitHub publishes;
  - it runs on copies of `/etc/nym` in a private mount namespace.
- **Before anything changes, the copies must show:** the QUIC key and QUIC entry unchanged, `forward`
  and the public IPs unchanged, and older apps still seeing only QUIC in `transports`.
- **Then:**
  1. a drop-in `Restart=always` (nym-bridge 0.3 stops QUIC too when TLS or SSH fails);
  2. a bridge restart;
  3. TLS and SSH must serve the published keys, and the host firewall must let their ports in;
  4. only then are the new transports published.
- Any failure restores `/etc/nym` and the unit exactly. `bridge-plan` shows the change without making it.

**Also**
- A process of the unit must run the installed binary after an update, and a rollback needs the
  service to stop first.
- `doctor` checks the develop NTM and the bridge setup script.
- The NTM and bridge setup lines are no longer listed as manual commands.

**Tested and not tested**
- **Tested** on one exit gateway (Debian 12, 13.11):
  - nym-node 1.43.0 -> 1.44.0;
  - NTM applied: 8000 tcp/udp in the exit policy for v4 and v6, INPUT DROP, SSH and every service
    reachable from outside;
  - the bridge configured: TLS and SSH serving the published keys from outside, QUIC unchanged;
  - a second run changed nothing.
- **Not run on a real host:** the failure paths (restore, dead-man timer, recovery on the next run,
  retries), and hosts with ufw active or a packaged bridge unit (`User=nym`).
- **Not tested:** a real NymVPN client connecting through the new TLS and SSH transports.

Update with `sudo /usr/local/sbin/nym-node-autoupdate.sh self-update`. On an exit gateway the next
hourly run then applies NTM and, with a 0.3+ bridge, the TLS/SSH transports.

## 1.8.0 - 2026-11-12

- **The Nymi check-in sends the updater version** (an `X-Updater-Version` header), so the bot can tell
  which paired nodes still run an old updater. Nothing else is added to the request.

## 1.7.0 - 2026-11-12

`doctor` now runs when upstream publishes something, not on a clock.

- **Trigger.** The hourly run re-checks when a new nym-node or nym-bridge release appears, prereleases
  included, so a rename shows up at the prerelease, before a stable release needs it. One more check
  runs when the newest stable release is 48h old, by when its operator notes should exist. A new
  script version re-checks too.
- **NTM of the prerelease** is checked as well as the stable one.
- **Alerts only on change.** One Telegram alert when the set of problems appears or changes, one when
  it clears; the same problem is never repeated.

## 1.6.1 - 2026-11-12

- No more `printf: write error: Broken pipe` in the journal when the operator notes are read (systemd
  ignores SIGPIPE, so the pipe into awk reported it).

## 1.6.0 - 2026-11-12

`doctor`: a check that the updater still matches how Nym publishes releases.

Two upstream changes this year (bridge tags at 0.2, the docs path in October) made the updater skip
updates without any error. `doctor` checks each thing it relies on, against GitHub:

- the newest nym-node release uses the `nym-binaries-v` tag prefix, and a stable one is not older than 45 days;
- the newest nym-bridges release uses the `v` prefix and ships `nym-bridge`;
- the operator notes are at a known path and have a section for the current release (48h after it);
- NTM is at its path in the release and has every subcommand the updater calls.

`sudo /usr/local/sbin/nym-node-autoupdate.sh doctor` prints one `ok` or `WARN` line per check. The hourly
run also does it once a day (bridge and NTM checks only where they apply) and sends a Telegram alert on
`WARN`, if alerts are set up.

Update with `sudo /usr/local/sbin/nym-node-autoupdate.sh self-update`.

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
