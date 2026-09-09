#!/system/bin/sh
# shellcheck shell=ash disable=SC3043
#
# common.sh — paths, logging, locking, config/stats and permission helpers.
# Sourced by post-fs-data.sh, service.sh and sh/inject.sh.
#
# Strictly POSIX sh: no `local` outside functions, no bashisms, no `expr`.

MODULE_ID="trust-user-certs"
MODDIR="${MODDIR:-/data/adb/modules/$MODULE_ID}"

# ── Paths ─────────────────────────────────────────────────────────────────────
DATA_DIR="/data/adb/$MODULE_ID"
CONFIG_FILE="$DATA_DIR/config"
STATS_FILE="$DATA_DIR/stats"
FAIL_FILE="$DATA_DIR/boot_fail_count"
LOG_DIR="$DATA_DIR/logs"
LOG_FILE="$LOG_DIR/service.log"
LOCK_DIR="$DATA_DIR/locks"
STATS_LOCK="$LOCK_DIR/stats.lock"
CONFIG_LOCK="$LOCK_DIR/config.lock"
SYNC_LOCK="$LOCK_DIR/sync.lock"
WATCH_PID_FILE="$DATA_DIR/watcher.pid"

EXCLUDE_HASH_FILE="$DATA_DIR/exclude_hashes"
EXCLUDE_SUBJ_FILE="$DATA_DIR/exclude_subjects"

CERT_STAGE="$DATA_DIR/cert_stage"
BASE_CERT_DIR="$DATA_DIR/base_certs"

# Root-only drop-in dir for manually added certificates.
CUSTOM_CERT_DIR="$DATA_DIR/certs"
# Pre-v3 location — world-writable by the shell user, migrated away on boot.
LEGACY_CUSTOM_CERT_DIR="/data/local/tmp/cert"

USER_CERT_DIR="/data/misc/user/0/cacerts-added"
SYSTEM_CERT_DIR="/system/etc/security/cacerts"
APEX_CONSCRYPT_DIR="/apex/com.android.conscrypt/cacerts"

TEMP_MOUNT="/mnt/tuc_stage"

# ── Tunables ──────────────────────────────────────────────────────────────────
FAIL_LIMIT=3
LOG_MAX_BYTES=262144
LOG_KEEP_LINES=300
SETTLE_SECONDS=15

# ── SDK (never leave this unset — every branch below depends on it) ───────────
SDK="$(getprop ro.build.version.sdk 2>/dev/null)"
case "$SDK" in
  '' | *[!0-9]*) SDK=0 ;;
esac

# ── External tools ────────────────────────────────────────────────────────────
# Nothing here may be assumed to exist. Android ships toybox, but which applets
# are built in varies by ROM, and a WebUI shell does not always inherit the PATH
# that post-fs-data runs with. Every risky tool is resolved once, with a busybox
# fallback and, where possible, a pure-shell implementation on top of that.

BUSYBOX=""
for _bb_cand in \
  /data/adb/magisk/busybox \
  /data/adb/ksu/bin/busybox \
  /data/adb/ap/bin/busybox \
  /data/adb/modules/busybox-ndk/system/bin/busybox \
  /system/bin/busybox \
  /system/xbin/busybox; do
  [ -x "$_bb_cand" ] || continue
  "$_bb_cand" echo >/dev/null 2>&1 || continue
  BUSYBOX="$_bb_cand"
  break
done
unset _bb_cand

_BB_APPLETS=""
[ -n "$BUSYBOX" ] && _BB_APPLETS=$("$BUSYBOX" --list 2>/dev/null)

has_applet() {
  [ -n "$_BB_APPLETS" ] || return 1
  printf '%s\n' "$_BB_APPLETS" | grep -qx "$1"
}

# resolve_cmd <name> — prints a runnable command prefix, or nothing if the tool
# is unavailable in any form. Intentionally unquoted at the call site so
# "busybox nsenter" splits into two words.
resolve_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '%s' "$1"
    return 0
  fi
  if [ -n "$BUSYBOX" ] && has_applet "$1"; then
    printf '%s %s' "$BUSYBOX" "$1"
    return 0
  fi
  return 1
}

