#!/system/bin/sh
# shellcheck shell=ash disable=SC1091,SC3043
#
# service.sh — late_start boot flow, the Live Sync watcher, and every command
# the WebUI calls. All commands print machine-readable "key=value" lines so the
# UI needs exactly one root call per refresh instead of a dozen.
#
# Usage:
#   service.sh                      boot flow (called by Magisk/KSU/APatch)
#   service.sh --status             one-shot status dump
#   service.sh --certs              user/custom certificates, base64 encoded
#   service.sh --log [lines]        tail of the service log
#   service.sh --clear-log
#   service.sh --force-inject
#   service.sh --sync               (alias: --live-sync-trigger)
#   service.sh --watch              run the watcher in the foreground
#   service.sh --watch-start        spawn the watcher detached
#   service.sh --watch-stop
#   service.sh --config KEY VALUE   LIVE_SYNC=0|1, LOG_LEVEL=0|1|2
#   service.sh --reset-fail

MODDIR="${0%/*}"
case "$MODDIR" in
  '' | "$0") MODDIR="/data/adb/modules/trust-user-certs" ;;
esac

. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/inject.sh"

mkdir -p "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR" "$CUSTOM_CERT_DIR" 2>/dev/null
_load_log_level

# ── Watcher process helpers ───────────────────────────────────────────────────
watcher_pid() {
  _w=$(cat "$WATCH_PID_FILE" 2>/dev/null)
  case "$_w" in
    '' | *[!0-9]*) _w=0 ;;
  esac
  printf '%s' "$_w"
  unset _w
}

watcher_is_running() {
  _wr=$(watcher_pid)
  [ "$_wr" -gt 0 ] || return 1
  [ -d "/proc/$_wr" ] || return 1
  # Guard against a recycled PID belonging to some unrelated process.
  grep -q 'service.sh' "/proc/$_wr/cmdline" 2>/dev/null || return 1
  unset _wr
  return 0
}

watcher_shutdown() {
  log_info "Watcher stopping (pid $$)"
  write_stats "LIVESYNC_STATUS=stopped" "LIVESYNC_PID=0"
  rm -f "$WATCH_PID_FILE" 2>/dev/null
  exit 0
}

detect_inotify() {
  INOTIFY_BIN=""
  for _di_c in "$MODDIR/bin/inotifywait" "$MODDIR/system/bin/inotifywait"; do
    if [ -f "$_di_c" ]; then
      chmod 755 "$_di_c" 2>/dev/null
      INOTIFY_BIN="$_di_c"
      break
    fi
  done
  if [ -z "$INOTIFY_BIN" ] && command -v inotifywait >/dev/null 2>&1; then
    INOTIFY_BIN="$(command -v inotifywait)"
  fi
  if [ -n "$INOTIFY_BIN" ]; then
    "$INOTIFY_BIN" -h >/dev/null 2>&1
    if [ "$?" -ge 126 ]; then
      log_warn "inotifywait found but not executable on this device — using poll mode"
      INOTIFY_BIN=""
    fi
  fi
  unset _di_c
}

