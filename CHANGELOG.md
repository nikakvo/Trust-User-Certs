# Changelog

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
