#!/bin/bash
# Repackage Termux .deb files into signed .apk packages under repo/<arch>/
# and build a signed repository index.
#
# Usage:
#   ./repack-debs.sh                     -> repackage *.deb in cwd
#   ./repack-debs.sh --auto 25           -> pick 25 packages from the Termux
#                                           apt repos (with all their deps),
#                                           skipping unchanged ones and
#                                           rebuilding updated ones
#   ./repack-debs.sh --update            -> rebuild repo packages that have a
#                                           newer version in the apt repos
#   ./repack-debs.sh cbonsai ...         -> repackage named apt packages + deps
#   ./repack-debs.sh --update cbonsai    -> same, but force-refresh if outdated
#   ./repack-debs.sh --x11 pkg ...       -> same, but writes into x11-repo/
#                                           (requires the x11 apt channel
#                                           enabled, e.g. pkg install x11-repo)
set -eu

USE_X11=0
for a in "$@"; do [ "$a" = "--x11" ] && USE_X11=1; done

if [ "$USE_X11" -eq 1 ]; then REPO_DIR="x11-repo"; else REPO_DIR="repo"; fi
REPO_ARCH="aarch64"
KEYSIGN_DIR=".apk-sign"
KEYID="apk-termux@local"	# same signing key for both repos
TERMUX_PREFIX_GLOB="data/data/com.termux/files/usr"
DOWNLOAD_DIR="$KEYSIGN_DIR/apt-debs-$REPO_DIR"
MANIFEST="$KEYSIGN_DIR/manifest-${REPO_DIR}.txt"

# migrate legacy single-repo manifest only into the main repo manifest
if [ "$USE_X11" -eq 0 ] && [ -f "$KEYSIGN_DIR/manifest.txt" ] && [ ! -f "$MANIFEST" ]; then
	mv "$KEYSIGN_DIR/manifest.txt" "$MANIFEST"
fi

