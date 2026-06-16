#!/usr/bin/env bash
#
# nym-node-autoupdate.sh
# Safe, self-contained, ROLE-AWARE auto-updater for a Nym node under systemd.
#
# It keeps two things current, with the same safety machinery for both:
#   * nym-node       - the one binary that runs in ANY role (mixnode / entry-gw / exit-gw).
#                      Source: github.com/nymtech/nym  (tags nym-binaries-v*), sha256-verified.
#   * nym-bridge     - the QUIC bridge, GATEWAYS ONLY. Updated only if nym-bridge.service exists.
#                      Source: github.com/nymtech/nym-bridges (tags bridge-binaries-v*).
#
# Two phases:
#   * INSTALL (interactive) - run the script once. It auto-detects the nym-node unit, the user it
#       runs as, the binary path, the node role, and (on gateways) the nym-bridge unit/binary;
#       shows you what it found; lets you CONFIRM or CORRECT it; saves it to
#       /etc/nym-node-autoupdate.conf; then installs a systemd timer for the hourly checks.
#   * RUN (unattended) - the timer calls "run" hourly. For each component, if a genuinely new
#       stable release exists, it downloads it, verifies it, swaps the binary, restarts the
#       service, and ROLLS BACK automatically if the service does not come back healthy.
#
# Safety: binaries are checksum-verified (when the release ships hashes) and smoke-tested before
# install; the only downtime is the stop->copy->start window; any failure restores the previous
# binary; a release that fails its health check is recorded and never retried. It is built so it
# can never leave a node down.
#
# Subcommands:
#   nym-node-autoupdate.sh            # same as 'install' (interactive setup)
#   nym-node-autoupdate.sh install    # detect, confirm/correct, save config, set up the timer
#   nym-node-autoupdate.sh run        # one unattended check + update of every component
#   nym-node-autoupdate.sh uninstall  # remove the timer (leaves config, state and binaries alone)
#   nym-node-autoupdate.sh status     # print detected/configured setup and last known state
#
set -euo pipefail

# ------------------------------- configuration -------------------------------
REPO="nymtech/nym";          TAG_PREFIX="nym-binaries-v";    ASSET="nym-node"
BRIDGE_REPO="nymtech/nym-bridges"; BRIDGE_TAG_PREFIX="bridge-binaries-v"; BRIDGE_ASSET="nym-bridge"
NTM_REPO_PATH="scripts/nym-node-setup/network-tunnel-manager.sh"  # tunnel manager, fetched tag-pinned from $REPO

MIN_AGE_HOURS="${NYM_MIN_AGE_HOURS:-2}"     # ignore releases younger than this (soak delay)
HEALTH_WAIT="${NYM_HEALTH_WAIT:-25}"        # seconds to wait after restart before health check
KEEP_BACKUPS="${NYM_KEEP_BACKUPS:-3}"       # how many old binaries to keep, per component
# fall back to defaults if an operator set a non-numeric value, else sleep/arithmetic would abort under set -e/-u
[[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || MIN_AGE_HOURS=2
[[ "$HEALTH_WAIT"   =~ ^[0-9]+$ ]] || HEALTH_WAIT=25
[[ "$KEEP_BACKUPS"  =~ ^[0-9]+$ ]] || KEEP_BACKUPS=3

CONFIG_FILE="/etc/nym-node-autoupdate.conf" # written by install, read on every run
STATE_DIR="/var/lib/nym-autoupdate"
LOGFILE="/var/log/nym-autoupdate.log"
LOCKFILE="/run/nym-autoupdate.lock"
BACKUP_DIR="$STATE_DIR/backups"
STATE_TAG="$STATE_DIR/last_tag";               FAILED_TAGS="$STATE_DIR/failed_tags"
BRIDGE_STATE_TAG="$STATE_DIR/bridge_last_tag"; BRIDGE_FAILED_TAGS="$STATE_DIR/bridge_failed_tags"
NTM_STATE="$STATE_DIR/ntm_last_tag"            # nym-node tag for which the tunnel was last evaluated

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
  touch "$FAILED_TAGS" "$BRIDGE_FAILED_TAGS" 2>/dev/null || true
}

# Re-run under sudo when not root (install/run/uninstall must replace binaries + manage systemd).
need_root() {
  if [[ "$(id -u)" -eq 0 ]]; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    echo "not root; re-running via sudo..."
    exec sudo -E -- "$SELF_PATH" "$@"
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
detect_bin() {            # binary path for the given unit (absolute from ExecStart, else via PATH)
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
detect_role() {           # best-effort label for display/logging
  local unit="${1:-}" es
  if [[ -n "$(detect_bridge_unit)" ]]; then echo "gateway (has QUIC bridge)"; return; fi
  es="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null || true)"
  case "$es" in
    *exit-gateway*|*entry-gateway*) echo "gateway" ;;
    *mixnode*)                      echo "mixnode" ;;
    *)                              echo "node (role set in config [modes])" ;;
  esac
}
bin_version() {           # extract "Build Version: X.Y.Z" from a nym binary; empty if none
  "$1" --version 2>/dev/null | grep -ioP 'build version:\s*\K[0-9][0-9.]*' | head -n1 || true
}