# ── The watcher itself ────────────────────────────────────────────────────────
run_watcher() {
  if watcher_is_running && [ "$(watcher_pid)" != "$$" ]; then
    log_warn "Watcher already running (pid $(watcher_pid)) — not starting a second one"
    return 0
  fi

  mkdir -p "$USER_CERT_DIR" 2>/dev/null
  detect_inotify

  if [ -n "$INOTIFY_BIN" ]; then
    WATCH_MODE="inotifywait"
  else
    WATCH_MODE="poll"
  fi

  daemon_detach
  echo "$$" >"$WATCH_PID_FILE"
  trap 'watcher_shutdown' TERM INT HUP

  log_sep "Live Sync watcher started (mode=$WATCH_MODE, pid=$$)"
  write_stats "LIVESYNC_MODE=$WATCH_MODE" "LIVESYNC_PID=$$" "LIVESYNC_STATUS=running"

  # Never inherit a lock from a process that died mid-sync.
  lock_is_held "$SYNC_LOCK" || lock_release "$SYNC_LOCK"

  if [ "$WATCH_MODE" = "inotifywait" ]; then
    while true; do
      "$INOTIFY_BIN" -q -t 45 \
        -e create -e moved_to -e delete -e modify \
        "$USER_CERT_DIR" >/dev/null 2>&1
      _rc=$?
      log_rotate
      case "$_rc" in
        0)
          if lock_is_held "$SYNC_LOCK"; then
            log_debug "Change detected but a sync is already running — skipping"
          else
            log_info "Change detected in $USER_CERT_DIR"
            sleep 1 # debounce bursts of create+modify on the same file
            do_live_sync
          fi
          ;;
        2) : ;; # -t timeout, perfectly normal
        *)
          log_debug "inotifywait exited with $_rc — backing off 5s"
          sleep 5
          ;;
      esac
    done
  else
    log_info "Polling $USER_CERT_DIR every 30s"
    # The listing itself is the fingerprint — no md5sum dependency.
    LAST_HASH=$(ls -la "$USER_CERT_DIR" 2>/dev/null)
    while true; do
      sleep 30
      log_rotate
      CURRENT_HASH=$(ls -la "$USER_CERT_DIR" 2>/dev/null)
      if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
        if lock_is_held "$SYNC_LOCK"; then
          log_debug "Change detected but a sync is already running — skipping"
        else
          log_info "Poll: change detected in $USER_CERT_DIR"
          do_live_sync
        fi
        CURRENT_HASH=$(ls -la "$USER_CERT_DIR" 2>/dev/null)
      fi
      LAST_HASH="$CURRENT_HASH"
    done
  fi
}

cmd_watch_start() {
  if watcher_is_running; then
    log_debug "Watcher already running (pid $(watcher_pid))"
    echo "watcher=already-running"
    echo "rc=0"
    return 0
  fi
  spawn_detached sh "$MODDIR/service.sh" --watch
  _i=0
  while [ "$_i" -lt 5 ]; do
    sleep 1
    if watcher_is_running; then
      echo "watcher=started"
      echo "rc=0"
      unset _i
      return 0
    fi
    _i=$((_i + 1))
  done
  log_error "Watcher failed to start"
  echo "watcher=failed"
  echo "rc=1"
  unset _i
  return 1
}

cmd_watch_stop() {
  _p=$(watcher_pid)
  if [ "$_p" -gt 0 ] && [ -d "/proc/$_p" ]; then
    kill "$_p" 2>/dev/null
    kill_children "$_p" TERM
    _i=0
    while [ -d "/proc/$_p" ] && [ "$_i" -lt 4 ]; do
      sleep 1
      _i=$((_i + 1))
    done
    if [ -d "/proc/$_p" ]; then
      kill -9 "$_p" 2>/dev/null
      kill_children "$_p" KILL
    fi
    log_info "Watcher stopped (was pid $_p)"
  fi
  rm -f "$WATCH_PID_FILE" 2>/dev/null
  write_stats "LIVESYNC_STATUS=stopped" "LIVESYNC_PID=0"
  echo "watcher=stopped"
  echo "rc=0"
  unset _p _i
  return 0
}

# ── UI commands ───────────────────────────────────────────────────────────────
cmd_force_inject() {
  log_sep "Force inject (from UI)"
  _store=$(trust_store_dir)
  if is_mounted "$_store"; then
    sync_store
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      log_warn "Refresh failed verification — rebuilding the overlay from scratch"
      inject_full
      _rc=$?
    fi
  else
    inject_full
    _rc=$?
  fi
  if [ "$_rc" -eq 0 ]; then
    write_fail_count 0
    write_stats "BLOCKED=0"
    log_info "Force inject complete"
  else
    log_error "Force inject failed"
  fi
  echo "rc=$_rc"
  return $_rc
}

cmd_sync() {
  log_sep "Manual sync (from UI)"
  do_live_sync
  _rc=$?

  # Live Sync is meant to be on but the watcher is gone — most likely it was
  # started from the WebUI and died with the manager app. Bring it back.
  if [ "$(read_cfg LIVE_SYNC)" = "1" ] && ! watcher_is_running; then
    log_warn "Watcher was not running — starting it"
    cmd_watch_start >/dev/null
    if watcher_is_running; then
      echo "watcher=restarted"
    else
      echo "watcher=failed"
    fi
  fi

  echo "rc=$_rc"
  return $_rc
}