mkdir -p "$KEYSIGN_DIR" "$DOWNLOAD_DIR"
# legacy shared deb cache: migrate into the main repo cache once
if [ -d "$KEYSIGN_DIR/apt-debs" ] && [ $USE_X11 -eq 0 ]; then
	mv -n "$KEYSIGN_DIR"/apt-debs/*.deb "$DOWNLOAD_DIR/" 2>/dev/null || true
fi
touch "$MANIFEST"

# Sync manifest from the existing index (last wins = index truth)
if [ -f "$REPO_DIR/$REPO_ARCH/APKINDEX.adb" ]; then
	{ cat "$MANIFEST"
	  apk adbdump "$REPO_DIR/$REPO_ARCH/APKINDEX.adb" 2>/dev/null \
		| awk '/name:/{n=$NF} /version:/{print n, $NF}'
	} | awk '{v[$1]=$2} END{for (k in v) print k, v[k]}' > "$MANIFEST.new"
	mv "$MANIFEST.new" "$MANIFEST"
fi
if [ ! -f "$KEYSIGN_DIR/$KEYID.rsa" ]; then
	openssl genrsa -out "$KEYSIGN_DIR/$KEYID.rsa" 2048 2>/dev/null
	openssl rsa -in "$KEYSIGN_DIR/$KEYID.rsa" -pubout -out "$KEYSIGN_DIR/$KEYID.rsa.pub" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# deb version -> apk version: strip epoch, 'N-M' -> 'N-rM', sanitize junk
apk_version_of_deb() {
	local ver="$1" rev="-r0"
	ver="${ver#*:}"
	if [[ "$ver" == *-* ]]; then rev="-r${ver##*-}"; ver="${ver%-*}"; fi
	ver="$(echo "$ver" | tr -c '0-9.' '.' | sed -e 's/\.\{2,\}/./g' -e 's/^\.//' -e 's/\.$//')"
	printf '%s%s' "$ver" "$rev"
}

# manifest lookup: prints "version arch" or empty
manifest_get() {
	awk -v p="$1" '$1==p {print $2; exit}' "$MANIFEST"
}

manifest_put() {
	local p="$1" v="$2"
	grep -v "^$p " "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null || true
	mv "$MANIFEST.tmp" "$MANIFEST"
	echo "$p $v" >> "$MANIFEST"
}

# returns 0 if the package needs (re)building: no entry, or newer apt version
repo_needs_build() {
	local name="$1" want="$2" have
	have="$(manifest_get "$name")"
	[ -z "$have" ] && return 0
	[ "$have" = "$want" ] && return 1	# duplicate, unchanged
	local cmp
	cmp="$(apk version -t "$have" "$want" 2>/dev/null || echo '?')"
	if [ "$cmp" = "<" ]; then
		return 0	# repo outdated -> rebuild
	fi
	return 1	# repo newer than apt, keep
}

pkg_mkapk() {
	local deb="$1"
	local pkgname debver arch desc maintainer homepage depends
	pkgname=$(dpkg-deb -f "$deb" Package)
	debver=$(dpkg-deb -f "$deb" Version)
	arch=$(dpkg-deb -f "$deb" Architecture)
	desc=$(dpkg-deb -f "$deb" Description)
	maintainer=$(dpkg-deb -f "$deb" Maintainer)
	homepage=$(dpkg-deb -f "$deb" Homepage)
	depends=$( (dpkg-deb -f "$deb" Depends 2>/dev/null; dpkg-deb -f "$deb" Pre-Depends 2>/dev/null) | tr '\n' , | sed 's/,$//' )

	local version; version=$(apk_version_of_deb "$debver")

	if ! repo_needs_build "$pkgname" "$version"; then
		echo "skip (up-to-date): $pkgname-$version"
		return 0
	fi

	local old; old="$(manifest_get "$pkgname")"
	[ -n "$old" ] && rm -f "$REPO_DIR/$REPO_ARCH/$pkgname-$old.apk"

	# first alternative of each dep, version constraints dropped
	local apk_deps="" dep
	local IFS_save="$IFS"; IFS=','; local deparr=($depends); IFS="$IFS_save"
	for dep in "${deparr[@]}"; do
		dep="${dep%%|*}"
		dep="${dep%%\(*}"
		dep="${dep%%:*}"
		dep="$(echo "$dep" | xargs)"
		[ -n "$dep" ] && apk_deps="$apk_deps $dep"
	done
	apk_deps="$(echo "$apk_deps" | xargs)"

	local stagedir="$KEYSIGN_DIR/stage-$pkgname"
	rm -rf "$stagedir"; mkdir -p "$stagedir"
	dpkg-deb -x "$deb" "$stagedir"

	if [ -d "$stagedir/$TERMUX_PREFIX_GLOB" ]; then
		cp -a "$stagedir/$TERMUX_PREFIX_GLOB/." "$stagedir/"
		rm -rf "$stagedir/data"
	fi

	[ "$arch" = "all" ] && arch="noarch"
	mkdir -p "$REPO_DIR/$REPO_ARCH"
	local out="$REPO_DIR/$REPO_ARCH/$pkgname-$version.apk"
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
	manifest_put "$pkgname" "$version"

	rm -rf "$stagedir"
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
AUTO=0 UPDATE_ONLY=0 SIZE_CAP_KB=$((64*1024))
declare -a ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--auto) AUTO="${2:?--auto needs a count}"; shift 2 ;;
		--size-cap) SIZE_CAP_KB="${2:?--size-cap needs KBs}"; shift 2 ;;
		--update) UPDATE_ONLY=1; shift ;;
		--x11) shift ;;
		-h|--help) grep '^#' "$0" | head -16; exit 0 ;;
		*) ARGS+=("$1"); shift ;;
	esac
done

# skip debs bigger than the cap (bytes)
pkg_size_ok() {
	local p="$1" s
	s=$(apt-cache show "$p" 2>/dev/null | awk '/^Size:/{print $2; exit}')
	[ -z "$s" ] && return 1
	[ "$s" -le $((SIZE_CAP_KB*1024)) ]
}

declare -a DEBS=()

# ---------------------------------------------------------------------------
# --auto N: pick N packages from the apt repo that are new or outdated here
# ---------------------------------------------------------------------------
if [ "$AUTO" -gt 0 ]; then
	echo "scanning apt repository for $AUTO packages..."
	selected=0
	while read -r pkg ver; do
		[ $selected -ge "$AUTO" ] && break
		[ -z "$pkg" ] && continue
		av="$(apk_version_of_deb "$ver")"
		pkg_size_ok "$pkg" || { echo "skip (too large): $pkg"; continue; }
		if repo_needs_build "$pkg" "$av"; then
			echo "select: $pkg ($av)"
			ARGS+=("$pkg"); selected=$((selected+1))
		fi
	done < <(apt list 2>/dev/null | grep -v '^Listing' \
		| awk '{n=$1; sub("/.*","",n); if ($2 != "" && $2 != "Listing") print n, $2}' | sort -u)
fi

# ---------------------------------------------------------------------------
# --update alone: refresh all manifest-listed packages
# ---------------------------------------------------------------------------
if [ $UPDATE_ONLY -eq 1 ] && [ ${#ARGS[@]} -eq 0 ] && [ "$AUTO" -eq 0 ]; then
	while read -r pkg oldver; do
		deb_ver=$(apt-cache show "$pkg" 2>/dev/null | grep -m1 '^Version:' | awk '{print $2}')
		[ -n "$deb_ver" ] && ARGS+=("$pkg")
	done < "$MANIFEST"
fi

# ---------------------------------------------------------------------------
# resolve names via apt (+ recursive deps) and download
# ---------------------------------------------------------------------------
declare -a NAMES=()
for a in "${ARGS[@]:-}"; do
	case "$a" in
		*.deb) DEBS+=("$a") ;;
		*) [ -n "$a" ] && NAMES+=("$a") ;;
	esac
done

if [ ${#NAMES[@]} -gt 0 ]; then
	declare -A wanted=()
	queue=("${NAMES[@]}")
	while ((${#queue[@]})); do
		pkg="${queue[0]}"; queue=("${queue[@]:1}")
		[ -n "${wanted[$pkg]+x}" ] && continue
		apt-cache show "$pkg" >/dev/null 2>&1 || { echo "warning: no such apt package: $pkg"; continue; }
		wanted[$pkg]=1
		while read -r dep; do
			[ -n "$dep" ] && queue+=("$dep")
		done < <(apt-cache depends "$pkg" 2>/dev/null \
			| grep -E '^[[:space:]]+(Pre)?Depends:' | grep -vE '^[[:space:]]*[|]' \
			| awk '{print $2}')
	done
	echo "apt closure: ${!wanted[*]}"
	for pkg in "${!wanted[@]}"; do
		f=$(ls "$DOWNLOAD_DIR/${pkg}"_*_*.deb 2>/dev/null | head -1)
		if [ -z "$f" ]; then
			echo "downloading: $pkg"
			(cd "$DOWNLOAD_DIR" && apt-get download "$pkg" >/dev/null)
			f=$(ls "$DOWNLOAD_DIR/${pkg}"_*_*.deb 2>/dev/null | head -1)
		fi
		[ -n "$f" ] && DEBS+=("$f")
	done
fi

# cwd debs if nothing was given at all
if [ ${#DEBS[@]} -eq 0 ] && [ "$AUTO" -eq 0 ] && [ $UPDATE_ONLY -eq 0 ]; then
	shopt -s nullglob
	DEBS=(./*.deb)
	shopt -u nullglob
	((${#DEBS[@]})) || { echo "no .deb files and no package names given"; exit 1; }
fi

# ---------------------------------------------------------------------------
# repackage everything
# ---------------------------------------------------------------------------
built=0
for deb in "${DEBS[@]}"; do
	pkgname=$(dpkg-deb -f "$deb" Package)
	debver=$(dpkg-deb -f "$deb" Version)
	version=$(apk_version_of_deb "$debver")
	if repo_needs_build "$pkgname" "$version"; then
		pkg_mkapk "$deb" && built=$((built+1))
	else
		echo "skip (up-to-date): $pkgname-$version"
	fi
done

echo "repackaged: $built new/updated packages"

# ---------------------------------------------------------------------------
# rebuild + sign index, publish pubkey
# ---------------------------------------------------------------------------
abs_keysign="$(cd "$KEYSIGN_DIR" && pwd)"
(cd "$REPO_DIR/$REPO_ARCH" && apk mkndx --sign-key "$abs_keysign/$KEYID.rsa" \
	-o APKINDEX.adb --description "termux-converted repo" *.apk)
cp "$KEYSIGN_DIR/$KEYID.rsa.pub" "$REPO_DIR/$KEYID.rsa.pub"

echo
echo "Repository at $REPO_DIR/$REPO_ARCH ($(ls "$REPO_DIR/$REPO_ARCH"/*.apk | wc -l) packages)"