CMD_NSENTER=$(resolve_cmd nsenter)
CMD_SETSID=$(resolve_cmd setsid)
CMD_NOHUP=$(resolve_cmd nohup)
CMD_PGREP=$(resolve_cmd pgrep)
CMD_PKILL=$(resolve_cmd pkill)
CMD_STAT=$(resolve_cmd stat)
CMD_BASE64=$(resolve_cmd base64)

log_tools() {
  log_debug "busybox: ${BUSYBOX:-none}"
  log_debug "tools: nsenter=${CMD_NSENTER:-MISSING} setsid=${CMD_SETSID:-none} nohup=${CMD_NOHUP:-none} pgrep=${CMD_PGREP:-none} stat=${CMD_STAT:-none} base64=${CMD_BASE64:-none}"
  [ -n "$CMD_NSENTER" ] || log_warn "nsenter is unavailable — certificates cannot be pushed into the zygote mount namespace, so apps started before the inject may not see them until a reboot"
  return 0
}

# ── Pure-shell replacements for tools that may be missing ────────────────────
# list_pids_by_name <substring> — pgrep, or /proc walked by hand.
list_pids_by_name() {
  if [ -n "$CMD_PGREP" ]; then
    $CMD_PGREP "$1" 2>/dev/null
    return 0
  fi
  for _lp_d in /proc/[0-9]*; do
    [ -r "$_lp_d/comm" ] || continue
    read -r _lp_c <"$_lp_d/comm" 2>/dev/null || continue
    case "$_lp_c" in
      *"$1"*) printf '%s\n' "${_lp_d#/proc/}" ;;
    esac
  done
  unset _lp_d _lp_c
  return 0
}

# kill_children <ppid> [signal] — pkill -P, or /proc/<pid>/stat parsed by hand.
kill_children() {
  _kc_ppid="$1"
  _kc_sig="${2:-TERM}"
  if [ -n "$CMD_PKILL" ]; then
    $CMD_PKILL "-$_kc_sig" -P "$_kc_ppid" 2>/dev/null
    unset _kc_ppid _kc_sig
    return 0
  fi
  for _kc_d in /proc/[0-9]*; do
    [ -r "$_kc_d/stat" ] || continue
    # The comm field can contain spaces, so cut everything up to the closing
    # parenthesis first; ppid is then the second remaining field.
    _kc_parent=$(sed 's/.*) //' "$_kc_d/stat" 2>/dev/null | cut -d' ' -f2)
    [ "$_kc_parent" = "$_kc_ppid" ] || continue
    kill "-$_kc_sig" "${_kc_d#/proc/}" 2>/dev/null
  done
  unset _kc_ppid _kc_sig _kc_d _kc_parent
  return 0
}

# file_size <path> — stat, falling back to wc.
file_size() {
  [ -f "$1" ] || {
    printf '0'
    return 0
  }
  _fs=""
  [ -n "$CMD_STAT" ] && _fs=$($CMD_STAT -c %s "$1" 2>/dev/null)
  case "$_fs" in
    '' | *[!0-9]*) _fs=$(wc -c <"$1" 2>/dev/null | tr -d ' \t') ;;
  esac
  case "$_fs" in
    '' | *[!0-9]*) _fs=0 ;;
  esac
  printf '%s' "$_fs"
  unset _fs
}

