#!/usr/bin/env bash
#
# nym-node-autoupdate.sh
# Safe, self-contained, ROLE-AWARE auto-updater for a Nym node under systemd.
#
# Keeps current, with the same safety machinery for each:
#   * nym-node   - the one binary that runs in ANY role (mixnode / entry-gw / exit-gw).
#                  Source: github.com/nymtech/nym (tags nym-binaries-v*), SHA-256 verified.
#   * nym-bridge - the QUIC bridge, GATEWAYS ONLY (only if nym-bridge.service exists).
#                  Source: github.com/nymtech/nym-bridges. Ships NO upstream checksum, so it is
#                  trusted on HTTPS + GitHub release integrity only (no independent verification).
#   * NTM        - the gateway tunnel + firewall rules (network-tunnel-manager.sh), where Nym runs it:
#                  exit gateways and WireGuard entry gateways. An entry gateway without WireGuard
#                  keeps ufw; Nym's bridge and Lewes Protocol ports are opened there.
#                  Fetched from github.com/nymtech/nym and RUN AS ROOT. There is no upstream
#                  checksum/signature; this trusts the integrity of the nym GitHub org, the same
#                  as running their documented install by hand. Set NTM_ENABLED=0 to opt out.
#   * nym-api    - a nym-api (validator API / ecash signer), only if nym-api.service exists. Same
#                  source, SHA-256 check, soak delay and hourly run as nym-node, updated right after
#                  it. After the restart it must answer its own health endpoint, report the new build
#                  version, and keep its signer state (an ecash signer must still have its keys). It
#                  is never restarted mid DKG ceremony. A box can run nym-api alone, and "update now"
#                  from Nymi works for it like for a node (pair the box first).
#
# Two phases:
#   * INSTALL (interactive) - run once. Auto-detects unit/user/binary/role and (on gateways) the
#       bridge + tunnel; shows it; lets you confirm or correct; saves /etc/nym-node-autoupdate.conf;
#       installs a systemd timer for the hourly checks.
#   * RUN (unattended) - the timer calls "run" hourly. For each component, if a genuinely new stable
#       release exists it downloads, verifies, swaps the binary, restarts, and ROLLS BACK if the
#       service does not come back healthy.
#
# It is built so it can never leave a node down: download/verify happens before anything is touched;
# the binary swap is an atomic rename; any failure restores the previous binary; the firewall is
# snapshotted before NTM changes and reverted if a real egress probe fails afterwards.
#
# Subcommands:
#   nym-node-autoupdate.sh            # same as 'install' (interactive setup)
#   nym-node-autoupdate.sh install    # detect, confirm/correct, save config, set up the timer
#   nym-node-autoupdate.sh run        # one unattended check + update of every component
#   nym-node-autoupdate.sh check      # read-only: report whether newer releases exist (installs nothing)
#   nym-node-autoupdate.sh status     # print detected/configured setup and last known state
#   nym-node-autoupdate.sh pair @nick # make this node yours on Nymi (run it ON the node; proves ownership by source IP)
#   nym-node-autoupdate.sh self-update# update THIS script to the latest from GitHub (verifies + backs up first)
#   nym-node-autoupdate.sh version    # print the script version
#   nym-node-autoupdate.sh uninstall  # remove the timer (leaves config, state and binaries alone)
#
set -euo pipefail
# Ensure sbin dirs are on PATH so `ip`, `iptables-save`, etc. resolve even for a non-root check/status.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ------------------------------- configuration -------------------------------
REPO="nymtech/nym";          TAG_PREFIX="nym-binaries-v";    ASSET="nym-node"
# nym-bridges tags were "bridge-binaries-v0.1.x" up to 0.1.2 and are plain "v0.2.2", "v0.3.0" since
BRIDGE_REPO="nymtech/nym-bridges"; BRIDGE_TAG_PREFIX="v"; BRIDGE_ASSET="nym-bridge"
NTM_REPO_PATH="scripts/nym-node-setup/network-tunnel-manager.sh"  # tunnel manager, from $REPO
# The operator notes say: take NTM from develop and run complete_networking_configuration. Followed
# as written, pinned to the commit resolved on each run (never the branch name itself).
NTM_BRANCH="${NYM_NTM_BRANCH:-develop}"
NTM_MIN_AGE_HOURS="${NYM_NTM_MIN_AGE_HOURS:-2}"     # a new NTM commit is applied once it is this old
NTM_TIMEOUT="${NYM_NTM_TIMEOUT:-900}"               # seconds for one NTM run
NTM_INPUT_POLICY="${NYM_NTM_INPUT_POLICY:-DROP}"    # NTM's HOST_INPUT_POLICY: DROP (its default) | KEEP

MIN_AGE_HOURS="${NYM_MIN_AGE_HOURS:-2}"     # ignore releases younger than this (soak delay)
HEALTH_STABLE="${NYM_HEALTH_STABLE:-60}"    # the service must stay up this long, with no restart, to pass
HEALTH_MAX="${NYM_HEALTH_MAX:-180}"         # give up (and roll back) if it is not stable within this many seconds
STOP_MODE="${NYM_STOP_MODE:-auto}"          # auto | graceful | kill  (see stop_unit)
KEEP_BACKUPS="${NYM_KEEP_BACKUPS:-3}"       # how many old binaries to keep, per component
# Quiet gate: restart nym-node only while it carries (almost) no traffic, i.e. out of the active set
# and after the leftover traffic has drained. auto = mixnodes only (gateways always have clients).
QUIET_GATE="${NYM_QUIET_GATE:-auto}"        # auto | on | off
QUIET_PPS="${NYM_QUIET_PPS:-10}"            # packets/s below which the node counts as idle
QUIET_MAX_HOURS="${NYM_QUIET_MAX_HOURS:-48}" # stop waiting and update anyway after this long
NODE_HTTP="${NYM_NODE_HTTP:-http://127.0.0.1:8080}"  # nym-node's own HTTP API (metrics)
# fall back to defaults on non-numeric input, else sleep/arithmetic would abort under set -e/-u
[[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || MIN_AGE_HOURS=2
[[ "$HEALTH_STABLE" =~ ^[0-9]+$ ]] || HEALTH_STABLE=60
[[ "$HEALTH_MAX"    =~ ^[0-9]+$ ]] || HEALTH_MAX=180
(( HEALTH_MAX >= HEALTH_STABLE + 10 )) || HEALTH_MAX=$(( HEALTH_STABLE + 10 ))
[[ "$STOP_MODE" =~ ^(auto|graceful|kill)$ ]] || STOP_MODE=auto
[[ "$KEEP_BACKUPS"  =~ ^[0-9]+$ ]] || KEEP_BACKUPS=3
[[ "$QUIET_GATE" =~ ^(auto|on|off)$ ]] || QUIET_GATE=auto
[[ "$QUIET_PPS" =~ ^[0-9]+$ ]] || QUIET_PPS=10
[[ "$QUIET_MAX_HOURS" =~ ^[0-9]+$ ]] || QUIET_MAX_HOURS=48
# --retry-all-errors needs curl >= 7.71; probe once so we never hard-fail on older LTS curl.
RETRY_ALL=""
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then RETRY_ALL="--retry-all-errors"; fi

CONFIG_FILE="/etc/nym-node-autoupdate.conf"
STATE_DIR="/var/lib/nym-autoupdate"
LOGFILE="/var/log/nym-autoupdate.log"
LOCKFILE="/run/nym-autoupdate.lock"
BACKUP_DIR="$STATE_DIR/backups"
STATE_TAG="$STATE_DIR/last_tag";               FAILED_TAGS="$STATE_DIR/failed_tags"
BRIDGE_STATE_TAG="$STATE_DIR/bridge_last_tag"; BRIDGE_FAILED_TAGS="$STATE_DIR/bridge_failed_tags"
NTM_STATE="$STATE_DIR/ntm_last_tag"
NTM_REF_STATE="$STATE_DIR/ntm_applied_ref"        # NTM commit applied here
NTM_FAILED_STATE="$STATE_DIR/ntm_failed_ref"      # NTM commit that failed here and was rolled back
NTM_IFACE_STATE="$STATE_DIR/ntm_iface_missing"    # a missing tunnel interface, already reported
API_ASSET="nym-api"
API_STATE_TAG="$STATE_DIR/api_last_tag";       API_FAILED_TAGS="$STATE_DIR/api_failed_tags"
# DKG contract on Nyx mainnet: a signer is not restarted while a ceremony is running
API_DKG_CONTRACT="${NYM_API_DKG_CONTRACT:-n19604yflqggs9mk2z26mqygq43q2kr3n932egxx630svywd5mpxjsztfpvx}"
API_LCDS="${NYM_API_LCDS:-http://127.0.0.1:1317 https://api.nymtech.net}"
# operator-facing changelog (docs). the release git tag is cut BEFORE its docs section is written,
# so the section is read from the docs branch, not the tag. official nym source, trusted.
# the docs moved from pages/ to content/ on 2026-10-14 (nym PR #7198); the old path is kept as a fallback
OP_CHANGELOG_PATHS="documentation/docs/content/operators/changelog.mdx documentation/docs/pages/operators/changelog.mdx"
OP_CHANGELOG_REFS="${NYM_DOCS_REFS:-develop main}"   # the notes are written on develop first
# a release can be installed before its operator notes are written; while the notes are missing and the
# tunnel is healthy, the tunnel decision is re-checked every run for up to this many hours
NTM_DOCS_WAIT_HOURS="${NYM_NTM_DOCS_WAIT_HOURS:-48}"
[[ "$NTM_DOCS_WAIT_HOURS" =~ ^[0-9]+$ ]] || NTM_DOCS_WAIT_HOURS=48
NTM_DOCS_WAIT="$STATE_DIR/ntm_docs_wait"
ACTIONS_STATE="$STATE_DIR/actions_last_tag"
CHANGELOG_ACTIONS="${NYM_CHANGELOG_ACTIONS:-0}"   # 0 = report only (SAFE DEFAULT). Was 1; auto-eval of commands pulled from a mutable docs branch is a root-RCE risk (deny-list is bypassable), so it is OFF unless explicitly opted in.

# Optional Telegram alerts. Both must be set (in the config, or via these env vars at install) to
# enable; empty = alerts stay off. The config, which stores them, is written 0600 (root-only).
TELEGRAM_BOT_TOKEN="${NYM_TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${NYM_TELEGRAM_CHAT_ID:-}"

# Nymi (shared Telegram bot) endpoints. The node never holds a bot token - it proves
# ownership to the hub with a one-time code the operator gets in the bot (`pair`), then
# asks "was I asked to update?" (`poll`), authenticating every poll with its own secret.
NYMI_HUB_BASE="${NYM_NYMI_HUB:-https://nymcheckby.unclelem.uk/nymi}"

SELF_PATH="$(readlink -f "$0")"
DEST_PATH="/usr/local/sbin/nym-node-autoupdate.sh"
SCRIPT_VERSION="1.9.3"
SELF_UPDATE_URL="${NYM_SELF_UPDATE_URL:-https://raw.githubusercontent.com/vvmmaann/nym-node-autoupdate/main/nym-node-autoupdate.sh}"

# --------------------------------- logging ----------------------------------
log() {
  local line; line="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOGFILE" 2>/dev/null || true
  logger -t nym-autoupdate -- "$*" 2>/dev/null || true
}
die() { log "ERROR: $*"; exit 1; }

# Alerting hook, sent as "Nymi", the little creature that watches the node.
# Called as: notify <success|rollback|failed> <message>. Off unless TELEGRAM_BOT_TOKEN + _CHAT_ID
# are set. NOTE: $2 may contain GitHub-controlled tag text - it is only ever passed via
# --data-urlencode, never built into a shell command.
notify() {
  local kind="${1:-info}" msg="${2:-}"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
  local emoji host text
  case "$kind" in
    success)  emoji="$(printf '\xf0\x9f\x90\xbe')" ;;   # paw prints
    rollback) emoji="$(printf '\xf0\x9f\x9b\xa1')" ;;   # shield
    failed)   emoji="$(printf '\xe2\x9a\xa0')" ;;       # warning sign
    *)        emoji="$(printf '\xf0\x9f\x90\xbe')" ;;
  esac
  host="$(hostname 2>/dev/null || echo node)"
  printf -v text '%s Nymi on %s\n%s' "$emoji" "$host" "$msg"
  # fire-and-forget: a failed alert must never affect the update itself
  gcurl -sS -m 15 -o /dev/null \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    2>/dev/null || log "[notify] telegram send failed (non-fatal)"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  touch "$FAILED_TAGS" "$BRIDGE_FAILED_TAGS" "$API_FAILED_TAGS" 2>/dev/null || true
}

# Hard-fail (unit goes red) if a required command is missing, instead of silently never updating.
require_cmds() {
  local c missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  [[ -z "$missing" ]] || die "missing required command(s):$missing  (try: apt-get install -y curl jq coreutils)"
}

# Re-run under sudo when not root. Prefer the vetted installed copy over the (possibly writable)
# downloaded SELF_PATH, and refuse rather than hang if sudo would prompt with no terminal.
need_root() {
  if [[ "$(id -u)" -eq 0 ]]; then return 0; fi
  local self="$SELF_PATH"; [[ -x "$DEST_PATH" ]] && self="$DEST_PATH"
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null || [[ -t 0 ]]; then
      echo "not root; re-running via sudo..."
      exec sudo -E -- "$self" "$@"
    fi
    die "needs root and sudo would prompt but there is no terminal; run as root"
  fi
  die "this needs root (replaces binaries and manages systemd). Re-run as root or install sudo."
}

# ------------------------------- autodetection ------------------------------
detect_unit() {
  systemctl list-units --all --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '^nym-node(@[^.]*)?\.service$' | head -n1 || true
}
detect_bridge_unit() {
  systemctl list-units --all --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '^nym-bridge(@[^.]*)?\.service$' | head -n1 || true
}
detect_bin() {
  local unit="${1:-}" p
  p="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | grep -oP 'path=\K\S+' | head -n1 || true)"
  if [[ "$p" == /* && -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  command -v nym-node 2>/dev/null || true
}
detect_bridge_bin() {
  local unit="${1:-}" p
  p="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | grep -oP 'path=\K\S+' | head -n1 || true)"
  if [[ "$p" == /* && -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  command -v nym-bridge 2>/dev/null || true
}
detect_api_unit() {
  systemctl list-units --all --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '^nym-api(@[^.]*)?\.service$' | head -n1 || true
}
detect_api_bin() {
  local unit="${1:-}" p
  p="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | grep -oP 'path=\K\S+' | head -n1 || true)"
  if [[ "$p" == /* && -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  command -v nym-api 2>/dev/null || true
}
# where the nym-api answers HTTP: its bind_address from config.toml (0.0.0.0 -> loopback)
detect_api_url() {
  local unit="${1:-}" u home b
  u="$(detect_user "$unit")"; home="$(getent passwd "${u:-root}" | cut -d: -f6)"; home="${home:-/root}"
  b="$(grep -hoP "^\s*bind_address\s*=\s*['\"]\K[^'\"]+" "$home"/.nym/nym-api/*/config/config.toml 2>/dev/null | head -n1 || true)"
  [[ -n "$b" ]] || b="127.0.0.1:8080"
  b="${b/0.0.0.0/127.0.0.1}"
  printf 'http://%s\n' "$b"
}
detect_user() {
  local unit="${1:-}" u
  u="$(systemctl show -p User --value "$unit" 2>/dev/null || true)"
  printf '%s\n' "${u:-root}"
}
detect_role() {
  local unit="${1:-}" es
  if [[ -n "$(detect_bridge_unit)" ]]; then echo "gateway (has QUIC bridge)"; return; fi
  es="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null || true)"
  case "$es" in
    *exit-gateway*|*entry-gateway*) echo "gateway" ;;
    *mixnode*)                      echo "mixnode" ;;
    *)                              echo "node (role set in config [modes])" ;;
  esac
}
# Nym's rule (operators docs, Ansible deploy): NTM runs on exit gateways and on entry gateways with
# WireGuard; never on mixnodes, and not on entry gateways without WireGuard (those keep ufw). The mode
# comes from the node itself: /api/v1/roles (exit = ip_packet_router_enabled, entry = gateway_enabled)
# and client-interfaces (wireguard is null when it is off). stdout: exit | entry-wg | entry | mixnode
node_mode() {
  local r w
  r="$(curl -fsS --max-time 5 "$NODE_HTTP/api/v1/roles" 2>/dev/null)" || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$r" || return 1
  if jq -e '.mixnode_enabled == true' >/dev/null 2>&1 <<<"$r"; then echo mixnode
  elif jq -e '.ip_packet_router_enabled == true' >/dev/null 2>&1 <<<"$r"; then echo exit
  elif jq -e '.gateway_enabled == true' >/dev/null 2>&1 <<<"$r"; then
    w="$(curl -fsS --max-time 5 "$NODE_HTTP/api/v1/gateway/client-interfaces" 2>/dev/null)" || return 1
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$w" || return 1
    if jq -e '.wireguard != null' >/dev/null 2>&1 <<<"$w"; then echo entry-wg; else echo entry; fi
  else return 1; fi
}
# NTM applies to this node: not turned off, and an exit or WireGuard entry gateway. stdout: the mode
ntm_mode() {
  local m
  [[ "${NTM_ENABLED:-0}" == 1 ]] && m="$(node_mode)" && [[ "$m" == exit || "$m" == entry-wg ]] || return 1
  printf '%s\n' "$m"
}
# Nym's NTM sets up and tests both nymtun0 and nymwg and stops when either is missing. stdout: the missing
ntm_missing_ifaces() {
  local t
  for t in "${NTM_IFACE:-nymtun0}" nymwg; do ip link show "$t" >/dev/null 2>&1 || printf ' %s' "$t"; done
}
# NTM_ENABLED=0 in the config turns the NTM step off; otherwise node_mode decides on every run.
detect_ntm() {            # echoes "<enabled>\t<path>\t<iface>"
  local path=""
  path="$(ls -1 /usr/local/sbin/network-tunnel-manager.sh /root/network-tunnel-manager.sh /root/network_tunnel_manager.sh 2>/dev/null | head -n1 || true)"
  [[ -n "$path" ]] || path="/usr/local/sbin/network-tunnel-manager.sh"
  printf '1\t%s\tnymtun0\n' "$path"
}
# Best-effort detection of the host SSH port, so an NTM firewall apply never locks the operator
# out on a non-standard port. Prefers sshd's own effective config, then a listening sshd socket,
# then 22. Overridable via NYM_SSH_PORT / the saved config.
detect_ssh_port() {
  local p=""
  # sshd's effective config is authoritative; grab the first Port it actually listens on
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  # fall back to grepping the active sshd config, then to the default
  [[ "$p" =~ ^[0-9]+$ ]] || p="$(awk '/^[[:space:]]*[Pp]ort[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  [[ "$p" =~ ^[0-9]+$ ]] || p=22
  printf '%s\n' "$p"
}
bin_version() {
  "$1" --version 2>/dev/null | grep -ioP 'build version:\s*\K[0-9][0-9.]*' | head -n1 || true
}

