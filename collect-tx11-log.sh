#!/data/data/com.termux/files/usr/bin/sh
# collect-tx11-log.sh — collect everything we need to debug termux-x11
# "Aborted." on a rooted device (or via "adb shell su" from a PC).
#
# Produces: $PREFIX/tmp/tx11-log-<ts>.tgz with
#   - full logcat dump since repro,
#   - all crash lines + linker lines filtering,
#   - /data/system/dropbox crash dump for the last x11 crash (if any),
#   - dmesg tail, device props,
#   - stderr copy of the launcher itself.
#
# Usage:
#   termux-x11            <- first try again with just; this runs and captures
#   ./collect-tx11-log.sh
#
# (The script will run `termux-x11` itself in background, catch output, kill)
set -eu

PDIR="/data/data/com.termux/files/usr"
TS=$(date +%s)
OUT="$PDIR/tmp/tx11-log-$TS"
RUNMSG=$(mktemp)
PIDFILE=""

mkdir -p "$OUT"

echo "== device info =="
getprop ro.build.version.sdk > "$OUT/device.txt" 2>/dev/null || true
getprop ro.build.version.release >> "$OUT/device.txt" 2>/dev/null || true
getprop ro.vendor.build.security_patch >> "$OUT/device.txt" 2>/dev/null || true
uname -a >> "$OUT/device.txt" 2>/dev/null || true
id >> "$OUT/device.txt"
getenforce >> "$OUT/device.txt" 2>/dev/null || true
ls -ld "$PDIR/tmp" >> "$OUT/device.txt" 2>&1

echo "== reproduce & capture launcher stderr =="
( "$PDIR/bin/termux-x11" :99 2>&1 ) > "$OUT/launcher.out" 2>&1 &
PID=$!
sleep 4
kill "$PID" 2>/dev/null || true
wait 2>/dev/null || true

echo "== logcat (user privileges) =="
logcat -d -v brief > "$OUT/logcat.user.txt" 2>&1 || true

FULL=""
ROOT=""
if command -v su >/dev/null 2>&1 && su -c id >/dev/null 2>&1; then
	ROOT=1
	su -c 'logcat -d -v brief' > "$OUT/logcat.root.txt" 2>&1 || true
	su -c 'dmesg -T 2>/dev/null | tail -200' > "$OUT/dmesg.txt" 2>&1 || true

	# crash dumps
	if su -c 'ls /data/system/dropbox/*crash* /data/system/dropbox/*tombstone* 2>/dev/null' | grep -q .; then
		su -c 'ls -t /data/system/dropbox/ | head -20' > "$OUT/dropbox.list" 2>&1
		latest=$(su -c 'ls -t /data/system/dropbox/ | head -1' 2>/dev/null | tr -d '\r')
		[ -n "$latest" ] && su -c "cat /data/system/dropbox/$latest" > "$OUT/dropbox.latest.txt" 2>&1 || true
	fi

	# tombstones
	su -c 'ls -t /data/tombstones/ 2>/dev/null | head -5' > "$OUT/tombstones.list" 2>&1
	latest_ts=$(su -c 'ls -t /data/tombstones/*.pb /data/tombstones/tombstone_* 2>/dev/null | head -1' 2>/dev/null | tr -d '\r' || true)
	[ -n "$latest_ts" ] && su -c "cat \"$latest_ts\"" > "$OUT/tombstone.txt" 2>&1 || true
fi

echo "== package =="
"$PDIR/bin/apk" info -L termux-x11-nightly 2>&1 > "$OUT/pkg-files.txt" || true
"$PDIR/bin/apk" policy termux-x11-nightly 2>&1 > "$OUT/pkg-policy.txt" || true
sha256sum "$PDIR/libexec/termux-x11/loader.apk" "$PDIR/bin/termux-x11" > "$OUT/pkg-checksums.txt" 2>&1 || true
echo "sdk24+: $("$PDIR/bin/getprop" ro.build.version.sdk)" >> "$OUT/pkg-checksums.txt" 2>> "$OUT/pkg-checksums.txt" || true

echo "== package, tarballing =="
TAR="$PDIR/tmp/tx11-log-$TS.tgz"
tar czf "$TAR" -C "$PDIR/tmp" "tx11-log-$TS" 2>/dev/null || true
rm -rf "$OUT" "$RUNMSG"

echo
echo "==> log saved: $TAR"
echo "Send that over, or paste: $TAR"
if [ -z "$ROOT" ]; then
	echo
	echo "NOTE: not root — the root parts (dropbox/tombstones/system logcat) are empty."
	echo "Re-run with 'su' available, or from your PC:"
	echo "  adb shell su -c 'logcat -d -v brief' > log.txt"
fi
