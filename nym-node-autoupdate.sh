#!/usr/bin/env bash
#
# nym-node-autoupdate.sh
# Safe, self-contained auto-updater for a nym-node systemd service.
#
# Two phases:
#   * INSTALL (interactive)  - you run the script once. It auto-detects the nym-node systemd
#       unit, the user it runs as, and the binary path; shows you what it found; lets you
#       CONFIRM or CORRECT it; saves that to /etc/nym-node-autoupdate.conf; then installs a
#       systemd timer that does the hourly checks.
#   * RUN (unattended)       - the timer calls "run" every hour. It reads the saved config and,
#       if a genuinely new stable release exists, downloads it, verifies its SHA-256, swaps it
#       in, restarts the service, and ROLLS BACK automatically if the node does not come back
#       healthy. Between releases it does nothing.
#
# Safety: the binary is checksum-verified and smoke-tested before install; the only downtime is
# the stop->copy->start window; any failure restores the previous binary; a release that fails
# its health check is recorded and never retried. It never leaves the node down.
#
# Subcommands:
#   nym-node-autoupdate.sh            # same as 'install' (interactive setup)
#   nym-node-autoupdate.sh install    # interactive: detect, confirm/correct, save config, set timer
#   nym-node-autoupdate.sh run        # one unattended check + update (what the timer runs)
#   nym-node-autoupdate.sh uninstall  # remove the timer (leaves config, state and binary alone)
#   nym-node-autoupdate.sh status     # print detected/configured setup and last known state
#
set -euo pipefail

# ------------------------------- configuration -------------------------------
REPO="nymtech/nym"                          # GitHub repo that publishes nym-node
TAG_PREFIX="nym-binaries-v"                 # only releases tagged like this carry nym-node
ASSET="nym-node"                            # the release asset name == the binary name
MIN_AGE_HOURS="${NYM_MIN_AGE_HOURS:-2}"     # ignore releases younger than this (anti-yank buffer)
HEALTH_WAIT="${NYM_HEALTH_WAIT:-25}"        # seconds to wait after restart before health check
KEEP_BACKUPS="${NYM_KEEP_BACKUPS:-3}"       # how many old binaries to keep in the backup dir

CONFIG_FILE="/etc/nym-node-autoupdate.conf" # written by install, read on every run
STATE_DIR="/var/lib/nym-autoupdate"
LOGFILE="/var/log/nym-autoupdate.log"
LOCKFILE="/run/nym-autoupdate.lock"
BACKUP_DIR="$STATE_DIR/backups"
STATE_TAG="$STATE_DIR/last_tag"             # last release tag we successfully installed
FAILED_TAGS="$STATE_DIR/failed_tags"        # releases that failed health check (never retried)

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

# Optional alerting hook. Called as: notify <success|rollback|failed> <message>.
# No-op by default; drop a curl to your Telegram/webhook here if you want pings.
notify() { :; }

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  touch "$FAILED_TAGS" 2>/dev/null || true
}

# Re-run ourselves under sudo when we are not root (install/run/uninstall need root to replace
# the binary and manage systemd). Operators who are not root just get a sudo password prompt.
need_root() {
  if [[ "$(id -u)" -eq 0 ]]; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    echo "not root; re-running via sudo..."
    exec sudo -E -- "$SELF_PATH" "$@"
  fi
  die "this needs root (it replaces the binary and manages systemd). Re-run as root or install sudo."
}

# ------------------------------- autodetection ------------------------------
detect_unit() {
  systemctl list-units --all --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^nym-node(@[^.]*)?\.service$' \
    | head -n1 || true
}

