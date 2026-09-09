#!/system/bin/sh
# shellcheck shell=ash disable=SC3043
#
# inject.sh — certificate staging and trust-store injection.
# Requires sh/common.sh to be sourced first.

# ── Pristine snapshot of the OS trust store ───────────────────────────────────
# Taken only while our own overlay is NOT active, so re-staging never feeds our
# merged set back into itself. This is what makes cert *removal* propagate:
# the stage is rebuilt from the pristine base every time.
refresh_base_certs() {
  _rb_live=$(trust_store_dir)

  if is_mounted "$_rb_live"; then
    log_debug "Trust store already overlaid — keeping cached base snapshot"
    unset _rb_live
    return 0
  fi

  mkdir -p "$BASE_CERT_DIR" 2>/dev/null
  if dir_has_files "$_rb_live"; then
    rm -f "$BASE_CERT_DIR"/* 2>/dev/null
    cp -f "$_rb_live"/* "$BASE_CERT_DIR"/ 2>/dev/null
    log_debug "Base snapshot refreshed: $(count_files "$BASE_CERT_DIR") certs from $_rb_live"
  else
    log_warn "Live trust store $_rb_live is empty — snapshot not refreshed"
  fi
  unset _rb_live
  return 0
}

# ── Exclusion rules (AdGuard & friends) ───────────────────────────────────────
# Hash rules match <hash>.* in the stage. Subject rules are matched only against
# certificates that came from the user/custom stores — scanning all ~150 system
# certs on every sync was pure overhead.
remove_conflicting_certs() {
  _rc_dir="$1"

  if [ -f "$EXCLUDE_HASH_FILE" ]; then
    while IFS= read -r _rc_hash; do
      case "$_rc_hash" in
        '' | '#'*) continue ;;
      esac
      if [ -f "$_rc_dir/$_rc_hash.0" ] || [ -n "$(ls "$_rc_dir/$_rc_hash".* 2>/dev/null)" ]; then
        rm -f "$_rc_dir/$_rc_hash".* 2>/dev/null
        log_debug "Excluded by hash: $_rc_hash"
      fi
    done <"$EXCLUDE_HASH_FILE"
  fi

  [ -f "$EXCLUDE_SUBJ_FILE" ] || {
    unset _rc_dir _rc_hash
    return 0
  }
  [ -s "$EXCLUDE_SUBJ_FILE" ] || {
    unset _rc_dir _rc_hash
    return 0
  }

  for _rc_src in "$USER_CERT_DIR" "$CUSTOM_CERT_DIR"; do
    [ -d "$_rc_src" ] || continue
    for _rc_f in "$_rc_src"/*; do
      [ -f "$_rc_f" ] || continue
      _rc_base="${_rc_f##*/}"
      [ -f "$_rc_dir/$_rc_base" ] || continue
      while IFS= read -r _rc_pat; do
        case "$_rc_pat" in
          '' | '#'*) continue ;;
        esac
        if grep -q "$_rc_pat" "$_rc_f" 2>/dev/null; then
          rm -f "$_rc_dir/$_rc_base" 2>/dev/null
          log_debug "Excluded by subject '$_rc_pat': $_rc_base"
          break
        fi
      done <"$EXCLUDE_SUBJ_FILE"
    done
  done

  unset _rc_dir _rc_hash _rc_src _rc_f _rc_base _rc_pat
  return 0
}

# ── Custom certs ──────────────────────────────────────────────────────────────
# Copied into the stage ONLY. The pre-v3 code also wrote them into
# $USER_CERT_DIR, which re-triggered the inotify watcher on every inject.
copy_custom_certs() {
  _cc_dst="$1"
  [ -d "$CUSTOM_CERT_DIR" ] || return 0
  dir_has_files "$CUSTOM_CERT_DIR" || return 0

  for _cc_f in "$CUSTOM_CERT_DIR"/*; do
    [ -f "$_cc_f" ] || continue
    _cc_base="${_cc_f##*/}"
    case "$_cc_base" in
      *.0) ;;
      *)
        log_warn "Custom cert '$_cc_base' is not named <subject_hash_old>.0 — Android will ignore it"
        ;;
    esac
    cp -f "$_cc_f" "$_cc_dst"/ 2>/dev/null
  done

  log_debug "Custom certs staged from $CUSTOM_CERT_DIR"
  unset _cc_dst _cc_f _cc_base
  return 0
}

