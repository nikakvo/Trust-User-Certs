# Trust-User-Certs

A KernelSU / Magisk / APatch module that injects user-installed CA certificates into the system trust store, making them trusted by all apps — including those that ignore user certificates.

---

## What it does

Android separates certificates into two stores: **system** (trusted by all apps) and **user** (trusted only by apps that opt in). Since Android 7, most apps ignore user certificates entirely, which makes HTTP proxies and traffic analyzers (HttpCanary, mitmproxy, Burp, Charles…) difficult to use.

This module merges the user certificates from `/data/misc/user/0/cacerts-added` — plus any custom certificates you drop into its own directory — into the system trust store, so every app sees them as system-trusted. On Android 14+ it bind mounts into the APEX Conscrypt directory, which is the only method that works reliably on modern Android.

Install and remove certificates the normal way in Android Settings; with Live Sync on, the change reaches the system store within a few seconds, without a reboot.

---

## Features

- **Android 7 – 16** (SDK 24 – 36). Verified on SDK 36; the SDK ≤ 33 path was rewritten in v3
- **Live Sync** — the root manager's own busybox `inotifyd` reports every change to the user and custom certificate stores; a burst of events becomes exactly one sync. Nothing is bundled, nothing polls. Self-healing, with a 30 s polling fallback
- **Verified injection** — every inject and sync is checked against the live store, for user *and* custom certificates. A failed mount is reported as a failure instead of a success
- **Removal propagates** — deleting a certificate removes it from the system store on the next sync, because the set is rebuilt from a pristine snapshot of the OS store
- **Custom certificates** — a root-only drop-in directory, watched by Live Sync
- **Web UI** — status, certificate list, Live Sync toggle, log level, actions, a filterable log and a built-in **help page**
- **Bootloop protection** — the fail counter is cleared only after `sys.boot_completed`, so it reflects an actual survived boot
- **Configurable exclusion rules** — by subject hash or by a substring of the certificate body (ships with an AdGuard rule)
- **No unchecked dependencies** — `nsenter`, `pgrep`, `pkill`, `setsid`, `stat`, `mkfifo` and `base64` are resolved at runtime with a busybox fallback and, where possible, a pure-shell implementation

---

## Requirements

- KernelSU, SukiSU-Ultra, APatch or Magisk
- Android 7+ (SDK 24+)
- A busybox with `inotifyd` for event-driven Live Sync — every current Magisk, KernelSU, SukiSU and APatch busybox has one. Without it Live Sync polls every 30 s
- **The WebUI needs a root manager that provides the `ksu` JavaScript bridge** — KernelSU, SukiSU, APatch or MMRL. Plain Magisk has no built-in WebUI; the module itself works there, but the interface is only reachable through MMRL or KsuWebUIStandalone.

Zygisk is **not** required. The module enters the zygote mount namespaces itself with `nsenter`.

### Tested on

- **Poco F6 Pro**, **Xiaomi.eu ROM** (HyperOS 3, Android 16), custom GKI kernel 5.15, **SukiSU-Ultra**

Other devices, ROMs and root managers are supported by design but have not been tested by the author. If something does not work, the service log usually says why — reports are welcome.

---

## Installation