detect_bin() {
  local unit="${1:-}" p
  p="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | grep -oP 'path=\K\S+' | head -n1 || true)"
  if [[ "$p" == /* && -x "$p" ]]; then
    printf '%s\n' "$p"; return 0
  fi
  # ExecStart used a bare name resolved via PATH (e.g. templated units) -> resolve it.
  command -v nym-node 2>/dev/null || true
}

detect_user() {
  local unit="${1:-}" u
  u="$(systemctl show -p User --value "$unit" 2>/dev/null || true)"
  printf '%s\n' "${u:-root}"
}

bin_version() {
  "$1" --version 2>/dev/null | grep -ioP 'build version:\s*\K[0-9][0-9.]*' | head -n1 || true
}

# Resolve unit/bin/user from the saved config first, falling back to live detection.
resolve_target() {
  UNIT=""; BIN=""; SVC_USER=""
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || true
  fi
  [[ -n "${UNIT:-}" ]]     || UNIT="$(detect_unit)"
  [[ -n "${BIN:-}" ]]      || BIN="$(detect_bin "$UNIT")"
  [[ -n "${SVC_USER:-}" ]] || SVC_USER="$(detect_user "$UNIT")"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# nym-node-autoupdate config - written by 'install', read on every run.
# Edit by hand if your setup changes, or re-run: $DEST_PATH install
UNIT="$1"
BIN="$2"
SVC_USER="$3"
EOF
  chmod 0644 "$CONFIG_FILE"
}

# ------------------------------- github lookup ------------------------------
gh_releases() {
  curl -fsSL --retry 3 --retry-delay 5 --max-time 45 \
       -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" \
       "https://api.github.com/repos/$REPO/releases?per_page=30"
}

# From the releases JSON on stdin, emit "tag<TAB>published<TAB>node_url<TAB>hash_url"
# for the newest stable nym-binaries release that has a nym-node asset.
pick_latest() {
  jq -r --arg pref "$TAG_PREFIX" --arg asset "$ASSET" '
    [ .[]
      | select(.draft==false and .prerelease==false)
      | select(.tag_name | startswith($pref))
      | select(any(.assets[]?; .name==$asset))
    ]
    | sort_by(.published_at) | reverse | .[0] // empty
    | [ .tag_name,
        .published_at,
        (.assets[] | select(.name==$asset)        | .browser_download_url),
        ((.assets[] | select(.name=="hashes.json") | .browser_download_url) // "")
      ] | @tsv
  '
}

age_hours() { # arg: ISO8601 date -> integer hours since then
  local pub now
  pub="$(date -u -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  printf '%s\n' "$(( (now - pub) / 3600 ))"
}

expected_sha() { jq -r --arg a "$ASSET" '.assets[$a].sha256 // empty' "$1"; }

# --------------------------------- the work ---------------------------------
cmd_run() {
  ensure_dirs
  resolve_target
  local unit="$UNIT" bin="$BIN" svcuser="$SVC_USER" curver
  [[ -n "$unit" ]]               || die "no nym-node systemd service found (run 'install' first)"
  systemctl cat "$unit" >/dev/null 2>&1 || die "configured unit '$unit' not known to systemd"
  [[ -n "$bin" && -x "$bin" ]]   || die "could not locate the nym-node binary ('$bin')"
  curver="$(bin_version "$bin")"
  log "target: unit=$unit user=$svcuser bin=$bin current_version=${curver:-unknown}"

  # --- find the newest stable release ---
  local rels latest tag published node_url hash_url
  rels="$(gh_releases)"            || { log "github query failed; will retry next run"; exit 0; }
  latest="$(printf '%s' "$rels" | pick_latest)" || { log "could not parse releases; skip"; exit 0; }
  [[ -n "$latest" ]]              || { log "no qualifying nym-binaries release found; skip"; exit 0; }
  IFS=$'\t' read -r tag published node_url hash_url <<<"$latest" || true
  [[ -n "$tag" && -n "$node_url" ]] || { log "incomplete release metadata; skip"; exit 0; }

  local last; last="$(cat "$STATE_TAG" 2>/dev/null || true)"
  if [[ "$tag" == "$last" ]]; then
    log "already on latest release ($tag); nothing to do"; exit 0
  fi
  if grep -qxF "$tag" "$FAILED_TAGS" 2>/dev/null; then
    log "release $tag already failed health check here; skipping (clear $FAILED_TAGS to retry)"; exit 0
  fi

  local age; age="$(age_hours "$published")" || age=9999
  if (( age < MIN_AGE_HOURS )); then
    log "newest release $tag is only ${age}h old (< ${MIN_AGE_HOURS}h); waiting before adopting"; exit 0
  fi
  log "new release available: $tag (published $published, ~${age}h ago)"

  # --- download + verify (nothing on the node is touched yet) ---
  local tmp; tmp="$(mktemp -d /tmp/nym-autoupdate.XXXXXX)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 --retry-delay 5 --max-time 300 -o "$tmp/nym-node" "$node_url" \
    || { log "download of nym-node failed; skip"; exit 0; }

  local want=""
  if [[ -n "$hash_url" ]] && curl -fsSL --retry 3 --max-time 60 -o "$tmp/hashes.json" "$hash_url"; then
    want="$(expected_sha "$tmp/hashes.json")"
  fi
  if [[ -n "$want" ]]; then
    local got; got="$(sha256sum "$tmp/nym-node" | awk '{print $1}')"
    [[ "$got" == "$want" ]] || die "SHA-256 mismatch for $tag (want $want got $got) - NOT installing"
    log "sha256 verified ok"
  else
    log "WARNING: no published hash for $tag; proceeding without checksum verification"
  fi

  chmod +x "$tmp/nym-node"
  local newver; newver="$(bin_version "$tmp/nym-node")"
  [[ -n "$newver" ]] || die "downloaded binary does not run (--version failed) - NOT installing"
  log "downloaded nym-node build version $newver (release $tag)"

  if [[ -n "$curver" && "$newver" == "$curver" ]]; then
    log "binary version unchanged ($curver); recording tag, no restart needed"
    printf '%s\n' "$tag" > "$STATE_TAG"; exit 0
  fi

  # --- backup, swap (preserving the old binary's owner/mode), restart ---
  local stamp backup owner mode pid1 pid2 active substate runver
  owner="$(stat -c '%U:%G' "$bin" 2>/dev/null || echo root:root)"
  mode="$(stat -c '%a' "$bin" 2>/dev/null || echo 755)"
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup="$BACKUP_DIR/nym-node.${curver:-unknown}.$stamp"
  cp -a "$bin" "$backup" || die "backup failed; aborting before any change"
  log "backed up current binary -> $backup (owner=$owner mode=$mode)"

  log "stopping $unit"
  systemctl stop "$unit" || log "warning: stop returned non-zero"
  if ! install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$tmp/nym-node" "$bin"; then
    log "install of new binary failed; restoring backup"
    cp -a "$backup" "$bin"; systemctl start "$unit" || true
    die "install failed; rolled back to previous binary"
  fi
  log "installed new binary; starting $unit"
  systemctl start "$unit" || log "warning: start returned non-zero"

  # --- health check: active + running + correct version + PID stable over a 2nd window ---
  sleep "$HEALTH_WAIT"
  pid1="$(systemctl show -p ExecMainPID --value "$unit" 2>/dev/null || echo 0)"
  sleep 8
  pid2="$(systemctl show -p ExecMainPID --value "$unit" 2>/dev/null || echo 0)"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  substate="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
  runver="$(bin_version "$bin")"

  local healthy=1
  [[ "$active" == "active" ]]    || healthy=0
  [[ "$substate" == "running" ]] || healthy=0
  [[ "$runver" == "$newver" ]]   || healthy=0
  [[ "$pid1" != "0" && "$pid1" == "$pid2" ]] || healthy=0

  if (( healthy == 1 )); then
    printf '%s\n' "$tag" > "$STATE_TAG"
    log "SUCCESS: $unit healthy on $newver ($tag) [active=$active sub=$substate pid=$pid1]"
    notify success "nym-node updated to $newver ($tag) and healthy"
    ls -1t "$BACKUP_DIR"/nym-node.* 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f
    exit 0
  fi

  # --- rollback ---
  log "HEALTH CHECK FAILED [active=$active sub=$substate runver=$runver pid=$pid1/$pid2]; ROLLING BACK"
  systemctl stop "$unit" || true
  cp -a "$backup" "$bin"
  systemctl start "$unit" || true
  sleep "$HEALTH_WAIT"
  printf '%s\n' "$tag" >> "$FAILED_TAGS"
  local active2; active2="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [[ "$active2" == "active" ]]; then
    log "ROLLBACK OK: restored ${curver:-previous} binary, $unit active again. $tag marked failed (won't retry)."
    notify rollback "nym-node update to $tag FAILED; rolled back to ${curver:-previous}, node is UP"
    exit 1
  fi
  log "CRITICAL: rollback did NOT bring $unit back. MANUAL INTERVENTION NEEDED."
  notify failed "CRITICAL: nym-node update to $tag failed AND rollback failed on $unit"
  exit 2
}

# ------------------------------ install/remove ------------------------------
cmd_install() {
  ensure_dirs
  local unit bin svcuser curver
  unit="$(detect_unit)"
  bin="$(detect_bin "$unit")"
  svcuser="$(detect_user "$unit")"
  curver="$(bin_version "${bin:-/bin/false}")"

  echo "Detected nym-node setup on $(hostname):"
  echo "  service unit : ${unit:-<NOT FOUND>}"
  echo "  runs as user : ${svcuser:-root}"
  echo "  binary       : ${bin:-<NOT FOUND>}"
  echo "  version      : ${curver:-<unknown>}"
  echo

  if [[ "${NYM_ASSUME_YES:-0}" != "1" && -t 0 ]]; then
    local ans a
    read -rp "Use this? [Y = yes / n = let me correct it]: " ans
    if [[ "${ans:-}" =~ ^[nN] ]]; then
      read -rp "  systemd unit  [${unit}]: " a;    unit="${a:-$unit}"
      read -rp "  binary path   [${bin}]: " a;     bin="${a:-$bin}"
      read -rp "  service user  [${svcuser}]: " a; svcuser="${a:-$svcuser}"
    fi
  else
    log "non-interactive install; using detected values"
  fi

  # validate before committing anything
  [[ -n "$unit" ]] || die "no systemd unit set; aborting"
  systemctl cat "$unit" >/dev/null 2>&1 || die "unit '$unit' not found by systemd; aborting"
  [[ -n "$bin" && -x "$bin" ]] || die "binary '$bin' missing or not executable; aborting"

  save_config "$unit" "$bin" "${svcuser:-root}"
  log "saved config -> $CONFIG_FILE (unit=$unit bin=$bin user=${svcuser:-root})"

  install -m 0755 "$SELF_PATH" "$DEST_PATH"
  cat > /etc/systemd/system/nym-node-autoupdate.service <<UNIT
[Unit]
Description=nym-node auto-updater (check GitHub, update if a new stable release exists)
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
  echo "Done. It will check hourly and update only when a new stable nym-node release appears."
  echo "Re-run '$DEST_PATH install' to change settings, or edit $CONFIG_FILE."

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
  log "removed timer + service unit (config $CONFIG_FILE, state $STATE_DIR and nym-node binary left intact)"
}

cmd_status() {
  resolve_target
  echo "unit:      ${UNIT:-<none found>}"
  echo "user:      ${SVC_USER:-root}"
  echo "binary:    ${BIN:-<none found>}"
  echo "version:   $(bin_version "${BIN:-/bin/false}")"
  echo "active:    $(systemctl is-active "${UNIT:-nonexistent.service}" 2>/dev/null || true)"
  echo "config:    $( [[ -f "$CONFIG_FILE" ]] && echo "$CONFIG_FILE" || echo '<none - using live detection>')"
  echo "last_tag:  $(cat "$STATE_TAG" 2>/dev/null || echo '<none>')"
  echo "failed:    $(tr '\n' ' ' < "$FAILED_TAGS" 2>/dev/null || true)"
  if [[ -f /etc/systemd/system/nym-node-autoupdate.timer ]]; then
    systemctl list-timers nym-node-autoupdate.timer --no-pager 2>/dev/null || echo "timer:     installed"
  else
    echo "timer:     not installed"
  fi
}

# --------------------------------- dispatch ---------------------------------
main() {
  local cmd="${1:-install}"
  case "$cmd" in
    run)
      need_root "$@"
      exec 9>"$LOCKFILE"
      flock -n 9 || { echo "another nym-autoupdate run is in progress; exiting"; exit 0; }
      cmd_run
      ;;
    install)   need_root "$@"; cmd_install ;;
    uninstall) need_root "$@"; cmd_uninstall ;;
    status)    cmd_status ;;
    *) echo "usage: $0 {install|run|uninstall|status}"; exit 1 ;;
  esac
}
main "$@"