# ── Build the full certificate set ────────────────────────────────────────────
stage_certs() {
  refresh_base_certs

  mkdir -p "$CERT_STAGE" 2>/dev/null
  rm -f "$CERT_STAGE"/* 2>/dev/null

  cp -f "$BASE_CERT_DIR"/* "$CERT_STAGE"/ 2>/dev/null

  if ! dir_has_files "$CERT_STAGE"; then
    log_warn "Base snapshot empty — falling back to the live store"
    cp -f "$(trust_store_dir)"/* "$CERT_STAGE"/ 2>/dev/null
  fi

  if dir_has_files "$USER_CERT_DIR"; then
    cp -f "$USER_CERT_DIR"/* "$CERT_STAGE"/ 2>/dev/null
    log_debug "User certs staged: $(count_files "$USER_CERT_DIR")"
  else
    log_debug "No user certificates present"
  fi

  copy_custom_certs "$CERT_STAGE"
  remove_conflicting_certs "$CERT_STAGE"

  log_info "Staged $(count_files "$CERT_STAGE") certificates"
  return 0
}

# ── Verification ──────────────────────────────────────────────────────────────
# Every user certificate must be visible in the live store, and the store must
# not be smaller than the base system set. Without this the module used to
# report success even when every single mount had failed.
verify_inject() {
  _vi_store=$(trust_store_dir)
  _vi_want=$(count_files "$CERT_STAGE")
  _vi_have=$(count_files "$_vi_store")
  _vi_users=0
  _vi_found=0

  if [ -d "$USER_CERT_DIR" ]; then
    for _vi_f in "$USER_CERT_DIR"/*; do
      [ -f "$_vi_f" ] || continue
      # Certificates dropped by an exclusion rule are absent from the stage on
      # purpose — they must not count as a verification failure.
      [ -f "$CERT_STAGE/${_vi_f##*/}" ] || continue
      _vi_users=$((_vi_users + 1))
      [ -f "$_vi_store/${_vi_f##*/}" ] && _vi_found=$((_vi_found + 1))
    done
  fi

  if [ "$_vi_want" -gt 0 ] && [ "$_vi_have" -ge "$_vi_want" ] && [ "$_vi_found" -eq "$_vi_users" ]; then
    log_info "Verify OK — $_vi_have certs live, $_vi_found/$_vi_users user certs trusted"
    write_stats "INJECT_OK=1" "INJECT_COUNT=$_vi_have" "LAST_INJECT=$(date +%s)"
    unset _vi_store _vi_want _vi_have _vi_users _vi_found _vi_f
    return 0
  fi

  log_error "Verify FAILED — staged $_vi_want, live $_vi_have, user certs trusted $_vi_found/$_vi_users"
  write_stats "INJECT_OK=0" "INJECT_COUNT=$_vi_have" "LAST_INJECT=$(date +%s)"
  unset _vi_store _vi_want _vi_have _vi_users _vi_found _vi_f
  return 1
}