# systemctl wrapper that honors the service scope. A node run under `systemctl --user`
# by a lingering user (e.g. a node kept off root) is driven as that user via runuser +
# XDG_RUNTIME_DIR, so a root-run timer can still stop/start/health-check it. Anything not
# user-scope (the default, and always the autoupdate timer itself) stays system-wide.
sctl() {
  if [[ "${SVC_SCOPE:-system}" == "user" && -n "${SVC_USER:-}" && "$SVC_USER" != "root" ]]; then
    local uid; uid="$(id -u "$SVC_USER" 2>/dev/null)"
    if [[ -z "$uid" ]]; then log "[sctl] cannot resolve uid for user '$SVC_USER'"; return 1; fi
    runuser -u "$SVC_USER" -- env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user "$@"
  else
    systemctl "$@"
  fi
}

# Resolve everything from the saved config first, falling back to live detection.
resolve_target() {
  UNIT=""; BIN=""; SVC_USER=""; ROLE=""; BRIDGE_UNIT=""; BRIDGE_BIN=""; NTM_ENABLED=""; NTM_PATH=""; NTM_IFACE=""; SVC_SCOPE=""; SSH_PORT=""
  API_UNIT=""; API_BIN=""; API_URL=""; API_MIN_AGE_HOURS=""
  if [[ -f "$CONFIG_FILE" ]]; then
    # only trust the config if it is root-owned and not group/other-writable (we source it as root)
    if [[ "$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null || echo '?')" == "root" \
          && -z "$(find "$CONFIG_FILE" -perm /022 2>/dev/null)" ]]; then
      # shellcheck disable=SC1090
      source "$CONFIG_FILE" || true
    else
      log "WARNING: $CONFIG_FILE is not root-owned or is writable by others; ignoring it, using live detection"
    fi
  fi
  [[ -n "${UNIT:-}" ]]        || UNIT="$(detect_unit)"
  [[ -n "${UNIT:-}" && -z "${BIN:-}" ]] && BIN="$(detect_bin "$UNIT")"
  [[ -n "${API_UNIT:-}" ]]    || API_UNIT="$(detect_api_unit)"
  if [[ -n "${API_UNIT:-}" ]]; then
    [[ -n "${API_BIN:-}" ]] || API_BIN="$(detect_api_bin "$API_UNIT")"
    [[ -n "${API_URL:-}" ]] || API_URL="$(detect_api_url "$API_UNIT")"
  fi
  # same soak as nym-node unless the config sets its own
  [[ "${API_MIN_AGE_HOURS:-}" =~ ^[0-9]+$ ]] || API_MIN_AGE_HOURS="${NYM_API_MIN_AGE_HOURS:-$MIN_AGE_HOURS}"
  [[ "$API_MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || API_MIN_AGE_HOURS="$MIN_AGE_HOURS"
  [[ "${API_URL:-}" =~ ^https?://[A-Za-z0-9.:_-]+$ ]] || API_URL=""
  [[ -n "${SVC_USER:-}" ]]    || SVC_USER="$(detect_user "${UNIT:-$API_UNIT}")"
  [[ -n "${BRIDGE_UNIT:-}" ]] || BRIDGE_UNIT="$(detect_bridge_unit)"
  if [[ -n "${BRIDGE_UNIT:-}" && -z "${BRIDGE_BIN:-}" ]]; then BRIDGE_BIN="$(detect_bridge_bin "$BRIDGE_UNIT")"; fi
  [[ -n "${ROLE:-}" ]]        || ROLE="$(detect_role "$UNIT")"
  if [[ -z "${NTM_ENABLED:-}" ]]; then IFS=$'\t' read -r NTM_ENABLED NTM_PATH NTM_IFACE < <(detect_ntm) || true; fi
  # only "1" turns a step on (NTM_ENABLED has meant this since it exists); anything else is off
  if [[ "${NTM_ENABLED:-}" != 1 ]]; then NTM_ENABLED=0; fi
  if [[ "${UFW_PORTS_ENABLED:-1}" == 1 ]]; then UFW_PORTS_ENABLED=1; else UFW_PORTS_ENABLED=0; fi
  [[ -n "${NTM_IFACE:-}" ]] || NTM_IFACE="nymtun0"
  [[ "$NTM_IFACE" =~ ^[a-zA-Z0-9._-]+$ ]] || NTM_IFACE="nymtun0"   # sanity: never let junk reach iptables/ip
  [[ -n "${NTM_PATH:-}" ]]  || NTM_PATH="/usr/local/sbin/network-tunnel-manager.sh"
  [[ -n "${SVC_SCOPE:-}" ]] || SVC_SCOPE="system"
  [[ "$NTM_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || NTM_BRANCH="develop"
  [[ "$NTM_MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || NTM_MIN_AGE_HOURS=2
  [[ "$NTM_TIMEOUT" =~ ^[0-9]+$ ]] || NTM_TIMEOUT=900
  NTM_INPUT_POLICY="${NTM_INPUT_POLICY^^}"; [[ "$NTM_INPUT_POLICY" =~ ^(DROP|KEEP)$ ]] || NTM_INPUT_POLICY="DROP"
  # SSH port for NTM's firewall (config > NYM_SSH_PORT env > live detection > 22)
  [[ -n "${SSH_PORT:-}" ]] || SSH_PORT="${NYM_SSH_PORT:-$(detect_ssh_port)}"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# nym-node-autoupdate config - written by 'install', read on every run.
# Edit by hand if your setup changes, or re-run: $DEST_PATH install
# Leave BRIDGE_UNIT empty to disable QUIC-bridge updates; NTM_ENABLED=0 turns the NTM step off
# (otherwise NTM follows the node's mode: exit and WireGuard entry gateways only).
UNIT="$1"
BIN="$2"
SVC_USER="$3"
ROLE="$4"
BRIDGE_UNIT="$5"
BRIDGE_BIN="$6"
NTM_ENABLED="$7"
NTM_PATH="$8"
NTM_IFACE="$9"
SVC_SCOPE="${10:-system}"
SSH_PORT="${11:-}"
# Telegram alerts (optional). Both empty = alerts off. This file is root-only (0600) because of them.
TELEGRAM_BOT_TOKEN="${12:-}"
TELEGRAM_CHAT_ID="${13:-}"
# nym-api (optional): leave API_UNIT empty to skip it. API_URL is where it answers HTTP locally.
# API_MIN_AGE_HOURS = soak delay for nym-api releases, same as nym-node's by default.
API_UNIT="${14:-}"
API_BIN="${15:-}"
API_URL="${16:-}"
API_MIN_AGE_HOURS="${17:-$MIN_AGE_HOURS}"
# Quiet gate: restart nym-node only while it is idle (out of the active set, leftover traffic gone).
# QUIET_GATE = auto (mixnodes only) | on | off. NODE_HTTP = where nym-node's own HTTP API answers.
QUIET_GATE="$QUIET_GATE"
QUIET_PPS="$QUIET_PPS"
QUIET_MAX_HOURS="$QUIET_MAX_HOURS"
NODE_HTTP="$NODE_HTTP"
# NTM_INPUT_POLICY = NTM's HOST_INPUT_POLICY: DROP (its default) | KEEP.
# UFW_PORTS_ENABLED=0 leaves ufw alone on an entry gateway without WireGuard.
NTM_INPUT_POLICY="$NTM_INPUT_POLICY"
UFW_PORTS_ENABLED="$UFW_PORTS_ENABLED"
EOF
  chmod 0600 "$CONFIG_FILE"
}

# ------------------------------- github lookup ------------------------------
# gcurl: curl with an automatic IPv4 retry for hosts whose advertised IPv6 route is actually dead
# (resets mid-transfer). ONLY safe with -o to a file - in a $() capture it would concatenate the
# partial IPv6 attempt with the IPv4 retry. The short --connect-timeout hands off to IPv4 fast.
gcurl() { curl --connect-timeout 8 "$@" || curl -4 --connect-timeout 8 "$@"; }

gh_releases() {           # arg: owner/repo ; prints releases JSON
  local url="https://api.github.com/repos/$1/releases?per_page=100" out
  out="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 3 --retry-delay 5 --max-time 45 \
         -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$url")" \
   || out="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 3 --retry-delay 5 --max-time 45 \
         -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$url")" \
   || return 1
  printf '%s' "$out"
}
# From releases JSON on stdin, emit "tag<TAB>published<TAB>asset_url<TAB>hashes_url". args: prefix asset
pick_latest() {
  jq -r --arg pref "$1" --arg asset "$2" '
    [ .[]
      | select(.draft==false and .prerelease==false)
      | select(.tag_name | startswith($pref))
      | select(any(.assets[]?; .name==$asset))
    ]
    | sort_by(.published_at) | reverse | .[0] // empty
    | [ .tag_name, .published_at,
        (.assets[] | select(.name==$asset)        | .browser_download_url),
        ((.assets[] | select(.name=="hashes.json") | .browser_download_url) // "") ] | @tsv
  '
}
age_hours() { [[ -n "${1:-}" ]] || return 1; local pub now; pub="$(date -u -d "$1" +%s 2>/dev/null)" || return 1; now="$(date -u +%s)"; printf '%s\n' "$(( (now - pub) / 3600 ))"; }

# ---- failed-release memory: count failures (auto-retry once; blacklist after 2; expire after 7d) ----
fail_count() { awk -F'\t' -v t="$2" '$1==t{c=$2} END{print c+0}' "$1" 2>/dev/null || echo 0; }
record_fail() {
  local ff="$1" t="$2" n now tmp
  n="$(fail_count "$ff" "$t")"; n=$((n+1)); now="$(date -u +%s)"
  tmp="$(mktemp 2>/dev/null)" || return 0
  awk -F'\t' -v t="$t" '$1!=t' "$ff" 2>/dev/null > "$tmp" || true
  printf '%s\t%s\t%s\n' "$t" "$n" "$now" >> "$tmp"
  mv -f "$tmp" "$ff" 2>/dev/null || rm -f "$tmp"
}
is_blacklisted() {        # return 0 = skip this tag
  local ff="$1" t="$2" line n ts now
  line="$(awk -F'\t' -v t="$t" '$1==t{print; exit}' "$ff" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  n="$(printf '%s' "$line" | cut -f2)"; ts="$(printf '%s' "$line" | cut -f3)"; now="$(date -u +%s)"
  [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts > 604800 )) && return 1   # expired -> allow a retry
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 2 )) && return 0
  return 1
}

# is_healthy <unit> <bin> <expected_version_or_empty> - the unit must stay active for HEALTH_STABLE
# seconds within one activation (crash-loop guard), and it gets up to HEALTH_MAX seconds to get there.
# A single crash that systemd's own Restart= recovers from is tolerated: a new activation simply restarts
# the stability window. Why: a gateway exits at startup when a chain RPC call fails (seen 2026-10-02 on
# two gateways, old AND new version alike, ~30s after start), and a short fixed check rolled back a good
# binary. Works for Type=simple/forking/notify/oneshot+RemainAfterExit (does NOT demand SubState=running
# or a live main PID, which false-fail healthy non-simple units). Used identically by install and rollback.
is_healthy() {
  local u="$1" b="$2" expect="${3:-}" a t t0="" since=-1 el=0 restarts=0 rv
  if [[ -n "$expect" ]]; then
    rv="$(bin_version "$b")"
    [[ -z "$rv" || "$rv" == "$expect" ]] || return 1   # unparseable version = inconclusive = pass
  fi
  while (( el <= HEALTH_MAX )); do
    a="$(sctl is-active "$u" 2>/dev/null || true)"
    t="$(sctl show -p ActiveEnterTimestampMonotonic --value "$u" 2>/dev/null || echo 0)"
    if [[ "$a" == "active" ]]; then
      if [[ "$t" != "$t0" ]]; then
        [[ -n "$t0" ]] && { restarts=$((restarts+1)); log "  $u re-activated (restart #$restarts); stability window restarts"; }
        t0="$t"; since=$el
      fi
      if (( el - since >= HEALTH_STABLE )); then
        (( restarts == 0 )) || log "  $u stable for ${HEALTH_STABLE}s after $restarts restart(s)"
        return 0
      fi
    else
      since=-1
    fi
    sleep 5; el=$((el+5))
  done
  log "  $u not stable for ${HEALTH_STABLE}s within ${HEALTH_MAX}s (last state: ${a:-?}, restarts seen: $restarts)"
  return 1
}

# bridge_listening <unit> <bin> - the bridge must listen on every port its config names. nym-bridge 0.3+
# prints them with --print-ports; an older binary, an unreadable config or a host without ss skips the
# check (returns 0), so it can only catch "service active but a transport did not come up".
bridge_listening() {
  local u="$1" b="$2" cfg ports port proto i miss
  command -v ss >/dev/null 2>&1 || { log "  bridge port check skipped (no ss)"; return 0; }
  cfg="$(sctl show -p ExecStart --value "$u" 2>/dev/null | grep -oE -- '--config[= ]+[^ ;]+' | head -n1 | sed -E 's/--config[= ]+//' || true)"
  [[ -n "$cfg" ]] || cfg="/etc/nym/bridges.toml"
  ports="$(timeout 10 "$b" --config "$cfg" --print-ports 2>/dev/null)" || { log "  bridge port check skipped (binary has no --print-ports, or $cfg unreadable)"; return 0; }
  [[ -n "$ports" ]] || return 0
  for i in 1 2 3 4 5 6; do
    miss=""
    while IFS=/ read -r port proto; do
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      if [[ "$proto" == "udp" ]]; then
        ss -lnu "sport = :$port" 2>/dev/null | tail -n +2 | grep -q . || miss="$miss $port/udp"
      else
        ss -lnt "sport = :$port" 2>/dev/null | tail -n +2 | grep -q . || miss="$miss $port/tcp"
      fi
    done <<< "$ports"
    [[ -z "$miss" ]] && { log "  bridge listening on: $(printf '%s ' $ports)"; return 0; }
    sleep 5
  done
  log "  bridge not listening on:$miss"
  return 1
}

# ------------------------------ nym-api checks ------------------------------
api_get() { curl -fsS --max-time 8 "${API_URL}$1" 2>/dev/null; }
# "isEcashSigner hasSigningKeys signerDisabled", e.g. "true true false"; empty if it does not answer
api_signer_state() {
  api_get /v1/ecash/signer-status | jq -r '.body | "\(.isEcashSigner) \(.hasSigningKeys) \(.signerDisabled)"' 2>/dev/null || true
}
# api_http_healthy <expected_version> <signer state before the update>
# The API must say it is up, run the new build, and an ecash signer must still be one with its keys.
# chain_status is NOT required: a node still catching up is no reason to roll back a good binary.
api_http_healthy() {
  local want="$1" before="${2:-}" i h v s
  for i in $(seq 1 24); do
    h="$(api_get /v1/api-status/health | jq -r '.status // empty' 2>/dev/null || true)"
    v="$(api_get /v1/api-status/build-information | jq -r '.build_version // empty' 2>/dev/null || true)"
    s="$(api_signer_state)"
    if [[ "$h" == "up" && ( -z "$want" || "$v" == "$want" ) ]]; then
      if [[ "$before" != "true true false" || "$s" == "true true false" ]]; then
        log "  nym-api answers: health=$h version=${v:-?} signer=[${s:-n/a}]"; return 0
      fi
    fi
    sleep 5
  done
  log "  nym-api HTTP check failed: health=${h:-none} version=${v:-?} (want ${want:-any}) signer=[${s:-n/a}] (before [${before:-n/a}])"
  return 1
}
# 0 = a DKG ceremony is running right now (do not restart a signer); 1 = idle or unknown
api_dkg_busy() {
  local lcd st="" b64
  b64="$(printf '%s' '{"get_current_epoch_state":{}}' | base64 -w0)"
  for lcd in $API_LCDS; do
    st="$(curl -fsS --max-time 10 "$lcd/cosmwasm/wasm/v1/contract/$API_DKG_CONTRACT/smart/$b64" 2>/dev/null \
          | jq -r '.data.state | if type=="string" then . else (keys[0] // empty) end' 2>/dev/null || true)"
    [[ -n "$st" ]] && break
  done
  [[ -n "$st" ]] || { log "[nym-api] could not read the DKG state; assuming no ceremony"; return 1; }
  case "$st" in
    in_progress|waiting_initialisation) return 1 ;;
    *) log "[nym-api] DKG ceremony in progress (state: $st); not restarting the signer now, will retry"; return 0 ;;
  esac
}

# stop_unit <unit> <role> - stop the service before the binary swap.
# A gateway nym-node ignores its graceful shutdown: every gateway stop measured (2026-09-16 and
# 2026-10-02, two hosts) took 3.3-3.8 min - the node's own shutdown stalls, systemd's SIGKILL after
# TimeoutStopSec does not take effect for another ~2 min. A SIGKILL sent to the RUNNING gateway
# process instead stops it in ~2s (4 of 4 times). Mixnodes stop gracefully in 0-5s, so they keep it.
#   STOP_MODE=auto     -> gateway nym-node: SIGKILL; anything else: graceful, SIGKILL if still up after 90s
#   STOP_MODE=graceful -> always the plain `systemctl stop`
#   STOP_MODE=kill     -> always SIGKILL
stop_unit() {
  local u="$1" role="${2:-}" mode="$STOP_MODE" i st
  [[ "$mode" == "auto" ]] && { [[ "$role" == gateway* ]] && mode=kill || mode=graceful; }
  if [[ "$mode" == "graceful" ]]; then
    sctl stop --no-block "$u" 2>/dev/null || true
    for i in $(seq 1 90); do
      st="$(sctl is-active "$u" 2>/dev/null || true)"
      [[ "$st" == "inactive" || "$st" == "failed" ]] && return 0
      sleep 1
    done
    log "  $u still stopping after 90s; sending SIGKILL"
  fi
  sctl kill -s SIGKILL "$u" 2>/dev/null || true
  for i in $(seq 1 60); do
    st="$(sctl is-active "$u" 2>/dev/null || true)"
    [[ "$st" == "inactive" || "$st" == "failed" || "$st" == "activating" ]] && break
    sleep 1
  done
  sctl stop "$u" 2>/dev/null || true          # cancel a pending Restart= so the swap happens while stopped
  sctl reset-failed "$u" 2>/dev/null || true
  st="$(sctl is-active "$u" 2>/dev/null || true)"
  [[ "$st" == active || "$st" == activating || "$st" == deactivating || "$st" == reloading ]] && { log "  $u did not stop (state: $st)"; return 1; }
  return 0
}

# After a start: some process of the unit runs exactly the installed file (same device and inode),
# and none still runs the replaced one (same path, shown as deleted).
unit_runs_current_binary() {   # args: unit bin
  local u="$1" bin="$2" want cg pids="" p hit=0 stale="" exe real
  want="$(stat -L -c '%d:%i' "$bin" 2>/dev/null)" || return 1
  real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
  cg="$(sctl show -p ControlGroup --value "$u" 2>/dev/null || true)"
  for p in "/sys/fs/cgroup$cg/cgroup.procs" "/sys/fs/cgroup/systemd$cg/cgroup.procs"; do
    [[ -n "$cg" && -r "$p" ]] && { pids="$(cat "$p" 2>/dev/null || true)"; [[ -n "$pids" ]] && break; }
  done
  [[ -n "$pids" ]] || pids="$(sctl show -p MainPID --value "$u" 2>/dev/null || true)"
  for p in $pids; do
    [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] || continue
    if [[ "$(stat -L -c '%d:%i' "/proc/$p/exe" 2>/dev/null || true)" == "$want" ]]; then hit=1; continue; fi
    exe="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
    [[ "$exe" == "$bin (deleted)" || "$exe" == "$real (deleted)" ]] && stale="$stale $p"
  done
  [[ -z "$stale" ]] || { log "  $u: process(es)$stale still run the replaced $bin"; return 1; }
  (( hit )) && return 0
  log "  $u: no process runs the installed $bin"; return 1
}

# ------------------------------- quiet gate ----------------------------------
# Packets/s the node is mixing right now, from its own metrics (last ~30 s window). Empty = unknown.
node_pps() {
  local m
  m="$(curl -fsS --max-time 5 "$NODE_HTTP/api/v1/metrics/mixing" 2>/dev/null)" || return 0
  printf '%s' "$m" | jq -r '
    (.received_since_last_update // empty) as $n
    | ((.update_time // "") | sub("\\.[0-9]+";"") | fromdateiso8601? ) as $t1
    | ((.previous_update_time // "") | sub("\\.[0-9]+";"") | fromdateiso8601? ) as $t0
    | if $n == null or $t1 == null or $t0 == null or ($t1 - $t0) <= 0 then empty
      elif (now - $t1) > 300 then empty            # stale metrics (a stuck task) = unknown, not busy
      else (($n / ($t1 - $t0)) | floor) end' 2>/dev/null | grep -E '^[0-9]+$' || true
}

# the config file is sourced after the defaults were validated, so validate again before use
quiet_validate() {
  [[ "$QUIET_GATE" =~ ^(auto|on|off)$ ]] || QUIET_GATE=auto
  [[ "$QUIET_PPS" =~ ^[0-9]+$ ]] || QUIET_PPS=10
  [[ "$QUIET_MAX_HOURS" =~ ^[0-9]+$ ]] || QUIET_MAX_HOURS=48
}

quiet_gate_applies() {
  quiet_validate
  [[ "${NAU_MANUAL:-0}" == "1" ]] && return 1          # an operator pressed "update now"
  case "$QUIET_GATE" in
    on)  return 0 ;;
    off) return 1 ;;
  esac
  [[ "${ROLE:-}" == mixnode* ]] && return 0
  [[ "${ROLE:-}" == gateway* ]] && return 1
  # mode set in config.toml rather than on the command line: ask the node itself
  curl -fsS --max-time 5 "$NODE_HTTP/api/v1/roles" 2>/dev/null \
    | jq -e '.mixnode_enabled == true and (.gateway_enabled // false) == false' >/dev/null 2>&1
}

# return 0 = go ahead with the restart now, 1 = defer to a later run. arg: tag
quiet_gate_ok() {
  local tag="$1" f="$STATE_DIR/quiet_wait" pps first now waited
  quiet_gate_applies || return 0
  pps="$(node_pps)"
  now="$(date -u +%s)"
  if [[ -z "$pps" ]]; then
    log "[nym-node] quiet gate: could not read traffic from $NODE_HTTP; not blocking the update"; rm -f "$f"; return 0
  fi
  if (( pps < QUIET_PPS )); then
    log "[nym-node] quiet gate: ${pps} pkt/s (< ${QUIET_PPS}), node is idle; updating now"; rm -f "$f"; return 0
  fi
  first="$(awk -v t="$tag" '$1==t{print $2}' "$f" 2>/dev/null || true)"
  [[ "$first" =~ ^[0-9]+$ ]] || { first="$now"; printf '%s %s\n' "$tag" "$now" > "$f"; }
  waited=$(( (now - first) / 3600 ))
  if (( waited >= QUIET_MAX_HOURS )); then
    log "[nym-node] quiet gate: still ${pps} pkt/s after ${waited}h of waiting; updating anyway"; rm -f "$f"; return 0
  fi
  log "[nym-node] quiet gate: ${pps} pkt/s (>= ${QUIET_PPS}), node is carrying traffic; deferring $tag (waiting ${waited}h of max ${QUIET_MAX_HOURS}h)"
  return 1
}

# ----------------------- the generic component updater ----------------------
# update_component <name> <repo> <tagprefix> <asset> <bin> <unit> <statefile> <failedfile> <smoke>
#   smoke = "version" (nym-node: must report a build version; refuses install without a checksum)
#         | "runs"    (nym-bridge: --help must work; no upstream checksum, HTTPS+smoke only)
# Returns: 0 = updated or nothing-to-do; 1 = aborted/rolled-back (service up); 2 = critical.
update_component() {
  local NAME="$1" CREPO="$2" CPREF="$3" CASSET="$4" CBIN="$5" CUNIT="$6" CSTATE="$7" CFAILED="$8" SMODE="$9"
  local curver="" srole="" api_before=""
  [[ "$NAME" == "nym-node" ]] && srole="${ROLE:-}"   # the gateway stop quirk is nym-node's, not the bridge's
  [[ "$SMODE" == "version" ]] && curver="$(bin_version "$CBIN")"

  local rels latest tag published url hashurl
  rels="$(gh_releases "$CREPO")"               || { log "[$NAME] github query failed; skip this cycle"; return 0; }
  latest="$(printf '%s' "$rels" | pick_latest "$CPREF" "$CASSET")" || { log "[$NAME] could not parse releases; skip"; return 0; }
  [[ -n "$latest" ]]                           || { log "[$NAME] no qualifying release found; skip"; return 0; }
  IFS=$'\t' read -r tag published url hashurl <<<"$latest" || true
  [[ -n "$tag" && -n "$url" ]]                  || { log "[$NAME] incomplete release metadata; skip"; return 0; }

  local last; last="$(cat "$CSTATE" 2>/dev/null || true)"
  [[ "$tag" != "$last" ]]                        || { log "[$NAME] already on latest ($tag); nothing to do"; return 0; }
  if is_blacklisted "$CFAILED" "$tag"; then log "[$NAME] WARNING: $tag failed its health check >=2x here; staying put (clear $CFAILED to retry)"; return 0; fi

  local age; age="$(age_hours "$published")" || { log "[$NAME] cannot parse release age for $tag; deferring this cycle"; return 0; }
  if (( age < MIN_AGE_HOURS )); then log "[$NAME] newest $tag only ${age}h old (< ${MIN_AGE_HOURS}h); waiting"; return 0; fi
  log "[$NAME] new release available: $tag (published $published, ~${age}h ago)"
  if [[ "$NAME" == "nym-node" ]] && ! quiet_gate_ok "$tag"; then return 0; fi

  local tmp rc=0
  tmp="$(mktemp -d "$STATE_DIR/tmp.XXXXXX" 2>/dev/null)" || { log "[$NAME] mktemp failed; skip this cycle"; return 0; }
  while :; do
    if ! gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 5 $RETRY_ALL --retry-delay 5 --max-time 600 -o "$tmp/bin" "$url"; then
      log "[$NAME] download failed (after retries over IPv6+IPv4); skip this cycle"; rc=0; break
    fi

    local want=""
    if [[ -n "$hashurl" ]] && gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 3 $RETRY_ALL --max-time 60 -o "$tmp/hashes.json" "$hashurl"; then
      want="$(jq -r --arg a "$CASSET" '.assets[$a].sha256 // empty' "$tmp/hashes.json" 2>/dev/null || true)"
    fi
    if [[ -n "$want" ]]; then
      local got; got="$(sha256sum "$tmp/bin" | awk '{print $1}')"
      if [[ "$got" != "$want" ]]; then log "[$NAME] SHA-256 mismatch for $tag (want $want got $got) - NOT installing"; rc=1; break; fi
      log "[$NAME] sha256 verified ok"
    elif [[ "$SMODE" == "version" && "${NYM_ALLOW_UNVERIFIED:-0}" != "1" ]]; then
      log "[$NAME] no checksum available for $tag; REFUSING to install (set NYM_ALLOW_UNVERIFIED=1 to override)"; rc=1; break
    else
      log "[$NAME] no published checksum for $tag; proceeding on HTTPS + smoke test (expected for this component)"
    fi

    chmod +x "$tmp/bin"
    local newver=""
    if [[ "$SMODE" == "version" ]]; then
      newver="$(bin_version "$tmp/bin")"
      if [[ -z "$newver" ]]; then log "[$NAME] downloaded binary fails --version; NOT installing"; rc=1; break; fi
      log "[$NAME] downloaded build version $newver ($tag)"
      if [[ -n "$curver" && "$newver" == "$curver" ]]; then
        log "[$NAME] binary version unchanged ($curver); recording tag, no restart"; printf '%s\n' "$tag" > "$CSTATE"; rc=0; break
      fi
    else
      if ! "$tmp/bin" --help >/dev/null 2>&1; then log "[$NAME] downloaded binary does not execute (--help failed); NOT installing"; rc=1; break; fi
      log "[$NAME] downloaded new binary ($tag); smoke test ok"
    fi

    # nothing to do if the new binary is byte-identical to the installed one
    if cmp -s "$tmp/bin" "$CBIN"; then
      log "[$NAME] $tag is byte-identical to the installed binary; recording tag, no restart"
      printf '%s\n' "$tag" > "$CSTATE"; rc=0; break
    fi

    # backup, then stage the new binary next to the target (same fs) BEFORE stopping, so the swap
    # is a single atomic rename and the live binary is never a half-written file.
    local owner mode stamp backup dir staged
    owner="$(stat -c '%U:%G' "$CBIN" 2>/dev/null || echo root:root)"
    mode="$(stat -c '%a' "$CBIN" 2>/dev/null || echo 755)"
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    backup="$BACKUP_DIR/${NAME}.${curver:-prev}.$stamp"
    dir="$(dirname "$CBIN")"; staged="$dir/.nau-new.$$"
    if ! cp -a "$CBIN" "$backup"; then log "[$NAME] backup failed; aborting (no change made)"; rc=1; break; fi
    log "[$NAME] backed up -> $backup (owner=$owner mode=$mode)"
    if ! install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$tmp/bin" "$staged" 2>/dev/null; then
      log "[$NAME] could not stage new binary in $dir; aborting (no change made)"; rm -f "$staged" 2>/dev/null || true; rc=1; break
    fi

    [[ "$NAME" == "nym-api" ]] && api_before="$(api_signer_state)"
    # the download and checks above can take minutes; if an epoch changed meanwhile and the node
    # was put into the active set, do not restart it now (nothing has been changed yet)
    if [[ "$NAME" == "nym-node" ]] && ! quiet_gate_ok "$tag"; then
      rm -f "$staged" "$backup" 2>/dev/null || true; rc=0; break
    fi
    log "[$NAME] stopping $CUNIT"
    if ! stop_unit "$CUNIT" "$srole"; then
      log "[$NAME] $CUNIT did not stop; binary NOT swapped, $tag will be tried again next run"
      rm -f "$staged" "$backup" 2>/dev/null || true; sctl start "$CUNIT" >/dev/null 2>&1 || true; rc=1; break
    fi
    if ! mv -f "$staged" "$CBIN"; then
      log "[$NAME] atomic swap failed; restoring previous binary"
      rm -f "$staged" 2>/dev/null || true
      cp -a "$backup" "$CBIN" 2>/dev/null || log "[$NAME] CRITICAL: restore after failed swap failed ($backup -> $CBIN)"
      sctl start "$CUNIT" || true; rc=1; break
    fi
    log "[$NAME] installed new binary; starting $CUNIT"
    sctl start "$CUNIT" || log "[$NAME] warning: start returned non-zero"

    if is_healthy "$CUNIT" "$CBIN" "$newver" && unit_runs_current_binary "$CUNIT" "$CBIN" \
       && { [[ "$NAME" != "nym-api" ]] || api_http_healthy "$newver" "$api_before"; } \
       && { [[ "$NAME" != "nym-bridge" ]] || bridge_listening "$CUNIT" "$CBIN"; }; then
      printf '%s\n' "$tag" > "$CSTATE"
      log "[$NAME] SUCCESS: $CUNIT healthy on ${newver:-$tag}"
      notify success "$NAME updated to ${newver:-$tag} and healthy"
      ls -1t "$BACKUP_DIR/${NAME}."* 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f || true
      rc=0; break
    fi

    # rollback: restore the previous binary (atomically), record the failure, verify just as strictly
    log "[$NAME] HEALTH CHECK FAILED for $tag; ROLLING BACK to previous binary"
    record_fail "$CFAILED" "$tag"
    if ! stop_unit "$CUNIT" "$srole"; then
      # putting the old file back under a process that keeps running would make disk and process differ
      log "[$NAME] CRITICAL: $CUNIT did not stop, so the rollback was NOT done; still on $tag. MANUAL INTERVENTION NEEDED."
      notify failed "CRITICAL: $NAME $tag failed its health check and $CUNIT did not stop for the rollback; check by hand"
      rc=2; break
    fi
    if cp -a "$backup" "$dir/.nau-rb.$$" 2>/dev/null && mv -f "$dir/.nau-rb.$$" "$CBIN" 2>/dev/null; then :; else
      log "[$NAME] CRITICAL: rollback restore failed ($backup -> $CBIN)"; rm -f "$dir/.nau-rb.$$" 2>/dev/null || true
    fi
    sctl start "$CUNIT" || true
    if is_healthy "$CUNIT" "$CBIN" "$curver" && unit_runs_current_binary "$CUNIT" "$CBIN"; then
      log "[$NAME] ROLLBACK OK: restored ${curver:-previous} binary, $CUNIT healthy again. $tag failure recorded."
      notify rollback "$NAME update to $tag FAILED; rolled back to ${curver:-previous}, $CUNIT is UP"; rc=1; break
    fi
    log "[$NAME] CRITICAL: rollback did NOT restore a healthy $CUNIT. MANUAL INTERVENTION NEEDED."
    notify failed "CRITICAL: $NAME update to $tag failed AND rollback unhealthy on $CUNIT"; rc=2; break
  done
  rm -rf "$tmp"
  return "$rc"
}

# ------------------- network tunnel manager (gateways only) -----------------
# Scan ONLY this release's changelog section for tunnel/port relevance. arg: tag
# stdout = matched lines; return 0 = relevant, 1 = not relevant, 2 = could not read/parse.
# Print the operator-changelog section for a release version, e.g. "2026.15-bydgoszcz".
# Docs headings look like:  ## `v2026.15-bydgoszcz`   (the leading char before v is a backtick,
# matched here with '.'). Tries each docs branch in turn.
op_changelog_section() {   # arg: version (tag minus TAG_PREFIX)
  local ver="$1" ref path cl section
  for ref in $OP_CHANGELOG_REFS; do
    for path in $OP_CHANGELOG_PATHS; do
      cl="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 60 \
            "https://raw.githubusercontent.com/$REPO/$ref/$path" 2>/dev/null)" \
        || cl="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 60 \
            "https://raw.githubusercontent.com/$REPO/$ref/$path" 2>/dev/null)" || continue
      # awk stops at the next section; under systemd SIGPIPE is ignored, so printf would log EPIPE
      section="$(printf '%s\n' "$cl" 2>/dev/null | awk -v pat="^## .v${ver}([^A-Za-z0-9]|$)" '
        $0 ~ pat {f=1; print; next}
        f && /^## .v20/ {exit}
        f {print}')"
      [[ -n "$section" ]] && { printf '%s\n' "$section"; return 0; }
    done
  done
  return 1
}

# Does this release's operator notes give an NTM instruction? Only an explicit one counts: the NTM
# command with a subcommand in a shell block, or prose telling operators to re-run NTM. arg: tag
# stdout = matched lines; return 0 = yes, 1 = no, 2 = could not read the notes.
changelog_mentions_ntm() {
  local tag="$1" ver section matched
  ver="${tag#${TAG_PREFIX}}"
  section="$(op_changelog_section "$ver")" || return 2
  [[ -n "$section" ]] || return 2
  matched="$( { printf '%s\n' "$section" | changelog_commands | grep -E 'network.?tunnel.?manager\.sh[[:space:]]+[a-z_]+' || true
                printf '%s\n' "$section" | grep -iE 're-?run[^.]{0,60}(NTM|tunnel.?manager|network.?tunnel)' || true; } )"
  [[ -n "$matched" ]] || return 1
  printf '%s\n' "$matched"
}

ntm_run() {               # args: <ntm_path> <cmd> [arg...]  -- run an NTM subcommand, log its output
  local p="$1"; shift
  local out code
  # HOST_SSH_PORT: NTM's firewall keeps this SSH port open. stdin from /dev/null: never wait on a prompt.
  if out="$(HOST_SSH_PORT="${SSH_PORT:-22}" HOST_INPUT_POLICY="$NTM_INPUT_POLICY" DEBIAN_FRONTEND=noninteractive \
            timeout "$NTM_TIMEOUT" bash "$p" "$@" </dev/null 2>&1)"; then code=0; else code=$?; fi
  log "[ntm] \`$*\` exit=$code"
  printf '%s\n' "$out" | sed 's/^/[ntm]   /' >> "$LOGFILE" 2>/dev/null || true
  return "$code"
}

# Independent, hard-failing probe: a packet SOURCED FROM the tunnel IP must reach the internet.
# This proves FORWARD + MASQUERADE end-to-end regardless of ruleset structure (chain/direct/nft).
ntm_selftest() {          # arg: iface ; return 0 = egressing
  local iface="$1" a4 a6
  a4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  a6="$(ip -6 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^fe80' | head -n1 || true)"
  [[ -n "$a4$a6" ]] || { log "[ntm] probe: $iface has no usable IP"; return 1; }
  if [[ -n "$a4" ]]; then
    curl --interface "$a4" -fsS --max-time 10 -o /dev/null https://icanhazip.com 2>/dev/null && return 0
    ping -c1 -W4 -I "$a4" 1.1.1.1 >/dev/null 2>&1 && return 0
  fi
  if [[ -n "$a6" ]]; then
    curl -g --interface "$a6" -fsS --max-time 10 -o /dev/null https://icanhazip.com 2>/dev/null && return 0
    ping6 -c1 -W4 -I "$a6" 2606:4700:4700::1111 >/dev/null 2>&1 && return 0
  fi
  log "[ntm] probe: no egress from $iface (v4=${a4:-none} v6=${a6:-none}) - forwarding/masquerade broken"; return 1
}

gh_commit_of() {          # arg: repo path ; newest commit on $NTM_BRANCH touching it: "<sha>\t<date>"
  local url js sha date
  url="https://api.github.com/repos/$REPO/commits?sha=$NTM_BRANCH&path=$1&per_page=1"
  js="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" \
    || js="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" || return 1
  sha="$(printf '%s' "$js" | jq -r '.[0].sha // empty' 2>/dev/null || true)"
  date="$(printf '%s' "$js" | jq -r '.[0].commit.committer.date // empty' 2>/dev/null || true)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\t%s\n' "$sha" "$date"
}

# The exit-policy ports of an NTM script ("8000", "3478:3484"), and whether NYM-EXIT holds each of
# them for tcp and udp, v4 and v6 (where the chain exists), ahead of the chain's final REJECT.
ntm_allowlist() {
  awk '/PORT_MAPPINGS=\(/ {f = 1; next} f && /^[[:space:]]*\)/ {exit} f' "$1" 2>/dev/null | grep -vE '^[[:space:]]*#' \
    | grep -oE '^[[:space:]]*\["[^"]+"\]="[0-9]+(-[0-9]+)?"' | sed -E 's/.*="([^"]+)"/\1/; s/-/:/' | sort -u
}
ntm_check_allowlist() {   # arg: ntm script ; stdout: what is missing
  local want have ipt spec miss=""
  want="$(ntm_allowlist "$1")"
  [[ -n "$want" ]] || { echo "no port allowlist in the NTM script"; return 1; }
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    if ! "$ipt" -w -S NYM-EXIT >/dev/null 2>&1; then [[ "$ipt" == iptables ]] && { echo "no NYM-EXIT chain"; return 1; }; continue; fi
    have="$("$ipt" -w -S NYM-EXIT | awk '{ u = $0; gsub(/ -m comment --comment ("[^"]*"|[^ ]+)/, "", u) }
      u ~ /^-A NYM-EXIT -j (REJECT|DROP)( |$)/ { exit }
      u ~ /^-A NYM-EXIT -p (tcp|udp) -m (tcp|udp) --dport [0-9:]+ -j ACCEPT$/ { split(u, a, " "); print a[4], a[8] }' | sort -u)"
    while read -r spec; do
      grep -qxF "tcp $spec" <<<"$have" || miss="$miss $ipt:tcp/$spec"
      grep -qxF "udp $spec" <<<"$have" || miss="$miss $ipt:udp/$spec"
    done <<<"$want"
  done
  [[ -z "$miss" ]] && return 0
  echo "missing:$(printf '%s' "$miss" | cut -c1-300)"; return 1
}

# Services listening on this host (not loopback, not on the tunnel interfaces): "proto port fam".
host_listeners() {
  local skip proto addr port host fam i
  skip="$(for i in "${NTM_IFACE:-nymtun0}" nymwg; do ip -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; done)"
  ss -Hlntu 2>/dev/null | awk '{print $1, $5}' | while read -r proto addr; do
    port="${addr##*:}"; host="${addr%:*}"
    [[ "$proto" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]+$ ]] || continue
    host="${host#[}"; host="${host%%[%]*}"; host="${host%]}"
    case "$host" in 127.*|::1|::ffff:127.*|fe80:*|FE80:*) continue ;; esac
    [[ -n "$skip" ]] && grep -qxF -- "$host" <<<"$skip" && continue
    case "$host" in '*') fam=46 ;; 0.0.0.0) fam=4 ;; *:*) fam=6 ;; *) fam=4 ;; esac
    printf '%s %s %s\n' "$proto" "$port" "$fam"
  done | sort -u
}
# NTM drops inbound traffic it does not list. Where the INPUT policy was ACCEPT, every service that
# listens here gets an ACCEPT appended at the END of INPUT: what used to reach the ACCEPT policy now
# reaches this rule, and whatever an earlier rule restricted stays restricted. args: policy v4, v6
NTM_KEEP_TAG="nym-node-autoupdate-keep"
ntm_keep_listeners() {    # stdin: host_listeners lines
  local p4="$1" p6="$2" proto port fam
  while read -r proto port fam; do
    [[ "$proto" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]+$ ]] || continue
    if [[ "$fam" == *4* && "$p4" == ACCEPT ]]; then
      iptables -w -C INPUT -p "$proto" --dport "$port" -m comment --comment "$NTM_KEEP_TAG" -j ACCEPT 2>/dev/null \
        || iptables -w -A INPUT -p "$proto" --dport "$port" -m comment --comment "$NTM_KEEP_TAG" -j ACCEPT 2>/dev/null || true
    fi
    if [[ "$fam" == *6* && "$p6" == ACCEPT ]] && command -v ip6tables >/dev/null 2>&1; then
      ip6tables -w -C INPUT -p "$proto" --dport "$port" -m comment --comment "$NTM_KEEP_TAG" -j ACCEPT 2>/dev/null \
        || ip6tables -w -A INPUT -p "$proto" --dport "$port" -m comment --comment "$NTM_KEEP_TAG" -j ACCEPT 2>/dev/null || true
    fi
  done
}
ssh_allowed() {           # arg: iptables|ip6tables ; INPUT lets a new SSH connection in from anywhere
  [[ "$(fw_decision "$1" tcp "${SSH_PORT:-22}")" == ACCEPT ]]
}

