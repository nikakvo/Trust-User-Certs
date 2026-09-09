# Trust-User-Certs

A KernelSU / Magisk module that injects user-installed CA certificates into the system trust store, making them trusted by all apps — including those that ignore user certificates.

---

## What it does

Android separates certificates into two stores: **system** (trusted by all apps) and **user** (trusted only by apps that opt in). Since Android 7, most apps ignore user certificates entirely, which makes tools like HTTP proxies and traffic analyzers difficult to use.

This module merges the user certificates from `/data/misc/user/0/cacerts-added` into the system trust store at boot, so every app sees them as system-trusted. On Android 14+ it bind mounts into the APEX Conscrypt directory, which is the only method that works reliably on modern Android.

---

## Features

- **Android 7 – 16** (SDK 24 – 36). Verified on SDK 36; the SDK ≤ 33 path was rewritten in v3
- **Live Sync** — watches the user certificate store with `inotifywait` and syncs without a reboot. Falls back to polling every 30 s when `inotifywait` cannot run
- **Verified injection** — every inject is checked against the live store and the result is recorded as `INJECT_OK`. A failed mount is reported as a failure instead of a success
- **Removal propagates** — deleting a user certificate removes it from the system store on the next sync, because the certificate set is rebuilt from a pristine snapshot of the OS store
- **Web UI** — status, certificate list, Live Sync toggle, log level, actions and a filterable log
- **Bootloop protection** — the fail counter is cleared only after `sys.boot_completed`, so it reflects an actual survived boot
- **Configurable exclusion rules** — certificates can be dropped by subject hash or by a substring of the certificate body (ships with an AdGuard rule)
- **Custom certificates** — drop extra certificates into a root-only directory and they are injected too
- **No unchecked dependencies** — `nsenter`, `pgrep`, `pkill`, `setsid`, `stat` and `base64` are resolved at runtime with a busybox fallback and, where possible, a pure-shell implementation

---

## Requirements

- KernelSU, SukiSU-Ultra, APatch or Magisk (tested on SukiSU-Ultra)
- Android 7+ (SDK 24+)
- **The WebUI needs a root manager that provides the `ksu` JavaScript bridge** — KernelSU, SukiSU, APatch or MMRL. Plain Magisk has no built-in WebUI; the module itself works there, but the interface is only reachable through MMRL or KsuWebUIStandalone.

Zygisk is **not** required. The module enters the zygote mount namespaces itself with `nsenter`.

---

## Installation

1. Download `Trust-User-Certs-v3.zip`
2. In your root manager → Install from storage → select the zip
3. Reboot
4. Open the module UI from the manager

<img width="300" alt="Trust-User-Certs" src="https://raw.githubusercontent.com/nikakvo/Trust-User-Certs/main/Trust-User-Certs.jpg" />

---

## UI

- **Module status** — `WORKING` / `PARTIAL` / `NOT WORKING` / `BLOCKED`, store certificate count, trusted user certificates, fail counter
- **Certificates** — every user and custom certificate with its file name, subject, validity dates, serial, source badge, and whether it actually reached the system store
- **Live Sync** — toggle that starts and stops the watcher immediately, plus watcher mode, PID and sync count
- **Log level** — off / normal / verbose
- **Actions** — Force Inject, Force Sync, Reset Fail Counter
- **Service log** — timestamped, filterable by INFO / WARN / ERR / DBG, with a size indicator and a clear button

---

## How it works

### Android 13 and below

At the `post-fs-data` stage a tmpfs is mounted over `/system/etc/security/cacerts` holding the merged certificate set. This runs early in boot, before any app starts.

### Android 14+

The system certificate store moved into the APEX Conscrypt module at `/apex/com.android.conscrypt/cacerts`. Bind mounting during `post-fs-data` is unreliable because the APEX is mounted but not yet finalised. Instead:

1. `post-fs-data.sh` records `DEFERRED=1` and exits
2. `service.sh` waits for zygote, tears down any previous overlay, then bind mounts the merged set over the APEX path, the versioned APEX path, and the mount namespaces of init and zygote

The deferred injection runs **before** the Live Sync check, so turning Live Sync off never disables certificate injection.

### Live Sync

`service.sh --watch` runs in the background watching `/data/misc/user/0/cacerts-added`. When a certificate is installed or removed through Android Settings, the change is synced into the active mount immediately.

The certificate set is rebuilt from `base_certs` — a snapshot of the OS trust store taken while no overlay of ours is active — then user certificates, custom certificates and exclusion rules are applied on top. That is why removals propagate.

A sync lock serialises the watcher against a sync triggered from the UI. The lock stores its owner PID, so a process that dies mid-sync cannot leave Live Sync permanently stuck. A one-second debounce collapses bursts of `create` + `modify` on the same file into a single sync.

---

## File structure