cmd_reset_fail() {
  write_fail_count 0
  write_stats "BLOCKED=0"
  log_info "Boot fail counter reset from the UI"
  echo "rc=0"
}

cmd_config() {
  case "$1" in
    LIVE_SYNC)
      case "$2" in
        0 | 1) ;;
        *)
          echo "rc=1"
          return 1
          ;;
      esac
      ;;
    LOG_LEVEL)
      case "$2" in
        0 | 1 | 2) ;;
        *)
          echo "rc=1"
          return 1
          ;;
      esac
      ;;
    *)
      echo "rc=1"
      return 1
      ;;
  esac

  write_cfg "$1" "$2" || {
    echo "rc=1"
    return 1
  }
  _load_log_level
  log_info "Config: $1=$2"

  if [ "$1" = "LIVE_SYNC" ]; then
    if [ "$2" = "1" ]; then
      cmd_watch_start
      return $?
    else
      cmd_watch_stop
      return $?
    fi
  fi
  echo "rc=0"
  return 0
}

cmd_status() {
  _store=$(trust_store_dir)

  _users=0
  _trusted=0
  _excluded=0
  if [ -d "$USER_CERT_DIR" ]; then
    for _f in "$USER_CERT_DIR"/*; do
      [ -f "$_f" ] || continue
      _users=$((_users + 1))
      if [ -d "$CERT_STAGE" ] && [ ! -f "$CERT_STAGE/${_f##*/}" ]; then
        _excluded=$((_excluded + 1))
        continue
      fi
      [ -f "$_store/${_f##*/}" ] && _trusted=$((_trusted + 1))
    done
  fi

  if watcher_is_running; then
    _wstate="running"
  elif [ "$(read_cfg LIVE_SYNC)" = "1" ]; then
    _wstate="dead"
  else
    _wstate="disabled"
  fi

  printf 'SDK=%s\n' "$SDK"
  printf 'VERSION=%s\n' "$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)"
  printf 'STORE_DIR=%s\n' "$_store"
  printf 'MOUNTED=%s\n' "$(is_mounted "$_store" && echo 1 || echo 0)"
  printf 'STORE_CERTS=%s\n' "$(count_files "$_store")"
  printf 'BASE_CERTS=%s\n' "$(count_files "$BASE_CERT_DIR")"
  printf 'STAGE_CERTS=%s\n' "$(count_files "$CERT_STAGE")"
  printf 'USER_CERTS=%s\n' "$_users"
  printf 'USER_TRUSTED=%s\n' "$_trusted"
  printf 'USER_EXCLUDED=%s\n' "$_excluded"
  printf 'CUSTOM_CERTS=%s\n' "$(count_files "$CUSTOM_CERT_DIR")"
  printf 'CUSTOM_DIR=%s\n' "$CUSTOM_CERT_DIR"
  printf 'FAIL=%s\n' "$(read_fail_count)"
  printf 'FAIL_LIMIT=%s\n' "$FAIL_LIMIT"
  printf 'BLOCKED=%s\n' "$(read_stat BLOCKED)"
  printf 'INJECT_OK=%s\n' "$(read_stat INJECT_OK)"
  printf 'LAST_INJECT=%s\n' "$(read_stat LAST_INJECT)"
  printf 'LIVE_SYNC=%s\n' "$(read_cfg LIVE_SYNC)"
  printf 'LOG_LEVEL=%s\n' "$(read_cfg LOG_LEVEL)"
  printf 'WATCHER=%s\n' "$_wstate"
  printf 'WATCHER_PID=%s\n' "$(watcher_pid)"
  printf 'WATCH_MODE=%s\n' "$(read_stat LIVESYNC_MODE)"
  printf 'LIVESYNCS=%s\n' "$(read_stat LIVESYNCS)"
  printf 'LAST_SYNC=%s\n' "$(read_stat LAST_SYNC)"
  printf 'LOG_SIZE=%s\n' "$(file_size "$LOG_FILE")"
  printf 'ENFORCING=%s\n' "$(getenforce 2>/dev/null)"
  printf 'BUSYBOX=%s\n' "${BUSYBOX:-none}"
  printf 'TOOL_NSENTER=%s\n' "${CMD_NSENTER:-none}"
  printf 'TOOL_PGREP=%s\n' "${CMD_PGREP:-none}"
  printf 'TOOL_SETSID=%s\n' "${CMD_SETSID:-none}"
  printf 'NOW=%s\n' "$(date +%s)"
  printf 'rc=0\n'
  unset _store _users _trusted _excluded _wstate _f
}