# Keep the gateway in step with the NTM the operator notes point to (network-tunnel-manager.sh on
# develop, run as complete_networking_configuration). It runs when NTM gets a new commit upstream
# (NIP exit-policy votes arrive that way) or when the current release's notes ask for it.
# Snapshot of the firewall before; checks after (exit code, egress, nym-node, SSH, the exit policy
# holds every port of the applied NTM); any failure restores the snapshot. NEVER aborts the run.
# Only where Nym runs NTM (node_mode): exit gateways, probed on nymtun0, and WireGuard entry
# gateways, probed on nymwg. Nym's NTM sets up and tests both nymtun0 and nymwg and stops when either
# is missing, so it is not run without both; that is reported once.
maybe_run_ntm() {
  [[ "${NTM_ENABLED:-0}" == 1 ]] || return 0
  local mode iface dest="${NTM_PATH:-/usr/local/sbin/network-tunnel-manager.sh}"
  mode="$(node_mode)" || { log "[ntm] nym-node at $NODE_HTTP did not report its mode; NTM step skipped this run"; return 0; }
  case "$mode" in
    exit)     iface="${NTM_IFACE:-nymtun0}" ;;
    entry-wg) iface="nymwg" ;;
    *)        return 0 ;;
  esac
  local tag ref="" rdate="" applied failed why="" matched crc age tmp t f ok=1 msg p4 p6 lst
  tag="$(cat "$STATE_TAG" 2>/dev/null || true)"
  IFS=$'\t' read -r ref rdate < <(gh_commit_of "$NTM_REPO_PATH") || true
  [[ -n "$ref" ]] || { log "[ntm] could not resolve NTM on $REPO@$NTM_BRANCH; will retry next run"; return 0; }
  applied="$(cat "$NTM_REF_STATE" 2>/dev/null || true)"
  failed="$(cat "$NTM_FAILED_STATE" 2>/dev/null || true)"

  # 1) NTM itself changed upstream (a new commit is taken once it is NTM_MIN_AGE_HOURS old)
  if [[ "$ref" != "$applied" ]]; then
    age="$(age_hours "$rdate" 2>/dev/null || echo 0)"
    if (( age >= NTM_MIN_AGE_HOURS )); then why="NTM ${ref:0:12} is not applied here yet"
    else log "[ntm] NTM changed upstream (${ref:0:12}, ${age}h old); applying after ${NTM_MIN_AGE_HOURS}h"; fi
  fi
  # 2) the current release's operator notes ask for a re-run (read until a decision is recorded)
  if [[ -n "$tag" && "$tag" != "$(cat "$NTM_STATE" 2>/dev/null || true)" ]]; then
    if matched="$(changelog_mentions_ntm "$tag")"; then crc=0; else crc=$?; fi
    if (( crc == 0 )); then
      log "[ntm] the operator notes for $tag ask to re-run NTM"; printf '%s\n' "$matched" | sed 's/^/[ntm]   /' >> "$LOGFILE" 2>/dev/null || true
      why="${why:+$why; }the notes for $tag ask to re-run NTM"
    elif (( crc == 1 )); then
      printf '%s\n' "$tag" > "$NTM_STATE"
    else
      local wtag="" wfirst="" now waited
      read -r wtag wfirst 2>/dev/null < "$NTM_DOCS_WAIT" || true
      now="$(date -u +%s)"
      if [[ "$wtag" != "$tag" || ! "$wfirst" =~ ^[0-9]+$ ]]; then wfirst="$now"; printf '%s %s\n' "$tag" "$now" > "$NTM_DOCS_WAIT"; fi
      waited=$(( (now - wfirst) / 3600 ))
      if ! ntm_selftest "$iface"; then why="${why:+$why; }no notes for $tag and the tunnel does not egress"
      elif (( waited >= NTM_DOCS_WAIT_HOURS )); then printf '%s\n' "$tag" > "$NTM_STATE"; rm -f "$NTM_DOCS_WAIT"
      else log "[ntm] no operator notes for $tag yet; checking again next run (${waited}h of ${NTM_DOCS_WAIT_HOURS}h)"; fi
    fi
  fi
  [[ -n "$why" ]] || return 0
  if [[ "$ref" == "$failed" && "${NAU_MANUAL:-0}" != "1" ]]; then
    log "[ntm] NTM ${ref:0:12} failed here before and was rolled back; waiting for a newer NTM (or Update now in Nymi)"
    return 0
  fi

  local noif; noif="$(ntm_missing_ifaces)"
  if [[ -n "$noif" ]]; then
    log "[ntm] Nym's NTM needs nymtun0 and nymwg; this $mode has no$noif. NOT applying"
    [[ "$mode$noif" != "$(cat "$NTM_IFACE_STATE" 2>/dev/null || true)" ]] || return 0   # reported already
    printf '%s\n' "$mode$noif" > "$NTM_IFACE_STATE"
    notify failed "NTM not run here: Nym's NTM needs nymtun0 and nymwg, this $mode has no$noif"; return 0
  fi
  rm -f "$NTM_IFACE_STATE"
  # we only touch the firewall if it can be snapshotted and put back
  if ! command -v iptables-save >/dev/null 2>&1 || [[ -z "$(iptables-save 2>/dev/null | head -c1)" ]]; then
    log "[ntm] the firewall cannot be snapshotted with iptables-save; NOT applying"; notify failed "NTM ${ref:0:12} not applied: no iptables-save snapshot possible here"; return 1
  fi
  tmp="$(mktemp -d "$STATE_DIR/ntm.XXXXXX" 2>/dev/null)" || { log "[ntm] mktemp failed"; return 0; }
  if ! gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 5 $RETRY_ALL --retry-delay 5 --max-time 180 \
         -o "$tmp/ntm.sh" "https://raw.githubusercontent.com/$REPO/$ref/$NTM_REPO_PATH" \
     || ! grep -qE '^[[:space:]]*complete_networking_configuration\)' "$tmp/ntm.sh"; then
    log "[ntm] could not download a usable NTM @ ${ref:0:12}; will retry next run"; rm -rf "$tmp"; return 0
  fi
  log "[ntm] applying NTM @ $ref ($why); sha256 $(sha256sum "$tmp/ntm.sh" | cut -c1-16)"

  # snapshot: live rules (with empty sections for tables NTM may create) and the files it rewrites.
  # Without a complete snapshot nothing is applied.
  t=1
  iptables-save > "$tmp/v4" 2>/dev/null && [[ -s "$tmp/v4" ]] || t=0
  if command -v ip6tables-save >/dev/null 2>&1; then ip6tables-save > "$tmp/v6" 2>/dev/null && [[ -s "$tmp/v6" ]] || t=0; fi
  for f in rules.v4 rules.v6; do if [[ -e "/etc/iptables/$f" ]]; then cp -a "/etc/iptables/$f" "$tmp/file.$f" || t=0; fi; done
  if (( t == 0 )); then log "[ntm] could not take a complete firewall snapshot; NOT applying"; rm -rf "$tmp"; return 1; fi
  for t in filter nat mangle; do
    grep -q "^\*$t\$" "$tmp/v4" || printf '*%s\nCOMMIT\n' "$t" >> "$tmp/v4"
    [[ ! -s "$tmp/v6" ]] || grep -q "^\*$t\$" "$tmp/v6" || printf '*%s\nCOMMIT\n' "$t" >> "$tmp/v6"
  done
  p4="$(iptables -w -S INPUT 2>/dev/null | awk 'NR==1 {print $3}')"; p6="$(ip6tables -w -S INPUT 2>/dev/null | awk 'NR==1 {print $3}' || true)"
  lst="$(host_listeners)"
  [[ "$NTM_INPUT_POLICY" == DROP ]] && printf '%s\n' "$lst" | ntm_keep_listeners "$p4" "$p6"

  ntm_run "$tmp/ntm.sh" complete_networking_configuration || ok=0
  [[ "$NTM_INPUT_POLICY" == DROP ]] && printf '%s\n' "$lst" | ntm_keep_listeners "$p4" "$p6"
  if (( ok )); then
    ntm_selftest "$iface"                         || { log "[ntm] check failed: the tunnel does not egress"; ok=0; }
    [[ "$(sctl is-active "$UNIT" 2>/dev/null)" == active ]] && curl -fsS --max-time 8 -o /dev/null "$NODE_HTTP/api/v1/health" 2>/dev/null \
                                                  || { log "[ntm] check failed: nym-node is not up"; ok=0; }
    ssh_allowed iptables                          || { log "[ntm] check failed: SSH port ${SSH_PORT:-22} is not let in (v4)"; ok=0; }
    ! command -v ip6tables >/dev/null 2>&1 || ssh_allowed ip6tables || { log "[ntm] check failed: SSH port ${SSH_PORT:-22} is not let in (v6)"; ok=0; }
    msg="$(ntm_check_allowlist "$tmp/ntm.sh")"    || { log "[ntm] check failed: exit policy $msg"; ok=0; }
  fi
  if (( ok )); then
    if command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1; then :
    else mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 && ip6tables-save > /etc/iptables/rules.v6 || { log "[ntm] could not save the rules for reboot"; ok=0; }; fi
  fi
  if (( ok )); then
    install -m 0755 "$tmp/ntm.sh" "$dest" 2>/dev/null || true
    printf '%s\n' "$ref" > "$NTM_REF_STATE"; rm -f "$NTM_FAILED_STATE"
    [[ -n "$tag" ]] && printf '%s\n' "$tag" > "$NTM_STATE"
    log "[ntm] SUCCESS: NTM ${ref:0:12} applied; tunnel egressing, nym-node up, SSH open, exit policy complete, rules saved"
    notify success "NTM ${ref:0:12} applied ($why)"
    rm -rf "$tmp"; return 0
  fi
  log "[ntm] restoring the firewall snapshot"
  local rok=1
  iptables-restore < "$tmp/v4" 2>/dev/null || { log "[ntm] iptables-restore failed"; rok=0; }
  if [[ -s "$tmp/v6" ]]; then ip6tables-restore < "$tmp/v6" 2>/dev/null || { log "[ntm] ip6tables-restore failed"; rok=0; }; fi
  for t in rules.v4 rules.v6; do
    if [[ -e "$tmp/file.$t" ]]; then cp -a "$tmp/file.$t" "/etc/iptables/$t" || rok=0; else rm -f "/etc/iptables/$t" || rok=0; fi
  done
  printf '%s\n' "$ref" > "$NTM_FAILED_STATE"; [[ -n "$tag" ]] && printf '%s\n' "$tag" > "$NTM_STATE"
  if (( rok == 0 )); then
    log "[ntm] CRITICAL: the firewall snapshot could not be fully restored (kept in $tmp) - MANUAL INTERVENTION NEEDED"
    notify failed "CRITICAL: NTM ${ref:0:12} failed AND restoring the firewall snapshot failed; snapshot kept in $tmp"; return 2
  fi
  if ntm_selftest "$iface"; then
    notify rollback "NTM ${ref:0:12} failed its checks; firewall restored, tunnel is UP. See $LOGFILE"; rm -rf "$tmp"; return 1
  fi
  notify failed "CRITICAL: NTM ${ref:0:12} failed AND the tunnel is still down after the restore"; rm -rf "$tmp"; return 2
}