# Resolve everything from the saved config first, falling back to live detection.
resolve_target() {
  UNIT=""; BIN=""; SVC_USER=""; ROLE=""; BRIDGE_UNIT=""; BRIDGE_BIN=""; NTM_ENABLED=""; NTM_PATH=""; NTM_IFACE=""
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
  [[ -n "${NTM_PATH:-}" ]]  || NTM_PATH="/usr/local/sbin/network-tunnel-manager.sh"
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
EOF
  chmod 0644 "$CONFIG_FILE"
}

# ------------------------------- github lookup ------------------------------
gh_releases() {           # arg: owner/repo
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --max-time 45 \
       -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
       "https://api.github.com/repos/$1/releases?per_page=100"
}
# From releases JSON on stdin, emit "tag<TAB>published<TAB>asset_url<TAB>hashes_url"
# for the newest stable release (tag startswith prefix) that carries the asset. args: prefix asset
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

# is_healthy <unit> <bin> <expected_version_or_empty> - samples SubState twice over ~8s.
# Used identically by the forward install AND the rollback, so a rollback is verified as strictly.
is_healthy() {
  local u="$1" b="$2" expect="${3:-}" sub1 sub2 pid2 active rv
  sub1="$(systemctl show -p SubState --value "$u" 2>/dev/null || true)"
  sleep 8
  sub2="$(systemctl show -p SubState --value "$u" 2>/dev/null || true)"
  pid2="$(systemctl show -p ExecMainPID --value "$u" 2>/dev/null || echo 0)"
  active="$(systemctl is-active "$u" 2>/dev/null || true)"
  # primary liveness: active, running at both samples (catches crash-loops), live main PID
  [[ "$active" == "active" && "$sub1" == "running" && "$sub2" == "running" && "$pid2" != "0" ]] || return 1
  # version: only a hard fail when we expect a version AND can parse one AND it differs (unparseable = inconclusive = pass)
  if [[ -n "$expect" ]]; then
    rv="$(bin_version "$b")"
    [[ -z "$rv" || "$rv" == "$expect" ]] || return 1
  fi
  return 0
}

