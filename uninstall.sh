#!/system/bin/sh
# uninstall.sh — runs when the module is removed via Magisk/KSU/APatch.

DATA_DIR="/data/adb/trust-user-certs"

# Stop the Live Sync watcher if it is still alive.
if [ -f "$DATA_DIR/watcher.pid" ]; then
  PID=$(cat "$DATA_DIR/watcher.pid" 2>/dev/null)
  case "$PID" in
    '' | *[!0-9]*) PID="" ;;
  esac
  if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    kill "$PID" 2>/dev/null
    command -v pkill >/dev/null 2>&1 && pkill -P "$PID" 2>/dev/null
    sleep 1
    [ -d "/proc/$PID" ] && kill -9 "$PID" 2>/dev/null
  fi
fi

# Drop the overlay so the stock trust store is back without a reboot.
umount /apex/com.android.conscrypt/cacerts 2>/dev/null
umount /system/etc/security/cacerts 2>/dev/null

rm -rf "$DATA_DIR"
rm -rf /data/local/tmp/cert
rm -rf /mnt/tuc_instaler /mnt/tuc_stage