# daemon_detach — leave the caller's cgroups and opt out of the low-memory
# killer. A watcher started from the WebUI is a child of the manager app's root
# shell, so it inherits the app's cgroup: when Android freezes or kills the
# manager, the watcher dies with it. Moving to the root cgroup and pinning
# oom_score_adj makes it behave like a boot-started service instead.
daemon_detach() {
  for _dd in /dev/cpuctl /dev/cpuset /dev/stune /dev/blkio /dev/memcg /sys/fs/cgroup; do
    [ -d "$_dd" ] || continue
    if [ -w "$_dd/cgroup.procs" ]; then
      echo "$$" >"$_dd/cgroup.procs" 2>/dev/null
    elif [ -w "$_dd/tasks" ]; then
      echo "$$" >"$_dd/tasks" 2>/dev/null
    fi
  done
  echo -1000 >"/proc/$$/oom_score_adj" 2>/dev/null
  unset _dd
  return 0
}

# spawn_detached <args...> — start a process that survives the calling shell.
# setsid, then nohup, then a plain background job with every fd redirected.
spawn_detached() {
  if [ -n "$CMD_SETSID" ]; then
    $CMD_SETSID "$@" </dev/null >/dev/null 2>&1 &
    return 0
  fi
  if [ -n "$CMD_NOHUP" ]; then
    $CMD_NOHUP "$@" </dev/null >/dev/null 2>&1 &
    return 0
  fi
  "$@" </dev/null >/dev/null 2>&1 &
  return 0
}

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_LEVEL_VAL=1

_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }

_log() {
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '[%s] %s %s\n' "$1" "$(_ts)" "$2" >>"$LOG_FILE" 2>/dev/null
}

log_error() { _log ERROR "$*"; return 0; }
log_warn() { [ "$LOG_LEVEL_VAL" -ge 1 ] && _log WARN "$*"; return 0; }
log_info() { [ "$LOG_LEVEL_VAL" -ge 1 ] && _log INFO "$*"; return 0; }
log_debug() { [ "$LOG_LEVEL_VAL" -ge 2 ] && _log DEBUG "$*"; return 0; }

log_sep() {
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '=== %s %s ===\n' "$(_ts)" "$*" >>"$LOG_FILE" 2>/dev/null
  return 0
}

log_rotate() {
  [ -f "$LOG_FILE" ] || return 0
  _lr_size=$(file_size "$LOG_FILE")
  case "$_lr_size" in
    '' | *[!0-9]*)
      unset _lr_size
      return 0
      ;;
  esac
  if [ "$_lr_size" -gt "$LOG_MAX_BYTES" ]; then
    if tail -n "$LOG_KEEP_LINES" "$LOG_FILE" >"$LOG_FILE.rot" 2>/dev/null; then
      mv -f "$LOG_FILE.rot" "$LOG_FILE" 2>/dev/null
      _log INFO "log rotated (was $_lr_size bytes)"
    else
      rm -f "$LOG_FILE.rot" 2>/dev/null
    fi
  fi
  unset _lr_size
  return 0
}

# ── Locking (mkdir is atomic on every filesystem Android ships) ───────────────
# lock_acquire <lockdir> [timeout_seconds]
lock_acquire() {
  _lk_path="$1"
  _lk_timeout="${2:-10}"
  _lk_i=0
  mkdir -p "$LOCK_DIR" 2>/dev/null
  while ! mkdir "$_lk_path" 2>/dev/null; do
    _lk_i=$((_lk_i + 1))
    if [ "$_lk_i" -gt "$_lk_timeout" ]; then
      unset _lk_path _lk_timeout _lk_i
      return 1
    fi
    _lk_owner=$(cat "$_lk_path/pid" 2>/dev/null)
    if [ -n "$_lk_owner" ] && [ ! -d "/proc/$_lk_owner" ]; then
      rm -rf "$_lk_path" 2>/dev/null
      continue
    fi
    sleep 1
  done
  echo "$$" >"$_lk_path/pid" 2>/dev/null
  unset _lk_path _lk_timeout _lk_i _lk_owner
  return 0
}

lock_release() { rm -rf "$1" 2>/dev/null; return 0; }