# ----------------------- the generic component updater ----------------------
# update_component <name> <repo> <tagprefix> <asset> <bin> <unit> <statefile> <failedfile> <smoke>
#   smoke = "version" (nym-node: must report a build version) | "runs" (nym-bridge: --help must work)
# Returns: 0 = updated or nothing-to-do; 1 = aborted/rolled-back (service still up); 2 = critical.
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
  if grep -qxF "$tag" "$CFAILED" 2>/dev/null; then log "[$NAME] WARNING: $tag previously failed its health check here; staying on the current binary (clear $CFAILED to retry)"; return 0; fi

  local age; age="$(age_hours "$published")" || age=9999
  if (( age < MIN_AGE_HOURS )); then log "[$NAME] newest $tag only ${age}h old (< ${MIN_AGE_HOURS}h); waiting"; return 0; fi
  log "[$NAME] new release available: $tag (published $published, ~${age}h ago)"

  local tmp rc=0; tmp="$(mktemp -d /tmp/nym-autoupdate.XXXXXX)"
  while :; do
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --max-time 300 -o "$tmp/bin" "$url"; then
      log "[$NAME] download failed; skip"; rc=0; break
    fi

    local want=""
    if [[ -n "$hashurl" ]] && curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 60 -o "$tmp/hashes.json" "$hashurl"; then
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

    # backup (preserve owner/mode) -> stop -> install -> start
    local owner mode stamp backup
    owner="$(stat -c '%U:%G' "$CBIN" 2>/dev/null || echo root:root)"
    mode="$(stat -c '%a' "$CBIN" 2>/dev/null || echo 755)"
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    backup="$BACKUP_DIR/${NAME}.${curver:-prev}.$stamp"
    if ! cp -a "$CBIN" "$backup"; then log "[$NAME] backup failed; aborting (no change made)"; rc=1; break; fi
    log "[$NAME] backed up -> $backup (owner=$owner mode=$mode)"

    log "[$NAME] stopping $CUNIT"
    systemctl stop "$CUNIT" || log "[$NAME] warning: stop returned non-zero"
    if ! install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$tmp/bin" "$CBIN"; then
      log "[$NAME] install failed; restoring backup"
      cp -a "$backup" "$CBIN" || log "[$NAME] CRITICAL: restore copy failed ($backup -> $CBIN)"
      systemctl start "$CUNIT" || true; rc=1; break
    fi
    log "[$NAME] installed new binary; starting $CUNIT"
    systemctl start "$CUNIT" || log "[$NAME] warning: start returned non-zero"

    # health-gate the new binary (active + running across an ~8s window + version match if known)
    sleep "$HEALTH_WAIT"
    if is_healthy "$CUNIT" "$CBIN" "$newver"; then
      printf '%s\n' "$tag" > "$CSTATE"
      log "[$NAME] SUCCESS: $CUNIT healthy on ${newver:-$tag}"
      notify success "$NAME updated to ${newver:-$tag} and healthy"
      ls -1t "$BACKUP_DIR/${NAME}."* 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f || true
      rc=0; break
    fi

    # rollback: restore the previous binary, record the bad tag, then verify just as strictly
    log "[$NAME] HEALTH CHECK FAILED for $tag; ROLLING BACK to previous binary"
    systemctl stop "$CUNIT" || true
    cp -a "$backup" "$CBIN" || log "[$NAME] CRITICAL: rollback restore copy failed ($backup -> $CBIN)"
    systemctl start "$CUNIT" || true
    printf '%s\n' "$tag" >> "$CFAILED"
    sleep "$HEALTH_WAIT"
    if is_healthy "$CUNIT" "$CBIN" "$curver"; then
      log "[$NAME] ROLLBACK OK: restored ${curver:-previous} binary, $CUNIT healthy again. $tag marked failed (clear $CFAILED to retry)."
      notify rollback "$NAME update to $tag FAILED; rolled back to ${curver:-previous}, $CUNIT is UP"; rc=1; break
    fi
    log "[$NAME] CRITICAL: rollback did NOT restore a healthy $CUNIT. MANUAL INTERVENTION NEEDED."
    notify failed "CRITICAL: $NAME update to $tag failed AND rollback unhealthy on $CUNIT"; rc=2; break
  done
  rm -rf "$tmp"
  return "$rc"
}

# ------------------- network tunnel manager (gateways only) -----------------
# NTM is a SCRIPT (not a service) that sets up the exit-gateway iptables/forwarding/tunnel rules.
# We never execute the changelog as instructions: it is used ONLY as a signal that this release
# touches the tunnel/ports, then we run NTM's own (version-matched, tag-pinned) apply + self-test.
detect_ntm() {            # echoes "<enabled>\t<path>\t<iface>"
  local en=0 path="" iface="nymtun0"
  ip link show nymtun0 >/dev/null 2>&1 && en=1
  path="$(ls -1 /usr/local/sbin/network-tunnel-manager.sh /root/network-tunnel-manager.sh /root/network_tunnel_manager.sh 2>/dev/null | head -n1 || true)"
  [[ -n "$path" ]] && en=1
  [[ -n "$path" ]] || path="/usr/local/sbin/network-tunnel-manager.sh"
  printf '%s\t%s\t%s\n' "$en" "$path" "$iface"
}

# Scan ONLY this release's changelog section for tunnel/port relevance. arg: tag
# stdout = matched lines; return 0 = relevant, 1 = not relevant, 2 = could not read/parse.
changelog_mentions_ntm() {
  local tag="$1" cl ver section matched
  cl="$(curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 45 \
        "https://raw.githubusercontent.com/$REPO/$tag/CHANGELOG.md" 2>/dev/null)" || return 2
  ver="${tag#${TAG_PREFIX}}"
  section="$(printf '%s\n' "$cl" | awk -v v="$ver" '
    $0 ~ "^## \\[" v "\\]" {f=1; next}
    f && /^## \[/ {exit}
    f {print}')"
  [[ -n "$section" ]] || return 2
  matched="$(printf '%s\n' "$section" | grep -iE 'tunnel|iptables|firewall|\bports?\b|wireguard|nymtun|forwarding|routing|exit.?polic' || true)"
  [[ -n "$matched" ]] || return 1
  printf '%s\n' "$matched"
}

