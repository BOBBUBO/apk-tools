#!/bin/bash
# Repackage Termux .deb files into signed .apk packages under repo/<arch>/
# and build a signed repository index.
#
# Usage:
#   ./repack-debs.sh                -> repackage *.deb in the current directory
#   ./repack-debs.sh *.deb          -> repackage the given .deb files
#   ./repack-debs.sh cmatrix ...    -> resolve names via Termux apt repos,
#                                      download them and all their deps,
#                                      then repackage everything
set -eu

REPO_DIR="repo"
KEYSIGN_DIR=".apk-sign"
KEYID="apk-termux@local"
TERMUX_PREFIX_GLOB="data/data/com.termux/files/usr"
DOWNLOAD_DIR="$KEYSIGN_DIR/apt-debs"

mkdir -p "$KEYSIGN_DIR"
if [ ! -f "$KEYSIGN_DIR/$KEYID.rsa" ]; then
	openssl genrsa -out "$KEYSIGN_DIR/$KEYID.rsa" 2048 2>/dev/null
	openssl rsa -in "$KEYSIGN_DIR/$KEYID.rsa" -pubout -out "$KEYSIGN_DIR/$KEYID.rsa.pub" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 1. Obtain debs: either given .deb files/nameless cwd debs, or resolve via apt
# ---------------------------------------------------------------------------
declare -a DEBS

if [ $# -gt 0 ] && [[ "$1" != *.deb ]]; then
	# Resolve package names and their recursive dependencies via apt
	declare -A wanted=()
	queue=("$@")
	while ((${#queue[@]})); do
		pkg="${queue[0]}"; queue=("${queue[@]:1}")
		[ -n "${wanted[$pkg]+x}" ] && continue
		apt-cache show "$pkg" >/dev/null 2>&1 || { echo "warning: no such apt package: $pkg"; continue; }
		wanted[$pkg]=1
		# apt-cache marks alternative deps with a '| ' prefix - take the
		# last (non-|) entry of each alternative group
		while read -r dep; do
			dep=${dep%% *}
			[ -n "$dep" ] && queue+=("$dep")
		done < <(apt-cache depends "$pkg" 2>/dev/null \
			| grep -E '^[[:space:]]+(Pre)?Depends:' | grep -v '^[[:space:]]*|' \
			| awk '{print $2}')
	done

	echo "apt closure: ${!wanted[*]}"
	mkdir -p "$DOWNLOAD_DIR"; cd "$DOWNLOAD_DIR"
	for pkg in "${!wanted[@]}"; do
		if ! ls "${pkg}"_*_*.deb >/dev/null 2>&1; then
			echo "downloading: $pkg"
			apt-get download "$pkg" >/dev/null
		fi
	done
	cd "$OLDPWD"
	for f in "$DOWNLOAD_DIR"/*_*.deb; do DEBS+=("$f"); done
elif [ $# -gt 0 ]; then
	DEBS=("$@")
else
	shopt -s nullglob
	DEBS=(./*.deb)
	shopt -u nullglob
	((${#DEBS[@]})) || { echo "no .deb files in $PWD and no package names given"; exit 1; }
fi

# ---------------------------------------------------------------------------
# 2. Repackage every deb into a signed apk
# ---------------------------------------------------------------------------
for deb in "${DEBS[@]}"; do
	pkgname=$(dpkg-deb -f "$deb" Package)
	debver=$(dpkg-deb -f "$deb" Version)
	arch=$(dpkg-deb -f "$deb" Architecture)
	desc=$(dpkg-deb -f "$deb" Description)
	maintainer=$(dpkg-deb -f "$deb" Maintainer)
	homepage=$(dpkg-deb -f "$deb" Homepage)
	depends=$(dpkg-deb -f "$deb" Depends 2>/dev/null || true; dpkg-deb -f "$deb" Pre-Depends 2>/dev/null || true)

	# deb version -> apk version: strip epoch, 'N-M' -> 'N-rM', then strip
	# characters apk rejects ('~', '+', ...) from the upstream version part
	ver="${debver#*:}"
	rev="-r0"
	if [[ "$ver" == *-* ]]; then rev="-r${ver##*-}"; ver="${ver%-*}"; fi
	ver="$(echo "$ver" | tr -c '0-9.' '.' | sed -e 's/\.\{2,\}/./g' -e 's/^\.//' -e 's/\.$//')"
	version="$ver$rev"

	# first alternative of each dep, version constraints dropped
	# (the closure we download pins the correct versions)
	apk_deps=""
	local_ifs="$IFS"; IFS=','; read -ra deparr <<< "$depends"; IFS="$local_ifs"
	for dep in "${deparr[@]}"; do
		dep="${dep%%|*}"	# alternatives: take first
		dep="${dep%%\(*}"	# version constraint in parens
		dep="${dep%%:*}"	# multi-arch qualifier
		dep="$(echo "$dep" | xargs)"
		[ -n "$dep" ] && apk_deps="$apk_deps $dep"
	done
	apk_deps="$(echo "$apk_deps" | xargs)"

	stagedir="$KEYSIGN_DIR/stage-$pkgname"
	rm -rf "$stagedir"; mkdir -p "$stagedir"
	dpkg-deb -x "$deb" "$stagedir"

	# Strip the deb's Termux prefix so files end up relative to the apk root
	if [ -d "$stagedir/$TERMUX_PREFIX_GLOB" ]; then
		cp -a "$stagedir/$TERMUX_PREFIX_GLOB/." "$stagedir/"
		rm -rf "$stagedir/data"
	fi

	# apk calls platform-independent packages 'noarch'
	[ "$arch" = "all" ] && arch="noarch"
	mkdir -p "$REPO_DIR/aarch64"
	out="$REPO_DIR/aarch64/$pkgname-$version.apk"
	set -- mkpkg \
		--files "$stagedir" \
		--info "name:$pkgname" \
		--info "version:$version" \
		--info "arch:$arch" \
		--sign-key "$(cd "$KEYSIGN_DIR" && pwd)/$KEYID.rsa" \
		--output "$out"
	[ -n "$desc" ]       && set -- "$@" --info "description:$desc"
	[ -n "$maintainer" ] && set -- "$@" --info "maintainer:$maintainer"
	[ -n "$homepage" ]   && set -- "$@" --info "url:$homepage"
	[ -n "$apk_deps" ]   && set -- "$@" --info "depends:$apk_deps"
	echo "mkpkg: $out"
	apk "$@"

	rm -rf "$stagedir"
done

# ---------------------------------------------------------------------------
# 3. Build and sign the repository index (v3 format)
# ---------------------------------------------------------------------------
abs_keysign="$(cd "$KEYSIGN_DIR" && pwd)"
(cd "$REPO_DIR/aarch64" && apk mkndx --sign-key "$abs_keysign/$KEYID.rsa" \
	-o APKINDEX.adb --description "termux-converted repo" *.apk)

cp "$KEYSIGN_DIR/$KEYID.rsa.pub" "$REPO_DIR/$KEYID.rsa.pub"

echo
echo "Repository at $REPO_DIR/aarch64:"
ls -la "$REPO_DIR/aarch64"