```
/data/adb/modules/trust-user-certs/
├── post-fs-data.sh     — early boot injection (Android <= 13) or defer flag
├── service.sh          — boot flow, Live Sync watcher, UI command interface
├── customize.sh        — installer
├── uninstall.sh        — cleanup and overlay teardown
├── sh/
│   ├── common.sh       — paths, logging, locking, tool resolution, permissions
│   └── inject.sh       — staging, injection, verification, live sync
├── bin/
│   └── inotifywait     — bundled watcher binary (not mounted into /system)
└── webroot/
    └── index.html      — WebUI

/data/adb/trust-user-certs/          (mode 0700)
├── config              — LIVE_SYNC, LOG_LEVEL
├── stats               — runtime state (watcher PID, sync counts, INJECT_OK)
├── boot_fail_count     — bootloop protection counter
├── watcher.pid         — Live Sync watcher PID
├── certs/              — your custom certificates
├── base_certs/         — pristine snapshot of the OS trust store
├── cert_stage/         — the merged set that gets mounted
├── locks/              — sync / stats / config locks
├── exclude_hashes      — exclusion rules by subject hash
├── exclude_subjects    — exclusion rules by certificate body substring
└── logs/
    └── service.log     — rotates at 256 KB
```

---

## Custom certificates

Put certificates in `/data/adb/trust-user-certs/certs/`, then press **Force Inject**.

Files **must** be named `<subject_hash_old>.0` — that is how Android looks certificates up in the trust store. A file with any other name is copied but silently ignored by the platform, so the module logs a warning for it. To produce a correctly named file from a PEM:

```sh
openssl x509 -inform PEM -subject_hash_old -in cert.pem | head -1
# -> e.g. 87bc3517, so the file must be named 87bc3517.0
cp cert.pem 87bc3517.0
```

The directory is root-only by design. Earlier versions used `/data/local/tmp/cert`, which any adb shell could write to — meaning anyone with adb access could install a *system-trusted* CA. Existing certificates are migrated automatically on install and on boot, and the old directory is removed.

---

## Exclusion rules

Certificates matched by a rule are kept out of the system store.

- `exclude_hashes` — one subject hash per line (the part before `.0`)
- `exclude_subjects` — one substring per line, matched against the certificate body; only user and custom certificates are scanned

Lines starting with `#` are ignored. Both files ship with a rule for AdGuard's personal intermediate CA, which conflicts when present in the system store.

---

## Command line

`service.sh` is the same interface the WebUI uses, so everything the UI does can be done from a root shell:

```sh
S=/data/adb/modules/trust-user-certs/service.sh

sh $S --status              # key=value status dump
sh $S --certs               # user/custom certificates, base64 encoded
sh $S --log 200             # tail of the service log
sh $S --clear-log
sh $S --force-inject        # refresh the overlay, rebuilding it if verification fails
sh $S --sync                # one live sync pass
sh $S --watch-start         # start the Live Sync watcher
sh $S --watch-stop
sh $S --config LIVE_SYNC 1  # also starts/stops the watcher
sh $S --config LOG_LEVEL 2
sh $S --reset-fail
```

---

## Troubleshooting

**Status shows NOT WORKING**
The trust store is not overlaid. Check the service log; the usual cause is a failed bind mount. Try Force Inject.

**Status shows PARTIAL**
The overlay is active but not every user certificate reached the store. The certificate list marks which one is missing. A certificate dropped by an exclusion rule is labelled *excluded by rule* and does not count as a failure.

**Status shows BLOCKED**
The bootloop guard tripped after three boots that did not complete. Press Reset Fail Counter, or:

```sh
echo 0 > /data/adb/trust-user-certs/boot_fail_count
```

**Live Sync shows DEAD**
Toggle it off and on — that restarts the watcher without a reboot. Liveness is read from `/proc/<pid>`, so Doze and suspend cannot produce a false dead reading.

**The log warns that `nsenter` is unavailable**
Certificates cannot be pushed into the zygote mount namespace on that device, so apps started before the injection may not see them until a reboot. `service.sh --status` reports the resolved toolchain as `BUSYBOX`, `TOOL_NSENTER`, `TOOL_PGREP` and `TOOL_SETSID`.

**Certificates not trusted by a specific app**
Apps with certificate pinning will not trust any injected certificate. Use [JustTrustMePro](https://github.com/hang666/JustTrustMePro/releases) via LSPosed to bypass pinning.

**The WebUI is blank or shows a red error box**
The root manager did not provide a working `ksu` JavaScript bridge. Open the module through KernelSU, SukiSU, APatch or MMRL.

---

## Uninstalling

Removing the module through your manager unmounts the overlay, stops the watcher and deletes `/data/adb/trust-user-certs`, including any custom certificates. Your user certificates in Android Settings are untouched.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## Credits

Inspired by and initially based on [AlwaysTrustUserCerts](https://github.com/NVISOsecurity/AlwaysTrustUserCerts). Rewritten and significantly improved.

---

## Notes

- Built and tested against the Poco F6 Pro SukiSU kernel setup and SukiSU Ultra Manager used in this repository: [GKI KernelSU SUSFS](https://github.com/nikakvo/GKI_KernelSU_SUSFS) and [Xiaomi.eu ROM](https://xiaomi.eu/community/)

---

## License

MIT