# Run one NTM subcommand with a timeout, logging its output. args: <ntm_path> <cmd> [arg...]
ntm_run() {
  local p="$1"; shift
  local out code
  if out="$(timeout 150 bash "$p" "$@" 2>&1)"; then code=0; else code=$?; fi
  log "[ntm] \`$*\` exit=$code"
  printf '%s\n' "$out" | sed 's/^/[ntm]   /' >> "$LOGFILE" 2>/dev/null || true
  return "$code"
}

ntm_selftest() {          # arg: ntm_path ; return 0 = tunnel verified healthy
  ntm_run "$1" check_nymtun_iptables   || return 1
  ntm_run "$1" joke_through_the_mixnet || return 1
  return 0
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

  local tmp rc=0; tmp="$(mktemp -d /tmp/nym-autoupdate-ntm.XXXXXX)"
  while :; do
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 \
           -o "$tmp/ntm.sh" "https://raw.githubusercontent.com/$REPO/$tag/$NTM_REPO_PATH"; then
      log "[ntm] could not download tag-pinned NTM for $tag; leaving the tunnel untouched"; rc=0; break
    fi
    chmod +x "$tmp/ntm.sh"
    log "[ntm] fetched NTM @ $tag (sha256 $(sha256sum "$tmp/ntm.sh" | awk '{print $1}'))"

    local healthy=1
    if ntm_selftest "$tmp/ntm.sh"; then log "[ntm] self-test OK (tunnel passing traffic)"; else healthy=0; log "[ntm] self-test FAILED"; fi

    if (( mentioned == 0 && healthy == 1 )); then
      log "[ntm] nothing to do (no changelog mention, tunnel healthy)"; printf '%s\n' "$tag" > "$NTM_STATE"; rc=0; break
    fi

    log "[ntm] applying tunnel rules (changelog_mentioned=$mentioned tunnel_healthy=$healthy)"
    ntm_run "$tmp/ntm.sh" adjust_ip_forwarding         || true
    ntm_run "$tmp/ntm.sh" apply_iptables_rules         || true
    ntm_run "$tmp/ntm.sh" apply_iptables_rules_wg      || true
    ntm_run "$tmp/ntm.sh" configure_dns_and_icmp_wg    || true
    ntm_run "$tmp/ntm.sh" remove_duplicate_rules "$iface" || true
    ip link show nymwg >/dev/null 2>&1 && { ntm_run "$tmp/ntm.sh" remove_duplicate_rules nymwg || true; }

    if ntm_selftest "$tmp/ntm.sh"; then
      command -v netfilter-persistent >/dev/null 2>&1 && { netfilter-persistent save >/dev/null 2>&1 || true; }
      install -m 0755 "$tmp/ntm.sh" "$dest" 2>/dev/null || true
      log "[ntm] SUCCESS: tunnel healthy after apply; rules persisted; NTM saved to $dest"
      notify success "NTM tunnel rules applied for $tag; tunnel healthy"
      printf '%s\n' "$tag" > "$NTM_STATE"; rc=0; break
    fi
    log "[ntm] CRITICAL: tunnel still failing after apply for $tag - MANUAL CHECK NEEDED (firewall changes are not auto-rolled-back)."
    notify failed "NTM apply for $tag did not restore the tunnel on this gateway; manual intervention needed"
    printf '%s\n' "$tag" > "$NTM_STATE"   # record to avoid hourly firewall thrash; clear $NTM_STATE to retry
    rc=1; break
  done
  rm -rf "$tmp"
  return "$rc"
}

# --------------------------------- run --------------------------------------
cmd_run() {
  ensure_dirs
  resolve_target
  [[ -n "$UNIT" ]]                       || die "no nym-node systemd service found (run 'install' first)"
  systemctl cat "$UNIT" >/dev/null 2>&1  || die "configured unit '$UNIT' not known to systemd"
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

  log "run complete (nym-node rc=$node_rc, nym-bridge rc=$bridge_rc, ntm rc=$ntm_rc)"
  if (( node_rc != 0 || bridge_rc != 0 || ntm_rc != 0 )); then exit 1; fi
  exit 0
}

