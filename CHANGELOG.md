# Changelog

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
