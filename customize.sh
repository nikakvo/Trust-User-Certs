##########################################################################################
# TrustUserCerts — installer
##########################################################################################

SKIPUNZIP=0

print_modname() {
  ui_print " "
  ui_print "****************************"
  ui_print "   TrustUserCerts v4"
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

  # A watcher from the previous version is left running on purpose: it keeps
  # working until the reboot that activates this version replaces it.

  # ── Directories ───────────────────────────────────────────────────────────
  ui_print "- Creating data directories..."
  mkdir -p "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR" "$CUSTOM_CERT_DIR"
  mkdir -p "$DATA_DIR/cert_stage" "$DATA_DIR/base_certs"

  # cacerts-added belongs to Android (system:system). v3.1 and older created
  # it as root, which blocks installing the first user certificate — undo it.
  _tuc_ud=/data/misc/user/0/cacerts-added
  if [ -d "$_tuc_ud" ] && [ "$(stat -c %u "$_tuc_ud" 2>/dev/null)" = 0 ]; then
    if rmdir "$_tuc_ud" 2>/dev/null; then
      ui_print "- Removed an empty root-owned cacerts-added (Android recreates it)"
    else
      chown 1000:1000 "$_tuc_ud" 2>/dev/null
      chmod 0755 "$_tuc_ud" 2>/dev/null
      restorecon "$_tuc_ud" 2>/dev/null
      ui_print "- Fixed the owner of cacerts-added (root -> system)"
    fi
  fi
  unset _tuc_ud

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

  # Live Sync uses the root manager's busybox inotifyd (Magisk, KernelSU and
  # APatch all ship it); nothing is bundled.
  _tuc_bb=""
  for _tuc_c in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -x "$_tuc_c" ] && { _tuc_bb="$_tuc_c"; break; }
  done
  if [ -n "$_tuc_bb" ] && "$_tuc_bb" --list 2>/dev/null | grep -qx inotifyd; then
    ui_print "- Live Sync: event-driven (busybox inotifyd)"
  else
    ui_print "- Live Sync: busybox inotifyd not found, will poll every 30s"
  fi
  unset _tuc_bb _tuc_c

  # v2 shipped inotifywait inside system/bin, which mounted it into /system for
  # every app on the device; v3 kept it in bin/. Neither is used any more.
  rm -rf "$MODPATH/system" "$MODPATH/apex" "$MODPATH/bin" 2>/dev/null

  ui_print " "
  ui_print "- Custom certificates go in:"
  ui_print "  $CUSTOM_CERT_DIR"
  ui_print "- Install complete. Reboot to apply."
}

print_modname
on_install
