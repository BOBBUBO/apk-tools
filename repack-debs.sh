#!/bin/bash
# Repackage Termux .deb files in the current directory into .apk packages
# under repo/<arch>/ and build a signed repository index there.
set -eu

REPO_DIR="repo"
KEYSIGN_DIR=".apk-sign"
KEYID="apk-termux@local"
TERMUX_PREFIX="/data/data/com.termux/files/usr"
TERMUX_PREFIX_GLOB="data/data/com.termux/files/usr"

mkdir -p "$KEYSIGN_DIR"
if [ ! -f "$KEYSIGN_DIR/$KEYID.rsa" ]; then
	openssl genrsa -out "$KEYSIGN_DIR/$KEYID.rsa" 2048 2>/dev/null
	openssl rsa -in "$KEYSIGN_DIR/$KEYID.rsa" -pubout -out "$KEYSIGN_DIR/$KEYID.rsa.pub" 2>/dev/null
fi

for deb in *.deb; do
	pkgname=$(dpkg-deb -f "$deb" Package)
	debver=$(dpkg-deb -f "$deb" Version)
	arch=$(dpkg-deb -f "$deb" Architecture)
	desc=$(dpkg-deb -f "$deb" Description)
	maintainer=$(dpkg-deb -f "$deb" Maintainer)
	homepage=$(dpkg-deb -f "$deb" Homepage)
	depends=$(dpkg-deb -f "$deb" Depends 2>/dev/null || true)

	# 1.4.2-1 (deb) -> 1.4.2-r1 (apk)
	version=${debver%-*}-r${debver##*-}
	case "$debver" in *-*) ;; *) version="$debver-r0";; esac

	stagedir="$KEYSIGN_DIR/stage-$pkgname"
	rm -rf "$stagedir"
	mkdir -p "$stagedir"
	dpkg-deb -x "$deb" "$stagedir"

	# Strip the deb's Termux prefix so files end up relative to the apk root
	if [ -d "$stagedir/$TERMUX_PREFIX_GLOB" ]; then
		cp -a "$stagedir/$TERMUX_PREFIX_GLOB/." "$stagedir/"
		rm -rf "$stagedir/data"
	fi

	mkdir -p "$REPO_DIR/$arch"
	out="$REPO_DIR/$arch/$pkgname-$version.apk"
	set -- mkpkg \
		--files "$stagedir" \
		--info "name:$pkgname" \
		--info "version:$version" \
		--info "arch:$arch" \
		--sign-key "$KEYSIGN_DIR/$KEYID.rsa" \
		--output "$out"
	[ -n "$desc" ]       && set -- "$@" --info "description:$desc"
	[ -n "$maintainer" ] && set -- "$@" --info "maintainer:$maintainer"
	[ -n "$homepage" ]   && set -- "$@" --info "url:$homepage"
	# NOTE: no 'depends' — deb deps refer to apt-managed Termux packages,
	# while apk would resolve them from the Alpine side (musl libc etc.)
	echo "mkpkg: $out"
	apk "$@"

	rm -rf "$stagedir"
done

# Build and sign the repository index (v3 format)
(cd "$REPO_DIR/aarch64" && apk mkndx --sign-key "$OLDPWD/$KEYSIGN_DIR/$KEYID.rsa" \
	-o APKINDEX.adb --description "termux-converted repo" *.apk)

cp "$KEYSIGN_DIR/$KEYID.rsa.pub" "$REPO_DIR/$KEYID.rsa.pub"

cp "$KEYSIGN_DIR/$KEYID.rsa.pub" "$REPO_DIR/$KEYID.rsa.pub"

echo
echo "Repository at $REPO_DIR/aarch64:"
ls -la "$REPO_DIR/aarch64"