1. Download `Trust-User-Certs-v4.zip` from the [releases](https://github.com/nikakvo/Trust-User-Certs/releases)
2. In your root manager → Install from storage → select the zip
3. Reboot
4. Open the module UI from the manager — **HELP** in the top right explains everything below

<img width="300" alt="Trust-User-Certs" src="https://raw.githubusercontent.com/nikakvo/Trust-User-Certs/main/Trust-User-Certs.jpg" />

---

## Installing a certificate

Use the **CA certificate** option — it is the only one that makes a certificate trusted.

| file | what it is |
|---|---|
| `.crt` `.cer` `.pem` `.der` | an X.509 certificate (text or binary) — install as **CA certificate** |
| `.p12` `.pfx` | certificate **and private key** — not a CA certificate; extract the certificate first: `openssl pkcs12 -in file.p12 -nokeys -out ca.pem` |

On the **Xiaomi.eu ROM (HyperOS 3)**:

```
Settings → Fingerprint, face data, and screen lock → Privacy
  → More security settings → Encryption & credentials
  → Install a certificate → CA certificate
```

On other ROMs, search Settings for *CA certificate*. To remove one: *Encryption & credentials → Trusted credentials → User → the certificate → Remove*.

The other two options in *Install a certificate* — *VPN & app user certificate* and *(Wi-Fi) certificate* — identify your phone to a VPN or Wi-Fi network. They never make anything trusted and are ignored by this module. Proxy apps do not need them either: their "VPN" is a local `VpnService`, and decrypting HTTPS depends only on their CA certificate.

---

## UI

- **Module status** — `WORKING` / `READY` / `PARTIAL` / `NOT WORKING` / `BLOCKED`, store certificate count, trusted user certificates, trusted custom certificates, fail counter
- **Certificates** — every user and custom certificate with its file name, subject, validity dates, serial, source badge, and whether it actually reached the system store
- **Live Sync** — toggle that starts and stops the watcher immediately, plus mode (event-driven / polling), PID, sync count and restarts
- **Log level** — errors only / normal / verbose
- **Actions** — Force Inject, Force Sync, Reset Fail Counter
- **Service log** — timestamped, filterable by INFO / WARN / ERR / DBG, with a size indicator and a clear button
- **Help** — a full guide built into the module

---

## How it works

### Android 13 and below

At the `post-fs-data` stage a tmpfs is mounted over `/system/etc/security/cacerts` holding the merged certificate set. This runs early in boot, before any app starts.

### Android 14+

The system certificate store moved into the APEX Conscrypt module at `/apex/com.android.conscrypt/cacerts`. Bind mounting during `post-fs-data` is unreliable because the APEX is mounted but not yet finalised. Instead:

1. `post-fs-data.sh` records `DEFERRED=1` and exits
2. `service.sh` waits for zygote, tears down any previous overlay, then bind mounts the merged set over the APEX path, the versioned APEX path, and the mount namespaces of init and zygote

The deferred injection runs **before** the Live Sync check, so turning Live Sync off never disables certificate injection.

The certificate set is rebuilt from `base_certs` — a snapshot of the OS trust store taken while no overlay of ours is active — then user certificates, custom certificates and exclusion rules are applied on top. That is why removals propagate.

### Verification

Every inject and sync checks that the live store holds at least the staged set and that every user and custom certificate actually reached it:

```
Verify OK — 151 certs live, 1/1 user certs trusted, 1/1 custom certs trusted
```

### Live Sync

`service.sh` runs a watcher built on busybox `inotifyd`, which writes kernel events into a FIFO the watcher reads with the shell's builtin `read`. Idle cost: two sleeping processes, no CPU, nothing spawned.

Watched:

- `/data/misc/user/0/cacerts-added` — certificates installed / removed in Settings
- `/data/misc/user/0` — notices `cacerts-added` being created (the first certificate ever) or removed
- `/data/adb/trust-user-certs/certs` — custom certificates

Only creations, completed writes, deletions and renames count; reading the certificates — which every sync does — never triggers a sync. Android's KeyChain writes a certificate in place (create → write, ~50 ms) and removes one with write → delete, so the watcher waits for 2 seconds of quiet and then syncs once (at the latest after 10 s of continuous changes):

```
Change detected (2 event(s), first: n cacerts-added/87bc3517.0)
```

Every 60 seconds the watcher checks that `inotifyd` is still alive and restarts it if not, followed by one resync. After more than 5 failures in 10 minutes — or when `inotifyd` does not exist — it switches to polling every 30 s. A sync lock serialises the watcher against a sync triggered from the UI; it stores its owner PID, so a process that dies mid-sync cannot leave Live Sync stuck.

PIDs from a file are never trusted on their own: a process counts as the watcher only if it is alive, not a zombie, and its command line contains the module's path. Runtime files are cleared at every boot.

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
└── webroot/
    ├── index.html      — WebUI
    └── help.html       — built-in guide

/data/adb/trust-user-certs/          (mode 0700, survives updates)
├── config              — LIVE_SYNC, LOG_LEVEL
├── stats               — runtime state (watcher mode and PID, sync counts, INJECT_OK)
├── boot_fail_count     — bootloop protection counter
├── certs/              — your custom certificates
├── base_certs/         — pristine snapshot of the OS trust store
├── cert_stage/         — the merged set that gets mounted
├── locks/              — sync / stats / config locks
├── exclude_hashes      — exclusion rules by subject hash
├── exclude_subjects    — exclusion rules by certificate body substring
├── watcher.pid         — runtime only, cleared at boot
├── inotifyd.pid        — runtime only
├── watch.fifo          — inotifyd → watcher
└── logs/
    └── service.log     — rotates at 256 KB

/data/misc/user/0/cacerts-added/     — Android's user store, owned by system — never created by the module
```

---

## Custom certificates

Put certificates in `/data/adb/trust-user-certs/certs/`. Live Sync picks them up within seconds (with Live Sync off: **Force Inject**). They appear in Settings under **System**.

Files **must** be named `<subject_hash_old>.0` — that is how Android looks certificates up in the trust store. A file with any other name is copied but ignored by the platform, so the module logs a warning for it. PEM and DER both work.

```sh
openssl x509 -in cert.pem -noout -subject_hash_old
# -> e.g. 87bc3517, so the file must be named 87bc3517.0
cp cert.pem 87bc3517.0
```

Without openssl: install the certificate once in Settings — Android names the file correctly — then copy it over and, if you like, remove it from Settings:

```sh
su -c "cp /data/misc/user/0/cacerts-added/87bc3517.0 /data/adb/trust-user-certs/certs/"
su -c "chmod 644 /data/adb/trust-user-certs/certs/87bc3517.0"
```

> **Uninstalling the module deletes this directory.** Keep a copy of your custom certificates elsewhere. Updates keep them.

The directory is root-only by design. Versions before v3 used `/data/local/tmp/cert`, which any adb shell could write to — meaning anyone with adb access could install a *system-trusted* CA. Existing certificates are migrated automatically on install and on boot, and the old directory is removed.

---

## Exclusion rules

Certificates matched by a rule are kept out of the system store.

- `exclude_hashes` — one subject hash per line (the part before `.0`)
- `exclude_subjects` — one substring per line, matched against the certificate body; only user and custom certificates are scanned

Lines starting with `#` are ignored. Both files ship with a rule for AdGuard's personal intermediate CA, which conflicts when present in the system store. An excluded certificate is labelled *excluded by rule* and does not count as a failure.

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
sh $S --sync                # one live sync pass (restarts a dead watcher)
sh $S --watch-start         # start the Live Sync watcher
sh $S --watch-stop
sh $S --config LIVE_SYNC 1  # also starts/stops the watcher
sh $S --config LOG_LEVEL 2
sh $S --reset-fail
```

Quick health check:

```sh
su -c "sh $S --status" | grep -E 'INJECT_OK|WATCH|USER_|CUSTOM_'
su -c "ps -A -o PID,PPID,ARGS | grep -E 'trust-user-certs|inotifyd - /data/misc' | grep -v grep"
```

Expect `WATCH_MODE=events` and exactly two processes: the watcher and its `inotifyd`.

---

## Troubleshooting

**Status shows NOT WORKING**
The trust store is not overlaid. Check the service log for `Verify FAILED`; the usual cause is a failed bind mount. Try Force Inject.

**Status shows PARTIAL**
The overlay is active but not every user or custom certificate reached the store. The certificate list marks which one. A certificate dropped by an exclusion rule is labelled *excluded by rule* and does not count as a failure.

**Status shows BLOCKED**
The bootloop guard tripped after three boots that did not complete. Press Reset Fail Counter, or:

```sh
echo 0 > /data/adb/trust-user-certs/boot_fail_count
```

**Live Sync shows DEAD**
Press Force Sync — it restarts the watcher — or toggle Live Sync off and on. A watcher started from the UI moves itself out of the manager app's cgroups, so closing the manager does not kill it.

**Live Sync says "polling every 30s"**
Your busybox has no `inotifyd`, or it kept exiting. Syncing still works, only up to 30 s later. The log says which.

**Android will not install the certificate**
A `.p12` / `.pfx` is not a CA certificate — extract it first. Versions up to v3.1 created `cacerts-added` as root, which could stop Android from installing the first user certificate; v4 repairs that on install and at boot.

**The log warns that `nsenter` is unavailable**
Certificates cannot be pushed into the zygote mount namespace on that device, so apps started before the injection may not see them until a reboot. `service.sh --status` reports the resolved toolchain as `BUSYBOX`, `TOOL_NSENTER`, `TOOL_PGREP` and `TOOL_SETSID`.

**Certificates not trusted by a specific app**
Apps with certificate pinning will not trust any injected certificate. Use [JustTrustMePro](https://github.com/hang666/JustTrustMePro/releases) via LSPosed to bypass pinning.

**The WebUI is blank or shows a red error box**
The root manager did not provide a working `ksu` JavaScript bridge. Open the module through KernelSU, SukiSU, APatch or MMRL.

---

## Uninstalling

Removing the module takes effect at the next reboot: the overlay is no longer mounted, and `uninstall.sh` stops anything left of Live Sync and deletes `/data/adb/trust-user-certs`, **including any custom certificates**. Your user certificates in Android Settings are untouched.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## Credits

Inspired by and initially based on [AlwaysTrustUserCerts](https://github.com/NVISOsecurity/AlwaysTrustUserCerts). Rewritten and significantly improved.

---

## Notes

- Built and tested against the Poco F6 Pro SukiSU kernel setup and SukiSU Ultra Manager used in this repository: [GKI KernelSU SUSFS](https://github.com/nikakvo/GKI_KernelSU_SUSFS) and [Xiaomi.eu ROM](https://xiaomi.eu/community/)
- Other modules by the same author: [developer-option-persist](https://github.com/nikakvo/developer-option-persist), [dnscrypt-proxy-android-arm64-only](https://github.com/nikakvo/dnscrypt-proxy-android-arm64-only)

---

## License

[MIT](LICENSE)