# ---------------------- QUIC bridge TLS/SSH (gateways only) -----------------------
# The operator notes ask to re-run the bridge setup. The updater runs the official
# quic_bridge_deployment.sh from develop (pinned to its commit), non-interactively, for the installed
# bridge release, as an operator would. It keeps a backup of /etc/nym and the nym-node config; after
# the run the bridge must be up on every port, with the same QUIC key, and publish TLS and SSH;
# otherwise both are put back and the bridge restarted. It runs again only when the bridge release
# or the setup script changes.
BRIDGE_HELPER_PATH="scripts/nym-node-setup/quic_bridge_deployment.sh"
BRIDGE_CFG_STATE="$STATE_DIR/bridge_cfg_applied"   # "<bridge tag> <setup script commit>"
BRIDGE_CFG_FAILED="$STATE_DIR/bridge_cfg_failed"
BRIDGE_CFG_ENABLED="${NYM_BRIDGE_CFG:-1}"
maybe_configure_bridge() {
  [[ "$BRIDGE_CFG_ENABLED" == 1 && -n "${BRIDGE_UNIT:-}" && "${SVC_SCOPE:-system}" == system ]] || return 0
  local btag href key node tmp json="/etc/nym/client_bridge_params.json" q0 q1 ok=1 n
  btag="$(cat "$BRIDGE_STATE_TAG" 2>/dev/null || true)"
  [[ "$btag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  [[ "$(printf '%s\n%s\n' v0.3.0 "$btag" | sort -V | head -n1)" == v0.3.0 ]] || return 0   # TLS/SSH need 0.3+
  href="$(gh_commit_of "$BRIDGE_HELPER_PATH" | cut -f1)" || href=""
  [[ -n "$href" ]] || { log "[bridge] could not resolve the bridge setup script; will retry next run"; return 0; }
  key="$btag $href"
  [[ "$key" != "$(cat "$BRIDGE_CFG_STATE" 2>/dev/null || true)" ]] || return 0
  if [[ "$key" == "$(cat "$BRIDGE_CFG_FAILED" 2>/dev/null || true)" && "${NAU_MANUAL:-0}" != "1" ]]; then return 0; fi
  [[ "$(systemctl is-active "$BRIDGE_UNIT" 2>/dev/null)" == active && -s /etc/nym/bridges.toml && -s "$json" ]] \
    || { log "[bridge] $BRIDGE_UNIT not running or /etc/nym incomplete; not configuring"; return 1; }
  n="$(ls -1 /root/.nym/nym-nodes/*/config/config.toml 2>/dev/null | wc -l)"
  [[ "$n" == 1 ]] || { log "[bridge] not exactly one nym-node config under /root/.nym/nym-nodes; not configuring"; return 1; }
  node="$(ls -1 /root/.nym/nym-nodes/*/config/config.toml)"
  q0="$(jq -r '.transports[]? | select(.transport_type=="quic_plain") | .args.id_pubkey' "$json" 2>/dev/null)"
  [[ -n "$q0" ]] || { log "[bridge] no QUIC key in $json; not configuring"; return 1; }

  tmp="$(mktemp -d "$STATE_DIR/bridge.XXXXXX" 2>/dev/null)" || return 0
  if ! gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 -o "$tmp/setup.sh" \
         "https://raw.githubusercontent.com/$REPO/$href/$BRIDGE_HELPER_PATH" || ! bash -n "$tmp/setup.sh" 2>/dev/null; then
    log "[bridge] could not download the setup script @ ${href:0:12}; will retry next run"; rm -rf "$tmp"; return 0
  fi
  log "[bridge] running the official bridge setup @ ${href:0:12} for $btag"
  # Backup of what the bridge runs on and the setup script changes: /etc/nym, the nym-node config,
  # the bridge binaries (it installs the .deb over /usr/bin and links /usr/local/bin) and our drop-in.
  # Not undone on a failure: the package stays registered with dpkg (removing it would stop and mask
  # the bridge unit), with its files under /usr/lib and the firewall rules its postinst added.
  local bins="" b di="/etc/systemd/system/$BRIDGE_UNIT.d" had_dropin=0 rok=1 p
  for b in usr/bin/nym-bridge usr/bin/bridge-cfg usr/local/bin/nym-bridge usr/local/bin/bridge-cfg; do
    if [[ -e "/$b" || -L "/$b" ]]; then bins="$bins $b"; fi
  done
  # shellcheck disable=SC2086
  if ! { tar -C / -cpf "$tmp/etc-nym.tar" etc/nym && cp -a "$node" "$tmp/node.toml" && tar -C / -cpf "$tmp/bins.tar" $bins; }; then
    log "[bridge] could not back up /etc/nym, the nym-node config and the bridge binaries; not configuring"; rm -rf "$tmp"; return 1
  fi
  # our drop-in may already exist (an earlier run): keep a copy to put back
  if [[ -e "$di/nym-node-autoupdate.conf" ]]; then
    had_dropin=1; cp -a "$di/nym-node-autoupdate.conf" "$tmp/dropin.conf" || { log "[bridge] could not back up the unit drop-in; not configuring"; rm -rf "$tmp"; return 1; }
  fi
  # nym-bridge 0.3 stops every listener, QUIC too, and exits 0 when TLS or SSH fails, which
  # Restart=on-failure would not restart: Restart=always goes in first, or nothing is changed
  if ! { mkdir -p "$di" && printf '[Service]\nRestart=always\nRestartSec=5\n' > "$di/.nym-node-autoupdate.conf.tmp" \
         && mv -f "$di/.nym-node-autoupdate.conf.tmp" "$di/nym-node-autoupdate.conf" && systemctl daemon-reload \
         && [[ "$(systemctl show -p Restart --value "$BRIDGE_UNIT" 2>/dev/null)" == always ]]; }; then
    log "[bridge] could not set Restart=always on $BRIDGE_UNIT; not configuring"
    bridge_put_dropin_back "$di" "$had_dropin" "$tmp/dropin.conf" || log "[bridge] CRITICAL: could not put the unit drop-in back"
    rm -rf "$tmp"; return 1
  fi

  if NONINTERACTIVE=1 NODE_CFG="$node" BRIDGE_TAG="$btag" DEBIAN_FRONTEND=noninteractive \
       timeout 900 bash "$tmp/setup.sh" full_bridge_setup </dev/null >> "$LOGFILE" 2>&1; then :
  else log "[bridge] the setup script failed (exit $?)"; ok=0; fi
  if (( ok )); then
    q1="$(jq -r '.transports[]? | select(.transport_type=="quic_plain") | .args.id_pubkey' "$json" 2>/dev/null)"
    [[ "$q1" == "$q0" ]] || { log "[bridge] check failed: the QUIC key changed"; ok=0; }
    [[ "$(jq -r '[.transports_v2[]?.transport_type] | sort | join(" ")' "$json" 2>/dev/null)" == "quic_plain ssh_plain tls_plain" ]] \
      || { log "[bridge] check failed: TLS/SSH are not published"; ok=0; }
    [[ "$(jq -r '[.transports[]?.transport_type] | join(" ")' "$json" 2>/dev/null)" == "quic_plain" ]] \
      || { log "[bridge] check failed: transports is not QUIC only (older apps would reject the gateway)"; ok=0; }
    is_healthy "$BRIDGE_UNIT" "$BRIDGE_BIN" "" && bridge_listening "$BRIDGE_UNIT" "$BRIDGE_BIN" || { log "[bridge] check failed: the bridge is not up on every port"; ok=0; }
  fi
  if (( ok )); then
    # what a client needs: TLS and SSH answer with the published keys, and the host firewall lets them in
    p="$(bridge_port tls_plain "$json")"; [[ -n "$p" ]] && bridge_check_tls "$p" "$json" && fw_port_open tcp "$p" || ok=0
    p="$(bridge_port ssh_plain "$json")"; [[ -n "$p" ]] && bridge_check_ssh "$p" "$json" && fw_port_open tcp "$p" || ok=0
  fi
  if (( ok )); then
    printf '%s\n' "$key" > "$BRIDGE_CFG_STATE"; rm -f "$BRIDGE_CFG_FAILED"
    log "[bridge] SUCCESS: TLS and SSH serve the published keys and are let in, QUIC key unchanged"
    notify success "Bridge $btag: TLS/SSH configured and published"
    rm -rf "$tmp"; return 0
  fi

  log "[bridge] restoring /etc/nym, the nym-node config, the bridge binaries and the unit from the backup"
  systemctl stop "$BRIDGE_UNIT" 2>/dev/null || true
  # /etc/nym: the backup is unpacked next to it first (same filesystem), then the two are swapped by
  # rename. The live /etc/nym is never deleted before the restored one is in place; if the swap fails
  # half way, the old one is renamed back and the result is CRITICAL.
  local st="/etc/.nau-restore.$$" old="/etc/.nym.nau-failed.$$"
  if mkdir "$st" && tar -C "$st" -xpf "$tmp/etc-nym.tar" && [[ -d "$st/etc/nym" ]]; then
    if mv /etc/nym "$old"; then
      if mv "$st/etc/nym" /etc/nym; then rm -rf "$old"
      else rok=0; mv "$old" /etc/nym || log "[bridge] CRITICAL: /etc/nym is missing; the changed copy is $old"; fi
    else rok=0; fi
  else rok=0; log "[bridge] could not unpack the /etc/nym backup; /etc/nym left as the setup script left it"; fi
  rm -rf "$st"
  cp -a "$tmp/node.toml" "$node" || rok=0
  for b in $bins; do rm -f "/$b" || rok=0; done
  tar -C / -xpf "$tmp/bins.tar" || rok=0
  bridge_put_dropin_back "$di" "$had_dropin" "$tmp/dropin.conf" || rok=0
  systemctl start "$BRIDGE_UNIT" 2>/dev/null || true
  printf '%s\n' "$key" > "$BRIDGE_CFG_FAILED"
  if (( rok )) && is_healthy "$BRIDGE_UNIT" "$BRIDGE_BIN" "" && bridge_listening "$BRIDGE_UNIT" "$BRIDGE_BIN" \
     && [[ "$(jq -r '.transports[]? | select(.transport_type=="quic_plain") | .args.id_pubkey' "$json" 2>/dev/null)" == "$q0" ]]; then
    notify rollback "Bridge TLS/SSH setup failed; restored, QUIC is up. See $LOGFILE"; rm -rf "$tmp"; return 1
  fi
  log "[bridge] CRITICAL: the restore is incomplete or the bridge is not back (backup kept in $tmp) - MANUAL INTERVENTION NEEDED"
  notify failed "CRITICAL: bridge setup failed AND the restore did not bring the bridge back; backup kept in $tmp"; return 2
}

bridge_port() {           # args: transport_type, client params ; the port it is published on
  jq -r --arg t "$1" '.transports_v2[]? | select(.transport_type==$t) | .args.addresses[0] // empty' "$2" 2>/dev/null | sed -E 's/.*:([0-9]+)$/\1/'
}
# TLS on <port> serves the published key: the certificate's ed25519 key equals the tls_plain id_pubkey.
bridge_check_tls() {      # args: port, client params
  local want host got
  want="$(jq -r '.transports_v2[]? | select(.transport_type=="tls_plain") | .args.id_pubkey' "$2")"
  host="$(jq -r '.transports_v2[]? | select(.transport_type=="tls_plain") | .args.host // empty' "$2")"
  got="$(timeout 10 openssl s_client -connect "127.0.0.1:$1" ${host:+-servername "$host"} </dev/null 2>/dev/null \
         | openssl x509 -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | tail -c 32 | base64 -w0)"
  [[ -n "$want" && "$got" == "$want" ]] && return 0
  log "[bridge] check failed: TLS on tcp/$1 does not serve the published key"; return 1
}
# SSH on <port> answers SSH-2.0 and its ed25519 host key equals the ssh_plain id_pubkey.
bridge_check_ssh() {      # args: port, client params
  local want banner got
  want="$(jq -r '.transports_v2[]? | select(.transport_type=="ssh_plain") | .args.id_pubkey' "$2")"
  banner="$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && head -n1 <&3" 2>/dev/null | tr -d '\r')"
  got="$(ssh-keyscan -T 5 -t ed25519 -p "$1" 127.0.0.1 2>/dev/null | awk '$2=="ssh-ed25519" {print $3; exit}' | base64 -d 2>/dev/null | tail -c 32 | base64 -w0)"
  [[ "$banner" == SSH-2.0-* && -n "$want" && "$got" == "$want" ]] && return 0
  log "[bridge] check failed: SSH on tcp/$1 does not serve the published key"; return 1
}
bridge_put_dropin_back() {     # args: drop-in dir, had one before (0|1), its copy ; then daemon-reload
  if [[ "$2" == 1 ]]; then cp -a "$3" "$1/nym-node-autoupdate.conf" || return 1
  else rm -f "$1/nym-node-autoupdate.conf" || return 1; fi
  systemctl daemon-reload
}

# What INPUT decides for a NEW packet from any internet address to <proto>/<port>: the first rule, in
# order, that applies to such a packet. Rules limited to a source, to loopback or the tunnel
# interfaces, to replies, or to some packets (rate and set matches) do not apply. A jump to another
# chain is not followed (such chains, like fail2ban's, hold source-specific rules). No rule: the policy.
# args: iptables|ip6tables proto port ; stdout ACCEPT | DROP
fw_decision() {
  "$1" -w -S INPUT 2>/dev/null | awk -v P="$2" -v N="$3" '
    function hasport(r,   s, a, k, j, b) {
      if (!match(r, / --dports? [0-9,:]+/)) return 1
      s = substr(r, RSTART, RLENGTH); sub(/ --dports? /, "", s); k = split(s, a, ",")
      for (j = 1; j <= k; j++) { if (index(a[j], ":")) { split(a[j], b, ":"); if (N + 0 >= b[1] + 0 && N + 0 <= b[2] + 0) return 1 } else if (a[j] + 0 == N + 0) return 1 }
      return 0 }
    $1 == "-P" && $2 == "INPUT" { pol = $3; next }
    $1 != "-A" { next }
    { r = " " $0 " "
      gsub(/ ! (-s|--source) [^ ]+/, " ", r)      # "not from X" applies to an arbitrary address
      if (r ~ / (-s|--source) /) next
      if (r ~ / ! /) next
      if (r ~ / -i (lo|nym[a-z0-9]*) /) next
      if (r ~ / --(ctstate|state) / && r !~ / --(ctstate|state) [A-Z,]*NEW/) next
      if (r ~ / -m (hashlimit|recent|limit|set|connlimit|addrtype|owner|u32|string|time) /) next
      if (r ~ / -p [^ ]+ / && r !~ (" -p " P " ")) next
      if (!hasport(r)) next
      if (r ~ / -j ACCEPT /) { print "ACCEPT"; found = 1; exit }
      if (r ~ / -j (DROP|REJECT) /) { print "DROP"; found = 1; exit } }
    END { if (!found) print (pol == "" ? "DROP" : pol) }'
}
# The host firewall lets <proto>/<port> in from anywhere, v4 and v6. Where ufw is active its rules
# decide first; where none of them does and its default drops, INPUT's own rules after ufw's decide.
fw_port_open() {          # args: proto port
  local c d v4="" v6="" def=""
  if ufw_active; then read -r v4 v6 def <<<"$(ufw_view "$1" "$2")"; fi
  for c in iptables ip6tables; do
    command -v "$c" >/dev/null 2>&1 || continue
    d="$v4"; [[ "$c" == ip6tables ]] && d="$v6"
    if [[ "$d" == R ]]; then d=-; fi
    case "$d:$def" in
      A:*|-:allow)  continue ;;
      D:*|-:reject) log "[bridge] check failed: ufw does not let $1/$2 in ($c)"; return 1 ;;
    esac
    [[ "$(fw_decision "$c" "$1" "$2")" == ACCEPT ]] || { log "[bridge] check failed: $c does not let $1/$2 in"; return 1; }
  done
}