# ------------------------------ install/remove ------------------------------
cmd_install() {
  ensure_dirs
  local unit bin svcuser role brunit brbin brver curver
  unit="$(detect_unit)"; bin="$(detect_bin "$unit")"; svcuser="$(detect_user "$unit")"
  role="$(detect_role "$unit")"; curver="$(bin_version "${bin:-/bin/false}")"
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
    echo "  QUIC bridge   : ${brunit}  bin=${brbin:-<?>}  ver=${brver:-<?>}   -> WILL be auto-updated"
  else
    echo "  QUIC bridge   : none (mixnode / no bridge)   -> bridge updates skipped"
  fi
  if [[ "$ntm_en" == "1" ]]; then
    echo "  tunnel (NTM)  : exit gateway (iface ${ntm_iface}) -> checked per release, changelog-gated; script ${ntm_path}"
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
  systemctl cat "$unit" >/dev/null 2>&1 || die "unit '$unit' not found by systemd; aborting"
  [[ -n "$bin" && -x "$bin" ]] || die "nym-node binary '$bin' missing or not executable; aborting"
  if [[ -n "$brunit" ]]; then
    systemctl cat "$brunit" >/dev/null 2>&1 || die "bridge unit '$brunit' not found by systemd; aborting"
    [[ -n "$brbin" && -x "$brbin" ]] || die "bridge binary '$brbin' missing or not executable; aborting"
  fi

  save_config "$unit" "$bin" "${svcuser:-root}" "$role" "$brunit" "$brbin" "${ntm_en:-0}" "$ntm_path" "${ntm_iface:-nymtun0}"
  log "saved config -> $CONFIG_FILE (unit=$unit bin=$bin user=${svcuser:-root} bridge=${brunit:-none} ntm=${ntm_en:-0})"

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

cmd_status() {
  resolve_target
  echo "nym-node unit : ${UNIT:-<none found>}"
  echo "user          : ${SVC_USER:-root}"
  echo "nym-node bin  : ${BIN:-<none found>}"
  echo "version       : $(bin_version "${BIN:-/bin/false}")"
  echo "role          : ${ROLE:-<unknown>}"
  echo "active         : $(systemctl is-active "${UNIT:-nonexistent.service}" 2>/dev/null || true)"
  echo "node last_tag : $(cat "$STATE_TAG" 2>/dev/null || echo '<none>')"
  echo "node failed   : $(tr '\n' ' ' < "$FAILED_TAGS" 2>/dev/null || true)"
  if [[ -n "${BRIDGE_UNIT:-}" ]]; then
    echo "bridge unit   : ${BRIDGE_UNIT}  bin=${BRIDGE_BIN:-<?>}  active=$(systemctl is-active "$BRIDGE_UNIT" 2>/dev/null || true)"
    echo "bridge last   : $(cat "$BRIDGE_STATE_TAG" 2>/dev/null || echo '<none>')"
    echo "bridge failed : $(tr '\n' ' ' < "$BRIDGE_FAILED_TAGS" 2>/dev/null || true)"
  else
    echo "bridge        : none (updates skipped)"
  fi
  if [[ "${NTM_ENABLED:-0}" == "1" ]]; then
    echo "tunnel (NTM)  : enabled  iface=${NTM_IFACE:-nymtun0}  script=${NTM_PATH:-<?>}"
    echo "ntm last_tag  : $(cat "$NTM_STATE" 2>/dev/null || echo '<none>')"
  else
    echo "tunnel (NTM)  : disabled (not an exit gateway)"
  fi
  echo "config        : $( [[ -f "$CONFIG_FILE" ]] && echo "$CONFIG_FILE" || echo '<none - live detection>')"
  if [[ -f /etc/systemd/system/nym-node-autoupdate.timer ]]; then
    systemctl list-timers nym-node-autoupdate.timer --no-pager 2>/dev/null || echo "timer: installed"
  else
    echo "timer         : not installed"
  fi
}

# --------------------------------- dispatch ---------------------------------
main() {
  local cmd="${1:-install}"
  case "$cmd" in
    run)
      need_root "$@"
      command -v flock >/dev/null 2>&1 || die "flock not found; refusing to run without single-instance locking"
      exec 9>"$LOCKFILE"
      flock -n 9 || { echo "another nym-autoupdate run is in progress; exiting"; exit 0; }
      cmd_run ;;
    install)   need_root "$@"; cmd_install ;;
    uninstall) need_root "$@"; cmd_uninstall ;;
    status)    cmd_status ;;
    *) echo "usage: $0 {install|run|uninstall|status}"; exit 1 ;;
  esac
}
main "$@"