# ── Android <= 13: tmpfs over /system/etc/security/cacerts ────────────────────
inject_low() {
  _il_ctx=$(read_selinux_context "$SYSTEM_CERT_DIR")
  stage_certs

  if ! is_mounted "$SYSTEM_CERT_DIR"; then
    if ! mount -t tmpfs tmpfs "$SYSTEM_CERT_DIR" 2>/dev/null; then
      log_error "Failed to mount tmpfs on $SYSTEM_CERT_DIR"
      write_stats "INJECT_OK=0"
      unset _il_ctx
      return 1
    fi
    log_info "tmpfs mounted on $SYSTEM_CERT_DIR"
  else
    log_debug "tmpfs already present on $SYSTEM_CERT_DIR — refreshing contents"
  fi

  cp -f "$CERT_STAGE"/* "$SYSTEM_CERT_DIR"/ 2>/dev/null
  fix_permissions "$SYSTEM_CERT_DIR"
  apply_selinux_context "$_il_ctx" "$SYSTEM_CERT_DIR"

  unset _il_ctx
  verify_inject
}

# ── Android >= 14: bind mount over the conscrypt APEX cacerts ─────────────────
unmount_apex_overlay() {
  _ua_ver="$1"
  _ua_i=0
  while is_mounted "$APEX_CONSCRYPT_DIR" && [ "$_ua_i" -lt 10 ]; do
    umount "$APEX_CONSCRYPT_DIR" 2>/dev/null || umount -l "$APEX_CONSCRYPT_DIR" 2>/dev/null || break
    _ua_i=$((_ua_i + 1))
  done
  if [ -n "$_ua_ver" ]; then
    _ua_i=0
    while is_mounted "$_ua_ver/cacerts" && [ "$_ua_i" -lt 10 ]; do
      umount "$_ua_ver/cacerts" 2>/dev/null || umount -l "$_ua_ver/cacerts" 2>/dev/null || break
      _ua_i=$((_ua_i + 1))
    done
  fi
  # Drop stale binds inside the zygote / init namespaces too, otherwise every
  # re-inject stacks another mount on top of the previous one.
  if [ -n "$CMD_NSENTER" ]; then
    for _ua_pid in 1 $(list_pids_by_name zygote); do
      [ -d "/proc/$_ua_pid" ] || continue
      $CMD_NSENTER --mount="/proc/$_ua_pid/ns/mnt" -- umount "$APEX_CONSCRYPT_DIR" 2>/dev/null
      [ -n "$_ua_ver" ] &&
        $CMD_NSENTER --mount="/proc/$_ua_pid/ns/mnt" -- umount "$_ua_ver/cacerts" 2>/dev/null
    done
  fi
  unset _ua_ver _ua_i _ua_pid
  return 0
}

inject_high() {
  stage_certs
  fix_permissions "$CERT_STAGE"

  _ih_ver=""
  for _ih_cand in /apex/com.android.conscrypt@*; do
    [ -d "$_ih_cand" ] || continue
    _ih_ver="$_ih_cand"
    break
  done
  log_debug "Versioned apex dir: ${_ih_ver:-none}"

  unmount_apex_overlay "$_ih_ver"

  rm -rf "$TEMP_MOUNT" 2>/dev/null
  mkdir -p "$TEMP_MOUNT" 2>/dev/null
  if ! mount -t tmpfs tmpfs "$TEMP_MOUNT" 2>/dev/null; then
    log_error "Failed to mount tmpfs on $TEMP_MOUNT"
    write_stats "INJECT_OK=0"
    unset _ih_ver
    return 1
  fi

  cp -f "$CERT_STAGE"/* "$TEMP_MOUNT"/ 2>/dev/null
  fix_permissions "$TEMP_MOUNT"
  apply_selinux_context "$(read_selinux_context "$APEX_CONSCRYPT_DIR")" "$TEMP_MOUNT"

  _ih_rc=0
  if mount -o bind "$TEMP_MOUNT" "$APEX_CONSCRYPT_DIR" 2>/dev/null; then
    log_debug "bind ok: $APEX_CONSCRYPT_DIR"
  else
    log_error "bind FAILED: $APEX_CONSCRYPT_DIR"
    _ih_rc=1
  fi

  if [ -n "$_ih_ver" ] && [ -d "$_ih_ver/cacerts" ]; then
    if mount -o bind "$TEMP_MOUNT" "$_ih_ver/cacerts" 2>/dev/null; then
      log_debug "bind ok: $_ih_ver/cacerts"
    else
      log_warn "bind failed: $_ih_ver/cacerts"
    fi
  fi

  # A zygote name match already covers both zygote and zygote64.
  if [ -n "$CMD_NSENTER" ]; then
    _ih_ns_ok=0
    _ih_ns_fail=0
    for _ih_pid in 1 $(list_pids_by_name zygote); do
      [ -d "/proc/$_ih_pid" ] || continue
      if $CMD_NSENTER --mount="/proc/$_ih_pid/ns/mnt" -- \
        mount --bind "$TEMP_MOUNT" "$APEX_CONSCRYPT_DIR" 2>/dev/null; then
        _ih_ns_ok=$((_ih_ns_ok + 1))
      else
        _ih_ns_fail=$((_ih_ns_fail + 1))
        log_debug "namespace bind failed for pid $_ih_pid"
      fi
      if [ -n "$_ih_ver" ] && [ -d "$_ih_ver/cacerts" ]; then
        $CMD_NSENTER --mount="/proc/$_ih_pid/ns/mnt" -- \
          mount --bind "$TEMP_MOUNT" "$_ih_ver/cacerts" 2>/dev/null
      fi
    done
    log_debug "namespace binds: $_ih_ns_ok ok, $_ih_ns_fail failed"
    unset _ih_ns_ok _ih_ns_fail
  else
    log_warn "Skipping namespace binds — nsenter is unavailable on this device"
  fi

  # The tmpfs stays alive through the bind mounts; only its staging path goes.
  umount "$TEMP_MOUNT" 2>/dev/null
  rmdir "$TEMP_MOUNT" 2>/dev/null

  if [ "$_ih_rc" -ne 0 ]; then
    write_stats "INJECT_OK=0"
    unset _ih_ver _ih_rc _ih_pid
    return 1
  fi

  unset _ih_ver _ih_rc _ih_pid _ih_cand
  verify_inject
}

# ── Public entry points ───────────────────────────────────────────────────────
inject_full() {
  if [ "$SDK" -ge 34 ]; then
    inject_high
  else
    inject_low
  fi
}

# Refresh the contents of an already active overlay. Much cheaper and far safer
# than tearing the mounts down and rebuilding them.
sync_store() {
  _ss_store=$(trust_store_dir)

  if ! is_mounted "$_ss_store"; then
    log_warn "Trust store is not overlaid — running a full inject instead"
    inject_full
    return $?
  fi

  stage_certs

  # Propagate deletions: anything in the live store that is no longer staged.
  for _ss_f in "$_ss_store"/*; do
    [ -f "$_ss_f" ] || continue
    [ -f "$CERT_STAGE/${_ss_f##*/}" ] && continue
    rm -f "$_ss_f" 2>/dev/null
    log_debug "Removed stale cert ${_ss_f##*/}"
  done

  cp -f "$CERT_STAGE"/* "$_ss_store"/ 2>/dev/null
  fix_permissions "$_ss_store"
  if [ "$SDK" -le 33 ]; then
    apply_selinux_context "" "$_ss_store"
  fi

  unset _ss_store _ss_f
  verify_inject
}

# Live sync — sync_store plus counters, serialised against the watcher.
do_live_sync() {
  if ! lock_acquire "$SYNC_LOCK" 20; then
    log_warn "Live sync skipped — another sync is still running"
    return 1
  fi

  log_info "Live sync started"
  sync_store
  _dls_rc=$?

  _dls_n=$(read_stat LIVESYNCS)
  case "$_dls_n" in
    '' | *[!0-9]*) _dls_n=0 ;;
  esac
  write_stats "LIVESYNCS=$((_dls_n + 1))" "LAST_SYNC=$(date +%s)"

  lock_release "$SYNC_LOCK"
  log_info "Live sync finished (rc=$_dls_rc)"
  unset _dls_n
  return $_dls_rc
}