ufw_active() { command -v ufw >/dev/null 2>&1 && [[ "$(LC_ALL=C ufw status 2>/dev/null | head -n1)" == "Status: active" ]]; }
# What ufw decides for a new connection from any internet address to <proto>/<port>, read from
# `ufw status verbose` (every IPv4 rule in order, then every IPv6 one; app profiles shown as ports).
# Per family, the first rule that decides: A (ALLOW, LIMIT), D (DENY, REJECT) or - (none); R when none
# decides but the operator allows the port only for some sources, an interface or an address; x when
# ufw does not manage IPv6 here. Rules for some sources only do not decide. A rule bound to a local
# address or an interface, or one not read here, decides only when it closes; a rule line that cannot
# be read closes (fail closed). stdout: "<v4> <v6> <ufw default incoming: allow|deny|reject>"
ufw_view() {              # args: proto port
  local v
  v="$(LC_ALL=C ufw status verbose 2>/dev/null | awk -v pr="$1" -v p="$2" '
    function covers(to,   a, n, c, k, i, b) {     # 1 covers, 0 does not, -1 not read
      n = split(to, a, "/")
      if (a[1] != "Anywhere" && a[1] !~ /^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$/) return -1
      if (n > 2 || (n == 2 && a[2] != pr)) return 0
      if (a[1] == "Anywhere") return 1
      k = split(a[1], c, ",")
      for (i = 1; i <= k; i++) {
        if (index(c[i], ":")) { split(c[i], b, ":"); if (p + 0 >= b[1] + 0 && p + 0 <= b[2] + 0) return 1 }
        else if (c[i] + 0 == p + 0) return 1 }
      return 0 }
    function is6(s) { return s ~ /:.*:/ && s !~ /,/ && s !~ /\/[a-z]+$/ }   # an IPv6 address, not a port list
    /^Status: active/ { st = 1; next }
    /^Default:/ { def = ($0 ~ /allow \(incoming\)/) ? "allow" : (($0 ~ /reject \(incoming\)/) ? "reject" : "deny"); next }
    /^--/ { go = 1; next }
    !go || /^[[:space:]]*$/ { next }
    !match($0, / (ALLOW|DENY|REJECT|LIMIT)( (IN|OUT|FWD))? /) { if (d4 == "") d4 = "D"; if (d6 == "") d6 = "D"; next }
    { to = substr($0, 1, RSTART - 1); act = substr($0, RSTART + 1, RLENGTH - 2); from = substr($0, RSTART + RLENGTH) }
    act ~ / (OUT|FWD)$/ { next }
    { sub(/^ +/, "", from); sub(/ +$/, "", to)
      v6 = sub(/ \(v6\)/, "", to); if (from ~ /^Anywhere(\/[a-z0-9]+)? \(v6\)/) v6 = 1
      split(from, fa, " "); if (is6(fa[1])) v6 = 1                 # ufw marks (v6) only when both ends are ::/0
      if (match(to, /^[^ ]+ /) && is6(substr(to, 1, RLENGTH - 1))) v6 = 1
      anyw = (from ~ /^Anywhere(\/[a-z0-9]+)?( \(v6\))?(  |$)/)
      narrow = sub(/ on [^ ]+$/, "", to); sub(/ \([^()]*\)$/, "", to); if (sub(/^[^ ]+ /, "", to)) narrow = 1
      allow = (act ~ /^(ALLOW|LIMIT)( IN)?$/); c = covers(to) }
    !anyw || c == 0 || (allow && (c < 0 || narrow)) { if (allow && c == 1 && to !~ /^Anywhere/) { if (v6) r6 = 1; else r4 = 1 }; next }
    v6 && d6 == "" { d6 = allow ? "A" : "D" }
    !v6 && d4 == "" { d4 = allow ? "A" : "D" }
    END { if (!st) { print "D D deny"; exit }                       # ufw did not answer: fail closed
          print (d4 != "" ? d4 : (r4 ? "R" : "-")), (d6 != "" ? d6 : (r6 ? "R" : "-")), (def == "" ? "deny" : def) }')"
  # ufw manages IPv6 exactly when its IPv6 chains exist
  ip6tables -w -n -L ufw6-user-input >/dev/null 2>&1 || v="${v%% *} x ${v##* }"
  printf '%s\n' "$v"
}

