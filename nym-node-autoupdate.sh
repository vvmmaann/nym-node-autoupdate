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
#   nym-node-autoupdate.sh uninstall  # remove the timer (leaves config, state and binaries alone)
#
set -euo pipefail
# Ensure sbin dirs are on PATH so `ip`, `iptables-save`, etc. resolve even for a non-root check/status.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ------------------------------- configuration -------------------------------
REPO="nymtech/nym";          TAG_PREFIX="nym-binaries-v";    ASSET="nym-node"
BRIDGE_REPO="nymtech/nym-bridges"; BRIDGE_TAG_PREFIX="bridge-binaries-v"; BRIDGE_ASSET="nym-bridge"
NTM_REPO_PATH="scripts/nym-node-setup/network-tunnel-manager.sh"  # tunnel manager, from $REPO

MIN_AGE_HOURS="${NYM_MIN_AGE_HOURS:-2}"     # ignore releases younger than this (soak delay)
HEALTH_WAIT="${NYM_HEALTH_WAIT:-25}"        # seconds to wait after restart before health check
KEEP_BACKUPS="${NYM_KEEP_BACKUPS:-3}"       # how many old binaries to keep, per component
# fall back to defaults on non-numeric input, else sleep/arithmetic would abort under set -e/-u
[[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || MIN_AGE_HOURS=2
[[ "$HEALTH_WAIT"   =~ ^[0-9]+$ ]] || HEALTH_WAIT=25
[[ "$KEEP_BACKUPS"  =~ ^[0-9]+$ ]] || KEEP_BACKUPS=3
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
# operator-facing changelog (docs). the release git tag is cut BEFORE its docs section is written,
# so the section is read from the docs branch, not the tag. official nym source, trusted.
OP_CHANGELOG_PATH="documentation/docs/pages/operators/changelog.mdx"
OP_CHANGELOG_REFS="${NYM_DOCS_REFS:-main develop}"
ACTIONS_STATE="$STATE_DIR/actions_last_tag"
CHANGELOG_ACTIONS="${NYM_CHANGELOG_ACTIONS:-0}"   # 0 = report only (SAFE DEFAULT). Was 1; auto-eval of commands pulled from a mutable docs branch is a root-RCE risk (deny-list is bypassable), so it is OFF unless explicitly opted in.

# Optional Telegram alerts. Both must be set (in the config, or via these env vars at install) to
# enable; empty = alerts stay off. The config, which stores them, is written 0600 (root-only).
TELEGRAM_BOT_TOKEN="${NYM_TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${NYM_TELEGRAM_CHAT_ID:-}"

# Nymi (shared Telegram bot) endpoints. The node never holds a bot token - it
# tells the hub "this node belongs to @nick" and asks "was I asked to update?".
NYMI_HUB_BASE="${NYM_NYMI_HUB:-https://nymcheckby.unclelem.uk/nymi}"

SELF_PATH="$(readlink -f "$0")"
DEST_PATH="/usr/local/sbin/nym-node-autoupdate.sh"

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
  touch "$FAILED_TAGS" "$BRIDGE_FAILED_TAGS" 2>/dev/null || true
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
  [[ -n "${BIN:-}" ]]         || BIN="$(detect_bin "$UNIT")"
  [[ -n "${SVC_USER:-}" ]]    || SVC_USER="$(detect_user "$UNIT")"
  [[ -n "${BRIDGE_UNIT:-}" ]] || BRIDGE_UNIT="$(detect_bridge_unit)"
  if [[ -n "${BRIDGE_UNIT:-}" && -z "${BRIDGE_BIN:-}" ]]; then BRIDGE_BIN="$(detect_bridge_bin "$BRIDGE_UNIT")"; fi
  [[ -n "${ROLE:-}" ]]        || ROLE="$(detect_role "$UNIT")"
  if [[ -z "${NTM_ENABLED:-}" ]]; then IFS=$'\t' read -r NTM_ENABLED NTM_PATH NTM_IFACE < <(detect_ntm) || true; fi
  [[ -n "${NTM_IFACE:-}" ]] || NTM_IFACE="nymtun0"
  [[ "$NTM_IFACE" =~ ^[a-zA-Z0-9._-]+$ ]] || NTM_IFACE="nymtun0"   # sanity: never let junk reach iptables/ip
  [[ -n "${NTM_PATH:-}" ]]  || NTM_PATH="/usr/local/sbin/network-tunnel-manager.sh"
  [[ -n "${SVC_SCOPE:-}" ]] || SVC_SCOPE="system"
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

# is_healthy <unit> <bin> <expected_version_or_empty> - active at two samples ~8s apart, with no
# restart between them (crash-loop guard). Works for Type=simple/forking/notify/oneshot+RemainAfterExit
# (does NOT demand SubState=running or a live main PID, which false-fail healthy non-simple units).
is_healthy() {
  local u="$1" b="$2" expect="${3:-}" a1 a2 t1 t2 rv
  a1="$(sctl is-active "$u" 2>/dev/null || true)"
  t1="$(sctl show -p ActiveEnterTimestampMonotonic --value "$u" 2>/dev/null || echo 0)"
  sleep 8
  a2="$(sctl is-active "$u" 2>/dev/null || true)"
  t2="$(sctl show -p ActiveEnterTimestampMonotonic --value "$u" 2>/dev/null || echo 0)"
  [[ "$a1" == "active" && "$a2" == "active" ]] || return 1
  [[ "$t1" == "$t2" ]] || return 1
  if [[ -n "$expect" ]]; then
    rv="$(bin_version "$b")"
    [[ -z "$rv" || "$rv" == "$expect" ]] || return 1   # unparseable version = inconclusive = pass
  fi
  return 0
}

# ----------------------- the generic component updater ----------------------
# update_component <name> <repo> <tagprefix> <asset> <bin> <unit> <statefile> <failedfile> <smoke>
#   smoke = "version" (nym-node: must report a build version; refuses install without a checksum)
#         | "runs"    (nym-bridge: --help must work; no upstream checksum, HTTPS+smoke only)
# Returns: 0 = updated or nothing-to-do; 1 = aborted/rolled-back (service up); 2 = critical.
update_component() {
  local NAME="$1" CREPO="$2" CPREF="$3" CASSET="$4" CBIN="$5" CUNIT="$6" CSTATE="$7" CFAILED="$8" SMODE="$9"
  local curver=""
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

    log "[$NAME] stopping $CUNIT"
    sctl stop "$CUNIT" || log "[$NAME] warning: stop returned non-zero"
    if ! mv -f "$staged" "$CBIN"; then
      log "[$NAME] atomic swap failed; restoring previous binary"
      rm -f "$staged" 2>/dev/null || true
      cp -a "$backup" "$CBIN" 2>/dev/null || log "[$NAME] CRITICAL: restore after failed swap failed ($backup -> $CBIN)"
      sctl start "$CUNIT" || true; rc=1; break
    fi
    log "[$NAME] installed new binary; starting $CUNIT"
    sctl start "$CUNIT" || log "[$NAME] warning: start returned non-zero"

    sleep "$HEALTH_WAIT"
    if is_healthy "$CUNIT" "$CBIN" "$newver"; then
      printf '%s\n' "$tag" > "$CSTATE"
      log "[$NAME] SUCCESS: $CUNIT healthy on ${newver:-$tag}"
      notify success "$NAME updated to ${newver:-$tag} and healthy"
      ls -1t "$BACKUP_DIR/${NAME}."* 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f || true
      rc=0; break
    fi

    # rollback: restore the previous binary (atomically), record the failure, verify just as strictly
    log "[$NAME] HEALTH CHECK FAILED for $tag; ROLLING BACK to previous binary"
    sctl stop "$CUNIT" || true
    if cp -a "$backup" "$dir/.nau-rb.$$" 2>/dev/null && mv -f "$dir/.nau-rb.$$" "$CBIN" 2>/dev/null; then :; else
      log "[$NAME] CRITICAL: rollback restore failed ($backup -> $CBIN)"; rm -f "$dir/.nau-rb.$$" 2>/dev/null || true
    fi
    sctl start "$CUNIT" || true
    record_fail "$CFAILED" "$tag"
    sleep "$HEALTH_WAIT"
    if is_healthy "$CUNIT" "$CBIN" "$curver"; then
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
  local ver="$1" ref cl section
  for ref in $OP_CHANGELOG_REFS; do
    cl="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 60 \
          "https://raw.githubusercontent.com/$REPO/$ref/$OP_CHANGELOG_PATH" 2>/dev/null)" \
      || cl="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 60 \
          "https://raw.githubusercontent.com/$REPO/$ref/$OP_CHANGELOG_PATH" 2>/dev/null)" || continue
    section="$(printf '%s\n' "$cl" | awk -v pat="^## .v${ver}([^A-Za-z0-9]|$)" '
      $0 ~ pat {f=1; print; next}
      f && /^## .v20/ {exit}
      f {print}')"
    [[ -n "$section" ]] && { printf '%s\n' "$section"; return 0; }
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
  # operator-changelog is human-written and explicit, so we can key off its real vocabulary,
  # including the exact commands it tells operators to run.
  matched="$(printf '%s\n' "$section" | grep -iE 'network.?tunnel.?manager|(^|[^a-z])NTM([^a-z]|$)|complete_networking_configuration|nymtun|iptables|firewall|wireguard|re-?run[^.]{0,40}tunnel|(^|[^a-z])bands?([^a-z]|$)|bandwidth|open[^.]{0,20}\bports?\b' || true)"
  [[ -n "$matched" ]] || return 1
  printf '%s\n' "$matched"
}

ntm_run() {               # args: <ntm_path> <cmd> [arg...]  -- run an NTM subcommand, log its output
  local p="$1"; shift
  local out code
  if out="$(timeout 150 bash "$p" "$@" 2>&1)"; then code=0; else code=$?; fi
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

# Evaluate / apply tunnel rules after a nym-node release. Gateways only. NEVER aborts the run.
maybe_run_ntm() {
  [[ "${NTM_ENABLED:-0}" == "1" ]] || return 0
  local iface="${NTM_IFACE:-nymtun0}" dest="${NTM_PATH:-/usr/local/sbin/network-tunnel-manager.sh}"
  local tag; tag="$(cat "$STATE_TAG" 2>/dev/null || true)"
  [[ -n "$tag" ]] || return 0
  local ntm_last; ntm_last="$(cat "$NTM_STATE" 2>/dev/null || true)"
  [[ "$tag" != "$ntm_last" ]] || return 0       # already evaluated the tunnel for this release

  log "[ntm] evaluating exit-gateway tunnel for release $tag"

  local mentioned=0 matched crc
  if matched="$(changelog_mentions_ntm "$tag")"; then crc=0; else crc=$?; fi
  if   (( crc == 0 )); then mentioned=1; log "[ntm] changelog for $tag mentions tunnel/ports:"; printf '%s\n' "$matched" | sed 's/^/[ntm]   /' >> "$LOGFILE" 2>/dev/null || true
  elif (( crc == 1 )); then log "[ntm] changelog for $tag has no tunnel/port changes"
  else                       log "[ntm] could not read changelog for $tag; deciding on self-test only"; fi
  log "[ntm] changelog: https://github.com/$REPO/blob/$tag/CHANGELOG.md"

  local tmp rc=0
  tmp="$(mktemp -d "$STATE_DIR/ntm.XXXXXX" 2>/dev/null)" || { log "[ntm] mktemp failed; skip"; return 0; }
  while :; do
    # content-pin: resolve the (mutable) tag to its immutable commit SHA and fetch the script by SHA.
    local sha ntm_ref
    sha="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --retry 2 --max-time 30 \
           -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/commits/$tag" 2>/dev/null \
           | jq -r '.sha // empty' 2>/dev/null || true)"
    ntm_ref="${sha:-$tag}"
    if ! gcurl -fsSL --proto '=https' --proto-redir '=https' --retry 5 $RETRY_ALL --retry-delay 5 --max-time 180 \
           -o "$tmp/ntm.sh" "https://raw.githubusercontent.com/$REPO/$ntm_ref/$NTM_REPO_PATH"; then
      log "[ntm] could not download NTM for $tag (ref $ntm_ref); leaving the tunnel untouched"; rc=0; break
    fi
    chmod +x "$tmp/ntm.sh"
    log "[ntm] fetched NTM @ $ntm_ref (sha256 $(sha256sum "$tmp/ntm.sh" | awk '{print $1}'); no upstream checksum, trusts nym GitHub org)"

    local healthy=1
    if ntm_selftest "$iface"; then log "[ntm] pre-apply self-test OK (tunnel egressing)"; else healthy=0; log "[ntm] pre-apply self-test FAILED (tunnel not egressing)"; fi

    if (( mentioned == 0 && healthy == 1 )); then
      log "[ntm] nothing to do (no changelog mention, tunnel healthy)"; printf '%s\n' "$tag" > "$NTM_STATE"; rc=0; break
    fi

    # we will only modify the firewall if we can snapshot it (so a bad apply can be reverted)
    if ! command -v iptables-save >/dev/null 2>&1 || ! command -v iptables-restore >/dev/null 2>&1; then
      log "[ntm] iptables-save/restore unavailable; SKIPPING apply (no safe revert path on this host)"; printf '%s\n' "$tag" > "$NTM_STATE"; rc=0; break
    fi
    iptables-save  > "$tmp/v4.bak" 2>/dev/null || true
    ip6tables-save > "$tmp/v6.bak" 2>/dev/null || true
    if [[ ! -s "$tmp/v4.bak" ]]; then
      log "[ntm] firewall snapshot empty (nft-native host?); SKIPPING apply to stay safe"; printf '%s\n' "$tag" > "$NTM_STATE"; rc=0; break
    fi

    log "[ntm] applying tunnel rules (changelog_mentioned=$mentioned tunnel_healthy=$healthy)"
    # tell NTM the real SSH port so its firewall never locks the operator out on a non-standard port
    export HOST_SSH_PORT="${SSH_PORT:-22}"
    log "[ntm] HOST_SSH_PORT=$HOST_SSH_PORT (firewall will keep this SSH port open)"
    ntm_run "$tmp/ntm.sh" adjust_ip_forwarding         || true
    ntm_run "$tmp/ntm.sh" apply_iptables_rules         || true
    ntm_run "$tmp/ntm.sh" apply_iptables_rules_wg      || true
    ntm_run "$tmp/ntm.sh" configure_dns_and_icmp_wg    || true
    ntm_run "$tmp/ntm.sh" remove_duplicate_rules "$iface" || true
    ip link show nymwg >/dev/null 2>&1 && { ntm_run "$tmp/ntm.sh" remove_duplicate_rules nymwg || true; }

    if ntm_selftest "$iface"; then
      command -v netfilter-persistent >/dev/null 2>&1 && { netfilter-persistent save >/dev/null 2>&1 || true; } \
        || log "[ntm] note: netfilter-persistent absent - rules may not survive reboot"
      install -m 0755 "$tmp/ntm.sh" "$dest" 2>/dev/null || true
      log "[ntm] SUCCESS: tunnel egressing after apply; rules persisted; NTM saved to $dest"
      notify success "NTM tunnel rules applied for $tag; tunnel healthy"
      printf '%s\n' "$tag" > "$NTM_STATE"; rc=0; break
    fi

    # apply broke the tunnel -> revert the firewall to the pre-apply snapshot and re-persist
    log "[ntm] post-apply self-test FAILED for $tag; REVERTING firewall to pre-apply snapshot"
    iptables-restore  < "$tmp/v4.bak" 2>/dev/null || log "[ntm] WARN: iptables-restore failed"
    [[ -s "$tmp/v6.bak" ]] && { ip6tables-restore < "$tmp/v6.bak" 2>/dev/null || log "[ntm] WARN: ip6tables-restore failed"; }
    command -v netfilter-persistent >/dev/null 2>&1 && { netfilter-persistent save >/dev/null 2>&1 || true; }
    printf '%s\n' "$tag" > "$NTM_STATE"   # record to avoid hourly thrash; clear $NTM_STATE to retry
    if ntm_selftest "$iface"; then
      log "[ntm] REVERT OK: firewall restored, tunnel egressing again. $tag recorded (clear $NTM_STATE to retry)."
      notify rollback "NTM apply for $tag broke the tunnel; reverted firewall, tunnel is UP"
      rc=1; break
    fi
    log "[ntm] CRITICAL: tunnel still failing after revert for $tag - MANUAL INTERVENTION NEEDED."
    notify failed "CRITICAL: NTM apply for $tag broke the tunnel AND revert did not restore it"
    rc=2; break
  done
  rm -rf "$tmp"
  return "$rc"
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

# Deny-list: refuse to auto-run anything that could destroy the node, wipe data, change the host
# or its accounts, or fetch from a non-nym origin. Everything else from the official operator
# changelog is allowed. return 0 = BLOCK, 1 = allow.
changelog_cmd_blocked() {   # arg: command
  local c="$1"
  printf '%s' "$c" | grep -iqE 'unbond|undelegate|rm[[:space:]]+-[a-zA-Z]*[rf]|mkfs|\bdd[[:space:]]+if=|of=/dev/|shutdown|reboot|poweroff|\bhalt\b|init[[:space:]]+0|user(del|add|mod)|deluser|passwd|\bwipe\b|drop[[:space:]]+(table|database)|:\(\)[[:space:]]*\{|>[[:space:]]*/dev/|chmod[[:space:]]+-?R?[[:space:]]*777|chown[[:space:]]+-R|\.nym|nym-nodes|/etc/(passwd|shadow|sudoers)|\bdelete\b|--purge|remove' && return 0
  if printf '%s' "$c" | grep -iqE 'curl|wget'; then
    printf '%s' "$c" | grep -iqE '\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh)\b' && return 0     # pipe-to-shell
    local u host
    for u in $(printf '%s' "$c" | grep -oE 'https?://[^"'"'"' )]+'); do
      host="$(printf '%s' "$u" | sed -E 's#https?://([^/]+).*#\1#')"
      case "$host" in
        raw.githubusercontent.com|github.com|*.nymtech.net|nymtech.net|*.nym.com|nym.com) ;;
        *) return 0 ;;
      esac
    done
  fi
  return 1
}

# Run the operator actions the official changelog lists for this release. Tunnel/firewall commands
# are left to the snapshot-protected NTM path (maybe_run_ntm); other commands run only if they clear
# the deny-list. Recorded per tag so it never repeats.
apply_changelog_actions() {   # arg: tag
  [[ "${CHANGELOG_ACTIONS:-1}" == "1" ]] || return 0
  local tag="$1" ver section cmds
  [[ -n "$tag" ]] || return 0
  [[ "$(cat "$ACTIONS_STATE" 2>/dev/null || true)" != "$tag" ]] || return 0
  ver="${tag#${TAG_PREFIX}}"
  section="$(op_changelog_section "$ver")" || { log "[actions] no operator changelog section for $ver yet (docs lag); will retry next run"; return 0; }
  cmds="$(printf '%s\n' "$section" | changelog_commands)"
  if [[ -z "$cmds" ]]; then log "[actions] operator changelog for $ver lists no runnable commands"; printf '%s\n' "$tag" > "$ACTIONS_STATE"; return 0; fi

  log "[actions] operator changelog for $ver lists commands; evaluating with deny-list enforced"
  local c ran=0 blocked=0 deferred=0 skipped=0 first
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    # code blocks also carry command OUTPUT and examples, which must never be eval'd:
    if printf '%s' "$c" | grep -qE '<[A-Za-z0-9_.-]+>'; then log "[actions] skip (placeholder): $c"; skipped=$((skipped+1)); continue; fi     # e.g. HOST_SSH_PORT=<PORT>
    if printf '%s' "$c" | grep -qE '^[A-Za-z][A-Za-z ]+:[[:space:]][[:space:]]+[^[:space:]]'; then skipped=$((skipped+1)); continue; fi         # "Build Version:   1.37.0" output
    if changelog_cmd_blocked "$c"; then
      log "[actions] BLOCKED (suspicious - manual review): $c"; notify failed "changelog action BLOCKED for $ver: $c"; blocked=$((blocked+1)); continue
    fi
    # tunnel/firewall work is done by the snapshot-protected NTM path, never eval'd here
    if printf '%s' "$c" | grep -qiE 'network-tunnel-manager|nymtun|iptables|complete_networking_configuration'; then
      [[ "${NTM_ENABLED:-0}" == "1" ]] && log "[actions] tunnel command handled by the NTM path: $c" || log "[actions] skip (not an exit gateway): $c"
      deferred=$((deferred+1)); continue
    fi
    # only run if the first real token is an executable present on THIS host (drops examples for
    # other setups, e.g. ansible-playbook, and any stray non-command lines)
    first="$(printf '%s' "$c" | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)+//; s/[[:space:]].*//')"
    case "$first" in nym-node|nym-bridge|nymvisor) log "[actions] skip (managed binary, updated separately): $c"; skipped=$((skipped+1)); continue;; esac
    if [[ "$first" != ./* ]] && ! command -v "$first" >/dev/null 2>&1; then log "[actions] skip (command '$first' not on this host): $c"; skipped=$((skipped+1)); continue; fi
    log "[actions] running: $c"
    if ( eval "$c" ) >>"$LOGFILE" 2>&1; then ran=$((ran+1)); log "[actions] ok: $c"; else log "[actions] WARN non-zero exit: $c"; fi
  done <<<"$cmds"
  log "[actions] done for $ver (ran=$ran deferred=$deferred blocked=$blocked skipped=$skipped)"
  printf '%s\n' "$tag" > "$ACTIONS_STATE"
}

# --------------------------------- run --------------------------------------
cmd_run() {
  ensure_dirs
  resolve_target
  [[ -n "$UNIT" ]]                       || die "no nym-node systemd service found (run 'install' first)"
  sctl cat "$UNIT" >/dev/null 2>&1       || die "configured unit '$UNIT' not known to systemd (${SVC_SCOPE:-system} scope)"
  [[ -n "$BIN" && -x "$BIN" ]]           || die "could not locate the nym-node binary ('$BIN')"
  log "target: unit=$UNIT user=$SVC_USER bin=$BIN role=$ROLE"

  local node_rc=0 bridge_rc=0
  update_component "nym-node" "$REPO" "$TAG_PREFIX" "$ASSET" \
                   "$BIN" "$UNIT" "$STATE_TAG" "$FAILED_TAGS" "version" || node_rc=$?

  if [[ -n "${BRIDGE_UNIT:-}" ]] && systemctl cat "$BRIDGE_UNIT" >/dev/null 2>&1 \
        && [[ -n "${BRIDGE_BIN:-}" && -x "${BRIDGE_BIN:-}" ]]; then
    log "gateway: also checking QUIC bridge ($BRIDGE_UNIT)"
    update_component "nym-bridge" "$BRIDGE_REPO" "$BRIDGE_TAG_PREFIX" "$BRIDGE_ASSET" \
                     "$BRIDGE_BIN" "$BRIDGE_UNIT" "$BRIDGE_STATE_TAG" "$BRIDGE_FAILED_TAGS" "runs" || bridge_rc=$?
  fi

  local ntm_rc=0
  maybe_run_ntm || ntm_rc=$?

  # run any remaining operator actions the official changelog lists (non-tunnel; deny-list enforced)
  apply_changelog_actions "$(cat "$STATE_TAG" 2>/dev/null || true)" || true

  log "run complete (nym-node rc=$node_rc, nym-bridge rc=$bridge_rc, ntm rc=$ntm_rc)"
  if (( node_rc != 0 || bridge_rc != 0 || ntm_rc != 0 )); then exit 1; fi
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
  [[ -n "$unit" ]] || die "no systemd unit set; aborting"
  sctl cat "$unit" >/dev/null 2>&1 || die "unit '$unit' not found in ${svcscope} scope; aborting"
  [[ -n "$bin" && -x "$bin" ]] || die "nym-node binary '$bin' missing or not executable; aborting"
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
  save_config "$unit" "$bin" "${svcuser:-root}" "$role" "$brunit" "$brbin" "${ntm_en:-0}" "$ntm_path" "${ntm_iface:-nymtun0}" "$svcscope" "$sshport" "$tg_token" "$tg_chat"
  local tg_state=off; [[ -n "$tg_token" && -n "$tg_chat" ]] && tg_state=on
  log "saved config -> $CONFIG_FILE (unit=$unit bin=$bin user=${svcuser:-root} scope=${svcscope} bridge=${brunit:-none} ntm=${ntm_en:-0} ssh_port=${sshport} telegram=${tg_state})"
  TELEGRAM_BOT_TOKEN="$tg_token"; TELEGRAM_CHAT_ID="$tg_chat"

  install -m 0755 "$SELF_PATH" "$DEST_PATH"
  cat > /etc/systemd/system/nym-node-autoupdate.service <<UNIT
[Unit]
Description=nym-node auto-updater (nym-node + QUIC bridge + tunnel rules on new stable releases)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DEST_PATH run
UNIT
  cat > /etc/systemd/system/nym-node-autoupdate.timer <<UNIT
[Unit]
Description=Run nym-node auto-updater hourly

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
  systemctl list-timers nym-node-autoupdate.timer --no-pager 2>/dev/null || true
  echo
  echo "Done. It checks hourly and updates only when a new stable release appears."
  echo "Re-run '$DEST_PATH install' to change settings, or edit $CONFIG_FILE."
  notify success "now watching this node (${role}). I'll ping you on updates, rollbacks, or anything that needs you."

  # Register this node with Nymi (the shared Telegram bot) so its operator gets alerts.
  if [[ "${NYM_ASSUME_YES:-0}" != "1" && -t 0 ]]; then
    local tgnick
    read -rp "Your Telegram @nick for Nymi alerts (blank to skip): " tgnick
    if [[ -n "$tgnick" ]]; then
      cmd_link "$tgnick" || true
      echo ">>> Open https://t.me/nyminodebot and press Start to activate Nymi."
    fi
  elif [[ -n "${NYM_NYMI_NICK:-}" ]]; then
    cmd_link "$NYM_NYMI_NICK" || true
  fi

  if [[ "${NYM_ASSUME_YES:-0}" != "1" && -t 0 ]]; then
    local now
    read -rp "Run an update check right now? [y/N]: " now
    if [[ "${now:-}" =~ ^[yY] ]]; then exec "$DEST_PATH" run; fi
  fi
}

cmd_uninstall() {
  systemctl disable --now nym-node-autoupdate.timer 2>/dev/null || true
  rm -f /etc/systemd/system/nym-node-autoupdate.timer /etc/systemd/system/nym-node-autoupdate.service
  systemctl daemon-reload || true
  log "removed timer + service unit (config, state and binaries left intact)"
}

cmd_check() {             # read-only: report whether newer releases exist (no changes, no root)
  resolve_target
  echo "Checking GitHub for updates (read-only - nothing is installed)..."
  echo
  local curver inst lt
  curver="$(bin_version "${BIN:-/bin/false}")"
  inst="$(cat "$STATE_TAG" 2>/dev/null || echo '<none>')"
  lt="$(gh_releases "$REPO" 2>/dev/null | pick_latest "$TAG_PREFIX" "$ASSET" 2>/dev/null | cut -f1 || true)"
  if   [[ -z "$lt" ]];       then echo "nym-node   : could not reach GitHub"
  elif [[ "$lt" == "$inst" ]]; then echo "nym-node   : up to date (${curver:-?}, $lt)"
  else                            echo "nym-node   : UPDATE AVAILABLE -> $lt   (installed ${curver:-?}, last applied $inst)"; fi

  if [[ -n "${BRIDGE_UNIT:-}" ]]; then
    local binst blt
    binst="$(cat "$BRIDGE_STATE_TAG" 2>/dev/null || echo '<none>')"
    blt="$(gh_releases "$BRIDGE_REPO" 2>/dev/null | pick_latest "$BRIDGE_TAG_PREFIX" "$BRIDGE_ASSET" 2>/dev/null | cut -f1 || true)"
    if   [[ -z "$blt" ]];        then echo "nym-bridge : could not reach GitHub"
    elif [[ "$blt" == "$binst" ]]; then echo "nym-bridge : up to date ($blt)"
    else                              echo "nym-bridge : UPDATE AVAILABLE -> $blt   (last applied $binst)"; fi
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
  echo "nym-node unit : ${UNIT:-<none found>}"
  echo "user          : ${SVC_USER:-root}"
  echo "nym-node bin  : ${BIN:-<none found>}"
  echo "version       : $(bin_version "${BIN:-/bin/false}")"
  echo "role          : ${ROLE:-<unknown>}"
  echo "active        : $(systemctl is-active "${UNIT:-nonexistent.service}" 2>/dev/null || true)"
  echo "node last_tag : $(cat "$STATE_TAG" 2>/dev/null || echo '<none>')"
  echo "node failed   : $(cut -f1 "$FAILED_TAGS" 2>/dev/null | tr '\n' ' ' || true)"
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
  echo "config        : $( [[ -f "$CONFIG_FILE" ]] && echo "$CONFIG_FILE" || echo '<none - live detection>')"
  if [[ -f /etc/systemd/system/nym-node-autoupdate.timer ]]; then
    systemctl list-timers nym-node-autoupdate.timer --no-pager 2>/dev/null || echo "timer: installed"
  else
    echo "timer         : not installed"
  fi
}

cmd_link() {   # link this node to a Telegram operator on Nymi, by their @nick
  local nick="${1:-}" ip="${2:-}"
  nick="${nick#@}"
  [[ -n "$nick" ]] || die "usage: $0 link @your_telegram_nick [node_ip]"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ "$ip" =~ ^[0-9.]+$ ]] || ip="$(curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  fi
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "could not auto-detect this node's IP; run: $0 link @$nick <node_ip>"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s' "$ip" > "$STATE_DIR/nymi_node_ip" 2>/dev/null || true   # for the poll
  local resp
  resp="$(curl -s --max-time 12 -X POST "$NYMI_HUB_BASE/link" \
            --data-urlencode "nick=$nick" --data-urlencode "ip=$ip" \
            --data-urlencode "updater=1" 2>/dev/null || true)"
  case "$resp" in
    *'"linked"'*)
      echo "Linked node $ip to @$nick on Nymi - you should see it in the bot now." ;;
    *'"pending"'*)
      echo "Registered node $ip for @$nick."
      echo "Now open  https://t.me/nyminodebot  and press Start - it links the instant you do." ;;
    *)
      echo "Sent to Nymi, but the reply was unexpected: ${resp:-<none>}"
      echo "Open https://t.me/nyminodebot, press Start, then retry: $0 link @$nick" ;;
  esac
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
    status)    cmd_status ;;
    link)      require_cmds curl; cmd_link "${2:-}" "${3:-}" ;;
    *) echo "usage: $0 {install|run|check|status|link|uninstall}"; exit 1 ;;
  esac
}
main "$@"
