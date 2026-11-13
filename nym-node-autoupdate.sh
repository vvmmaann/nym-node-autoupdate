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
#   * NTM        - the exit-gateway tunnel rules (network-tunnel-manager.sh), EXIT GATEWAYS ONLY.
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
#   nym-node-autoupdate.sh bridge-plan# show what the bridge TLS/SSH step would change (changes nothing)
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
# The operator notes tell operators to take NTM from develop and run complete_networking_configuration.
# The updater follows that branch, pinned to the commit it resolves (never the branch name itself).
NTM_BRANCH="${NYM_NTM_BRANCH:-develop}"
NTM_MIN_AGE_HOURS="${NYM_NTM_MIN_AGE_HOURS:-2}"    # a new NTM commit is applied once it is this old
NTM_TIMEOUT="${NYM_NTM_TIMEOUT:-900}"              # seconds for one NTM run (it apt-installs, downloads lists)
NTM_INPUT_POLICY="${NYM_NTM_INPUT_POLICY:-DROP}"   # NTM's HOST_INPUT_POLICY: DROP (its default) | KEEP
NTM_KEEP_LISTENERS="${NYM_NTM_KEEP_LISTENERS:-1}"  # 1 = services already listening here stay reachable under DROP

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
NTM_REF_STATE="$STATE_DIR/ntm_applied_ref"      # NTM commit last applied in full (complete_networking_configuration)
NTM_SUM_STATE="$STATE_DIR/ntm_applied_sha256"   # and the sha256 of that script
NTM_NOTES_STATE="$STATE_DIR/ntm_notes_tag"       # release whose operator notes were last acted on
NTM_FAILED_STATE="$STATE_DIR/ntm_failed_ref"     # NTM commit whose apply failed here and was rolled back
NTM_BLOCK_STATE="$STATE_DIR/ntm_blocked"         # last preflight refusal (alerted once per reason)
API_ASSET="nym-api"
API_STATE_TAG="$STATE_DIR/api_last_tag";       API_FAILED_TAGS="$STATE_DIR/api_failed_tags"
# DKG contract on Nyx mainnet: a signer is not restarted while a ceremony is running
API_DKG_CONTRACT="${NYM_API_DKG_CONTRACT:-n19604yflqggs9mk2z26mqygq43q2kr3n932egxx630svywd5mpxjsztfpvx}"
API_LCDS="${NYM_API_LCDS:-http://127.0.0.1:1317 https://api.nymtech.net}"
# operator-facing changelog (docs). the release git tag is cut BEFORE its docs section is written,
# so the section is read from the docs branch, not the tag. official nym source, trusted.
# the docs moved from pages/ to content/ on 2026-10-14 (nym PR #7198); the old path is kept as a fallback
OP_CHANGELOG_PATHS="documentation/docs/content/operators/changelog.mdx documentation/docs/pages/operators/changelog.mdx"
OP_CHANGELOG_REFS="${NYM_DOCS_REFS:-develop main}"   # develop first: the notes are written and edited there
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
SCRIPT_VERSION="1.9.0"
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
# NTM is enabled ONLY when the live tunnel interface exists (a leftover script file is just a path hint,
# never an enable signal - otherwise a former-gateway-now-mixnode would run tunnel apply on a dead iface).
detect_ntm() {            # echoes "<enabled>\t<path>\t<iface>"
  local en=0 path="" iface="nymtun0"
  ip link show "$iface" >/dev/null 2>&1 && en=1
  path="$(ls -1 /usr/local/sbin/network-tunnel-manager.sh /root/network-tunnel-manager.sh /root/network_tunnel_manager.sh 2>/dev/null | head -n1 || true)"
  [[ -n "$path" ]] || path="/usr/local/sbin/network-tunnel-manager.sh"
  printf '%s\t%s\t%s\n' "$en" "$path" "$iface"
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
  [[ -n "${NTM_IFACE:-}" ]] || NTM_IFACE="nymtun0"
  [[ "$NTM_IFACE" =~ ^[a-zA-Z0-9._-]+$ ]] || NTM_IFACE="nymtun0"   # sanity: never let junk reach iptables/ip
  [[ -n "${NTM_PATH:-}" ]]  || NTM_PATH="/usr/local/sbin/network-tunnel-manager.sh"
  [[ -n "${SVC_SCOPE:-}" ]] || SVC_SCOPE="system"
  # NTM settings may come from the config: validate after it is sourced
  [[ "$NTM_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || NTM_BRANCH="develop"
  [[ "$NTM_MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || NTM_MIN_AGE_HOURS=2
  [[ "$NTM_TIMEOUT" =~ ^[0-9]+$ ]] && (( NTM_TIMEOUT >= 120 )) || NTM_TIMEOUT=900
  NTM_INPUT_POLICY="${NTM_INPUT_POLICY^^}"; [[ "$NTM_INPUT_POLICY" =~ ^(DROP|KEEP)$ ]] || NTM_INPUT_POLICY="DROP"
  [[ "$NTM_KEEP_LISTENERS" =~ ^[01]$ ]] || NTM_KEEP_LISTENERS=1
  # SSH port for NTM's firewall (config > NYM_SSH_PORT env > live detection > 22)
  [[ -n "${SSH_PORT:-}" ]] || SSH_PORT="${NYM_SSH_PORT:-$(detect_ssh_port)}"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# nym-node-autoupdate config - written by 'install', read on every run.
# Edit by hand if your setup changes, or re-run: $DEST_PATH install
# Leave BRIDGE_UNIT empty to disable QUIC-bridge updates; set NTM_ENABLED=0 to disable tunnel checks.
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
# Exit gateways: NTM (network-tunnel-manager.sh) is kept in step with $NTM_BRANCH of nymtech/nym.
# NTM_INPUT_POLICY = DROP (NTM's default: inbound traffic not in its list is dropped) | KEEP (no drop).
# NTM_KEEP_LISTENERS = 1: services already listening on this host get their own ACCEPT rule under DROP.
NTM_INPUT_POLICY="$NTM_INPUT_POLICY"
NTM_KEEP_LISTENERS="$NTM_KEEP_LISTENERS"
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
  [[ "$st" == "active" || "$st" == "activating" || "$st" == "deactivating" || "$st" == "reloading" ]] \
    && { log "  $u did not stop (state: $st)"; return 1; }
  return 0
}

# A process of the unit runs exactly the file installed at <bin>: the executable of one of its
# processes (its cgroup, or its main PID) has the same device and inode as <bin>. Any process left
# on a replaced file, a wrapper running something else, or no readable process at all: fail.
unit_runs_current_binary() {   # args: unit bin
  local u="$1" bin="$2" want cg pids p
  want="$(stat -L -c '%d:%i' "$bin" 2>/dev/null)" || { log "  cannot stat $bin"; return 1; }
  cg="$(sctl show -p ControlGroup --value "$u" 2>/dev/null || true)"
  pids=""
  if [[ -n "$cg" ]]; then
    for p in "/sys/fs/cgroup$cg/cgroup.procs" "/sys/fs/cgroup/systemd$cg/cgroup.procs" "/sys/fs/cgroup/unified$cg/cgroup.procs"; do
      [[ -r "$p" ]] && { pids="$(cat "$p" 2>/dev/null || true)"; [[ -n "$pids" ]] && break; }
    done
  fi
  [[ -n "$pids" ]] || pids="$(sctl show -p MainPID --value "$u" 2>/dev/null || true)"
  # every process is looked at: one on the installed file is required, and none may still run the
  # replaced one (same path, shown as deleted). Other helpers in the cgroup (a shell, a pre-start
  # script) run other files and are neither.
  local hit=0 stale="" exe real
  real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
  for p in $pids; do
    [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] || continue
    if [[ "$(stat -L -c '%d:%i' "/proc/$p/exe" 2>/dev/null || true)" == "$want" ]]; then hit=1; continue; fi
    exe="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
    if [[ "$exe" == "$bin (deleted)" || "$exe" == "$real (deleted)" ]]; then stale="$stale $p"; fi
  done
  if [[ -n "$stale" ]]; then log "  $u: process(es)$stale still run the replaced $bin"; return 1; fi
  (( hit )) && return 0
  log "  $u: no process runs the installed $bin (pids: ${pids:-none})"; return 1
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
      # swapping now would leave the old binary running while the state says "updated"
      log "[$NAME] $CUNIT did not stop; binary NOT swapped, $tag will be tried again next run"
      rm -f "$staged" "$backup" 2>/dev/null || true
      sctl start "$CUNIT" >/dev/null 2>&1 || true
      notify failed "$NAME: $CUNIT did not stop, so $tag was not installed; trying again next run"
      rc=1; break
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
      log "[$NAME] CRITICAL: $CUNIT did not stop, so the rollback was NOT done; $tag stays on disk and running. MANUAL INTERVENTION NEEDED."
      notify failed "CRITICAL: $NAME $tag failed its health check and $CUNIT did not stop for the rollback; still on $tag. Check by hand."
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

# Scan the operator-changelog section for tunnel/firewall relevance. arg: tag
# stdout = matched lines; return 0 = relevant, 1 = not relevant, 2 = could not read/parse.
changelog_mentions_ntm() {
  local tag="$1" ver section matched
  ver="${tag#${TAG_PREFIX}}"
  section="$(op_changelog_section "$ver")" || return 2
  [[ -n "$section" ]] || return 2
  # only an explicit instruction counts: an NTM command with a subcommand in a shell code block, or
  # prose telling operators to re-run NTM. A link to the script, or words like "firewall" or
  # "wireguard", are not one. Rule changes (NIP votes) do not need the notes at all: they arrive as a
  # new NTM commit, which maybe_run_ntm applies by itself.
  matched="$( { printf '%s\n' "$section" | changelog_commands \
                  | grep -E 'network.?tunnel.?manager\.sh[[:space:]]+[a-z_]+' || true
                printf '%s\n' "$section" | grep -iE 're-?run[^.]{0,60}(NTM|tunnel.?manager|network.?tunnel)' || true; } )"
  [[ -n "$matched" ]] || return 1
  printf '%s\n' "$matched"
}

# Newest commit of the operator notes file on the first docs branch: when it changes, the notes changed.
op_notes_ref() {
  local ref="${OP_CHANGELOG_REFS%% *}" path="${OP_CHANGELOG_PATHS%% *}" url js sha
  url="https://api.github.com/repos/$REPO/commits?sha=$ref&path=$path&per_page=1"
  js="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" \
    || js="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" || return 1
  sha="$(printf '%s' "$js" | jq -r '.[0].sha // empty' 2>/dev/null || true)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}

ntm_run() {               # args: <ntm_path> <cmd> [arg...]  -- run an NTM subcommand, log its output (also in NTM_LAST_OUT)
  local p="$1"; shift
  local code
  # HOST_SSH_PORT: NTM's firewall keeps this SSH port open. stdin from /dev/null: never wait on a prompt.
  if NTM_LAST_OUT="$(HOST_SSH_PORT="${SSH_PORT:-22}" HOST_INPUT_POLICY="$NTM_INPUT_POLICY" DEBIAN_FRONTEND=noninteractive \
                     timeout "${NTM_RUN_TIMEOUT:-$NTM_TIMEOUT}" bash "$p" "$@" </dev/null 2>&1)"; then code=0; else code=$?; fi
  log "[ntm] \`$*\` exit=$code"
  printf '%s\n' "$NTM_LAST_OUT" | sed 's/^/[ntm]   /' >> "$LOGFILE" 2>/dev/null || true
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

# Keep the gateway in step with the NTM the operator notes point to (network-tunnel-manager.sh on
# $NTM_BRANCH, run as `complete_networking_configuration`). Two things trigger a run:
#   1. NTM itself changed upstream. NIP exit-policy votes and firewall changes land there, often before
#      any release notes; a newer NTM is applied once it is NTM_MIN_AGE_HOURS old.
#   2. The current release's operator notes ask to re-run NTM (or there are no notes and the tunnel
#      does not egress).
# Each apply: preflight, a full snapshot, a dead-man timer that restores it if this run dies (no timer,
# no apply), the run, then checks: NTM's own check_firewall_setup, the exit chain closed and holding
# every port of the applied NTM's allowlist, every inbound port that was open to everyone before still
# open to everyone (judged by walking the INPUT rules in order), tunnel egress, nym-node up. A failed
# check restores the snapshot; the same NTM is retried after 6h, 12h, 24h, then left for a human.
# NEVER aborts the run.
NTM_MAX_TRIES=3
NTM_CHECK_TIMEOUT=180
NTM_LOCK_WAIT=600        # seconds the run or the dead-man waits for the snapshot lock
maybe_run_ntm() {
  # an earlier apply that never settled comes first: restore its snapshot; until that works, no new apply
  ntm_recover_pending || return 2
  [[ "${NTM_ENABLED:-0}" == "1" ]] || return 0
  local iface="${NTM_IFACE:-nymtun0}" tag ref="" rdate="" applied notes_done reasons="" notes_rc=1 matched age fn="" fts="" wait_h now
  tag="$(cat "$STATE_TAG" 2>/dev/null || true)"

  IFS=$'\t' read -r ref rdate < <(ntm_upstream_ref) || true
  if [[ -z "$ref" ]]; then log "[ntm] could not resolve the current NTM on $REPO@$NTM_BRANCH; will retry next run"; return 0; fi
  applied="$(cat "$NTM_REF_STATE" 2>/dev/null || true)"
  # notes state: "<tag> <sum of the NTM instruction lines in its notes> <notes commit they were read at>"
  local ntag="" nsum="" nref="" sum curnref
  read -r ntag nsum nref 2>/dev/null < "$NTM_NOTES_STATE" || true
  curnref="$(op_notes_ref || true)"
  now="$(date -u +%s)"
  NTM_NOTES_NEW=""          # what ntm_apply writes to the notes state once it has acted on them

  # 1) NTM changed upstream (or this updater has never applied it here)
  if [[ "$ref" != "$applied" ]]; then
    age="$(age_hours "$rdate" 2>/dev/null || echo 0)"
    if (( age < NTM_MIN_AGE_HOURS )); then
      log "[ntm] NTM changed upstream (${ref:0:12}, ${age}h old); applying after ${NTM_MIN_AGE_HOURS}h"
    elif [[ -n "$applied" ]]; then reasons="NTM changed upstream (${applied:0:12} -> ${ref:0:12})"
    else reasons="NTM ${ref:0:12} not applied by this updater yet"; fi
  fi

  # 2) this release's operator notes. They get edited after a release, so they are read again
  #    whenever the notes file gets a new commit (one API call a run tells), for as long as this
  #    release is installed; an NTM instruction that changed counts as new.
  if [[ -n "$tag" ]] && { [[ "$tag" != "$ntag" ]] || [[ -n "$curnref" && "$curnref" != "$nref" ]]; }; then
    if matched="$(changelog_mentions_ntm "$tag")"; then notes_rc=0; else notes_rc=$?; fi
    (( notes_rc <= 1 )) && sum="$(printf '%s' "$matched" | sha256sum | cut -c1-16)"
    if (( notes_rc <= 1 )) && [[ "$tag" == "$ntag" && "$sum" == "$nsum" ]]; then
      notes_rc=1                                   # the notes changed, but not their NTM instruction
      printf '%s %s %s\n' "$tag" "$sum" "${curnref:--}" > "$NTM_NOTES_STATE"
    elif (( notes_rc == 0 )); then
      log "[ntm] operator notes for $tag ask to re-run NTM$([[ "$tag" == "$ntag" ]] && echo ' (the instruction changed)'):"
      printf '%s\n' "$matched" | sed 's/^/[ntm]   /' >> "$LOGFILE" 2>/dev/null || true
      reasons="${reasons:+$reasons; }the notes for $tag ask to re-run NTM"
      NTM_NOTES_NEW="$tag $sum ${curnref:--}"
    elif (( notes_rc == 1 )); then
      log "[ntm] operator notes for $tag: no NTM instruction"
      printf '%s %s %s\n' "$tag" "$sum" "${curnref:--}" > "$NTM_NOTES_STATE"
    elif [[ "$tag" == "$ntag" ]]; then
      :                                            # notes read before; this time GitHub did not answer
    else
      # notes not written yet: while the tunnel works, wait for them (a "re-run NTM" note may still come)
      local wtag="" wfirst="" waited
      read -r wtag wfirst 2>/dev/null < "$NTM_DOCS_WAIT" || true
      now="$(date -u +%s)"
      if [[ "$wtag" != "$tag" || ! "$wfirst" =~ ^[0-9]+$ ]]; then wfirst="$now"; printf '%s %s\n' "$tag" "$now" > "$NTM_DOCS_WAIT"; fi
      waited=$(( (now - wfirst) / 3600 ))
      if ! ntm_selftest "$iface"; then
        reasons="${reasons:+$reasons; }no notes for $tag and the tunnel does not egress"
      elif (( waited < NTM_DOCS_WAIT_HOURS )); then
        log "[ntm] no operator notes for $tag yet; checking again next run (waited ${waited}h of max ${NTM_DOCS_WAIT_HOURS}h)"
      else
        log "[ntm] still no operator notes for $tag after ${waited}h; going by the NTM version only"
        printf '%s - %s\n' "$tag" "${curnref:--}" > "$NTM_NOTES_STATE"; rm -f "$NTM_DOCS_WAIT"
      fi
    fi
  fi
  [[ -n "$reasons" ]] || return 0

  # this NTM failed here before: retry after 6h, 12h, 24h; after NTM_MAX_TRIES leave it to a human
  # (a newer NTM, or "Update now" in Nymi, always tries at once)
  read -r fn fts <<<"$(ntm_fail_info "$ref")" || true
  if [[ "$fn" =~ ^[0-9]+$ && "$fts" =~ ^[0-9]+$ && "${NAU_MANUAL:-0}" != "1" ]]; then
    if (( fn >= NTM_MAX_TRIES )); then
      log "[ntm] NTM ${ref:0:12} failed here $fn times; not retrying it (a newer NTM, or Update now in Nymi, will)"; return 0
    fi
    now="$(date -u +%s)"; wait_h=$(( 6 << (fn - 1) ))
    if (( now - fts < wait_h * 3600 )); then
      log "[ntm] NTM ${ref:0:12} failed here $fn time(s); next try $(( wait_h - (now - fts) / 3600 ))h from now"; return 0
    fi
  fi
  ntm_apply "$ref" "$tag" "$reasons" "$notes_rc"
}

ntm_fail_info() { awk -v r="$1" '$1==r {print $2, $3}' "$NTM_FAILED_STATE" 2>/dev/null || true; }   # "count ts"
ntm_record_fail() {       # arg: ref ; stdout: the new failure count
  local r="$1" n="" ts=""
  read -r n ts <<<"$(ntm_fail_info "$r")" || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1)); printf '%s %s %s\n' "$r" "$n" "$(date -u +%s)" > "$NTM_FAILED_STATE"; printf '%s\n' "$n"
}

# The NTM the operator notes point to: the newest commit on $NTM_BRANCH that touched it.
# stdout "<sha>\t<commit date>". Fails closed: never falls back to the mutable branch name.
ntm_upstream_ref() {
  local url js sha date
  url="https://api.github.com/repos/$REPO/commits?sha=$NTM_BRANCH&path=$NTM_REPO_PATH&per_page=1"
  js="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" \
    || js="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" || return 1
  sha="$(printf '%s' "$js" | jq -r '.[0].sha // empty' 2>/dev/null || true)"
  date="$(printf '%s' "$js" | jq -r '.[0].commit.committer.date // empty' 2>/dev/null || true)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ && -n "$date" ]] || return 1
  printf '%s\t%s\n' "$sha" "$date"
}

# Why NTM must not run here now (empty = go). NTM aborts half way without both tunnel interfaces,
# installing iptables-persistent removes ufw on Debian/Ubuntu, and without a dead-man timer a run
# that dies mid-apply leaves the firewall half-changed.
ntm_preflight() {         # arg: iface ; stdout: reason
  local iface="$1" i rm
  for i in "$iface" nymwg; do ip link show "$i" >/dev/null 2>&1 || { echo "interface $i is missing (is nym-node running as an exit gateway?)"; return 0; }; done
  [[ -n "${UNIT:-}" && "$(sctl is-active "$UNIT" 2>/dev/null || true)" == "active" ]] || { echo "nym-node ($UNIT) is not running"; return 0; }
  command -v iptables-save >/dev/null 2>&1 && command -v iptables-restore >/dev/null 2>&1 \
    || { echo "iptables-save/restore are missing, so a bad apply could not be undone"; return 0; }
  [[ -n "$(iptables-save 2>/dev/null | head -c1)" ]] || { echo "the firewall cannot be snapshotted with iptables-save (nft-native host?)"; return 0; }
  command -v systemd-run >/dev/null 2>&1 || { echo "systemd-run is missing, so a run that dies mid-apply could not be undone"; return 0; }
  grep -q '^    ntm-restore)' "$DEST_PATH" 2>/dev/null || { echo "$DEST_PATH has no ntm-restore (run: $DEST_PATH self-update)"; return 0; }
  if ! dpkg -s iptables-persistent >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    rm="$(apt-get -s install iptables-persistent 2>/dev/null | awk '/^Remv /{print $2}' | tr '\n' ' ' || true)"
    [[ -z "$rm" ]] || { echo "NTM installs iptables-persistent, which would remove: ${rm% } (install iptables-persistent yourself first)"; return 0; }
  fi
  return 0
}

# Inbound services listening on this host now: not loopback, not on the tunnel interfaces.
# stdout "proto port fam" (fam 4, 6 or 46), one per line.
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

# Would a NEW packet from a random internet address, arriving on an uplink, reach this tcp/udp port?
# Walks the filter-table INPUT rules in order, follows jumps into user chains, and stops at the first
# rule that matches every such packet: ACCEPT or DROP/REJECT; no such rule -> the chain policy.
# -s X never matches a random source, ! -s X always does; -d, unknown match modules and the like match
# only some packets. A DROP/REJECT that matches only some packets, met before the deciding ACCEPT,
# turns ACCEPT into PARTIAL (open to some, like a fail2ban chain). Prints ACCEPT | PARTIAL | DROP |
# UNKNOWN. nft tables outside iptables are not seen, so the result is only compared before vs after
# an apply (NTM touches iptables only).
FW_EVAL_AWK='
function inports(spec, p,   a, k, j, r) {
  k = split(spec, a, ",")
  for (j = 1; j <= k; j++) {
    if (index(a[j], ":")) { split(a[j], r, ":"); if (p + 0 >= r[1] + 0 && p + 0 <= r[2] + 0) return 1 }
    else if (a[j] + 0 == p + 0) return 1
  }
  return 0
}
function ifmatch(v,   a, k, j, pre) {
  k = split(UP, a, ",")
  for (j = 1; j <= k; j++) {
    if (substr(v, length(v)) == "+") { pre = substr(v, 1, length(v) - 1); if (substr(a[j], 1, length(pre)) == pre) return 1 }
    else if (a[j] == v) return 1
  }
  return 0
}
function kind(r,   t, n, i, neg, m, partial, val) {
  n = split(r, t, " "); partial = 0; neg = 0; TGT = ""
  for (i = 3; i <= n; i++) {
    if (t[i] == "!") { neg = 1; continue }
    if (t[i] == "-p" || t[i] == "--protocol") {
      val = t[++i]; m = (val == PROTO || val == "all"); if (neg) m = !m; neg = 0
      if (!m) return "none"; continue }
    if (t[i] ~ /^--(dport|dports|destination-port|destination-ports)$/) {
      val = t[++i]; m = inports(val, PORT); if (neg) m = !m; neg = 0
      if (!m) return "none"; continue }
    if (t[i] == "-i" || t[i] == "--in-interface") {
      val = t[++i]
      if (UP == "") { if (val == "lo" && !neg) return "none"; partial = 1; neg = 0; continue }
      m = ifmatch(val); if (neg) m = !m; neg = 0
      if (!m) return "none"; continue }
    if (t[i] == "-s" || t[i] == "--source") { i++; if (!neg) return "none"; neg = 0; continue }
    if (t[i] == "-d" || t[i] == "--destination") { i++; neg = 0; partial = 1; continue }
    if (t[i] == "--ctstate" || t[i] == "--state") {
      val = t[++i]; m = (("," val ",") ~ /,NEW,/); if (neg) m = !m; neg = 0
      if (!m) return "none"; continue }
    if (t[i] == "-m" || t[i] == "--match") {
      val = t[++i]; if (val !~ /^(tcp|udp|multiport|comment|conntrack|state)$/) partial = 1; continue }
    if (t[i] == "--comment") { i++; if (substr(t[i], 1, 1) == "\"") { while (i < n && t[i] !~ /"$/) i++ }; continue }
    if (t[i] == "-j" || t[i] == "--jump" || t[i] == "-g" || t[i] == "--goto") { TGT = t[i + 1]; break }
    if (t[i] == "-f" || t[i] ~ /^--/) { partial = 1; neg = 0; continue }
  }
  return partial ? "part" : "full"
}
function evalc(ch, d,   i, k, tg, s) {
  if (d > 8) return "UNKNOWN"
  for (i = 1; i <= NRC[ch]; i++) {
    k = kind(R[ch, i]); if (k == "none") continue
    tg = TGT
    if (tg == "ACCEPT") { if (k == "full") return "ACCEPT"; continue }
    if (tg == "DROP" || tg == "REJECT") { if (k == "full") return "DROP"; SEENPART = 1; continue }
    if (tg == "RETURN") { if (k == "full") return "RET"; continue }
    if (tg in UC) { s = evalc(tg, d + 1); if (k == "full" && s != "RET") return s; if (s == "DROP" || s == "UNKNOWN") SEENPART = 1; continue }
  }
  return "RET"
}
$1 == "-P" { P[$2] = $3; next }
$1 == "-N" { UC[$2] = 1; next }
$1 == "-A" { NRC[$2]++; R[$2, NRC[$2]] = $0; next }
END { v = evalc("INPUT", 0); if (v == "RET") v = P["INPUT"]; if (v == "") v = "UNKNOWN"; if (v == "ACCEPT" && SEENPART) v = "PARTIAL"; print v }'
uplinks() {               # arg: 4|6 ; the interfaces of the default routes, comma separated
  ip "-$1" -o route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u | paste -sd, - || true
}
fw_verdict() {            # args: iptables|ip6tables tcp|udp port ; stdout ACCEPT | PARTIAL | DROP | UNKNOWN
  local ipt="$1" fam=4; [[ "$ipt" == ip6tables ]] && fam=6
  "$ipt" -w -S 2>/dev/null | awk -v PROTO="$2" -v PORT="$3" -v UP="$(uplinks "$fam")" "$FW_EVAL_AWK" || echo UNKNOWN
}
# "fam proto port verdict" for every listener and the SSH port, per address family
ntm_port_verdicts() {     # stdin: host_listeners lines
  local proto port fam f ipt
  { cat; printf 'tcp %s 46\n' "${SSH_PORT:-22}"; } | while read -r proto port fam; do
    [[ "$proto" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]+$ ]] || continue
    for f in 4 6; do
      [[ "$fam" == *"$f"* ]] || continue
      ipt=iptables; [[ "$f" == 6 ]] && ipt=ip6tables
      command -v "$ipt" >/dev/null 2>&1 || continue
      printf '%s %s %s %s\n' "$f" "$proto" "$port" "$(fw_verdict "$ipt" "$proto" "$port")"
    done
  done | sort -u
}

NTM_KEEP_TAG="nym-node-autoupdate-keep"
NTM_FW_TAG="NYM-NETWORK-FW"           # NTM's own comment on the INPUT rules it manages
# Under NTM's INPUT DROP a service that listens here but is not in NTM's list (a monitoring agent, a
# website) would be cut off. Where the INPUT policy of an address family was ACCEPT, each listener
# of that family gets an ACCEPT appended at the END of INPUT, after every rule that exists now: a
# packet that used to fall through to the ACCEPT policy now meets this rule instead, and a packet
# that an earlier rule dropped or restricted still meets that rule first. So access stays exactly
# what it was, never wider. Where the policy was already DROP, nothing is added.
# args: INPUT policy v4, v6 ; stdin: host_listeners lines.
ntm_keep_listeners() {
  local p4="$1" p6="$2" proto port fam f ipt
  while read -r proto port fam; do
    [[ "$proto" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]+$ ]] || continue
    for f in 4 6; do
    [[ "$fam" == *"$f"* ]] || continue
    if [[ "$f" == 4 ]]; then ipt=iptables; [[ "$p4" == ACCEPT ]] || continue; else ipt=ip6tables; [[ "$p6" == ACCEPT ]] || continue; fi
    command -v "$ipt" >/dev/null 2>&1 || continue
    "$ipt" -w -C INPUT -p "$proto" --dport "$port" -m comment --comment "$NTM_KEEP_TAG" -j ACCEPT 2>/dev/null \
      || "$ipt" -w -A INPUT -p "$proto" --dport "$port" -m comment --comment "$NTM_KEEP_TAG" -j ACCEPT 2>/dev/null || true
    done
  done
}
ntm_prune_keeps() {       # remove our keep rule wherever NTM's own rule allows the same port
  local ipt proto port
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    "$ipt" -w -S INPUT 2>/dev/null | grep -- "--comment $NTM_KEEP_TAG" \
      | sed -nE 's/.*-p (tcp|udp) .*--dport ([0-9]+) .*/\1 \2/p' | while read -r proto port; do
        if "$ipt" -w -C INPUT -p "$proto" --dport "$port" -m conntrack --ctstate NEW -m comment --comment "$NTM_FW_TAG" -j ACCEPT 2>/dev/null; then
          "$ipt" -w -D INPUT -p "$proto" --dport "$port" -m comment --comment "$NTM_KEEP_TAG" -j ACCEPT 2>/dev/null || true
        fi
      done
  done
}
ntm_kept_list() {         # "tcp/8767 udp/123 ..." still open only because of a keep rule
  { iptables -w -S INPUT 2>/dev/null; ip6tables -w -S INPUT 2>/dev/null; } | grep -- "--comment $NTM_KEEP_TAG" \
    | sed -nE 's/.*-p (tcp|udp) .*--dport ([0-9]+) .*/\1\/\2/p' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# The exit-policy ports of an NTM script, one per line as iptables writes them ("8000", "3478:3484").
ntm_allowlist() {         # arg: ntm script
  awk '/PORT_MAPPINGS=\(/ {f = 1; next} f && /^[[:space:]]*\)/ {exit} f' "$1" 2>/dev/null | grep -vE '^[[:space:]]*#' \
    | grep -oE '^[[:space:]]*\["[^"]+"\]="[0-9]+(-[0-9]+)?"' | sed -E 's/.*="([^"]+)"/\1/; s/-/:/' | sort -u
}
# Every allowlist port is ACCEPTed for tcp and udp in NYM-EXIT (v4, and v6 where the chain exists),
# ahead of the chain's catch-all REJECT. arg: ntm script ; stdout: what is missing ; return 1 if any.
ntm_check_allowlist() {
  local want have ipt spec miss="" n
  want="$(ntm_allowlist "$1")"; n="$(grep -c . <<<"$want" || true)"
  (( n > 0 )) || { echo "no port allowlist found in the NTM script"; return 1; }
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    if ! "$ipt" -w -S NYM-EXIT >/dev/null 2>&1; then [[ "$ipt" == iptables ]] && { echo "iptables has no NYM-EXIT"; return 1; }; continue; fi
    have="$("$ipt" -w -S NYM-EXIT | awk '
      { u = $0; gsub(/ -m comment --comment ("[^"]*"|[^ ]+)/, "", u) }
      u ~ /^-A NYM-EXIT -j (REJECT|DROP)( |$)/ { exit }
      u ~ /^-A NYM-EXIT -p (tcp|udp) -m (tcp|udp) --dport [0-9:]+ -j ACCEPT$/ { split(u, a, " "); print a[4], a[8] }' | sort -u)"
    while read -r spec; do
      grep -qxF "tcp $spec" <<<"$have" || miss="$miss $ipt:tcp/$spec"
      grep -qxF "udp $spec" <<<"$have" || miss="$miss $ipt:udp/$spec"
    done <<<"$want"
  done
  [[ -z "$miss" ]] && return 0
  echo "missing:$(printf '%s' "$miss" | cut -c1-400)"; return 1
}

# Snapshot of everything NTM changes that can be put back: iptables (with empty sections for tables
# that did not exist yet, so a restore also empties a table NTM created), the files it rewrites, the
# net.ipv4/net.ipv6 sysctls (it runs sysctl --system), ufw's config and whether ufw was on.
# Not put back: packages NTM installs (iptables-persistent, jq) and its own logs and backups.
NTM_SNAP_FILES="/etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/sysctl.d/99-nym-forwarding.conf /etc/nym/exit-policy.txt /etc/iptables/ntm-ufw-families"
ntm_snapshot() {          # arg: dir
  local d="$1" f i=0 t
  rm -rf "$d"; mkdir -p "$d/files" || return 1
  iptables-save > "$d/v4" 2>/dev/null && [[ -s "$d/v4" ]] || return 1
  for t in filter nat mangle; do grep -q "^\*$t\$" "$d/v4" || printf '*%s\nCOMMIT\n' "$t" >> "$d/v4"; done
  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > "$d/v6" 2>/dev/null || return 1
    for t in filter nat mangle; do grep -q "^\*$t\$" "$d/v6" || printf '*%s\nCOMMIT\n' "$t" >> "$d/v6"; done
  fi
  for f in $NTM_SNAP_FILES; do i=$((i+1)); if [[ -e "$f" ]]; then cp -a "$f" "$d/files/$i" || return 1; fi; done
  sysctl -a 2>/dev/null | grep -E '^net\.ipv(4|6)\.' > "$d/sysctl" || true
  if [[ -d /etc/ufw ]]; then tar -C /etc -cpf "$d/ufw.tar" ufw 2>/dev/null || return 1; fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then touch "$d/ufw_active"; fi
  return 0
}
ntm_restore() {           # arg: dir ; return 1 if any part could not be put back
  local d="$1" f i=0 k v cur err="" line
  [[ -s "$d/v4" ]] || { log "[ntm] restore: no snapshot in $d"; return 1; }
  iptables-restore < "$d/v4" 2>/dev/null || err="$err iptables-restore"
  if [[ -s "$d/v6" ]]; then ip6tables-restore < "$d/v6" 2>/dev/null || err="$err ip6tables-restore"; fi
  for f in $NTM_SNAP_FILES; do
    i=$((i+1))
    if [[ -e "$d/files/$i" ]]; then cp -a "$d/files/$i" "$f" 2>/dev/null || err="$err $f"
    else rm -f "$f" 2>/dev/null || err="$err rm:$f"; fi
  done
  if [[ -s "$d/sysctl" ]]; then
    while IFS= read -r line; do
      k="${line%% = *}"; v="${line#* = }"
      [[ "$k" =~ ^net\.ipv[46]\.[A-Za-z0-9_./-]+$ ]] || continue
      cur="$(sysctl -n "$k" 2>/dev/null || true)"
      sysctl -n "$k" >/dev/null 2>&1 || continue   # the key is gone (an interface went away)
      [[ "$cur" == "$v" ]] || sysctl -qw "$k=$v" >/dev/null 2>&1 || err="$err sysctl:$k"
    done < "$d/sysctl"
  fi
  if [[ -s "$d/ufw.tar" ]]; then tar -C /etc -xpf "$d/ufw.tar" 2>/dev/null || err="$err /etc/ufw"; fi
  if [[ -e "$d/ufw_active" ]] && ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw --force enable >/dev/null 2>&1 || err="$err ufw-enable"
  fi
  if [[ -n "$err" ]]; then log "[ntm] restore from $d INCOMPLETE, failed:$err"; return 1; fi
  log "[ntm] restored from $d: iptables, saved rules, sysctls, ufw"
}
ntm_persist() {
  if command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1; then return 0; fi
  mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 && { ! command -v ip6tables-save >/dev/null 2>&1 || ip6tables-save > /etc/iptables/rules.v6; }
}

# Dead-man: if this run dies mid-apply, a transient systemd timer restores the snapshot. The run and
# the timer act only under "$snap/.lock". Markers in the snapshot dir:
#   done    - the change is kept (success) or fully undone; nobody acts any more
#   fired   - the timer has acted; the run may not declare success after that
#   counted - the failure of this apply is recorded (once, by whichever side gets there first)
# A restore that did not complete leaves no "done": the other side tries again (the run after the
# timer, or a timer re-armed for 120s after the run), and every later hourly run retries it first
# (ntm_recover_pending), with no new apply until it works. Alerts are CRITICAL until then.
NTM_DEADMAN_UNIT="nym-node-autoupdate-ntm-restore"
ntm_deadman_arm() {       # args: snapshot dir [seconds] ; return 1 = not armed (then nothing may be applied)
  ntm_deadman_disarm
  systemd-run --quiet --unit="$NTM_DEADMAN_UNIT" --on-active="${2:-$(( NTM_TIMEOUT + NTM_CHECK_TIMEOUT + 600 ))}" \
    "$DEST_PATH" ntm-restore "$1" >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$NTM_DEADMAN_UNIT.timer" 2>/dev/null
}
ntm_deadman_disarm() {
  systemctl stop "$NTM_DEADMAN_UNIT.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "$NTM_DEADMAN_UNIT.timer" "$NTM_DEADMAN_UNIT.service" >/dev/null 2>&1 || true
}
# Second line of defence, on the updater's own persistent hourly timer: a snapshot without "done"
# means an apply that never settled (its run died, the dead-man failed or was never re-armed). A run
# only gets here while holding the updater's main lock, so the run that took that snapshot is gone and
# nobody else will act on it: restore it now. Returns 1 while it cannot be restored (then nothing new
# is applied and the snapshot is kept); alerts once per snapshot.
# Note: the restore puts back the iptables tables as they were at the snapshot, so rules other tools
# added since (docker, fail2ban bans) are dropped too.
ntm_recover_pending() {
  local snap="$STATE_DIR/ntm-snapshot" n="" restored=0
  [[ -d "$snap" && ! -e "$snap/done" ]] || return 0
  if [[ ! -e "$snap/applying" ]]; then   # taken, but the run stopped before changing anything
    log "[ntm] removing a snapshot that was never used for an apply ($snap)"; ntm_deadman_disarm; rm -rf "$snap"; return 0
  fi
  if [[ ! -s "$snap/v4" ]]; then
    log "[ntm] CRITICAL: unsettled apply but no usable snapshot in $snap - MANUAL INTERVENTION NEEDED"
    [[ -e "$snap/alerted" ]] || { touch "$snap/alerted"; notify failed "CRITICAL: an NTM apply never settled and its snapshot ($snap) is unusable; check the firewall by hand, then delete $snap"; }
    return 1
  fi
  log "[ntm] an earlier NTM apply never settled; restoring its snapshot ($snap) before anything else"
  exec 8>"$snap/.lock"
  if ! flock -w "$NTM_LOCK_WAIT" 8; then
    exec 8>&-
    log "[ntm] CRITICAL: could not take $snap/.lock; will retry next run"
    [[ -e "$snap/alerted" ]] || { touch "$snap/alerted"; notify failed "CRITICAL: an NTM apply never settled and its snapshot lock is busy; retrying hourly"; }
    return 1
  fi
  if [[ -e "$snap/done" ]]; then exec 8>&-; ntm_deadman_disarm; return 0; fi
  touch "$snap/fired"
  if ntm_restore "$snap"; then touch "$snap/done"; restored=1; fi
  if [[ ! -e "$snap/counted" ]]; then n="$(ntm_record_fail "$(cat "$snap/ref" 2>/dev/null || echo unknown)")"; touch "$snap/counted"; fi
  exec 8>&-
  if (( restored == 1 )); then
    ntm_deadman_disarm
    log "[ntm] restored the snapshot of the unsettled apply"
    notify rollback "An NTM apply never settled; the hourly run restored its firewall snapshot${n:+ (failure $n for this NTM)}"
    return 0
  fi
  log "[ntm] CRITICAL: the snapshot of the unsettled apply could not be fully restored; no new apply until it is (retrying hourly)"
  [[ -e "$snap/alerted" ]] || { touch "$snap/alerted"; notify failed "CRITICAL: an NTM apply never settled and restoring its snapshot ($snap) fails; retrying hourly, MANUAL INTERVENTION NEEDED"; }
  return 1
}

ntm_deadman_fire() {      # arg: snapshot dir ; run by the timer through `ntm-restore` (under set -e)
  local d="$1" n="" restored=0
  exec 8>"$d/.lock"
  if ! flock -w "$NTM_LOCK_WAIT" 8; then
    log "[ntm] dead-man: could not take $d/.lock in ${NTM_LOCK_WAIT}s"
    notify failed "CRITICAL: the NTM dead-man timer could not take the snapshot lock ($d); check the firewall by hand"
    return 1
  fi
  if [[ -e "$d/done" ]]; then exec 8>&-; return 0; fi
  if [[ ! -e "$d/applying" ]]; then touch "$d/done"; exec 8>&-; return 0; fi   # nothing was changed yet
  touch "$d/fired"
  log "[ntm] dead-man: the NTM apply did not settle; restoring the snapshot"
  if ntm_restore "$d"; then touch "$d/done"; restored=1; fi
  if [[ ! -e "$d/counted" ]]; then n="$(ntm_record_fail "$(cat "$d/ref" 2>/dev/null || echo unknown)")"; touch "$d/counted"; fi
  exec 8>&-
  if (( restored == 1 )); then
    notify failed "NTM apply did not settle; the dead-man timer restored the firewall snapshot${n:+ (failure $n for this NTM)}"
  else
    log "[ntm] CRITICAL: dead-man restore incomplete - MANUAL INTERVENTION NEEDED (snapshot: $d)"
    notify failed "CRITICAL: the dead-man timer could not fully restore the firewall snapshot ($d); MANUAL INTERVENTION NEEDED"
  fi
}

# Checks after an apply. args: iface, the NTM script, the port verdicts from before. return 0 = all good
ntm_verify() {
  local iface="$1" ntm="$2" pre="$3" ipt fail="" msg fam proto port v ipx now
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    if ! "$ipt" -w -S NYM-EXIT >/dev/null 2>&1; then [[ "$ipt" == iptables ]] && fail="$fail $ipt:no-NYM-EXIT"; continue; fi
    [[ "$("$ipt" -w -S NYM-EXIT | tail -n1)" == *"-j REJECT"* ]] || fail="$fail $ipt:NYM-EXIT-not-closed"
    "$ipt" -w -S FORWARD | grep -q -- '-j NYM-EXIT' || fail="$fail $ipt:no-FORWARD-hook"
  done
  msg="$(ntm_check_allowlist "$ntm")" || fail="$fail exit-policy($msg)"
  # every listener and the SSH port is no less reachable than before (DROP < PARTIAL < ACCEPT)
  while read -r fam proto port v; do
    [[ "$v" == ACCEPT || "$v" == PARTIAL ]] || continue
    ipx=iptables; [[ "$fam" == 6 ]] && ipx=ip6tables
    now="$(fw_verdict "$ipx" "$proto" "$port")"
    [[ "$now" == ACCEPT || ( "$v" == PARTIAL && "$now" == PARTIAL ) ]] || fail="$fail v$fam:$proto/$port:was-$v-now-$now"
  done <<<"$pre"
  ntm_selftest "$iface" || fail="$fail tunnel-no-egress"
  [[ "$(sctl is-active "$UNIT" 2>/dev/null || true)" == "active" ]] || fail="$fail nym-node-down"
  curl -fsS --max-time 8 -o /dev/null "$NODE_HTTP/api/v1/health" 2>/dev/null || fail="$fail nym-node-api-silent"
  [[ -z "$fail" ]] && return 0
  log "[ntm] post-apply checks failed:$fail"; return 1
}

ntm_apply() {             # args: ref tag reasons notes_rc
  local ref="$1" tag="$2" why="$3" notes_rc="$4"
  local iface="${NTM_IFACE:-nymtun0}" dest="${NTM_PATH:-/usr/local/sbin/network-tunnel-manager.sh}"
  local work="$STATE_DIR/ntm-work" snap="$STATE_DIR/ntm-snapshot" block sum lst pre p4 p6 ok=1 kept rc=0 keep=0 restored=1 counted=0 n=""
  [[ "$NTM_INPUT_POLICY" == "DROP" && "$NTM_KEEP_LISTENERS" == "1" ]] && keep=1
  log "[ntm] applying NTM ${ref:0:12}: $why"

  block="$(ntm_preflight "$iface")"
  if [[ -n "$block" ]]; then
    log "[ntm] NOT applied: $block"
    if [[ "$block" != "$(cat "$NTM_BLOCK_STATE" 2>/dev/null || true)" ]]; then
      printf '%s\n' "$block" > "$NTM_BLOCK_STATE"
      notify failed "NTM ${ref:0:12} not applied: $block. The next hourly run tries again."
    fi
    return 1
  fi
  rm -f "$NTM_BLOCK_STATE"

  rm -rf "$work"; mkdir -p "$work" || { log "[ntm] cannot create $work"; return 0; }
  if ! gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 5 $RETRY_ALL --retry-delay 5 --max-time 180 \
         -o "$work/ntm.sh" "https://raw.githubusercontent.com/$REPO/$ref/$NTM_REPO_PATH"; then
    log "[ntm] could not download NTM @ ${ref:0:12}; will retry next run"; rm -rf "$work"; return 0
  fi
  if ! grep -qE '^[[:space:]]*complete_networking_configuration\)' "$work/ntm.sh" || ! bash -n "$work/ntm.sh" 2>/dev/null \
     || [[ -z "$(ntm_allowlist "$work/ntm.sh")" ]]; then
    log "[ntm] NTM @ ${ref:0:12} has no complete_networking_configuration, no port allowlist, or does not parse; not applied"
    n="$(ntm_record_fail "$ref")"; notify failed "NTM ${ref:0:12} does not look like the NTM this updater knows; not applied (failure $n)"
    rm -rf "$work"; return 1
  fi
  sum="$(sha256sum "$work/ntm.sh" | awk '{print $1}')"
  log "[ntm] fetched NTM @ $ref (sha256 $sum; no upstream checksum, trusts the nym GitHub org)"

  # never overwrite the snapshot of an apply that has not settled (ntm_recover_pending handles that one)
  if [[ -d "$snap" && ! -e "$snap/done" ]]; then
    log "[ntm] CRITICAL: $snap belongs to an apply that has not settled; not applying"; rm -rf "$work"; return 2
  fi
  # a snapshot that is never used for an apply is removed, so it cannot look like an unsettled one
  if ! ntm_snapshot "$snap"; then log "[ntm] could not take a full snapshot; not applied"; rm -rf "$work" "$snap"; return 1; fi
  lst="$(host_listeners)"; pre="$(printf '%s\n' "$lst" | ntm_port_verdicts)"
  p4="$(iptables -w -S INPUT 2>/dev/null | awk 'NR==1 {print $3}')"
  p6="$(ip6tables -w -S INPUT 2>/dev/null | awk 'NR==1 {print $3}' || true)"
  printf '%s\n' "$lst" > "$snap/listeners"; printf '%s\n' "$pre" > "$snap/verdicts"; printf '%s\n' "$ref" > "$snap/ref"
  if ! ntm_deadman_arm "$snap"; then
    log "[ntm] could not arm the dead-man restore timer; not applied"
    notify failed "NTM ${ref:0:12} not applied: the dead-man restore timer could not be armed"; rm -rf "$work" "$snap"; return 1
  fi
  # from here on the host changes: only a snapshot marked "applying" is ever restored
  touch "$snap/applying"
  # added before NTM switches INPUT to DROP, so these services never see a gap
  (( keep )) && printf '%s\n' "$lst" | ntm_keep_listeners "$p4" "$p6"

  log "[ntm] running complete_networking_configuration (HOST_INPUT_POLICY=$NTM_INPUT_POLICY HOST_SSH_PORT=${SSH_PORT:-22})"
  ntm_run "$work/ntm.sh" complete_networking_configuration || ok=0
  if printf '%s' "$NTM_LAST_OUT" | grep -q 'exit policy tests reported problems'; then
    log "[ntm] note: NTM's own exit-policy connectivity tests reported problems (they probe remote hosts; not a failure by themselves)"
  fi
  if (( ok && keep )); then printf '%s\n' "$lst" | ntm_keep_listeners "$p4" "$p6"; ntm_prune_keeps; fi
  (( ok )) && { NTM_RUN_TIMEOUT="$NTM_CHECK_TIMEOUT" ntm_run "$work/ntm.sh" check_firewall_setup || ok=0; }
  (( ok )) && { ntm_verify "$iface" "$work/ntm.sh" "$pre" || ok=0; }

  # settle under the snapshot lock, so the dead-man timer and this run never both act.
  # Without the lock nothing is touched: the firewall stays as it is and the timer stays armed.
  exec 8>"$snap/.lock"
  if ! flock -w "$NTM_LOCK_WAIT" 8; then
    exec 8>&-
    log "[ntm] CRITICAL: could not take $snap/.lock in ${NTM_LOCK_WAIT}s; left the firewall and the dead-man timer as they are"
    notify failed "CRITICAL: NTM ${ref:0:12} apply could not settle (snapshot lock busy); the dead-man timer stays armed. See $LOGFILE"
    rm -rf "$work"; return 2
  fi
  if [[ -e "$snap/fired" ]]; then
    ok=0
    if [[ -e "$snap/done" ]]; then log "[ntm] the dead-man timer already restored the snapshot"; restored=1
    else
      log "[ntm] the dead-man timer could not fully restore the snapshot; trying again"
      if ntm_restore "$snap"; then restored=1; touch "$snap/done"; else restored=0; fi
    fi
  elif (( ok )) && ntm_persist; then
    touch "$snap/done"
  else
    # a rule set that is live but not saved would be gone after a reboot while the state says
    # "applied": undo it instead, so the live and the saved firewall never differ
    if (( ok )); then log "[ntm] could not save the rules for reboot; undoing the apply"; ok=0; fi
    log "[ntm] NTM ${ref:0:12} failed its checks; restoring the snapshot"
    if ntm_restore "$snap"; then restored=1; touch "$snap/done"; else restored=0; fi
  fi
  # count a failed apply once, whoever (this run or the timer) gets to it first
  if (( ! ok )) && [[ ! -e "$snap/counted" ]]; then n="$(ntm_record_fail "$ref")"; touch "$snap/counted"; fi
  [[ -n "$n" ]] || n="$(ntm_fail_info "$ref" | awk '{print $1}')"
  exec 8>&-
  # "done" = the change is kept or fully undone: the timer can go. Otherwise it gets one more try soon.
  if [[ -e "$snap/done" ]]; then ntm_deadman_disarm
  elif ntm_deadman_arm "$snap" 120; then log "[ntm] restore incomplete; the dead-man timer will try again in 120s"
  else
    log "[ntm] CRITICAL: restore incomplete and the dead-man timer could not be re-armed; the next hourly run restores the snapshot"
    notify failed "CRITICAL: NTM ${ref:0:12} restore incomplete and no dead-man timer; the next hourly run retries the restore (snapshot $snap)"
  fi

  if (( ok )); then
    install -m 0755 "$work/ntm.sh" "$dest" 2>/dev/null || true
    printf '%s\n' "$ref" > "$NTM_REF_STATE"; printf '%s\n' "$sum" > "$NTM_SUM_STATE"
    if [[ -n "$tag" ]]; then printf '%s\n' "$tag" > "$NTM_STATE"; fi
    if [[ -n "${NTM_NOTES_NEW:-}" ]]; then printf '%s\n' "$NTM_NOTES_NEW" > "$NTM_NOTES_STATE"; fi
    rm -f "$NTM_FAILED_STATE"
    kept="$( (( keep )) && ntm_kept_list || true)"
    log "[ntm] SUCCESS: NTM ${ref:0:12} applied, checks passed, rules persisted; NTM saved to $dest${kept:+; kept open for services already listening here: $kept}"
    notify success "$(printf 'NTM %s applied (%s).\nINPUT policy %s%s' "${ref:0:12}" "$why" "$NTM_INPUT_POLICY" "${kept:+; kept open for services already listening here: $kept}")"
    rm -rf "$work"; return 0
  fi

  if (( restored )) && ntm_selftest "$iface" && [[ "$(sctl is-active "$UNIT" 2>/dev/null || true)" == "active" ]]; then
    log "[ntm] ROLLED BACK: snapshot restored, tunnel egressing. Failure $n of $NTM_MAX_TRIES for NTM ${ref:0:12}."
    notify rollback "NTM ${ref:0:12} failed its checks; firewall restored, tunnel is UP (failure $n of $NTM_MAX_TRIES). See $LOGFILE"; rc=1
  else
    log "[ntm] CRITICAL: the restore is incomplete or the tunnel is still down - MANUAL INTERVENTION NEEDED (snapshot: $snap)"
    notify failed "CRITICAL: NTM ${ref:0:12} failed AND the restore did not fully bring the host back (snapshot $snap)"; rc=2
  fi
  rm -rf "$work"; return "$rc"
}

# -------------------- QUIC bridge configuration (gateways only) --------------------
# The operator notes (istanbul on) ask to re-run the bridge setup (quic_bridge_deployment.sh). For an
# existing bridge it adds the transports in its NEW_TRANSPORTS list (tls_plain tcp/4443, ssh_plain
# tcp/4422), mints their keys and regenerates the client params with the bridge-cfg of the bridge's
# release. The updater does the same without running that script or dpkg:
#   - the target transports are read from the helper on $NTM_BRANCH, pinned to its commit;
#   - bridge-cfg is the standalone asset of the installed bridge release, checked against the sha256
#     the GitHub API publishes for it;
#   - bridge-cfg runs in a private mount namespace on COPIES of /etc/nym and the nym-node config
#     (it writes in place, without rename): only the copies are ever half-written;
#   - the copies are validated (same QUIC key file and QUIC entry, forward/public_ips unchanged, only
#     the expected files changed, the bridge parses them), then installed by rename;
#   - nym-bridge restarts; QUIC, TLS and SSH are checked (listening by the unit, TLS and SSH serving
#     the published keys, the firewall letting the new ports in); only then are the new transports
#     published (client params JSON); any failed check restores /etc/nym exactly.
# nym-bridge 0.3 stops ALL listeners, QUIC included, and exits 0 when any listener fails, and a
# Restart=on-failure unit is then not restarted. A drop-in Restart=always comes with the change.
# Triggers: the bridge release or the helper commit differs from what was applied, or never applied.
BRIDGE_HELPER_PATH="scripts/nym-node-setup/quic_bridge_deployment.sh"
BRIDGE_CFG_ASSET="bridge-cfg"
BRIDGE_ETC="/etc/nym"
BRIDGE_CONF="$BRIDGE_ETC/bridges.toml"
BRIDGE_CFG_STATE="$STATE_DIR/bridge_cfg_applied"   # "<bridge tag> <helper commit>"
BRIDGE_CFG_FAILED="$STATE_DIR/bridge_cfg_failed"   # "<bridge tag>+<helper commit> <count> <ts>"
BRIDGE_CFG_BLOCK="$STATE_DIR/bridge_cfg_blocked"
BRIDGE_SNAP="$STATE_DIR/bridge-snapshot"
BRIDGE_DEADMAN_UNIT="nym-node-autoupdate-bridge-restore"
BRIDGE_DROPIN_NAME="nym-node-autoupdate.conf"
BRIDGE_CFG_ENABLED="${NYM_BRIDGE_CFG:-1}"          # 0 = never touch the bridge configuration

bridge_helper_ref() {     # stdout "<sha>" of the newest helper commit on $NTM_BRANCH
  local url js sha
  url="https://api.github.com/repos/$REPO/commits?sha=$NTM_BRANCH&path=$BRIDGE_HELPER_PATH&per_page=1"
  js="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" \
    || js="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" || return 1
  sha="$(printf '%s' "$js" | jq -r '.[0].sha // empty' 2>/dev/null || true)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}
# The helper's target transports, "name port" per line, from its NEW_TRANSPORTS=("tls_plain:4443" ...)
bridge_wanted_transports() {   # arg: helper script
  grep -m1 -E '^[[:space:]]*NEW_TRANSPORTS=\(' "$1" 2>/dev/null | grep -oE '"[a-z_]+:[0-9]+"' | tr -d '"' | tr ':' ' ' \
    | awk '$1 ~ /^(tls_plain|ssh_plain)$/ && $2 > 0 && $2 < 65536' || true
}
# The nym-node config the bridge belongs to: the only <home>/.nym/nym-nodes/*/config/config.toml
bridge_node_cfg() {
  local home n
  home="$(getent passwd "${SVC_USER:-root}" 2>/dev/null | cut -d: -f6)"; [[ -n "$home" ]] || home=/root
  n="$(ls -1 "$home"/.nym/nym-nodes/*/config/config.toml 2>/dev/null | wc -l)"
  [[ "$n" == 1 ]] || return 1
  readlink -f "$(ls -1 "$home"/.nym/nym-nodes/*/config/config.toml)"
}
toml_top() {              # args: file key ; value of a key before the first [table], quotes and spaces removed
  awk -v k="$2" '/^[[:space:]]*\[/ {exit} { line=$0; sub(/[[:space:]]*#.*/, "", line); split(line, a, "="); key=a[1]; gsub(/[[:space:]]/, "", key)
       if (key == k) { sub(/^[^=]*=/, "", line); gsub(/["\x27 \t]/, "", line); print line; exit } }' "$1"
}
toml_in() {               # args: file table key ; value of key inside [table], quotes and spaces removed
  awk -v t="[$2]" -v k="$3" '{ s=$0; gsub(/[[:space:]]/, "", s) } s ~ /^\[/ { f = (s == t); next }
       f { line=$0; sub(/[[:space:]]*#.*/, "", line); split(line, a, "="); key=a[1]; gsub(/[[:space:]]/, "", key)
           if (key == k) { sub(/^[^=]*=/, "", line); gsub(/["\x27 \t]/, "", line); print line; exit } }' "$1"
}
# Download bridge-cfg of a bridge release and check it against the sha256 the GitHub API publishes.
bridge_cfg_fetch() {      # args: tag dest ; return 1 on any doubt
  local tag="$1" dest="$2" js url digest got
  js="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$BRIDGE_REPO/releases/tags/$tag" 2>/dev/null)" \
    || js="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
          -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$BRIDGE_REPO/releases/tags/$tag" 2>/dev/null)" || return 1
  url="$(printf '%s' "$js" | jq -r --arg a "$BRIDGE_CFG_ASSET" '.assets[]? | select(.name==$a) | .browser_download_url' 2>/dev/null | head -n1)"
  digest="$(printf '%s' "$js" | jq -r --arg a "$BRIDGE_CFG_ASSET" '.assets[]? | select(.name==$a) | .digest // empty' 2>/dev/null | head -n1)"
  digest="${digest#sha256:}"
  [[ "$url" == https://github.com/* && "$digest" =~ ^[0-9a-f]{64}$ ]] || { log "[bridge-cfg] $tag has no $BRIDGE_CFG_ASSET asset with a published sha256"; return 1; }
  gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 3 $RETRY_ALL --retry-delay 5 --max-time 180 -o "$dest" "$url" || return 1
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$got" == "$digest" ]] || { log "[bridge-cfg] sha256 mismatch for $tag $BRIDGE_CFG_ASSET (got $got, published $digest)"; return 1; }
  chmod 0755 "$dest"
  timeout 10 "$dest" --help >/dev/null 2>&1 || { log "[bridge-cfg] downloaded $BRIDGE_CFG_ASSET does not run"; return 1; }
}

# Why the bridge must not be configured here now (empty = go).
# The private key file of the QUIC transport, as named in its [[transports]] block of bridges.toml.
bridge_quic_key_file() {  # arg: bridges.toml
  awk '{ s = $0; sub(/[[:space:]]*#.*/, "", s) }
       s ~ /^[[:space:]]*\[\[transports\]\]/ { t = ""; next }
       s ~ /^[[:space:]]*transport_type[[:space:]]*=/ { v = s; sub(/^[^=]*=/, "", v); gsub(/["\x27 \t]/, "", v); t = v; next }
       t == "quic_plain" && s ~ /^[[:space:]]*private_ed25519_identity_key_file[[:space:]]*=/ {
         v = s; sub(/^[^=]*=/, "", v); gsub(/["\x27 \t]/, "", v); print v; exit }' "$1"
}

bridge_cfg_preflight() {
  local t k
  # the helpers this step uses (sctl, is_healthy, the drop-in under /etc/systemd/system) assume a
  # system service; a host whose nym-node runs as a user service is left alone
  [[ "${SVC_SCOPE:-system}" == system ]] || { echo "nym-node runs as a user service; the bridge step supports system services only"; return 0; }
  systemctl cat "$BRIDGE_UNIT" >/dev/null 2>&1 || { echo "$BRIDGE_UNIT is not a system service"; return 0; }
  [[ "$(systemctl is-active "$BRIDGE_UNIT" 2>/dev/null || true)" == active ]] || { echo "$BRIDGE_UNIT is not running"; return 0; }
  k="$(bridge_quic_key_file "$BRIDGE_CONF" 2>/dev/null || true)"
  [[ -n "$k" && -f "$k" && ! -L "$k" ]] || { echo "the QUIC key file named in $BRIDGE_CONF (${k:-none}) is not a regular file"; return 0; }
  [[ -s "$BRIDGE_CONF" && -s "$BRIDGE_ETC/client_bridge_params.json" ]] || { echo "$BRIDGE_CONF or the client params are missing"; return 0; }
  [[ "$(sctl show -p ExecStart --value "$BRIDGE_UNIT" 2>/dev/null | grep -oE -- '--config[= ]+[^ ;]+' | head -n1 | sed -E 's/--config[= ]+//')" == "$BRIDGE_CONF" ]] \
    || { echo "$BRIDGE_UNIT does not run with --config $BRIDGE_CONF"; return 0; }
  for t in unshare mount openssl ssh-keyscan jq; do command -v "$t" >/dev/null 2>&1 || { echo "$t is missing"; return 0; }; done
  command -v systemd-run >/dev/null 2>&1 || { echo "systemd-run is missing, so a run that dies mid-change could not be undone"; return 0; }
  grep -q '^    bridge-restore)' "$DEST_PATH" 2>/dev/null || { echo "$DEST_PATH has no bridge-restore (run: $DEST_PATH self-update)"; return 0; }
  [[ "$(toml_top "$BRIDGE_CONF" client_params_path)" == "$BRIDGE_ETC/client_bridge_params.json" ]] \
    || { echo "client_params_path in $BRIDGE_CONF is not $BRIDGE_ETC/client_bridge_params.json"; return 0; }
  return 0
}

# Run bridge-cfg on copies and check them. args: work dir, bridge-cfg, node config, wanted transports
# stdout: the files that differ ("bridges.toml", "client_bridge_params.json", "keys/<new>"), one per line
# return 0 = staged and valid (no output = nothing to change), 1 = refuse (reason logged)
bridge_cfg_stage() {
  local w="$1" cfg="$2" node="$3" wanted="$4" name port out rc f lp sp want_ports quic_live quic_t quic_v2 nb
  rm -rf "$w/etc" "$w/tmp" "$w/node.toml"; mkdir -p "$w/tmp"; chmod 0700 "$w" "$w/tmp"
  cp -a "$BRIDGE_ETC" "$w/etc" || return 1
  cp -a "$node" "$w/node.toml" || return 1
  # the helper's own step: append each missing transport (same block it writes)
  while read -r name port; do
    [[ -n "${name:-}" ]] || continue
    if grep -Eq "^[[:space:]]*transport_type[[:space:]]*=[[:space:]]*[\"']$name[\"']" "$w/etc/bridges.toml"; then continue; fi
    if [[ -n "$(ss -Hltn "sport = :$port" 2>/dev/null)" ]]; then log "[bridge-cfg] tcp/$port is already in use on this host; not adding $name"; return 1; fi
    printf '\n[[transports]]\ntransport_type = "%s"\n[transports.args]\nlisten = "[::]:%s"\n' "$name" "$port" >> "$w/etc/bridges.toml"
  done <<<"$wanted"
  # bridge-cfg sees the copies at the real paths, so every path it embeds is the real one
  out="$(unshare -m --propagation private /bin/bash -c '
          mount --bind "$1" /etc/nym && mount --bind "$2" "$3" || exit 97
          TMPDIR="$4" exec timeout 120 "$5" --gen -i /etc/nym/bridges.toml -n "$3" -d /etc/nym -o /etc/nym/bridges.toml
        ' _ "$w/etc" "$w/node.toml" "$node" "$w/tmp" "$cfg" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -v -iE 'client_auth_key|private' | sed 's/^/[bridge-cfg]   /' >> "$LOGFILE" 2>/dev/null || true
  # bridge-cfg exits 0 on its handled errors: the log line and the output decide
  if (( rc != 0 )) || printf '%s' "$out" | grep -qiE 'config adaptation failed|panicked'; then log "[bridge-cfg] bridge-cfg failed (exit $rc)"; return 1; fi

  # 1. every key file that exists now is unchanged (the QUIC key above all)
  for f in "$BRIDGE_ETC"/keys/*; do
    [[ -e "$f" ]] || continue
    cmp -s "$f" "$w/etc/keys/$(basename "$f")" || { log "[bridge-cfg] existing key $(basename "$f") would change; refusing"; return 1; }
  done
  # 2. forward, public IPs and client params path unchanged
  for f in public_ips client_params_path; do
    [[ "$(toml_top "$BRIDGE_CONF" "$f")" == "$(toml_top "$w/etc/bridges.toml" "$f")" ]] || { log "[bridge-cfg] $f would change; refusing"; return 1; }
  done
  [[ "$(toml_in "$BRIDGE_CONF" forward address)" == "$(toml_in "$w/etc/bridges.toml" forward address)" ]] \
    || { log "[bridge-cfg] forward.address would change ($(toml_in "$BRIDGE_CONF" forward address) -> $(toml_in "$w/etc/bridges.toml" forward address)); refusing"; return 1; }
  # 3. the nym-node config already points at the client params, so it is never installed
  [[ "$(toml_in "$node" gateway_tasks.storage_paths bridge_client_params)" == "$BRIDGE_ETC/client_bridge_params.json" ]] \
    || { log "[bridge-cfg] the nym-node config does not serve $BRIDGE_ETC/client_bridge_params.json (bridge_client_params); set it and restart nym-node first"; return 1; }
  # 4. the bridge parses the staged config and listens on the old ports plus the new ones
  lp="$(timeout 10 "$BRIDGE_BIN" --config "$BRIDGE_CONF" --print-ports 2>/dev/null | sort -u)" || { log "[bridge-cfg] the bridge cannot print its current ports"; return 1; }
  sp="$(timeout 10 "$BRIDGE_BIN" --config "$w/etc/bridges.toml" --print-ports 2>/dev/null | sort -u)" || { log "[bridge-cfg] the bridge does not parse the staged config; refusing"; return 1; }
  want_ports="$( { printf '%s\n' "$lp"; while read -r name port; do [[ -n "${port:-}" ]] && echo "$port/tcp"; done <<<"$wanted"; } | grep . | sort -u)"
  [[ "$sp" == "$want_ports" ]] || { log "[bridge-cfg] staged ports [$(echo $sp)] are not the expected [$(echo $want_ports)]; refusing"; return 1; }
  # 5. client params: "transports" is exactly the old QUIC entry (old apps reject anything else),
  #    "transports_v2" holds that same QUIC entry and every wanted transport
  quic_live="$(jq -cS '[.transports[]? | select(.transport_type=="quic_plain")]' "$BRIDGE_ETC/client_bridge_params.json" 2>/dev/null)"
  quic_t="$(jq -cS '.transports' "$w/etc/client_bridge_params.json" 2>/dev/null)"
  quic_v2="$(jq -cS '[.transports_v2[]? | select(.transport_type=="quic_plain")]' "$w/etc/client_bridge_params.json" 2>/dev/null)"
  [[ -n "$quic_live" && "$quic_live" != "[]" && "$quic_t" == "$quic_live" && "$quic_v2" == "$quic_live" ]] \
    || { log "[bridge-cfg] the staged QUIC entry differs from the published one; refusing"; return 1; }
  while read -r name port; do
    [[ -n "${name:-}" ]] || continue
    nb="$(jq -r --arg t "$name" '[.transports_v2[]? | select(.transport_type==$t) | .args.id_pubkey // empty] | length' "$w/etc/client_bridge_params.json" 2>/dev/null)"
    [[ "$nb" == 1 ]] || { log "[bridge-cfg] staged transports_v2 has no single $name entry with a key; refusing"; return 1; }
  done <<<"$wanted"
  if grep -q '^ssh_plain' <<<"$wanted" && ! grep -q 'client_auth_key' "$w/etc/bridges.toml"; then log "[bridge-cfg] staged ssh_plain has no client_auth_key; refusing"; return 1; fi
  # 6. only the expected files changed; anything else is a surprise
  ( cd "$w/etc" && find . -type f | sed 's#^\./##' ) | while read -r f; do
    if [[ ! -e "$BRIDGE_ETC/$f" ]] || ! cmp -s "$BRIDGE_ETC/$f" "$w/etc/$f"; then
      case "$f" in bridges.toml|client_bridge_params.json|keys/tls_*|keys/ssh_*) echo "$f" ;; *) echo "UNEXPECTED:$f" ;; esac
    fi
  done > "$w/changed"
  if grep -q '^UNEXPECTED:' "$w/changed"; then log "[bridge-cfg] unexpected staged changes: $(grep '^UNEXPECTED:' "$w/changed" | tr '\n' ' '); refusing"; return 1; fi
  # bridges.toml is always rewritten by bridge-cfg; without a new transport or key it is not a change
  if [[ "$(grep -v '^bridges.toml$' "$w/changed" | grep -c .)" == 0 ]] \
     && jq -e -S --slurpfile a "$BRIDGE_ETC/client_bridge_params.json" '. == $a[0]' "$w/etc/client_bridge_params.json" >/dev/null 2>&1; then
    : > "$w/changed"
  fi
  cat "$w/changed"
}

# Install one staged file by rename, with the owner and mode of a reference file. "secret" clears the
# bits for others: new private keys (reference: the QUIC key file) and bridges.toml (which now holds
# the SSH client_auth_key) are never readable by everyone, whatever the reference allowed.
# args: staged path, live path, reference file, [secret]
bridge_install_file() {
  local src="$1" dst="$2" ref="$3" own mode tmp
  own="$(stat -c '%u:%g' "$ref")" && mode="$(stat -c '%a' "$ref")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  if [[ "${4:-}" == secret ]]; then mode="$(printf '%o' $(( 8#$mode & 8#0770 )))"; fi
  tmp="$(dirname "$dst")/.$(basename "$dst").nau-new"
  install -m "$mode" -o "${own%:*}" -g "${own#*:}" "$src" "$tmp" && mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

# TLS on <port> serves the published key: the certificate's ed25519 key equals the tls_plain id_pubkey.
bridge_check_tls() {      # args: port, client params file
  local want host got
  want="$(jq -r '.transports_v2[]? | select(.transport_type=="tls_plain") | .args.id_pubkey' "$2")"
  host="$(jq -r '.transports_v2[]? | select(.transport_type=="tls_plain") | .args.host // empty' "$2")"
  got="$(timeout 10 openssl s_client -connect "127.0.0.1:$1" ${host:+-servername "$host"} </dev/null 2>/dev/null \
         | openssl x509 -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | tail -c 32 | base64 -w0)"
  [[ -n "$want" && "$got" == "$want" ]] && return 0
  log "  TLS on tcp/$1 does not serve the published key"; return 1
}
# SSH on <port> answers with SSH-2.0 and its ed25519 host key equals the ssh_plain id_pubkey.
bridge_check_ssh() {      # args: port, client params file
  local want banner got
  want="$(jq -r '.transports_v2[]? | select(.transport_type=="ssh_plain") | .args.id_pubkey' "$2")"
  # head -n1 returns at the first line; the server sends its banner first and then waits for ours
  banner="$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && head -n1 <&3" 2>/dev/null | tr -d '\r')"
  got="$(ssh-keyscan -T 5 -t ed25519 -p "$1" 127.0.0.1 2>/dev/null | awk '$2=="ssh-ed25519" {print $3; exit}' | base64 -d 2>/dev/null | tail -c 32 | base64 -w0)"
  [[ "$banner" == SSH-2.0-* && -n "$want" && "$got" == "$want" ]] && return 0
  log "  SSH on tcp/$1 does not serve the published key (banner: ${banner:-none})"; return 1
}

# Snapshot of everything this change touches: /etc/nym as a tar with owners and modes, its path list
# (so a restore also removes what appeared), path/type/mode/owner and sha256 lists (to prove a restore
# is exact), and the unit drop-in: its copy, or a marker that there was none.
bridge_meta() { ( cd / && find "${BRIDGE_ETC#/}" -mindepth 1 -printf '%p %y %m %U %G\n' | sort ); }
bridge_sums() { ( cd / && find "${BRIDGE_ETC#/}" -mindepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum ); }
bridge_snapshot() {       # arg: dir
  local d="$1" di
  rm -rf "$d"; mkdir -p "$d" && chmod 0700 "$d" || return 1
  tar -C / -cpf "$d/etc-nym.tar" "${BRIDGE_ETC#/}" 2>/dev/null || return 1
  ( cd / && find "${BRIDGE_ETC#/}" -mindepth 1 | sort ) > "$d/manifest" && [[ -s "$d/manifest" ]] || return 1
  bridge_meta > "$d/meta" && bridge_sums > "$d/sums" && [[ -s "$d/meta" && -s "$d/sums" ]] || return 1
  di="/etc/systemd/system/$BRIDGE_UNIT.d"
  [[ -d "$di" ]] || touch "$d/dropin_dir_absent"
  if [[ -e "$di/$BRIDGE_DROPIN_NAME" || -L "$di/$BRIDGE_DROPIN_NAME" ]]; then
    cp -a "$di/$BRIDGE_DROPIN_NAME" "$d/dropin" && [[ -e "$d/dropin" || -L "$d/dropin" ]] || return 1
  else
    touch "$d/dropin_absent" || return 1
  fi
  jq -cS '[.transports[]? | select(.transport_type=="quic_plain")]' "$BRIDGE_ETC/client_bridge_params.json" > "$d/quic" 2>/dev/null || return 1
  # the restart policy systemd actually applies to the unit now, to prove the unit is back after a restore
  systemctl show -p Restart -p RestartUSec "$BRIDGE_UNIT" > "$d/unit_restart" 2>/dev/null && [[ -s "$d/unit_restart" ]] || return 1
}
bridge_restore() {        # arg: dir ; return 1 if any part failed, /etc/nym differs from the snapshot, or QUIC is not back
  local d="$1" f err="" di
  [[ -s "$d/etc-nym.tar" && -s "$d/manifest" && -s "$d/meta" && -s "$d/sums" ]] || { log "[bridge-cfg] restore: no complete snapshot in $d"; return 1; }
  # remove what appeared since the snapshot, deepest first, in this shell so every failure counts
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -d "/$f" && ! -L "/$f" ]]; then rm -rf -- "/$f" || err="$err rm:/$f"; else rm -f -- "/$f" || err="$err rm:/$f"; fi
  done < <(cd / && find "${BRIDGE_ETC#/}" -mindepth 1 | sort -r | grep -vxF -f "$d/manifest" || true)
  tar -C / -xpf "$d/etc-nym.tar" 2>/dev/null || err="$err tar"
  # the drop-in: put back the old one, or remove ours; a snapshot that does not say is an error
  di="/etc/systemd/system/$BRIDGE_UNIT.d"
  if [[ -e "$d/dropin" || -L "$d/dropin" ]]; then cp -a "$d/dropin" "$di/$BRIDGE_DROPIN_NAME" || err="$err dropin"
  elif [[ -e "$d/dropin_absent" ]]; then rm -f -- "$di/$BRIDGE_DROPIN_NAME" || err="$err dropin"
  else err="$err dropin-state-unknown"; fi
  if [[ -e "$d/dropin_dir_absent" && -d "$di" ]]; then rmdir -- "$di" 2>/dev/null || err="$err dropin-dir"; fi
  # /etc/nym must now be exactly the snapshot: same paths, types, modes, owners, file contents
  [[ "$(bridge_meta)" == "$(cat "$d/meta")" ]] || err="$err meta-differs"
  [[ "$(bridge_sums)" == "$(cat "$d/sums")" ]] || err="$err contents-differ"
  # without a reload systemd keeps running the unit with the drop-in it loaded, whatever is on disk
  systemctl daemon-reload >/dev/null 2>&1 || err="$err daemon-reload"
  [[ "$(systemctl show -p Restart -p RestartUSec "$BRIDGE_UNIT" 2>/dev/null)" == "$(cat "$d/unit_restart" 2>/dev/null)" ]] || err="$err unit-restart-policy-differs"
  systemctl restart "$BRIDGE_UNIT" >/dev/null 2>&1 || err="$err restart"
  if is_healthy "$BRIDGE_UNIT" "$BRIDGE_BIN" "" && bridge_listening "$BRIDGE_UNIT" "$BRIDGE_BIN" \
     && [[ "$(jq -cS '[.transports[]? | select(.transport_type=="quic_plain")]' "$BRIDGE_ETC/client_bridge_params.json" 2>/dev/null)" == "$(cat "$d/quic")" ]]; then :
  else err="$err quic-not-back"; fi
  if [[ -n "$err" ]]; then log "[bridge-cfg] restore from $d INCOMPLETE, failed:$err"; return 1; fi
  log "[bridge-cfg] restored $BRIDGE_ETC and the bridge unit from $d; QUIC is back"
}
bridge_deadman_arm() {    # args: snapshot dir [seconds]
  bridge_deadman_disarm
  systemd-run --quiet --unit="$BRIDGE_DEADMAN_UNIT" --on-active="${2:-900}" "$DEST_PATH" bridge-restore "$1" >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$BRIDGE_DEADMAN_UNIT.timer" 2>/dev/null
}
bridge_deadman_disarm() {
  systemctl stop "$BRIDGE_DEADMAN_UNIT.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "$BRIDGE_DEADMAN_UNIT.timer" "$BRIDGE_DEADMAN_UNIT.service" >/dev/null 2>&1 || true
}
bridge_record_fail() {    # arg: key ; stdout: count
  local k="$1" n="" ts=""
  read -r _ n ts <<<"$(awk -v k="$k" '$1==k' "$BRIDGE_CFG_FAILED" 2>/dev/null)" || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1)); printf '%s %s %s\n' "$k" "$n" "$(date -u +%s)" > "$BRIDGE_CFG_FAILED"; printf '%s\n' "$n"
}
# Same markers as the NTM snapshot: done, fired, counted, applying, alerted.
bridge_settle_restore() { # arg: snapshot dir ; restore under the lock unless settled; used by the timer and by recovery
  local d="$1" restored=0 n=""
  exec 7>"$d/.lock"
  if ! flock -w "$NTM_LOCK_WAIT" 7; then log "[bridge-cfg] could not take $d/.lock"; return 1; fi
  if [[ -e "$d/done" ]]; then exec 7>&-; return 0; fi
  if [[ ! -e "$d/applying" ]]; then touch "$d/done"; exec 7>&-; return 0; fi
  touch "$d/fired"
  if bridge_restore "$d"; then touch "$d/done"; restored=1; fi
  if [[ ! -e "$d/counted" ]]; then n="$(bridge_record_fail "$(cat "$d/key" 2>/dev/null || echo unknown)")"; touch "$d/counted"; fi
  exec 7>&-
  if (( restored == 1 )); then notify rollback "A bridge configuration change never settled; restored /etc/nym, QUIC is up${n:+ (failure $n)}"; return 0; fi
  [[ -e "$d/alerted" ]] || { touch "$d/alerted"; notify failed "CRITICAL: a bridge configuration change never settled and restoring $d fails; MANUAL INTERVENTION NEEDED"; }
  return 1
}
bridge_recover_pending() {     # like ntm_recover_pending, for the bridge snapshot
  [[ -d "$BRIDGE_SNAP" && ! -e "$BRIDGE_SNAP/done" ]] || return 0
  if [[ ! -e "$BRIDGE_SNAP/applying" ]]; then log "[bridge-cfg] removing a snapshot never used for a change"; bridge_deadman_disarm; rm -rf "$BRIDGE_SNAP"; return 0; fi
  log "[bridge-cfg] an earlier bridge configuration change never settled; restoring its snapshot first"
  if bridge_settle_restore "$BRIDGE_SNAP"; then bridge_deadman_disarm; return 0; fi
  return 1
}

# `bridge-plan`: everything up to the staged, checked copies, then print what would change.
# Runs bridge-cfg on copies only; nothing on the host changes. Secrets are not printed.
bridge_plan() {
  local btag href block node work="$STATE_DIR/bridge-plan" wanted changed
  btag="$(cat "$BRIDGE_STATE_TAG" 2>/dev/null || true)"
  [[ -n "${BRIDGE_UNIT:-}" && "$btag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "no QUIC bridge release recorded on this host"; return 1; }
  href="$(bridge_helper_ref)" || { echo "could not resolve the bridge helper on $REPO@$NTM_BRANCH"; return 1; }
  block="$(bridge_cfg_preflight)"; [[ -z "$block" ]] || { echo "would not configure: $block"; return 1; }
  node="$(bridge_node_cfg)" || { echo "the nym-node config.toml of this bridge is not unique"; return 1; }
  rm -rf "$work"; mkdir -p "$work" && chmod 0700 "$work" || return 1
  gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 -o "$work/helper.sh" \
        "https://raw.githubusercontent.com/$REPO/$href/$BRIDGE_HELPER_PATH" || { echo "could not download the helper"; rm -rf "$work"; return 1; }
  wanted="$(bridge_wanted_transports "$work/helper.sh")"
  echo "bridge $btag, helper ${href:0:12}, node config $node"
  echo "wanted transports: $(echo $wanted)"
  bridge_cfg_fetch "$btag" "$work/bridge-cfg" || { echo "no verified bridge-cfg for $btag"; rm -rf "$work"; return 1; }
  echo "bridge-cfg $btag: sha256 $(sha256sum "$work/bridge-cfg" | cut -c1-16)... verified against the published digest"
  if ! changed="$(bridge_cfg_stage "$work" "$work/bridge-cfg" "$node" "$wanted")"; then
    echo "the staged configuration FAILS its checks:"; printf '%s\n' "$changed" | grep -v '^$' | sed 's/^/  /'; rm -rf "$work"; return 1
  fi
  echo "staged configuration passes its checks"
  echo "would change: $(echo ${changed:-nothing})"
  echo "transports (old apps): $(jq -r '[.transports[]?.transport_type] | join(" ")' "$work/etc/client_bridge_params.json")"
  echo "transports_v2:         $(jq -r '[.transports_v2[]?.transport_type] | join(" ")' "$work/etc/client_bridge_params.json")"
  echo "staged ports:          $(timeout 10 "$BRIDGE_BIN" --config "$work/etc/bridges.toml" --print-ports 2>/dev/null | tr '\n' ' ')"
  rm -rf "$work"
}

maybe_configure_bridge() {
  [[ "$BRIDGE_CFG_ENABLED" == 1 && -n "${BRIDGE_UNIT:-}" && -n "${BRIDGE_BIN:-}" ]] || return 0
  bridge_recover_pending || return 2
  local btag href key applied fn="" fts="" now wait_h block work="$STATE_DIR/bridge-work" node wanted changed f ok=1 n="" restored=1 p
  btag="$(cat "$BRIDGE_STATE_TAG" 2>/dev/null || true)"
  [[ "$btag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0            # bridge release not known yet
  if [[ "$(printf '%s\n%s\n' "v0.3.0" "$btag" | sort -V | head -n1)" != "v0.3.0" ]]; then return 0; fi   # TLS/SSH need bridge-cfg >= 0.3.0
  href="$(bridge_helper_ref || true)"
  [[ -n "$href" ]] || { log "[bridge-cfg] could not resolve the bridge helper on $REPO@$NTM_BRANCH; will retry next run"; return 0; }
  key="$btag+$href"
  applied="$(cat "$BRIDGE_CFG_STATE" 2>/dev/null || true)"
  [[ "$applied" != "$btag $href" ]] || return 0
  read -r _ fn fts <<<"$(awk -v k="$key" '$1==k' "$BRIDGE_CFG_FAILED" 2>/dev/null)" || true
  if [[ "$fn" =~ ^[0-9]+$ && "$fts" =~ ^[0-9]+$ && "${NAU_MANUAL:-0}" != "1" ]]; then
    (( fn >= NTM_MAX_TRIES )) && { log "[bridge-cfg] configuring $key failed $fn times; not retrying it (a new bridge release or helper, or Update now in Nymi, will)"; return 0; }
    now="$(date -u +%s)"; wait_h=$(( 6 << (fn - 1) ))
    (( now - fts < wait_h * 3600 )) && { log "[bridge-cfg] configuring $key failed $fn time(s); next try in $(( wait_h - (now - fts) / 3600 ))h"; return 0; }
  fi
  log "[bridge-cfg] bridge configuration: bridge $btag, helper ${href:0:12} (applied: ${applied:-never})"

  block="$(bridge_cfg_preflight)"
  if [[ -z "$block" ]]; then node="$(bridge_node_cfg)" || block="the nym-node config.toml of this bridge is not unique under ~${SVC_USER:-root}/.nym/nym-nodes"; fi
  if [[ -n "$block" ]]; then
    log "[bridge-cfg] NOT configured: $block"
    [[ "$block" == "$(cat "$BRIDGE_CFG_BLOCK" 2>/dev/null || true)" ]] || { printf '%s\n' "$block" > "$BRIDGE_CFG_BLOCK"; notify failed "Bridge TLS/SSH not configured: $block"; }
    return 1
  fi
  rm -f "$BRIDGE_CFG_BLOCK"

  rm -rf "$work"; mkdir -p "$work" && chmod 0700 "$work" || return 0
  if ! gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 3 $RETRY_ALL --retry-delay 5 --max-time 120 \
         -o "$work/helper.sh" "https://raw.githubusercontent.com/$REPO/$href/$BRIDGE_HELPER_PATH"; then
    log "[bridge-cfg] could not download the helper @ ${href:0:12}; will retry next run"; rm -rf "$work"; return 0
  fi
  wanted="$(bridge_wanted_transports "$work/helper.sh")"
  if [[ -z "$wanted" ]]; then log "[bridge-cfg] the helper @ ${href:0:12} names no transports this updater knows (NEW_TRANSPORTS)"; n="$(bridge_record_fail "$key")"; rm -rf "$work"; return 1; fi
  if ! bridge_cfg_fetch "$btag" "$work/bridge-cfg"; then log "[bridge-cfg] no verified bridge-cfg for $btag; will retry next run"; rm -rf "$work"; return 0; fi

  if ! changed="$(bridge_cfg_stage "$work" "$work/bridge-cfg" "$node" "$wanted")"; then
    n="$(bridge_record_fail "$key")"
    notify failed "Bridge TLS/SSH not configured: the staged configuration failed its checks (failure $n of $NTM_MAX_TRIES). See $LOGFILE"
    rm -rf "$work"; return 1
  fi
  if [[ -z "$changed" ]]; then
    log "[bridge-cfg] already configured for $btag (helper ${href:0:12}); nothing to change"
    printf '%s %s\n' "$btag" "$href" > "$BRIDGE_CFG_STATE"; rm -f "$BRIDGE_CFG_FAILED"; rm -rf "$work"; return 0
  fi
  log "[bridge-cfg] staged and checked; changing: $(echo $changed)"

  # ---- from here the host changes ----
  if ! bridge_snapshot "$BRIDGE_SNAP"; then log "[bridge-cfg] could not snapshot $BRIDGE_ETC; not changed"; rm -rf "$work" "$BRIDGE_SNAP"; return 1; fi
  printf '%s\n' "$key" > "$BRIDGE_SNAP/key"
  if ! bridge_deadman_arm "$BRIDGE_SNAP"; then log "[bridge-cfg] could not arm the dead-man timer; not changed"; rm -rf "$work" "$BRIDGE_SNAP"; return 1; fi
  touch "$BRIDGE_SNAP/applying"

  # keys and bridges.toml first; the client params (what clients see) only after the checks.
  # a new private key gets the owner of the QUIC key file and never a mode readable by others
  p="$(bridge_quic_key_file "$BRIDGE_CONF")"
  if [[ -z "$p" || ! -f "$p" || -L "$p" ]]; then log "[bridge-cfg] the QUIC key file is gone (${p:-none})"; ok=0; fi
  if (( ok )); then
    for f in $changed; do
      case "$f" in keys/*) bridge_install_file "$work/etc/$f" "$BRIDGE_ETC/$f" "$p" secret || ok=0 ;; esac
    done
  fi
  (( ok )) && { bridge_install_file "$work/etc/bridges.toml" "$BRIDGE_CONF" "$BRIDGE_CONF" secret || ok=0; }
  if (( ok )); then
    f="/etc/systemd/system/$BRIDGE_UNIT.d"
    mkdir -p "$f" && printf '# written by nym-node-autoupdate: nym-bridge exits 0 when any listener fails, which\n# Restart=on-failure does not restart; QUIC must not stay down because TLS or SSH failed\n[Service]\nRestart=always\nRestartSec=5\n' \
      > "$f/.$BRIDGE_DROPIN_NAME.nau-new" && mv -f "$f/.$BRIDGE_DROPIN_NAME.nau-new" "$f/$BRIDGE_DROPIN_NAME" || ok=0
    systemctl daemon-reload >/dev/null 2>&1 || ok=0
  fi
  if (( ok )); then
    log "[bridge-cfg] restarting $BRIDGE_UNIT with the new transports"
    systemctl restart "$BRIDGE_UNIT" >/dev/null 2>&1 || ok=0
    (( ok )) && { is_healthy "$BRIDGE_UNIT" "$BRIDGE_BIN" "" && unit_runs_current_binary "$BRIDGE_UNIT" "$BRIDGE_BIN" && bridge_listening "$BRIDGE_UNIT" "$BRIDGE_BIN" || ok=0; }
  fi
  if (( ok )); then
    while read -r f p; do
      [[ -n "${f:-}" ]] || continue
      case "$f" in tls_plain) bridge_check_tls "$p" "$work/etc/client_bridge_params.json" || ok=0 ;; ssh_plain) bridge_check_ssh "$p" "$work/etc/client_bridge_params.json" || ok=0 ;; esac
      # the new port must get through this host's firewall, or clients would be sent to a dead end
      for ipx in iptables ip6tables; do
        command -v "$ipx" >/dev/null 2>&1 || continue
        [[ "$(fw_verdict "$ipx" tcp "$p")" == ACCEPT ]] || { log "  $ipx INPUT does not let tcp/$p in"; ok=0; }
      done
    done <<<"$wanted"
  fi
  # publish: install the client params, and nym-node (which reads the file per request) must serve them
  if (( ok )) && grep -qx 'client_bridge_params.json' <<<"$changed"; then
    bridge_install_file "$work/etc/client_bridge_params.json" "$BRIDGE_ETC/client_bridge_params.json" "$BRIDGE_ETC/client_bridge_params.json" || ok=0
    if (( ok )); then
      curl -fsS --max-time 8 "$NODE_HTTP/api/v1/bridges/client-params" 2>/dev/null \
        | jq -e -S --slurpfile a "$BRIDGE_ETC/client_bridge_params.json" '. == $a[0]' >/dev/null 2>&1 \
        || { log "  nym-node does not serve the new client params at $NODE_HTTP/api/v1/bridges/client-params"; ok=0; }
    fi
  fi

  exec 7>"$BRIDGE_SNAP/.lock"
  if ! flock -w "$NTM_LOCK_WAIT" 7; then
    exec 7>&-; log "[bridge-cfg] CRITICAL: could not take $BRIDGE_SNAP/.lock; left everything for the dead-man timer"
    notify failed "CRITICAL: bridge configuration could not settle (snapshot lock busy); the dead-man timer stays armed"; rm -rf "$work"; return 2
  fi
  if [[ -e "$BRIDGE_SNAP/fired" ]]; then
    ok=0; if [[ -e "$BRIDGE_SNAP/done" ]]; then restored=1; elif bridge_restore "$BRIDGE_SNAP"; then restored=1; touch "$BRIDGE_SNAP/done"; else restored=0; fi
  elif (( ok )); then
    touch "$BRIDGE_SNAP/done"
  else
    log "[bridge-cfg] the new configuration failed its checks; restoring $BRIDGE_ETC"
    if bridge_restore "$BRIDGE_SNAP"; then restored=1; touch "$BRIDGE_SNAP/done"; else restored=0; fi
  fi
  if (( ! ok )) && [[ ! -e "$BRIDGE_SNAP/counted" ]]; then n="$(bridge_record_fail "$key")"; touch "$BRIDGE_SNAP/counted"; fi
  exec 7>&-
  if [[ -e "$BRIDGE_SNAP/done" ]]; then bridge_deadman_disarm
  elif bridge_deadman_arm "$BRIDGE_SNAP" 120; then log "[bridge-cfg] restore incomplete; the dead-man timer tries again in 120s"
  else log "[bridge-cfg] CRITICAL: restore incomplete and no dead-man timer; the next hourly run retries"; notify failed "CRITICAL: bridge restore incomplete and no dead-man timer; the next hourly run retries"; fi

  if (( ok )); then
    printf '%s %s\n' "$btag" "$href" > "$BRIDGE_CFG_STATE"; rm -f "$BRIDGE_CFG_FAILED"
    log "[bridge-cfg] SUCCESS: bridge $btag serves $(echo $(jq -r '[.transports_v2[]?.transport_type] | join(" ")' "$BRIDGE_ETC/client_bridge_params.json")); QUIC key unchanged"
    notify success "Bridge $btag: TLS/SSH configured and published (helper ${href:0:12}); QUIC key unchanged"
    rm -rf "$work"; return 0
  fi
  if (( restored )); then
    notify rollback "Bridge TLS/SSH configuration failed its checks; /etc/nym restored, QUIC up${n:+ (failure $n of $NTM_MAX_TRIES)}. See $LOGFILE"; rm -rf "$work"; return 1
  fi
  log "[bridge-cfg] CRITICAL: the restore is incomplete - MANUAL INTERVENTION NEEDED (snapshot: $BRIDGE_SNAP)"
  notify failed "CRITICAL: bridge configuration failed AND the restore did not complete (snapshot $BRIDGE_SNAP)"
  rm -rf "$work"; return 2
}

# ------------------------- doctor: upstream drift check ----------------------
# The updater relies on how Nym publishes things: release tag prefixes and asset names, the path of
# the operator notes, the NTM path and its subcommands. Two of these changed in 2026 (bridge tags at
# 0.2, the docs path on 2026-10-14) and each time the updater just went quiet, with no error.
# doctor checks every one of these against GitHub. stdout: one "ok"/"WARN" line per check.
# arg: all | relevant (relevant = skip the bridge/NTM checks on a box without them). return 1 on WARN.
NTM_CMDS="complete_networking_configuration check_firewall_setup"
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
  if [[ "$scope" == "all" || "${NTM_ENABLED:-0}" == "1" ]]; then
    IFS=$'\t' read -r ref _ < <(ntm_upstream_ref) || ref=""
    for t in ${ref:-could-not-read-$NTM_BRANCH}; do
      tmp="$(mktemp 2>/dev/null)" || return 1
      if [[ -n "$ref" ]] && gcurl -fsSL --proto '=https' --retry 2 --max-time 120 -o "$tmp" "https://raw.githubusercontent.com/$REPO/$t/$NTM_REPO_PATH" 2>/dev/null; then
        miss=""
        for c in $NTM_CMDS; do grep -qE "^[[:space:]]*\"?$c\"?[[:space:]]*(\)|\|)" "$tmp" || miss="$miss $c"; done
        if [[ -n "$miss" ]]; then echo "WARN NTM: $NTM_BRANCH @ ${t:0:12} lacks subcommand(s):$miss"; warn=1
        else echo "ok   NTM: $NTM_BRANCH @ ${t:0:12} has the subcommands the updater calls"; fi
      else
        echo "WARN NTM: could not read $NTM_REPO_PATH on $NTM_BRANCH (${t:0:12})"; warn=1
      fi
      rm -f "$tmp"
    done
  fi
  # bridge helper: on $NTM_BRANCH, and its NEW_TRANSPORTS still names transports this updater knows
  if [[ "$scope" == "all" || -n "${BRIDGE_UNIT:-}" ]]; then
    ref="$(bridge_helper_ref || true)"
    tmp="$(mktemp 2>/dev/null)" || return 1
    if [[ -n "$ref" ]] && gcurl -fsSL --proto '=https' --retry 2 --max-time 120 -o "$tmp" "https://raw.githubusercontent.com/$REPO/$ref/$BRIDGE_HELPER_PATH" 2>/dev/null; then
      t="$(bridge_wanted_transports "$tmp" | awk '{print $1 ":" $2}' | tr '\n' ' ')"
      if [[ -n "$t" ]]; then echo "ok   bridge helper: $NTM_BRANCH @ ${ref:0:12} wants ${t% }"
      else echo "WARN bridge helper: $NTM_BRANCH @ ${ref:0:12} has no NEW_TRANSPORTS this updater knows (changed?)"; warn=1; fi
    else
      echo "WARN bridge helper: could not read $BRIDGE_HELPER_PATH on $NTM_BRANCH"; warn=1
    fi
    rm -f "$tmp"
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
    # the bridge setup is done by maybe_configure_bridge (its own checks and rollback)
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
  local node_rc=0 bridge_rc=0 ntm_rc=0 api_rc=0 bcfg_rc=0
  # an NTM apply or a bridge configuration change that never settled is restored before anything
  # else changes on this host; while that fails, this run changes nothing else either
  if ! ntm_recover_pending || ! bridge_recover_pending; then
    log "run stopped: an unsettled NTM or bridge change could not be restored (see above); nothing else was changed"
    printf '%s\n' 2 > "$STATE_DIR/last_node_rc" 2>/dev/null || true
    exit 2
  fi

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
    # after NTM: its firewall opens the bridge's TCP ports, which the bridge step checks
    if [[ -n "${BRIDGE_UNIT:-}" ]] && systemctl cat "$BRIDGE_UNIT" >/dev/null 2>&1 \
          && [[ -n "${BRIDGE_BIN:-}" && -x "${BRIDGE_BIN:-}" ]]; then
      maybe_configure_bridge || bcfg_rc=$?
    fi

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

  log "run complete (nym-node rc=$node_rc, nym-bridge rc=$bridge_rc, ntm rc=$ntm_rc, bridge-cfg rc=$bcfg_rc, nym-api rc=$api_rc)"
  # read by cmd_poll for the bot: the box's main component (nym-node, or nym-api on an api-only box)
  printf '%s\n' "$( [[ -n "$UNIT" ]] && echo "$node_rc" || echo "$api_rc" )" > "$STATE_DIR/last_node_rc" 2>/dev/null || true
  if (( node_rc != 0 || bridge_rc != 0 || ntm_rc != 0 || bcfg_rc != 0 || api_rc != 0 )); then exit 1; fi
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
  if [[ "$ntm_en" == "1" ]]; then
    echo "  tunnel (NTM)  : exit gateway (iface ${ntm_iface}) -> checked per release; runs nymtech NTM as root (no upstream checksum)"
  else
    echo "  tunnel (NTM)  : not an exit gateway -> NTM step skipped"
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
      read -rp "  enable NTM tunnel checks? (1/0) [${ntm_en}]: " a; ntm_en="${a:-$ntm_en}"
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
  # Telegram alerts: prefer env, else preserve whatever is already saved (so re-install keeps them).
  local tg_token="${NYM_TELEGRAM_BOT_TOKEN:-}" tg_chat="${NYM_TELEGRAM_CHAT_ID:-}"
  if [[ -f "$CONFIG_FILE" ]]; then
    [[ -n "$tg_token" ]] || tg_token="$(sed -n 's/^TELEGRAM_BOT_TOKEN="\(.*\)"$/\1/p' "$CONFIG_FILE" | head -n1)"
    [[ -n "$tg_chat"  ]] || tg_chat="$(sed -n 's/^TELEGRAM_CHAT_ID="\(.*\)"$/\1/p'  "$CONFIG_FILE" | head -n1)"
  fi
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

  if [[ "${NTM_ENABLED:-0}" == "1" && -n "$lt" ]]; then
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
  if [[ "${NTM_ENABLED:-0}" == "1" ]]; then
    echo "tunnel (NTM)  : enabled  iface=${NTM_IFACE:-nymtun0}  script=${NTM_PATH:-<?>}"
    echo "ntm last_tag  : $(cat "$NTM_STATE" 2>/dev/null || echo '<none>')"
  else
    echo "tunnel (NTM)  : disabled (no $NTM_IFACE interface / not an exit gateway)"
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
    ntm-restore)   # only for the dead-man timer: an NTM apply died before its checks finished
      need_root "$@"
      [[ "${2:-}" == "$STATE_DIR/ntm-snapshot" ]] || { echo "usage: $0 ntm-restore $STATE_DIR/ntm-snapshot"; exit 1; }
      resolve_target
      ntm_deadman_fire "$2" ;;
    bridge-plan)      # show what the bridge configuration step would change; changes nothing
      need_root "$@"; require_cmds curl jq sha256sum
      resolve_target; bridge_plan; exit $? ;;
    bridge-restore)   # only for the bridge dead-man timer: a bridge configuration change did not settle
      need_root "$@"
      [[ "${2:-}" == "$BRIDGE_SNAP" ]] || { echo "usage: $0 bridge-restore $BRIDGE_SNAP"; exit 1; }
      resolve_target
      bridge_settle_restore "$2" ;;
    self-update|selfupdate|update-self) cmd_self_update "$@" ;;
    version|--version|-v) echo "nym-node-autoupdate $SCRIPT_VERSION" ;;
    *) echo "usage: $0 {install|run|check|doctor|status|pair|self-update|version|poll|bridge-plan|uninstall}"; exit 1 ;;
  esac
}
main "$@"