# Emits: <name>|<source>|<trusted 0/1>|<base64 DER>
cmd_certs() {
  _n=0
  for _dir in "$USER_CERT_DIR" "$CUSTOM_CERT_DIR"; do
    [ -d "$_dir" ] || continue
    if [ "$_dir" = "$USER_CERT_DIR" ]; then _src="user"; else _src="custom"; fi
    for _f in "$_dir"/*; do
      [ -f "$_f" ] || continue
      _n=$((_n + 1))
      [ "$_n" -gt 40 ] && break
      _base="${_f##*/}"
      if [ -f "$(trust_store_dir)/$_base" ]; then
        _t=1
      elif [ -d "$CERT_STAGE" ] && [ ! -f "$CERT_STAGE/$_base" ]; then
        _t=x
      else
        _t=0
      fi
      printf '%s|%s|%s|%s\n' "$_base" "$_src" "$_t" "$(base64 "$_f" 2>/dev/null | tr -d '\n')"
    done
  done
  unset _n _dir _src _f _base _t
}

# Prints the command the WebUI should pipe through to base64-encode output.
# Single line on purpose: the legacy ksu.exec bridge only returns the last one.
cmd_b64cmd() {
  if [ -n "$CMD_BASE64" ]; then
    printf '%s\n' "$CMD_BASE64"
  else
    printf 'base64\n'
  fi
}

cmd_log() {
  _lines="${1:-400}"
  case "$_lines" in
    '' | *[!0-9]*) _lines=400 ;;
  esac
  tail -n "$_lines" "$LOG_FILE" 2>/dev/null
  unset _lines
}

cmd_clear_log() {
  : >"$LOG_FILE" 2>/dev/null
  log_info "Log cleared from the UI"
  echo "rc=0"
}

# ── Boot flow ─────────────────────────────────────────────────────────────────
boot_flow() {
  log_rotate
  log_sep "service.sh boot (SDK $SDK)"
  log_tools
  write_stats "BOOT_STAGE=service"

  _z=$(wait_for_zygote 60)
  log_info "Zygote ready after ${_z}s"

  # Android >= 14: the injection deferred by post-fs-data.sh happens here.
  # This block MUST run before the LIVE_SYNC check below — in v2 the early
  # `exit 0` for a disabled Live Sync also skipped the injection entirely.
  if [ "$SDK" -ge 34 ]; then
    if [ "$(read_stat BLOCKED)" = "1" ]; then
      log_error "Deferred inject skipped — bootloop guard is active"
    else
      if inject_high; then
        log_info "Deferred inject complete"
      else
        log_error "Deferred inject failed"
      fi
    fi
    del_stat DEFERRED
  fi

  # Reaching late_start with a booted system is the only honest signal that the
  # current injection did not put the device into a bootloop.
  if wait_for_prop sys.boot_completed 1 180; then
    sleep "$SETTLE_SECONDS"
    write_fail_count 0
    log_info "Boot completed — fail counter reset"
  else
    log_warn "sys.boot_completed never turned 1 — fail counter left at $(read_fail_count)"
  fi

  if [ "$(read_cfg LIVE_SYNC)" = "1" ]; then
    run_watcher
  else
    log_info "Live Sync is disabled — watcher not started"
    write_stats "LIVESYNC_STATUS=disabled" "LIVESYNC_PID=0"
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$1" in
  --status) cmd_status ;;
  --certs) cmd_certs ;;
  --log) cmd_log "$2" ;;
  --b64cmd) cmd_b64cmd ;;
  --clear-log) cmd_clear_log ;;
  --force-inject) cmd_force_inject ;;
  --sync | --live-sync-trigger) cmd_sync ;;
  --watch) run_watcher ;;
  --watch-start) cmd_watch_start ;;
  --watch-stop) cmd_watch_stop ;;
  --config) cmd_config "$2" "$3" ;;
  --reset-fail) cmd_reset_fail ;;
  '') boot_flow ;;
  *)
    echo "unknown command: $1"
    echo "rc=1"
    exit 1
    ;;
esac
