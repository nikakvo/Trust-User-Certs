#!/system/bin/sh
# shellcheck shell=ash disable=SC1091
#
# post-fs-data.sh — early boot stage.
#   Android <= 13 : inject now (tmpfs over /system/etc/security/cacerts works here)
#   Android >= 14 : only mark the work as deferred; the conscrypt APEX is mounted
#                   but not finalised yet, so a bind mount here fails.

MODDIR="${0%/*}"
case "$MODDIR" in
  '' | "$0") MODDIR="/data/adb/modules/trust-user-certs" ;;
esac

. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/inject.sh"

mkdir -p "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR" "$CUSTOM_CERT_DIR" "$USER_CERT_DIR" 2>/dev/null

_load_log_level
log_rotate
log_sep "post-fs-data (SDK $SDK)"
log_tools

migrate_legacy

# Locks never survive a reboot.
rm -rf "$LOCK_DIR"/*.lock 2>/dev/null

write_stats "BOOT_STAGE=post-fs-data" "LIVESYNC_STATUS=stopped" "LIVESYNC_PID=0"

FAIL_COUNT=$(read_fail_count)
if [ "$FAIL_COUNT" -ge "$FAIL_LIMIT" ]; then
  log_error "Boot fail counter is $FAIL_COUNT (limit $FAIL_LIMIT) — injection disabled to prevent a bootloop."
  log_error "Reset it from the WebUI or with: echo 0 > $FAIL_FILE"
  write_stats "INJECT_OK=0" "BLOCKED=1"
  exit 0
fi

# Counted up here, cleared in service.sh once the device has actually finished
# booting. Clearing it right after a successful mount (as v2 did) made the
# bootloop guard useless.
write_fail_count $((FAIL_COUNT + 1))
write_stats "BLOCKED=0"

if [ "$SDK" -le 33 ]; then
  if inject_low; then
    log_info "Injection complete (Android <= 13)"
  else
    log_error "Injection failed (Android <= 13)"
  fi
else
  log_info "Android >= 14 — deferring injection to service.sh"
  mkdir -p "$CERT_STAGE" 2>/dev/null
  write_stats "DEFERRED=1"
fi