# True only if the lock exists AND its owner is still alive (stale locks are
# cleared here, so a crashed sync can never disable Live Sync permanently).
lock_is_held() {
  [ -d "$1" ] || return 1
  _lh_owner=$(cat "$1/pid" 2>/dev/null)
  if [ -n "$_lh_owner" ] && [ ! -d "/proc/$_lh_owner" ]; then
    rm -rf "$1" 2>/dev/null
    unset _lh_owner
    return 1
  fi
  unset _lh_owner
  return 0
}

# ── Config ────────────────────────────────────────────────────────────────────
read_cfg() {
  [ -f "$CONFIG_FILE" ] || return 0
  sed -n "s/^$1=//p" "$CONFIG_FILE" 2>/dev/null | tail -n 1
}

write_cfg() {
  lock_acquire "$CONFIG_LOCK" 5 || {
    log_warn "config lock busy, $1 not written"
    return 1
  }
  _wc_tmp="$CONFIG_FILE.tmp.$$"
  grep -v "^$1=" "$CONFIG_FILE" 2>/dev/null >"$_wc_tmp"
  printf '%s=%s\n' "$1" "$2" >>"$_wc_tmp"
  mv -f "$_wc_tmp" "$CONFIG_FILE" 2>/dev/null
  lock_release "$CONFIG_LOCK"
  unset _wc_tmp
  return 0
}

_load_log_level() {
  _llv=$(read_cfg LOG_LEVEL)
  case "$_llv" in
    0 | 1 | 2) LOG_LEVEL_VAL="$_llv" ;;
    *) LOG_LEVEL_VAL=1 ;;
  esac
  unset _llv
}

# ── Stats ─────────────────────────────────────────────────────────────────────
read_stat() {
  [ -f "$STATS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATS_FILE" 2>/dev/null | tail -n 1
}

# write_stats KEY=VALUE [KEY=VALUE ...] — one locked read-modify-write for all
# keys, so the watcher and a UI-triggered sync can never clobber each other.
write_stats() {
  lock_acquire "$STATS_LOCK" 5 || {
    log_debug "stats lock busy, dropping: $*"
    return 1
  }
  _ws_tmp="$STATS_FILE.tmp.$$"
  if [ -f "$STATS_FILE" ]; then
    cp -f "$STATS_FILE" "$_ws_tmp" 2>/dev/null || : >"$_ws_tmp"
  else
    : >"$_ws_tmp"
  fi
  for _ws_pair in "$@"; do
    _ws_key="${_ws_pair%%=*}"
    grep -v "^$_ws_key=" "$_ws_tmp" >"$_ws_tmp.n" 2>/dev/null
    mv -f "$_ws_tmp.n" "$_ws_tmp" 2>/dev/null
    printf '%s\n' "$_ws_pair" >>"$_ws_tmp"
  done
  mv -f "$_ws_tmp" "$STATS_FILE" 2>/dev/null
  lock_release "$STATS_LOCK"
  unset _ws_tmp _ws_pair _ws_key
  return 0
}

del_stat() {
  lock_acquire "$STATS_LOCK" 5 || return 1
  _ds_tmp="$STATS_FILE.tmp.$$"
  grep -v "^$1=" "$STATS_FILE" 2>/dev/null >"$_ds_tmp"
  mv -f "$_ds_tmp" "$STATS_FILE" 2>/dev/null
  lock_release "$STATS_LOCK"
  unset _ds_tmp
  return 0
}

# ── Boot fail counter ─────────────────────────────────────────────────────────
read_fail_count() {
  _fc=$(cat "$FAIL_FILE" 2>/dev/null)
  case "$_fc" in
    '' | *[!0-9]*) _fc=0 ;;
  esac
  printf '%s' "$_fc"
  unset _fc
}

write_fail_count() {
  mkdir -p "$DATA_DIR" 2>/dev/null
  printf '%s\n' "$1" >"$FAIL_FILE" 2>/dev/null
  return 0
}

# ── Small utilities ───────────────────────────────────────────────────────────
is_mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

