##########################################################################################
# TrustUserCerts — installer
##########################################################################################

SKIPUNZIP=0

print_modname() {
  ui_print " "
  ui_print "****************************"
  ui_print "   TrustUserCerts v3"
  ui_print "   Android 7 - 16"
  ui_print "   Magisk / KSU / APatch"
  ui_print "****************************"
  ui_print " "
}

on_install() {
  DATA_DIR="/data/adb/trust-user-certs"
  LOG_DIR="$DATA_DIR/logs"
  LOCK_DIR="$DATA_DIR/locks"
  CONFIG_FILE="$DATA_DIR/config"
  STATS_FILE="$DATA_DIR/stats"
  FAIL_FILE="$DATA_DIR/boot_fail_count"
  CUSTOM_CERT_DIR="$DATA_DIR/certs"
  LEGACY_CERT_DIR="/data/local/tmp/cert"
  EXCLUDE_HASH_FILE="$DATA_DIR/exclude_hashes"
  EXCLUDE_SUBJ_FILE="$DATA_DIR/exclude_subjects"

  # ── Stop a watcher left over from the previous version ────────────────────
  if [ -f "$DATA_DIR/watcher.pid" ]; then
    OLD_PID=$(cat "$DATA_DIR/watcher.pid" 2>/dev/null)
    case "$OLD_PID" in
      '' | *[!0-9]*) OLD_PID="" ;;
    esac
    if [ -n "$OLD_PID" ] && [ -d "/proc/$OLD_PID" ]; then
      ui_print "- Stopping the running watcher (pid $OLD_PID)"
      kill "$OLD_PID" 2>/dev/null
      command -v pkill >/dev/null 2>&1 && pkill -P "$OLD_PID" 2>/dev/null
    fi
    rm -f "$DATA_DIR/watcher.pid"
  fi

  # ── Directories ───────────────────────────────────────────────────────────
  ui_print "- Creating data directories..."
  mkdir -p "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR" "$CUSTOM_CERT_DIR"
  mkdir -p "$DATA_DIR/cert_stage" "$DATA_DIR/base_certs"
  mkdir -p /data/misc/user/0/cacerts-added

  # Root only — the pre-v3 drop-in dir lived in /data/local/tmp, which any adb
  # shell could write to, i.e. anyone with adb could add a *system* trusted CA.
  chmod 700 "$DATA_DIR" "$CUSTOM_CERT_DIR"

  # ── Migrate certificates from the old drop-in location ────────────────────
  if [ -d "$LEGACY_CERT_DIR" ]; then
    if [ -n "$(ls -A "$LEGACY_CERT_DIR" 2>/dev/null)" ]; then
      ui_print "- Migrating custom certs from $LEGACY_CERT_DIR"
      cp -f "$LEGACY_CERT_DIR"/* "$CUSTOM_CERT_DIR"/ 2>/dev/null
    fi
    rm -rf "$LEGACY_CERT_DIR"
  fi

  # ── Config: keep the user's settings across updates ───────────────────────
  if [ -f "$CONFIG_FILE" ]; then
    ui_print "- Keeping existing configuration"
    grep -q '^LIVE_SYNC=' "$CONFIG_FILE" || echo "LIVE_SYNC=1" >>"$CONFIG_FILE"
    grep -q '^LOG_LEVEL=' "$CONFIG_FILE" || echo "LOG_LEVEL=1" >>"$CONFIG_FILE"
  else
    ui_print "- Writing default configuration"
    cat >"$CONFIG_FILE" <<'EOF'
LIVE_SYNC=1
LOG_LEVEL=1
EOF
  fi

  # ── Exclusion rules ───────────────────────────────────────────────────────
  # Certificates matched here are dropped from the system trust store.
  [ -f "$EXCLUDE_HASH_FILE" ] || cat >"$EXCLUDE_HASH_FILE" <<'EOF'
# One subject hash per line (the part before ".0"). Lines starting with # are ignored.
47ec1af8
EOF

  [ -f "$EXCLUDE_SUBJ_FILE" ] || cat >"$EXCLUDE_SUBJ_FILE" <<'EOF'
# One substring per line, matched against the certificate body.
# Only user/custom certificates are scanned. Lines starting with # are ignored.
Guard Personal Intermediate
EOF

  # ── Fresh runtime state ───────────────────────────────────────────────────
  cat >"$STATS_FILE" <<'EOF'
LIVESYNC_PID=0
LIVESYNC_STATUS=stopped
LIVESYNC_MODE=
LIVESYNCS=0
LAST_SYNC=0
LAST_INJECT=0
INJECT_OK=0
BLOCKED=0
EOF

  echo "0" >"$FAIL_FILE"
  rm -rf "$LOCK_DIR"/*.lock 2>/dev/null
  rm -rf /mnt/tuc_instaler /mnt/tuc_stage 2>/dev/null

  # ── Permissions ───────────────────────────────────────────────────────────
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
  set_perm "$MODPATH/uninstall.sh" 0 0 0755
  set_perm "$MODPATH/sh/common.sh" 0 0 0755
  set_perm "$MODPATH/sh/inject.sh" 0 0 0755

  if [ -f "$MODPATH/bin/inotifywait" ]; then
    set_perm "$MODPATH/bin/inotifywait" 0 0 0755
    ui_print "- inotifywait: found (event-driven Live Sync)"
  else
    ui_print "- inotifywait: missing, Live Sync will poll every 30s"
  fi

  # v2 shipped inotifywait inside system/bin, which mounted it into /system for
  # every app on the device. It lives in the module's own bin/ directory now.
  rm -rf "$MODPATH/system" "$MODPATH/apex" 2>/dev/null

  ui_print " "
  ui_print "- Custom certificates go in:"
  ui_print "  $CUSTOM_CERT_DIR"
  ui_print "- Install complete. Reboot to apply."
}

print_modname
on_install
