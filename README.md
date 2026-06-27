# Trust-User-Certs

A KernelSU / Magisk module that injects user-installed CA certificates into the system trust store, making them trusted by all apps — including those that ignore user certificates.

---

## What it does

Android separates certificates into two stores: **system** (trusted by all apps) and **user** (trusted only by apps that opt in). Since Android 7, most apps ignore user certificates entirely, which makes tools like HTTP proxies and traffic analyzers difficult to use.

This module copies user certificates from `/data/misc/user/0/cacerts-added` into the system trust store at boot, so all apps see them as system-trusted. On Android 14+ it uses bind mounts into the APEX Conscrypt directory, which is the only method that works reliably on modern Android.

---

## Features

- Works on **Android 13 and 14+** (SDK 33 and 36 tested)
- **Live Sync** — watches for certificate changes using `inotifywait` and syncs automatically without a reboot. Falls back to polling every 30s if `inotifywait` is not available
- **Web UI** — built-in module interface via KSU WebUI with real-time status, logs, and controls
- **Bootloop protection** — fail counter prevents the module from causing boot loops
- **AdGuard compatibility** — conflicting intermediate certificates are automatically removed
- **Custom certificate support** — drop extra certs in `/data/local/tmp/cert/` and they get injected too
- **Process liveness detection** — UI checks `/proc/<pid>` directly, immune to Android Doze/suspend false-dead readings

---

## Requirements

- KernelSU (tested with SUkiSU-Ultra) or Magisk
- Android 13+ (SDK 33+)
- Zygisk / ReZygisk for proper namespace injection on Android 14+

---

## Installation

1. Download `Trust-User-Certs.zip`
2. In KSU or Magisk Manager → Install from storage → select the zip
3. Reboot
4. Open the module UI from KSU Manager

---

## UI

The built-in WebUI shows:

- **Module status** — working / broken, cert counts, fail counter
- **User certificates** — lists all installed user CA certs with name, valid from, valid until, and serial number
- **Live Sync** — enable/disable, watcher mode (inotifywait or poll), running status via PID check
- **Log level** — off / normal / verbose
- **Actions** — Force Inject, Force Sync, Reset Fail Counter
- **Service log** — filterable by INFO / WARN / ERR / DBG

---

## How it works

### Android 13 and below
At `post-fs-data` stage, a tmpfs is mounted over `/system/etc/security/cacerts` containing both system and user certificates. This runs early in boot before apps start.

### Android 14+
The system certificate store moved into the APEX Conscrypt module at `/apex/com.android.conscrypt/cacerts`. Bind mounting in `post-fs-data` is unreliable at this stage because APEX is not fully initialized. Instead:

1. `post-fs-data.sh` sets a `DEFERRED=1` flag and exits
2. `service.sh` waits for zygote to be ready, then performs the bind mount injection into both the active APEX path and all per-process mount namespaces (init, zygote, zygote64)

### Live Sync
`service.sh` stays running in the background watching `/data/misc/user/0/cacerts-added` for changes. When a user installs or removes a certificate through Android Settings, the change is detected and synced into the active bind mount immediately — no reboot required.

A sync lockfile prevents the watcher from re-triggering on changes made by the sync itself. A 1-second debounce collapses rapid event bursts (create + attrib on the same file) into a single sync operation.

---

## File structure

```
/data/adb/modules/trust-user-certs/
├── post-fs-data.sh     — early boot injection (Android <= 13) or defer flag
├── service.sh          — deferred injection + Live Sync daemon
├── sh/
│   └── common.sh       — shared variables, logging, permission helpers
├── webroot/
│   └── index.html      — KSU WebUI
└── system/
    └── bin/
        └── inotifywait — optional, bundled binary for file watching

/data/adb/trust-user-certs/
├── config              — module settings (LIVE_SYNC, LOG_LEVEL)
├── stats               — runtime state (PID, status, sync count)
├── logs/
│   └── service.log     — module log
└── boot_fail_count     — bootloop protection counter
```

---

## Custom certificates

Place any `.pem` or `.0` certificate files in `/data/local/tmp/cert/` and they will be included in the next inject or sync cycle.

---

## Troubleshooting

**Module shows BROKEN**
Check the service log in the UI. Common cause: APEX bind mount failed. Try Force Inject from the Actions section.

**Live Sync shows DEAD after phone wakes from sleep**
This was a known issue with heartbeat-based detection. The current version uses `/proc/<pid>` liveness check which is not affected by Doze mode.

**Certificates not trusted by a specific app**
Some apps (e.g. those with certificate pinning) will not trust any injected certificate regardless. Use [JustTrustMePro](https://github.com/hang666/JustTrustMePro/releases) via LSPosed to bypass pinning.

**Bootloop**
The fail counter stops injection after 3 failed attempts. Boot into safe mode, open a root shell and run:
```sh
echo 0 > /data/adb/trust-user-certs/boot_fail_count
```
Or use the Reset Fail Counter button in the UI on next successful boot.

---

## Credits

Inspired by and initially based on [AlwaysTrustUserCerts](https://github.com/NVISOsecurity/AlwaysTrustUserCerts). Rewritten and significantly improved.

---

## License

MIT