# An entry gateway without WireGuard is not NTM's: Nym keeps it on ufw and opens the bridge and Lewes
# Protocol ports there (Ansible deploy, nym_ufw_rules). Same here, only where ufw is active. A port a
# ufw rule closes or limits to some sources or an interface is left alone and reported.
# UFW_PORTS_ENABLED=0 in the config turns it off.
UFW_ENTRY_PORTS="4443/tcp 4443/udp 4422/tcp 41264/tcp 51264/udp"
UFW_PORTS_ENABLED="${NYM_UFW_PORTS:-1}"
UFW_FAILED_STATE="$STATE_DIR/ufw_failed"
maybe_open_ufw_ports() {
  [[ "$UFW_PORTS_ENABLED" == 1 && "$(node_mode 2>/dev/null || true)" == entry ]] && ufw_active || return 0
  local p v4 v6 def added="" miss=""
  for p in $UFW_ENTRY_PORTS; do
    read -r v4 v6 def <<<"$(ufw_view "${p#*/}" "${p%/*}")"
    if [[ "$v4$v6" == *[DR]* ]]; then miss="$miss $p"; continue; fi
    [[ "$v4" == A && "$v6" =~ ^[Ax]$ ]] && continue
    # only the family with no rule: a generic `ufw allow` would replace the other family's rule in place
    [[ "$v4" == - ]] && { ufw allow proto "${p#*/}" from 0.0.0.0/0 to any port "${p%/*}" >/dev/null 2>&1 || true; }
    [[ "$v6" == - ]] && { ufw allow proto "${p#*/}" from ::/0 to any port "${p%/*}" >/dev/null 2>&1 || true; }
    read -r v4 v6 def <<<"$(ufw_view "${p#*/}" "${p%/*}")"
    if [[ "$v4" == A && "$v6" =~ ^[Ax]$ ]]; then added="$added $p"; else miss="$miss $p"; fi
  done
  if [[ -n "$added" ]]; then log "[ufw] opened$added (Nym's ports for an entry gateway without WireGuard)"; notify success "ufw: opened$added"; fi
  if [[ -z "$miss" ]]; then rm -f "$UFW_FAILED_STATE"; return 0; fi
  log "[ufw] not open to everyone:$miss (a ufw rule closes or limits them, or ufw allow failed); left as they are"
  [[ "$miss" != "$(cat "$UFW_FAILED_STATE" 2>/dev/null || true)" ]] || return 0   # reported already
  printf '%s\n' "$miss" > "$UFW_FAILED_STATE"; notify failed "ufw: not open to everyone:$miss (a ufw rule closes or limits them). See $LOGFILE"
  return 1
}


# ------------------------- doctor: upstream drift check ----------------------
# The updater relies on how Nym publishes things: release tag prefixes and asset names, the path of
# the operator notes, the NTM path and its subcommands. Two of these changed in 2026 (bridge tags at
# 0.2, the docs path on 2026-10-14) and each time the updater just went quiet, with no error.
# doctor checks every one of these against GitHub. stdout: one "ok"/"WARN" line per check.
# arg: all | relevant (relevant = skip the bridge/NTM checks on a box without them). return 1 on WARN.
NTM_CMDS="complete_networking_configuration"
DOCTOR_STALE_DAYS=45          # Nym ships a nym-node release every 2-3 weeks
DOCTOR_STATE="$STATE_DIR/doctor_last"

# newest non-draft release (prereleases included) as "tag<TAB>published<TAB>has_asset(true|false)"
newest_release() {        # stdin: releases JSON ; arg: asset
  jq -r --arg a "$1" '[.[] | select(.draft==false)] | sort_by(.published_at) | reverse | .[0] // empty
    | "\(.tag_name)\t\(.published_at)\t\(any(.assets[]?; .name==$a))"'
}

# newest nym-node release, prereleases included (the first place a rename would show up)
newest_node_tag() {       # stdin: nymtech/nym releases JSON
  jq -r --arg a "$ASSET" '[.[] | select(.draft==false) | select(any(.assets[]?; .name==$a))]
    | sort_by(.published_at) | reverse | .[0].tag_name // empty' 2>/dev/null || true
}

doctor_checks() {
  local scope="${1:-all}" warn=0 rels lt pub age ntag tag hasa ref path reach=0 tmp c miss t
  # nym-node: the newest release that ships nym-node must carry our tag prefix, and the newest
  # stable one must not be stale (a renamed tag or asset shows up as "nothing new for weeks")
  if rels="$(gh_releases "$REPO" 2>/dev/null)"; then
    ntag="$(printf '%s' "$rels" | newest_node_tag)"
    IFS=$'\t' read -r lt pub _ _ <<<"$(printf '%s' "$rels" | pick_latest "$TAG_PREFIX" "$ASSET" 2>/dev/null)" || true
    if [[ -z "$ntag" ]]; then echo "WARN nym-node: no recent nymtech/nym release ships an asset named '$ASSET'"; warn=1
    elif [[ "$ntag" != "$TAG_PREFIX"* ]]; then echo "WARN nym-node: newest release with '$ASSET' is tagged '$ntag', not '$TAG_PREFIX*'"; warn=1
    elif [[ -z "$lt" ]]; then echo "WARN nym-node: no stable '$TAG_PREFIX*' release with '$ASSET'"; warn=1
    else
      age="$(age_hours "$pub" 2>/dev/null || echo 0)"
      if (( age > DOCTOR_STALE_DAYS * 24 )); then echo "WARN nym-node: newest stable release $lt is $((age / 24)) days old"; warn=1
      else echo "ok   nym-node: newest stable $lt"; fi
    fi
  else
    echo "WARN nym-node: GitHub API unreachable"; return 1
  fi

  # nym-bridge: the newest release of any kind must carry our prefix and ship our asset
  if [[ "$scope" == "all" || -n "${BRIDGE_UNIT:-}" ]]; then
    IFS=$'\t' read -r tag pub hasa <<<"$(gh_releases "$BRIDGE_REPO" 2>/dev/null | newest_release "$BRIDGE_ASSET" 2>/dev/null)" || true
    if   [[ -z "$tag" ]]; then echo "WARN nym-bridge: could not read $BRIDGE_REPO releases"; warn=1
    elif [[ "$tag" != "$BRIDGE_TAG_PREFIX"* ]]; then echo "WARN nym-bridge: newest release is tagged '$tag', not '$BRIDGE_TAG_PREFIX*'"; warn=1
    elif [[ "$hasa" != "true" ]]; then echo "WARN nym-bridge: newest release $tag has no asset named '$BRIDGE_ASSET'"; warn=1
    else echo "ok   nym-bridge: newest release $tag"; fi
  fi

  # operator notes: the file must be at a known path, and once a release is older than the docs
  # wait it must have its own section (a missing section past that = moved file or new heading format)
  for ref in $OP_CHANGELOG_REFS; do
    for path in $OP_CHANGELOG_PATHS; do
      curl -fsS -o /dev/null --proto '=https' --connect-timeout 8 --max-time 60 \
        "https://raw.githubusercontent.com/$REPO/$ref/$path" 2>/dev/null && { reach=1; break 2; }
    done
  done
  if (( reach == 0 )); then echo "WARN operator notes: not found at any known path (docs moved?)"; warn=1
  elif [[ -n "$lt" ]]; then
    if op_changelog_section "${lt#${TAG_PREFIX}}" >/dev/null; then echo "ok   operator notes: section for $lt found"
    elif (( ${age:-0} >= NTM_DOCS_WAIT_HOURS )); then echo "WARN operator notes: no section for $lt, released ${age}h ago (heading format changed?)"; warn=1
    else echo "ok   operator notes: file found, section for $lt not written yet (${age}h old)"; fi
  fi

  # NTM: present at the stable tag and at a newer prerelease, with every subcommand maybe_run_ntm
  # calls (checking the prerelease warns before the updater ever needs that NTM)
  if [[ -n "$lt" ]] && { [[ "$scope" == "all" ]] || { ntm_mode >/dev/null && [[ -z "$(ntm_missing_ifaces)" ]]; }; }; then
    for t in $(gh_commit_of "$NTM_REPO_PATH" | cut -f1); do   # the NTM the notes point to: develop, pinned
      tmp="$(mktemp 2>/dev/null)" || return 1
      if gcurl -fsSL --proto '=https' --retry 2 --max-time 120 -o "$tmp" "https://raw.githubusercontent.com/$REPO/$t/$NTM_REPO_PATH" 2>/dev/null; then
        miss=""
        for c in $NTM_CMDS; do grep -qE "^[[:space:]]*\"?$c\"?[[:space:]]*(\)|\|)" "$tmp" || miss="$miss $c"; done
        if [[ -n "$miss" ]]; then echo "WARN NTM: $NTM_BRANCH @ ${t:0:12} lacks subcommand(s):$miss"; warn=1
        else echo "ok   NTM: $NTM_BRANCH @ ${t:0:12} has complete_networking_configuration"; fi
      else
        echo "WARN NTM: $NTM_REPO_PATH not found at $t (moved?)"; warn=1
      fi
      rm -f "$tmp"
    done
  fi
  return "$warn"
}

# From `run`: re-check when upstream publishes something new (a nym-node or bridge release,
# prereleases included) and once more when the newest stable release is NTM_DOCS_WAIT_HOURS old
# (its operator notes should exist by then). Alert only when the set of WARN lines changes, and
# once when it clears - never repeatedly for the same problem.
DOCTOR_WARNED="$STATE_DIR/doctor_warned"
doctor_watch() {
  local rels ntag lt pub age btag="-" key out warns real prev
  rels="$(gh_releases "$REPO" 2>/dev/null)" || return 0
  ntag="$(printf '%s' "$rels" | newest_node_tag)"
  IFS=$'\t' read -r lt pub _ _ <<<"$(printf '%s' "$rels" | pick_latest "$TAG_PREFIX" "$ASSET" 2>/dev/null)" || true
  age="$(age_hours "$pub" 2>/dev/null || echo 0)"
  if [[ -n "${BRIDGE_UNIT:-}" ]]; then
    btag="$(gh_releases "$BRIDGE_REPO" 2>/dev/null | newest_release "$BRIDGE_ASSET" 2>/dev/null | cut -f1)"
    [[ -n "$btag" ]] || return 0
  fi
  # the script version is part of the key: a fixed script re-checks (and clears the alert) at once
  key="$SCRIPT_VERSION ${ntag:--} ${lt:--} $btag $(( ${age:-0} >= NTM_DOCS_WAIT_HOURS ? 1 : 0 ))"
  [[ "$key" != "$(cat "$DOCTOR_STATE" 2>/dev/null || true)" ]] || return 0

  out="$(doctor_checks relevant)" || true
  warns="$(printf '%s\n' "$out" | grep '^WARN' || true)"
  real="$(printf '%s\n' "$warns" | grep -v -e 'unreachable' -e 'could not read' || true)"
  if [[ -n "$warns" && -z "$real" ]]; then log "[doctor] GitHub did not answer; will retry next run"; return 0; fi
  printf '%s\n' "$key" > "$DOCTOR_STATE"
  prev="$(cat "$DOCTOR_WARNED" 2>/dev/null || true)"
  if [[ -n "$real" ]]; then
    printf '%s\n' "$out" | sed 's/^/[doctor] /' >> "$LOGFILE" 2>/dev/null || true
    log "[doctor] upstream changed; the updater may be skipping updates. Run: $DEST_PATH self-update"
    if [[ "$real" != "$prev" ]]; then
      printf '%s\n' "$real" > "$DOCTOR_WARNED"
      notify failed "$(printf 'Upstream changed, updates may be skipped:\n%s\nTry: %s self-update' "$real" "$DEST_PATH")"
    fi
  else
    log "[doctor] upstream layout as expected (${ntag:-?}, bridge $btag)"
    if [[ -n "$prev" ]]; then rm -f "$DOCTOR_WARNED"; notify success "Upstream check is all ok again"; fi
  fi
}

# ------------------- changelog-driven operator actions ----------------------
# Pull runnable shell lines out of the fenced code blocks of a changelog section.
# Only bash/sh/shell/console blocks; skip comments, blanks, and leading "$ " prompts.
changelog_commands() {   # stdin: section text ; stdout: one command per line
  awk '
    /^[[:space:]]*```(bash|sh|shell|console)[[:space:]]*$/ { inb=1; next }
    /^[[:space:]]*```/ { inb=0; next }
    inb {
      line=$0
      sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/,"",line)
      if (line=="" || line ~ /^#/) next
      sub(/^\$[[:space:]]*/,"",line)
      print line
    }'
}

# Report (NEVER execute) the operator commands the official changelog lists for a release.
# Auto-eval of network-fetched changelog content was a root-RCE risk, so it is removed entirely:
# tunnel/firewall work still goes through the snapshot-protected NTM path (maybe_run_ntm); any other
# listed commands are only surfaced to the operator to review and run by hand. Recorded per tag.
apply_changelog_actions() {   # arg: tag  -- notify-only, does NOT run anything
  local tag="$1" ver section cmds
  [[ -n "$tag" ]] || return 0
  [[ "$(cat "$ACTIONS_STATE" 2>/dev/null || true)" != "$tag" ]] || return 0
  ver="${tag#${TAG_PREFIX}}"
  section="$(op_changelog_section "$ver")" || { log "[actions] no operator changelog section for $ver yet (docs lag); will retry next run"; return 0; }
  cmds="$(printf '%s\n' "$section" | changelog_commands)"
  if [[ -z "$cmds" ]]; then printf '%s\n' "$tag" > "$ACTIONS_STATE"; return 0; fi

  local c n=0
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    # tunnel/firewall commands are handled safely by the NTM path; don't surface those as "manual"
    if printf '%s' "$c" | grep -qiE 'network-tunnel-manager|nymtun|iptables|complete_networking_configuration'; then continue; fi
    if [[ "$BRIDGE_CFG_ENABLED" == 1 && -n "${BRIDGE_UNIT:-}" ]] && printf '%s' "$c" | grep -qiE 'quic_bridge_deployment'; then continue; fi
    if [[ "$n" -eq 0 ]]; then log "[actions] operator changelog for $ver suggests manual commands (NOT auto-run):"; fi
    log "[actions]   > $c"; n=$((n+1))
  done <<<"$cmds"
  [[ "$n" -gt 0 ]] && notify failed "Nym $ver changelog lists $n operator command(s) to review and run by hand (see the updater log). I never run these automatically."
  printf '%s\n' "$tag" > "$ACTIONS_STATE"
}

# --------------------------------- run --------------------------------------
# nym-api with its own soak delay (a dynamic-scope local shadows the global for update_component)
update_api() {
  local MIN_AGE_HOURS="$API_MIN_AGE_HOURS"
  update_component "nym-api" "$REPO" "$TAG_PREFIX" "$API_ASSET" \
                   "$API_BIN" "$API_UNIT" "$API_STATE_TAG" "$API_FAILED_TAGS" "version"
}

cmd_run() {
  ensure_dirs
  resolve_target
  [[ -n "$UNIT" || -n "${API_UNIT:-}" ]] || die "no nym-node or nym-api systemd service found (run 'install' first)"
  local node_rc=0 bridge_rc=0 ntm_rc=0 ufw_rc=0 api_rc=0

  if [[ -n "$UNIT" ]]; then
    sctl cat "$UNIT" >/dev/null 2>&1       || die "configured unit '$UNIT' not known to systemd (${SVC_SCOPE:-system} scope)"
    [[ -n "$BIN" && -x "$BIN" ]]           || die "could not locate the nym-node binary ('$BIN')"
    log "target: unit=$UNIT user=$SVC_USER bin=$BIN role=$ROLE"

    update_component "nym-node" "$REPO" "$TAG_PREFIX" "$ASSET" \
                     "$BIN" "$UNIT" "$STATE_TAG" "$FAILED_TAGS" "version" || node_rc=$?

    if [[ -n "${BRIDGE_UNIT:-}" ]] && systemctl cat "$BRIDGE_UNIT" >/dev/null 2>&1 \
          && [[ -n "${BRIDGE_BIN:-}" && -x "${BRIDGE_BIN:-}" ]]; then
      log "gateway: also checking QUIC bridge ($BRIDGE_UNIT)"
      update_component "nym-bridge" "$BRIDGE_REPO" "$BRIDGE_TAG_PREFIX" "$BRIDGE_ASSET" \
                       "$BRIDGE_BIN" "$BRIDGE_UNIT" "$BRIDGE_STATE_TAG" "$BRIDGE_FAILED_TAGS" "runs" || bridge_rc=$?
    fi

    maybe_run_ntm || ntm_rc=$?
    maybe_open_ufw_ports || ufw_rc=$?
    if [[ -n "${BRIDGE_UNIT:-}" ]] && systemctl cat "$BRIDGE_UNIT" >/dev/null 2>&1; then maybe_configure_bridge || bridge_rc=$?; fi

    # run any remaining operator actions the official changelog lists (non-tunnel; deny-list enforced)
    apply_changelog_actions "$(cat "$STATE_TAG" 2>/dev/null || true)" || true
  fi

  if [[ -n "${API_UNIT:-}" ]]; then
    if ! systemctl cat "$API_UNIT" >/dev/null 2>&1 || [[ -z "${API_BIN:-}" || ! -x "${API_BIN:-}" ]]; then
      log "[nym-api] unit '$API_UNIT' or binary '${API_BIN:-}' not found; skipping nym-api"; api_rc=1
    elif [[ "$(systemctl is-active "$API_UNIT" 2>/dev/null || true)" != "active" ]]; then
      # a leftover or deliberately stopped nym-api is not ours to start
      log "[nym-api] $API_UNIT is not running; leaving it alone"
    elif [[ -z "${API_URL:-}" ]]; then
      log "[nym-api] no API_URL (where it answers HTTP); skipping nym-api"; api_rc=1
    elif api_dkg_busy; then
      :
    else
      log "target: nym-api unit=$API_UNIT bin=$API_BIN url=$API_URL soak=${API_MIN_AGE_HOURS}h"
      update_api || api_rc=$?
    fi
  fi

  doctor_watch || true

  log "run complete (nym-node rc=$node_rc, nym-bridge rc=$bridge_rc, ntm rc=$ntm_rc, ufw rc=$ufw_rc, nym-api rc=$api_rc)"
  # read by cmd_poll for the bot: the box's main component (nym-node, or nym-api on an api-only box)
  printf '%s\n' "$( [[ -n "$UNIT" ]] && echo "$node_rc" || echo "$api_rc" )" > "$STATE_DIR/last_node_rc" 2>/dev/null || true
  if (( node_rc != 0 || bridge_rc != 0 || ntm_rc != 0 || ufw_rc != 0 || api_rc != 0 )); then exit 1; fi
  exit 0
}

# ------------------------------ install/remove ------------------------------
cmd_install() {
  ensure_dirs
  local unit bin svcuser role brunit brbin brver curver svcscope
  unit="$(detect_unit)"; bin="$(detect_bin "$unit")"; svcuser="$(detect_user "$unit")"
  role="$(detect_role "$unit")"; curver="$(bin_version "${bin:-/bin/false}")"
  # explicit overrides for setups system detection can't see, e.g. a node kept off root under
  # `systemctl --user` by a lingering user:  NYM_SCOPE=user NYM_USER=<u> NYM_UNIT=<svc> NYM_BIN=<path>
  svcscope="${NYM_SCOPE:-system}"
  [[ -n "${NYM_UNIT:-}" ]] && unit="$NYM_UNIT"
  [[ -n "${NYM_USER:-}" ]] && svcuser="$NYM_USER"
  [[ -n "${NYM_BIN:-}"  ]] && bin="$NYM_BIN"
  # point sctl at the right scope so the validation + version checks below hit the real service
  SVC_SCOPE="$svcscope"; SVC_USER="${svcuser:-root}"
  if [[ "$svcscope" == "user" ]]; then
    [[ -n "${NYM_BIN:-}" ]] && curver="$(bin_version "${bin:-/bin/false}")"
    local es; es="$(sctl show -p ExecStart --value "$unit" 2>/dev/null || true)"
    case "$es" in *mixnode*) role="mixnode";; *exit-gateway*|*entry-gateway*) role="gateway";; *) role="${role:-node}";; esac
  fi
  brunit="$(detect_bridge_unit)"; brbin=""; brver=""
  if [[ -n "$brunit" ]]; then brbin="$(detect_bridge_bin "$brunit")"; brver="$(dpkg-query -W -f='${Version}' nym-bridge 2>/dev/null || true)"; fi
  local ntm_en ntm_path ntm_iface
  IFS=$'\t' read -r ntm_en ntm_path ntm_iface < <(detect_ntm) || true
  # What the operator set survives a re-install. The old config is read the way `run` reads it (sourced,
  # the last assignment wins) and only if `run` would trust it; every value is checked before it goes
  # into the new config. An env var given now wins.
  local o_ntm="" o_ufw="" o_pol="" o_http="" o_tgt="" o_tgc="" re_http='^https?://[][A-Za-z0-9.:_-]+$'
  if [[ -f "$CONFIG_FILE" && "$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null || echo '?')" == root \
        && -z "$(find "$CONFIG_FILE" -perm /022 2>/dev/null)" ]]; then
    IFS=$'\x1f' read -r o_ntm o_ufw o_pol o_http o_tgt o_tgc < <(
      unset NTM_ENABLED UFW_PORTS_ENABLED NTM_INPUT_POLICY NODE_HTTP TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
      set +eu; source "$CONFIG_FILE" >/dev/null 2>&1
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${NTM_ENABLED-}" "${UFW_PORTS_ENABLED-}" "${NTM_INPUT_POLICY-}" \
        "${NODE_HTTP-}" "${TELEGRAM_BOT_TOKEN-}" "${TELEGRAM_CHAT_ID-}") || true
  elif [[ -f "$CONFIG_FILE" ]]; then
    log "WARNING: $CONFIG_FILE is not root-owned or is writable by others; its settings are not carried over"
  fi
  if [[ -n "$o_ntm" && "$o_ntm" != 1 ]]; then ntm_en=0; fi      # anything but 1 was off
  [[ -n "${NYM_UFW_PORTS:-}" || -z "$o_ufw" ]] || UFW_PORTS_ENABLED="$o_ufw"
  [[ -n "${NYM_NTM_INPUT_POLICY:-}" || -z "$o_pol" ]] || NTM_INPUT_POLICY="$o_pol"
  [[ -n "${NYM_NODE_HTTP:-}" || -z "$o_http" ]] || NODE_HTTP="$o_http"
  if [[ "$UFW_PORTS_ENABLED" == 1 ]]; then UFW_PORTS_ENABLED=1; else UFW_PORTS_ENABLED=0; fi
  NTM_INPUT_POLICY="${NTM_INPUT_POLICY^^}"; [[ "$NTM_INPUT_POLICY" =~ ^(DROP|KEEP)$ ]] || NTM_INPUT_POLICY=DROP
  [[ "$NODE_HTTP" =~ $re_http ]] || NODE_HTTP="http://127.0.0.1:8080"
  local apiunit apibin apiurl apiver apiage
  apiunit="${NYM_API_UNIT:-$(detect_api_unit)}"; apibin=""; apiurl=""; apiver=""
  apiage="${NYM_API_MIN_AGE_HOURS:-$MIN_AGE_HOURS}"; [[ "$apiage" =~ ^[0-9]+$ ]] || apiage="$MIN_AGE_HOURS"
  if [[ -n "$apiunit" ]]; then
    apibin="${NYM_API_BIN:-$(detect_api_bin "$apiunit")}"; apiurl="${NYM_API_URL:-$(detect_api_url "$apiunit")}"
    apiver="$(bin_version "${apibin:-/bin/false}")"
  fi
  if [[ -z "$unit" ]]; then svcuser="$(detect_user "$apiunit")"; role="none (nym-api box)"; fi

  echo "Detected on $(hostname):"
  echo "  nym-node unit : ${unit:-<NOT FOUND>}"
  echo "  runs as user  : ${svcuser:-root}"
  echo "  nym-node bin  : ${bin:-<NOT FOUND>}"
  echo "  version       : ${curver:-<unknown>}"
  echo "  role          : ${role}"
  if [[ -n "$brunit" ]]; then
    echo "  QUIC bridge   : ${brunit}  bin=${brbin:-<?>}  ver=${brver:-<?>}   -> auto-updated (HTTPS only, no upstream checksum)"
  else
    echo "  QUIC bridge   : none (mixnode / no bridge)   -> bridge updates skipped"
  fi
  local nmode; nmode="$(node_mode 2>/dev/null || echo "unknown (node API at $NODE_HTTP not answering)")"
  echo "  node mode     : ${nmode}"
  if [[ "$ntm_en" == 1 ]]; then
    echo "  tunnel (NTM)  : on exit and WireGuard entry gateways only (Nym's rule), checked every run; runs nymtech NTM as root (no upstream checksum)"
  else
    echo "  tunnel (NTM)  : off (NTM_ENABLED=0)"
  fi
  if [[ "$nmode" == entry && "$UFW_PORTS_ENABLED" == 1 ]]; then
    echo "  ufw           : if active, Nym's bridge and Lewes ports are opened ($UFW_ENTRY_PORTS)"
  elif [[ "$nmode" == entry ]]; then
    echo "  ufw           : left alone (UFW_PORTS_ENABLED=0)"
  fi
  if [[ -n "$apiunit" ]]; then
    echo "  nym-api       : ${apiunit}  bin=${apibin:-<?>}  ver=${apiver:-<?>}  url=${apiurl:-<?>}  -> auto-updated (SHA-256, HTTP + signer check, soak ${apiage}h)"
  else
    echo "  nym-api       : none -> skipped"
  fi
  echo

  if [[ "${NYM_ASSUME_YES:-0}" != "1" && -t 0 ]]; then
    local ans a
    read -rp "Use this? [Y = yes / n = let me correct it]: " ans
    if [[ "${ans:-}" =~ ^[nN] ]]; then
      read -rp "  nym-node unit   [${unit}]: " a;    unit="${a:-$unit}"
      read -rp "  nym-node bin    [${bin}]: " a;     bin="${a:-$bin}"
      read -rp "  service user    [${svcuser}]: " a; svcuser="${a:-$svcuser}"
      read -rp "  bridge unit (blank=none) [${brunit}]: " a; brunit="${a-$brunit}"
      if [[ -n "$brunit" ]]; then read -rp "  bridge bin    [${brbin}]: " a; brbin="${a:-$brbin}"; else brbin=""; fi
      read -rp "  nym-api unit (blank=none) [${apiunit}]: " a; apiunit="${a-$apiunit}"
      if [[ -n "$apiunit" ]]; then
        read -rp "  nym-api bin     [${apibin}]: " a; apibin="${a:-$apibin}"
        read -rp "  nym-api url     [${apiurl}]: " a; apiurl="${a:-$apiurl}"
      else apibin=""; apiurl=""; fi
      read -rp "  NTM step (1 = by node mode, 0 = off) [${ntm_en}]: " a; ntm_en="${a:-$ntm_en}"
      if [[ "$ntm_en" != 1 ]]; then ntm_en=0; fi
      if [[ "$ntm_en" == "1" ]]; then
        read -rp "  NTM script path [${ntm_path}]: " a;  ntm_path="${a:-$ntm_path}"
        read -rp "  tunnel iface    [${ntm_iface}]: " a; ntm_iface="${a:-$ntm_iface}"
      fi
    fi
  else
    log "non-interactive install; using detected values"
  fi

  # validate before committing anything
  [[ -n "$unit" || -n "$apiunit" ]] || die "no nym-node or nym-api systemd unit found; aborting"
  if [[ -n "$unit" ]]; then
    sctl cat "$unit" >/dev/null 2>&1 || die "unit '$unit' not found in ${svcscope} scope; aborting"
    [[ -n "$bin" && -x "$bin" ]] || die "nym-node binary '$bin' missing or not executable; aborting"
  fi
  if [[ -n "$apiunit" ]]; then
    systemctl cat "$apiunit" >/dev/null 2>&1 || die "nym-api unit '$apiunit' not found by systemd; aborting"
    [[ -n "$apibin" && -x "$apibin" ]] || die "nym-api binary '$apibin' missing or not executable; aborting"
    [[ "$apiurl" =~ ^https?://[A-Za-z0-9.:_-]+$ ]] || die "nym-api url '$apiurl' looks wrong; aborting"
  fi
  if [[ -n "$brunit" ]]; then
    systemctl cat "$brunit" >/dev/null 2>&1 || die "bridge unit '$brunit' not found by systemd; aborting"
    [[ -n "$brbin" && -x "$brbin" ]] || die "bridge binary '$brbin' missing or not executable; aborting"
  fi
  [[ "${ntm_iface:-nymtun0}" =~ ^[a-zA-Z0-9._-]+$ ]] || ntm_iface="nymtun0"

  local sshport="${NYM_SSH_PORT:-$(detect_ssh_port)}"; [[ "$sshport" =~ ^[0-9]+$ ]] || sshport=22
  # Telegram alerts: prefer env, else keep what the old config had (read above, so re-install keeps them)
  local tg_token="${NYM_TELEGRAM_BOT_TOKEN:-$o_tgt}" tg_chat="${NYM_TELEGRAM_CHAT_ID:-$o_tgc}"
  [[ -z "$tg_token" || "$tg_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { log "WARNING: the Telegram bot token does not look right; not saved"; tg_token=""; }
  [[ -z "$tg_chat" || "$tg_chat" =~ ^(-?[0-9]+|@[A-Za-z0-9_]+)$ ]] || { log "WARNING: the Telegram chat id does not look right; not saved"; tg_chat=""; }
  save_config "$unit" "$bin" "${svcuser:-root}" "$role" "$brunit" "$brbin" "${ntm_en:-0}" "$ntm_path" "${ntm_iface:-nymtun0}" "$svcscope" "$sshport" "$tg_token" "$tg_chat" "$apiunit" "$apibin" "$apiurl" "$apiage"
  local tg_state=off; [[ -n "$tg_token" && -n "$tg_chat" ]] && tg_state=on
  log "saved config -> $CONFIG_FILE (unit=${unit:-none} bin=${bin:-none} user=${svcuser:-root} scope=${svcscope} bridge=${brunit:-none} ntm=${ntm_en:-0} api=${apiunit:-none} ssh_port=${sshport} telegram=${tg_state})"
  TELEGRAM_BOT_TOKEN="$tg_token"; TELEGRAM_CHAT_ID="$tg_chat"

  install -m 0755 "$SELF_PATH" "$DEST_PATH"
  cat > /etc/systemd/system/nym-node-autoupdate.service <<UNIT
[Unit]
Description=Nym auto-updater (nym-node, QUIC bridge, tunnel rules, nym-api on new stable releases)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DEST_PATH run
UNIT
  cat > /etc/systemd/system/nym-node-autoupdate.timer <<UNIT
[Unit]
Description=Run the Nym auto-updater hourly

[Timer]
OnCalendar=hourly
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now nym-node-autoupdate.timer
  log "installed + enabled systemd timer (hourly, up to 20min jitter, catches missed runs after downtime)"

  # frequent, lightweight poll so the bot's "update now" reaches this node fast
  cat > /etc/systemd/system/nym-node-autoupdate-poll.service <<UNIT
[Unit]
Description=nym-node auto-updater: Nymi force-update poll
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DEST_PATH poll
UNIT
  cat > /etc/systemd/system/nym-node-autoupdate-poll.timer <<UNIT
[Unit]
Description=Poll Nymi for on-demand update requests

[Timer]
OnBootSec=45
OnUnitActiveSec=45
AccuracySec=10

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now nym-node-autoupdate-poll.timer
  log "installed + enabled Nymi force-update poll timer (every ~45s)"
  systemctl list-timers nym-node-autoupdate.timer --no-pager 2>/dev/null || true
  echo
  echo "Done. It checks hourly and updates only when a new stable release appears."
  echo "Re-run '$DEST_PATH install' to change settings, or edit $CONFIG_FILE."
  notify success "now watching this node (${role}). I'll ping you on updates, rollbacks, or anything that needs you."

  # Pair this node with Nymi (the shared Telegram bot) so it's YOURS: force-update +
  # alerts. One step, right here - running it on the node is what proves the node is
  # yours (the hub checks the request comes from this node's IP).
  echo
  if [[ "${NYM_ASSUME_YES:-0}" != "1" && -t 0 ]]; then
    local tgnick
    read -rp "Your Telegram @nick to make this node yours on Nymi (blank to skip): " tgnick
    if [[ -n "$tgnick" ]]; then
      cmd_pair "$tgnick" || true
      echo ">>> If it said 'press Start', open https://t.me/nyminodebot and press Start."
    fi
  elif [[ -n "${NYM_NYMI_NICK:-}" ]]; then
    cmd_pair "$NYM_NYMI_NICK" || true
  else
    echo ">>> To make this node yours later:  $DEST_PATH pair @your_telegram_nick"
  fi

  if [[ "${NYM_ASSUME_YES:-0}" != "1" && -t 0 ]]; then
    local now
    read -rp "Run an update check right now? [y/N]: " now
    if [[ "${now:-}" =~ ^[yY] ]]; then exec "$DEST_PATH" run; fi
  fi
}

# Update THIS script from GitHub. Manual + safe: it fetches over HTTPS, checks the
# download is really this script and parses cleanly (bash -n) BEFORE replacing itself,
# keeps a timestamped backup, and no-ops if already current. Run it whenever you like.
cmd_self_update() {
  need_root "$@"
  require_cmds curl
  local tmp; tmp="$(mktemp)" || die "mktemp failed"
  log "[self-update] fetching the latest script from GitHub..."
  gcurl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 3 \
        --retry-delay 3 --max-time 60 -o "$tmp" "$SELF_UPDATE_URL" \
    || { rm -f "$tmp"; die "download failed (network?)"; }
  head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' \
    || { rm -f "$tmp"; die "downloaded file is not a bash script; refusing to install"; }
  grep -q 'nym-node-autoupdate' "$tmp" \
    || { rm -f "$tmp"; die "downloaded file does not look like this updater; refusing to install"; }
  bash -n "$tmp" \
    || { rm -f "$tmp"; die "downloaded script failed a syntax check; NOT installing"; }
  local newver; newver="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)"
  local dst="$DEST_PATH"; [[ -e "$dst" ]] || dst="$SELF_PATH"
  if cmp -s "$tmp" "$dst" 2>/dev/null; then
    log "[self-update] already on the latest (${newver:-$SCRIPT_VERSION}); nothing to do"; rm -f "$tmp"; return 0
  fi
  cp -a "$dst" "$dst.bak.$(date -u '+%Y%m%dT%H%M%SZ')" 2>/dev/null || true
  install -m 0755 "$tmp" "$dst" || { rm -f "$tmp"; die "install to $dst failed"; }
  rm -f "$tmp"
  log "[self-update] updated $dst: $SCRIPT_VERSION -> ${newver:-latest}"
  echo "Updated to ${newver:-latest}. The hourly timer keeps using it from here - nothing else to run."
}

cmd_uninstall() {
  systemctl disable --now nym-node-autoupdate.timer 2>/dev/null || true
  systemctl disable --now nym-node-autoupdate-poll.timer 2>/dev/null || true
  rm -f /etc/systemd/system/nym-node-autoupdate.timer /etc/systemd/system/nym-node-autoupdate.service \
        /etc/systemd/system/nym-node-autoupdate-poll.timer /etc/systemd/system/nym-node-autoupdate-poll.service
  systemctl daemon-reload || true
  log "removed timers + service units (config, state and binaries left intact)"
}

cmd_check() {             # read-only: report whether newer releases exist (no changes, no root)
  resolve_target
  echo "Checking GitHub for updates (read-only - nothing is installed)..."
  echo
  local curver inst lt
  curver="$(bin_version "${BIN:-/bin/false}")"
  inst="$(cat "$STATE_TAG" 2>/dev/null || echo '<none>')"
  lt="$(gh_releases "$REPO" 2>/dev/null | pick_latest "$TAG_PREFIX" "$ASSET" 2>/dev/null | cut -f1 || true)"
  if   [[ -z "${UNIT:-}" ]]; then echo "nym-node   : none on this box"
  elif [[ -z "$lt" ]];       then echo "nym-node   : could not reach GitHub"
  elif [[ "$lt" == "$inst" ]]; then echo "nym-node   : up to date (${curver:-?}, $lt)"
  else                            echo "nym-node   : UPDATE AVAILABLE -> $lt   (installed ${curver:-?}, last applied $inst)"
    if quiet_gate_applies; then
      local qp; qp="$(node_pps)"
      if [[ -z "$qp" ]]; then echo "             quiet gate: traffic unknown (no fresh metrics on $NODE_HTTP), the gate will not block"
      elif (( qp >= QUIET_PPS )); then echo "             quiet gate: node busy (${qp} pkt/s), the update waits until it is idle"
      else echo "             quiet gate: node idle (${qp} pkt/s), the next run updates"; fi
    fi
  fi

  if [[ -n "${BRIDGE_UNIT:-}" ]]; then
    local binst blt
    binst="$(cat "$BRIDGE_STATE_TAG" 2>/dev/null || echo '<none>')"
    blt="$(gh_releases "$BRIDGE_REPO" 2>/dev/null | pick_latest "$BRIDGE_TAG_PREFIX" "$BRIDGE_ASSET" 2>/dev/null | cut -f1 || true)"
    if   [[ -z "$blt" ]];        then echo "nym-bridge : could not reach GitHub"
    elif [[ "$blt" == "$binst" ]]; then echo "nym-bridge : up to date ($blt)"
    else                              echo "nym-bridge : UPDATE AVAILABLE -> $blt   (last applied $binst)"; fi
  fi

  if [[ -n "${API_UNIT:-}" ]]; then
    local ainst alt aver
    ainst="$(cat "$API_STATE_TAG" 2>/dev/null || echo '<none>')"; aver="$(bin_version "${API_BIN:-/bin/false}")"
    alt="$(gh_releases "$REPO" 2>/dev/null | pick_latest "$TAG_PREFIX" "$API_ASSET" 2>/dev/null | cut -f1 || true)"
    if   [[ -z "$alt" ]];        then echo "nym-api    : could not reach GitHub"
    elif [[ "$alt" == "$ainst" ]]; then echo "nym-api    : up to date (${aver:-?}, $alt)"
    else                              echo "nym-api    : UPDATE AVAILABLE -> $alt   (installed ${aver:-?}, last applied $ainst)"; fi
  fi

  if [[ -n "$lt" ]] && ntm_mode >/dev/null && [[ -z "$(ntm_missing_ifaces)" ]]; then
    local ntm_inst
    ntm_inst="$(cat "$NTM_STATE" 2>/dev/null || echo '<none>')"
    if   [[ "$lt" == "$ntm_inst" ]]; then echo "tunnel(NTM): already evaluated for $lt"
    elif changelog_mentions_ntm "$lt" >/dev/null 2>&1; then echo "tunnel(NTM): $lt changelog mentions tunnel/ports -> NTM would re-apply on next run"
    else echo "tunnel(NTM): $lt changelog has no tunnel/port changes (NTM re-applies only if the egress probe fails)"; fi
  fi
  echo
  echo "To apply now: sudo $DEST_PATH run"
}

cmd_status() {
  resolve_target
  echo "updater ver   : ${SCRIPT_VERSION}  (self-update: $0 self-update)"
  echo "nym-node unit : ${UNIT:-<none found>}"
  echo "user          : ${SVC_USER:-root}"
  echo "nym-node bin  : ${BIN:-<none found>}"
  echo "version       : $(bin_version "${BIN:-/bin/false}")"
  echo "role          : ${ROLE:-<unknown>}"
  echo "active        : $(systemctl is-active "${UNIT:-nonexistent.service}" 2>/dev/null || true)"
  echo "node last_tag : $(cat "$STATE_TAG" 2>/dev/null || echo '<none>')"
  echo "node failed   : $(cut -f1 "$FAILED_TAGS" 2>/dev/null | tr '\n' ' ' || true)"
  local qp; qp="$(node_pps)"
  if quiet_gate_applies; then
    echo "quiet gate    : on (${QUIET_GATE}); traffic now ${qp:-?} pkt/s, updates wait below ${QUIET_PPS} pkt/s (max ${QUIET_MAX_HOURS}h)"
  else
    echo "quiet gate    : off for this node (${QUIET_GATE}); traffic now ${qp:-?} pkt/s"
  fi
  if [[ -n "${BRIDGE_UNIT:-}" ]]; then
    echo "bridge unit   : ${BRIDGE_UNIT}  bin=${BRIDGE_BIN:-<?>}  active=$(systemctl is-active "$BRIDGE_UNIT" 2>/dev/null || true)"
    echo "bridge last   : $(cat "$BRIDGE_STATE_TAG" 2>/dev/null || echo '<none>')"
  else
    echo "bridge        : none (updates skipped)"
  fi
  local nmode=none
  [[ -z "${UNIT:-}" ]] || nmode="$(node_mode 2>/dev/null || echo unknown)"
  echo "node mode     : ${nmode}"
  if [[ "$nmode" == none ]]; then
    echo "tunnel (NTM)  : none (no nym-node on this box)"
  elif [[ "${NTM_ENABLED:-0}" != 1 ]]; then
    echo "tunnel (NTM)  : off (NTM_ENABLED=0 in the config)"
  elif [[ "$nmode" == unknown ]]; then
    echo "tunnel (NTM)  : unknown: the nym-node API at $NODE_HTTP did not answer (NTM waits for it)"
  elif [[ "$nmode" != exit && "$nmode" != entry-wg ]]; then
    echo "tunnel (NTM)  : not on this node (Nym runs NTM on exit and WireGuard entry gateways only)"
  elif [[ -n "$(ntm_missing_ifaces)" ]]; then
    echo "tunnel (NTM)  : not run: Nym's NTM needs nymtun0 and nymwg, missing:$(ntm_missing_ifaces)"
  else
    echo "tunnel (NTM)  : on  script=${NTM_PATH:-<?>}  applied=$(cut -c1-12 "$NTM_REF_STATE" 2>/dev/null || echo '<none>')"
    echo "ntm last_tag  : $(cat "$NTM_STATE" 2>/dev/null || echo '<none>')"
  fi
  if [[ -n "${API_UNIT:-}" ]]; then
    echo "nym-api unit  : ${API_UNIT}  bin=${API_BIN:-<?>}  ver=$(bin_version "${API_BIN:-/bin/false}")  active=$(systemctl is-active "$API_UNIT" 2>/dev/null || true)"
    echo "nym-api url   : ${API_URL:-<none>}  soak=${API_MIN_AGE_HOURS}h  signer=[$(api_signer_state)]"
    echo "nym-api last  : $(cat "$API_STATE_TAG" 2>/dev/null || echo '<none>')"
  else
    echo "nym-api       : none (updates skipped)"
  fi
  echo "config        : $( [[ -f "$CONFIG_FILE" ]] && echo "$CONFIG_FILE" || echo '<none - live detection>')"
  if [[ -f /etc/systemd/system/nym-node-autoupdate.timer ]]; then
    systemctl list-timers nym-node-autoupdate.timer --no-pager 2>/dev/null || echo "timer: installed"
  else
    echo "timer         : not installed"
  fi
}

nymi_secret() {   # per-node secret proving THIS node to the hub (0600, generated once)
  local f="$STATE_DIR/nymi_secret"
  if [[ ! -s "$f" ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    ( umask 077; head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > "$f" )
    chmod 600 "$f" 2>/dev/null || true
  fi
  cat "$f" 2>/dev/null
}

cmd_pair() {   # make this node YOURS on Nymi, by your @nick. One step, run ON the node.
  local nick="${1:-}" ip="${2:-}"
  nick="${nick#@}"
  [[ -n "$nick" ]] || die "usage: $0 pair @your_telegram_nick [node_ip]"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ "$ip" =~ ^[0-9.]+$ ]] || ip="$(curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  fi
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "could not auto-detect this node's IP; run: $0 pair @$nick <node_ip>"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s' "$ip" > "$STATE_DIR/nymi_node_ip" 2>/dev/null || true   # for the poll
  local resp secret; secret="$(nymi_secret)"
  # Force IPv4 so the hub sees this request coming FROM the node's IPv4 (== the ident).
  # Running it here, on the node, is what proves the node is yours: a stranger who only
  # knows the IP is on another box and cannot send a request from it.
  resp="$(curl -4 -s --max-time 12 --proto '=https' --proto-redir '=https' -X POST "$NYMI_HUB_BASE/pair" \
            --data-urlencode "nick=$nick" --data-urlencode "ip=$ip" \
            --data-urlencode "updater=1" --data-urlencode "secret=$secret" 2>/dev/null || true)"
  case "$resp" in
    *'"paired"'*|*'"reclaimed"'*)
      echo "Done - node $ip is yours (@$nick) on Nymi. Force-update works now." ;;
    *'"pending"'*)
      echo "Registered node $ip for @$nick."
      echo "Now open  https://t.me/nyminodebot  and press Start - it becomes yours the instant you do." ;;
    *'from the node'*)
      echo "Nymi refused: run this ON the node itself (the request must come from the node's IP)." ;;
    *'who owns it'*)
      echo "Nymi needs your handle: $0 pair @your_telegram_nick" ;;
    *'supports'*|*'"error"'*)
      echo "Nymi refused: ${resp:-<none>}" ;;
    *)
      echo "Sent to Nymi, but the reply was unexpected: ${resp:-<none>}" ;;
  esac
}

