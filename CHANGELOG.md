# Changelog

## v3

### Fixed — critical

- **`local` outside a function killed `post-fs-data.sh` on Android 7–13.**
  `local selinux_ctx` sat in the body of an `if` block. In dash/busybox-ash that
  aborts the script, so the tmpfs was never mounted and no certificate was ever
  injected — while the boot fail counter had already been incremented, so the
  module disabled itself after three boots. Never noticed on Android 14+, which
  takes the other branch.
- **`LIVE_SYNC=0` disabled the whole module on Android 14+.** The early
  `exit 0` for a disabled Live Sync ran *before* the deferred injection block.
  The deferred inject now runs first, unconditionally.
- **Injection success was never verified.** `inject_high()` ignored the result of
  every `mount` call and always returned 0, so a completely failed inject was
  reported as "complete" and reset the bootloop counter. There is now a real
  verification step (`INJECT_OK` in the stats file) that checks the live store
  against the staged set and confirms every user certificate is present.
- **The WebUI reported NOT WORKING on Android ≤ 13.** Status counted only
  `/apex/com.android.conscrypt/cacerts`, which does not exist before Android 14.
  Status now comes from a single `service.sh --status` call that knows which
  store the running Android version actually uses.
- **Most WebUI buttons did nothing.** The UI assumed the single-argument
  `ksu.exec(cmd)` bridge. KernelSU/SukiSU/APatch expose a callback form
  (`ksu.exec(cmd, options, callbackName)`), and where the legacy form is absent
  the calls silently failed. The bridge is now probed at startup and both shapes
  are supported, with a visible error screen if neither works.

### Fixed — security

- **XSS in the certificate list.** `cert.cn` / `cert.o` were injected into
  `innerHTML` unescaped. Since the WebUI holds root through `ksu.exec`, a
  certificate with a crafted CN meant arbitrary code execution as root.
  All interpolated values are escaped now.
- **Custom certificate drop-in moved out of `/data/local/tmp/cert`.** That path
  is writable by the `shell` user, so anyone with adb could install a
  *system-trusted* CA. It is now `/data/adb/trust-user-certs/certs`, mode 0700.
  Existing certificates are migrated automatically on install and on boot.

### Fixed — correctness

- Bootloop counter is reset only after `sys.boot_completed` plus a settle delay,
  instead of immediately after mounting — v2's guard could never trigger.
- Certificate **removal** now propagates. The stage is rebuilt from a pristine
  snapshot of the OS trust store, so deleting a user certificate removes it from
  the system store on the next sync.
- Repeated injects no longer stack mount points; the previous overlay is torn
  down in the global namespace and in the zygote/init namespaces first.
- The sync lock now guards the operation that actually writes, is stored with a
  PID, and stale locks are cleared automatically instead of disabling Live Sync
  until the next reboot.
- All stats writes go through a lock, so the watcher and a UI-triggered sync can
  no longer clobber each other's file.
- `copy_custom_certs()` no longer writes into the watched directory, which used
  to retrigger the watcher on every inject.
- `pgrep zygote` already matches `zygote64`; the duplicate call was removed.
- Custom certificates not named `<subject_hash_old>.0` now produce a warning
  instead of being silently ignored by Android.
- SDK detection can no longer end up empty and break every numeric comparison.

### Removed (dead code)

- `MODULE_APEX_CONSCRYPT_DIR`, `MODULE_SYSTEM_CERT_DIR` — defined, never used.
- `log_warn()` — defined, never called (it is used throughout now).
- `LAST_LIVESYNC_HEARTBEAT` — written every 45 s, never read by anything.
- `$MODPATH/apex/...` staging directory — Magisk never mounts `/apex`.
- `$MODPATH/system/etc/security/cacerts` — empty, unused.

### Added — no unchecked external dependencies

Nothing outside the shell is assumed to exist any more. `sh/common.sh` resolves
every risky tool once at load time, in this order: the command on `PATH`, then
the same applet from busybox (Magisk, KernelSU/SukiSU, APatch, busybox-ndk or
`/system/bin`), then a pure-shell implementation where one is possible.

| Tool | Fallback |
|---|---|
| `nsenter` | busybox; otherwise the namespace binds are skipped and a warning explains the consequence |
| `pgrep` | busybox; otherwise `list_pids_by_name()` walks `/proc/*/comm` |
| `pkill -P` | busybox; otherwise `kill_children()` parses `/proc/*/stat` |
| `setsid` | `nohup`; otherwise a plain background job with every fd redirected (`spawn_detached()`) |
| `stat -c %s` | busybox; otherwise `wc -c` (`file_size()`) |
| `base64` | busybox; the WebUI asks `service.sh --b64cmd` at startup and pipes through whatever came back |
| `md5sum` | dependency removed — the poll watcher compares the directory listing directly |
| `find` | dependency removed — the versioned APEX directory is located with a glob |

The resolved toolchain is logged once per boot (`log_tools`) and reported by
`service.sh --status` as `BUSYBOX`, `TOOL_NSENTER`, `TOOL_PGREP`, `TOOL_SETSID`,
so a device missing something shows it in the log instead of failing silently.

### Changed

- `inotifywait` moved from `system/bin/` to the module's own `bin/`, so it is no
  longer mounted into `/system/bin` for every app on the device.
- Log lines carry timestamps and the log rotates at 256 KB (keeping the last
  300 lines).
- Runtime state moved out of the module directory into `/data/adb/trust-user-certs`.
- Configuration survives module updates instead of being reset every install.
- Exclusion rules are configurable: `exclude_hashes` and `exclude_subjects`.
- `service.sh` gained a command interface: `--status`, `--certs`, `--log`,
  `--clear-log`, `--force-inject`, `--sync`, `--watch-start`, `--watch-stop`,
  `--config KEY VALUE`, `--reset-fail`.
- WebUI: working Live Sync toggle, one root call per refresh instead of ~10,
  per-certificate source/trust badges, and PARTIAL / BLOCKED states.

---

## v2

ReBuild

---

## v1.0.0 — 2026-06-27

Initial release.

### Core
- Android 13 and below: tmpfs inject over `/system/etc/security/cacerts` at `post-fs-data`
- Android 14+: deferred bind mount injection into APEX Conscrypt at `service.sh` stage, after zygote is ready
- Per-process namespace injection into init, zygote, zygote64
- Bootloop protection via fail counter (stops after 3 failed boot attempts)
- AdGuard compatibility — conflicting intermediate certificates are automatically removed
- Custom certificate support via `/data/local/tmp/cert/`

### Live Sync
- Background `inotifywait` watcher on `/data/misc/user/0/cacerts-added`
- Automatic fallback to 30s polling if `inotifywait` is not available
- Sync lockfile prevents self-triggering when sync writes to watched directory
- 1-second debounce collapses rapid event bursts into a single sync
- Atomic stats file writes (PID + status + heartbeat in one `mv`) prevent race conditions with UI reads

### WebUI
- Module status with cert counts and fail counter
- User certificates section — lists installed CA certs with CN, organization, valid from, valid until, serial number; parsed from DER format in pure JavaScript (no external binaries)
- Live Sync status using `/proc/<pid>` liveness check — immune to Android Doze/suspend false-dead readings
- Log level control (off / normal / verbose)
- Actions: Force Inject, Force Sync, Reset Fail Counter
- Service log with INFO / WARN / ERR / DBG filters
