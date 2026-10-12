#!/bin/sh
# install-apk-bootstrap.sh — switch a stock Termux install from apt to apk
# without touching the app APK. Mirrors the "Switching package manager"
# wiki flow (bootstrap zip + usr/ swap via failsafe).
#
# Usage (on the device):
#   # 1. in a normal Termux session:
#   ./install-apk-bootstrap.sh [bootstrap-zip-or-url]
#   # 2. restart Termux into failsafe (recovery) mode, then:
#   /data/data/com.termux/files/install-apk-bootstrap.sh --finalize
#   # 3. exit failsafe, start Termux normally
#
# The default bootstrap URL points at our apk flavor of the same arch.
set -eu

FILES="${FILES_OVERRIDE:-/data/data/com.termux/files}"
USR="$FILES/usr"
USRN="$FILES/usr-n"
REPO_RAW="https://raw.githubusercontent.com/BOBBUBO/apk-termux-repo/main/bootstrap"

die() { echo "error: $*" >&2; exit 1; }

case "$(uname -m)" in
	aarch64|arm64) ARCH=aarch64 ;;
	armv7*|armv8*|armhf) ARCH=arm ;;
	i686|x86) ARCH=i686 ;;
	x86_64|amd64) ARCH=x86_64 ;;
	*) die "unsupported arch: $(uname -m)" ;;
esac

if [ "${1:-}" = "--finalize" ]; then
	# --- failsafe step: PATH may be unset; use absolute /system binaries ---
	RM=/system/bin/rm; MV=/system/bin/mv
	[ -x "$RM" ] || RM=rm; [ -x "$MV" ] || MV=mv
	[ -d "$USRN" ] || die "$USRN not found; run preparation first"
	$RM -rf "$USR.old"
	$MV "$USR" "$USR.old" || die "cannot move $USR aside"
	$MV "$USRN" "$USR" || { $MV "$USR.old" "$USR"; die "cannot move $USRN into place"; }

	# initialize apk db (the second-stage hook also does this on first boot)
	if [ -x "$USR/bin/apk" ]; then
		"$USR/bin/apk" add --initdb >/dev/null 2>&1 || true
	fi
	echo
	echo "Bootstrap swapped. Exit failsafe and start Termux normally, then:"
	echo "  apk update"
	echo "Old prefix kept at $USR.old; delete it once verified: rm -rf $USR.old"
	exit 0
fi

# --- preparation step ---
ZIP="${1:-$REPO_RAW/apk-bootstrap-$ARCH.zip}"

mkdir -p "$FILES"
# If $1 is a local file use it, otherwise download
if [ -f "$ZIP" ]; then
	cp "$ZIP" "$FILES/apk-bootstrap.zip"
else
	command -v curl >/dev/null || die "curl not found (pkg install curl)"
	echo "downloading $ZIP ..."
	curl -fL --progress-bar -o "$FILES/apk-bootstrap.zip" "$ZIP" || die "download failed"
fi

command -v unzip >/dev/null || die "unzip not found (pkg install unzip)"

[ -d "$USRN" ] && die "$USRN already exists; remove it or run --finalize first"
mkdir -p "$USRN"
echo "extracting bootstrap into $USRN ..."
unzip -q "$FILES/apk-bootstrap.zip" -d "$USRN"

[ -f "$USRN/SYMLINKS.txt" ] || die "SYMLINKS.txt missing from bootstrap"
[ -f "$USRN/bin/apk" ] || die "bin/apk missing from bootstrap (is this an apk bootstrap?)"

echo "creating symlinks ..."
(cd "$USRN" && awk -F '←' 'NF == 2 { system("ln -s \"" $1 "\" \"" $2 "\"") }' SYMLINKS.txt)
rm -f "$USRN/SYMLINKS.txt" "$FILES/apk-bootstrap.zip"

echo
echo "Prepared. Now do the swap:"
echo "  1. Fully exit Termux and restart it in failsafe (recovery) mode:"
echo "     long-press Termux icon -> Failsafe"
echo "  2. in the failsafe session run:"
echo "     $FILES/install-apk-bootstrap.sh --finalize"
echo "  3. exit failsafe and start Termux normally"
cp "$0" "$FILES/install-apk-bootstrap.sh" 2>/dev/null || true
chmod +x "$FILES/install-apk-bootstrap.sh" 2>/dev/null || true