cmd_link() {   # compatibility alias -> `pair @nick`
  echo "Use 'pair' now:  $0 pair @your_telegram_nick"
  echo "Run it here, on the node - running it on the node itself is what proves it's yours."
}

cmd_poll() {   # frequent timer: did the operator press "update now" in the bot?
  local ip resp secret cache="$STATE_DIR/nymi_node_ip"
  secret="$(nymi_secret)"; [[ -n "$secret" ]] || return 0
  ip="$(cat "$cache" 2>/dev/null || true)"
  if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ip="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { mkdir -p "$STATE_DIR" 2>/dev/null; printf '%s' "$ip" > "$cache"; }
  fi
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
  resp="$(curl -s --max-time 8 --proto '=https' --proto-redir '=https' \
            -H "Authorization: Bearer $secret" -H "X-Updater-Version: $SCRIPT_VERSION" \
            "$NYMI_HUB_BASE/poll?ip=$ip" 2>/dev/null || true)"
  printf '%s' "$resp" | grep -qE '"run"[[:space:]]*:[[:space:]]*true' || return 0
  log "[nymi] force-update requested from the bot; running now (quiet gate skipped: operator asked)"
  export NAU_MANUAL=1
  resolve_target
  local before after outcome rc=0 node_rc
  local vbin="${BIN:-}"; [[ -n "${UNIT:-}" ]] || vbin="${API_BIN:-}"
  before="$(bin_version "${vbin:-/bin/false}" 2>/dev/null || echo '')"
  rm -f "$STATE_DIR/last_node_rc" 2>/dev/null || true
  ( exec 9>"$LOCKFILE"; flock -n 9 || exit 75; cmd_run ) || rc=$?
  after="$(bin_version "${vbin:-/bin/false}" 2>/dev/null || echo '')"
  node_rc="$(cat "$STATE_DIR/last_node_rc" 2>/dev/null || true)"
  # updated = version changed; failed = new version rolled back (node up on the old one);
  # critical = rollback not healthy either; busy = an hourly run held the lock; else nothing new
  if [[ -n "$after" && "$after" != "$before" ]]; then outcome="updated"
  elif [[ "$node_rc" == "1" ]]; then outcome="failed"
  elif [[ "$node_rc" == "2" ]]; then outcome="critical"
  elif (( rc == 75 )); then outcome="busy"
  else outcome="noreleases"; fi
  curl -s --max-time 10 --proto '=https' --proto-redir '=https' -X POST "$NYMI_HUB_BASE/result" \
    --data-urlencode "ip=$ip" --data-urlencode "secret=$secret" \
    --data-urlencode "outcome=$outcome" --data-urlencode "version=${after:-}" >/dev/null 2>&1 || true
  log "[nymi] force-update result: $outcome ${after:-}"
}

# --------------------------------- dispatch ---------------------------------
main() {
  local cmd="${1:-install}"
  case "$cmd" in
    run)
      need_root "$@"
      require_cmds curl jq sha256sum flock
      exec 9>"$LOCKFILE"
      flock -n 9 || { echo "another nym-autoupdate run is in progress; exiting"; exit 0; }
      cmd_run ;;
    install)   need_root "$@"; require_cmds curl jq sha256sum; cmd_install ;;
    uninstall) need_root "$@"; cmd_uninstall ;;
    check)     require_cmds curl jq; cmd_check ;;
    doctor)    require_cmds curl jq; doctor_checks all; exit $? ;;
    status)    cmd_status ;;
    pair)      require_cmds curl; cmd_pair "${2:-}" "${3:-}" ;;
    link)      cmd_link ;;
    poll)      need_root "$@"; require_cmds curl jq sha256sum flock; cmd_poll ;;
    self-update|selfupdate|update-self) cmd_self_update "$@" ;;
    version|--version|-v) echo "nym-node-autoupdate $SCRIPT_VERSION" ;;
    *) echo "usage: $0 {install|run|check|doctor|status|pair|self-update|version|poll|uninstall}"; exit 1 ;;
  esac
}
main "$@"