count_files() {
  [ -d "$1" ] || {
    printf '0'
    return 0
  }
  _cf=0
  for _cf_f in "$1"/*; do
    [ -f "$_cf_f" ] || continue
    _cf=$((_cf + 1))
  done
  printf '%s' "$_cf"
  unset _cf _cf_f
}

dir_has_files() { [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

# The directory the platform actually reads CA certificates from.
trust_store_dir() {
  if [ "$SDK" -ge 34 ]; then
    printf '%s' "$APEX_CONSCRYPT_DIR"
  else
    printf '%s' "$SYSTEM_CERT_DIR"
  fi
}

wait_for_prop() { # wait_for_prop <prop> <value> <timeout>
  _wp_i=0
  while [ "$_wp_i" -lt "$3" ]; do
    [ "$(getprop "$1" 2>/dev/null)" = "$2" ] && {
      unset _wp_i
      return 0
    }
    sleep 1
    _wp_i=$((_wp_i + 1))
  done
  unset _wp_i
  return 1
}

wait_for_zygote() { # wait_for_zygote <timeout>
  _wz_i=0
  while [ "$_wz_i" -lt "$1" ]; do
    if [ -n "$(list_pids_by_name zygote)" ]; then
      printf '%s' "$_wz_i"
      unset _wz_i
      return 0
    fi
    sleep 1
    _wz_i=$((_wz_i + 1))
  done
  printf '%s' "$_wz_i"
  unset _wz_i
  return 1
}

# ── Permissions ───────────────────────────────────────────────────────────────
# One entry point, branching internally — calling the wrong variant for the
# running Android version is no longer possible.
fix_permissions() {
  _fp_dir="$1"
  [ -d "$_fp_dir" ] || return 1
  if [ "$SDK" -ge 34 ]; then
    chown -R system:system "$_fp_dir" 2>/dev/null
    chown root:shell "$_fp_dir" 2>/dev/null
    chmod -R 644 "$_fp_dir" 2>/dev/null
    chmod 755 "$_fp_dir" 2>/dev/null
    touch -t 197001010800 "$_fp_dir"/* 2>/dev/null
    touch -t 197001010800 "$_fp_dir" 2>/dev/null
  else
    chown -R root:root "$_fp_dir" 2>/dev/null
    chmod -R 644 "$_fp_dir" 2>/dev/null
    chmod 755 "$_fp_dir" 2>/dev/null
    touch -t 200901010800 "$_fp_dir"/* 2>/dev/null
    touch -t 200901010800 "$_fp_dir" 2>/dev/null
  fi
  unset _fp_dir
  return 0
}

# Read the SELinux label of a directory (empty string if unavailable).
read_selinux_context() {
  _rsc=$(ls -Zd "$1" 2>/dev/null | awk '{print $1}')
  case "$_rsc" in
    '' | '?') _rsc="" ;;
  esac
  printf '%s' "$_rsc"
  unset _rsc
}

# apply_selinux_context <context-or-empty> <target>
apply_selinux_context() {
  [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0
  if [ -n "$1" ]; then
    chcon -R "$1" "$2" 2>/dev/null
  else
    chcon -R "u:object_r:system_security_cacerts_file:s0" "$2" 2>/dev/null ||
      chcon -R "u:object_r:system_file:s0" "$2" 2>/dev/null
  fi
  return 0
}

# ── One-time migration from the pre-v3 layout ─────────────────────────────────
migrate_legacy() {
  [ -d "$LEGACY_CUSTOM_CERT_DIR" ] || return 0
  mkdir -p "$CUSTOM_CERT_DIR" 2>/dev/null
  if dir_has_files "$LEGACY_CUSTOM_CERT_DIR"; then
    cp -f "$LEGACY_CUSTOM_CERT_DIR"/* "$CUSTOM_CERT_DIR"/ 2>/dev/null
    log_warn "Migrated custom certs $LEGACY_CUSTOM_CERT_DIR -> $CUSTOM_CERT_DIR"
  fi
  rm -rf "$LEGACY_CUSTOM_CERT_DIR" 2>/dev/null
  return 0
}
