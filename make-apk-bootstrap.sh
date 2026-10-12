#!/bin/bash
# make-apk-bootstrap.sh [arch] [path-to-apk-tools.deb]
#
# Takes a stock Termux bootstrap zip, removes the apt/dpkg package
# management stack, and injects the apk-tools package (built by this
# repo's CI) together with its runtime dependencies, producing an
# apk-managed Termux bootstrap: apk-bootstrap-<arch>.zip
#
# Requires: bash, curl, unzip, zip, tar, ar, xz, zstd, gh (only when the
#           apk-tools deb is not given locally).
set -eu

TERMUX_PREFIX="/data/data/com.termux/files/usr"
ARCH="${1:-aarch64}"
APKTOOLS_DEB="${2:-}"
TERMUX_REPO="https://packages-cf.termux.dev/apt/termux-main"
WORKDIR="$(pwd)/.apk-bootstrap/$ARCH"
DEPS="zlib zstd openssl ca-certificates"
# packages removed from the stock bootstrap tree
APT_PKGS="apt libapt-pkg dpkg termux-keyring"
OUT="$(pwd)/apk-bootstrap-$ARCH.zip"

for cmd in curl unzip zip tar ar; do
	command -v "$cmd" >/dev/null || { echo "missing tool: $cmd"; exit 1; }
done

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/debs" "$WORKDIR/tree"
CACHEDIR="$(pwd)/.apk-bootstrap/cache"
mkdir -p "$CACHEDIR"

log() { echo "[*] $*"; }

# ---------------------------------------------------------------------------
# 1. stock bootstrap zip
# ---------------------------------------------------------------------------
STOCK_ZIP="$CACHEDIR/bootstrap-stock-$ARCH.zip"
if [ ! -f "$STOCK_ZIP" ]; then
	log "finding latest stock bootstrap release..."
	assets=$(curl -fsSL "https://api.github.com/repos/termux/termux-packages/releases?per_page=100")
	url=$(printf '%s\n' "$assets" \
		| grep -F "bootstrap-$ARCH.zip" | grep -oE 'https://[^"]+' \
		| head -1)
	[ -n "$url" ] || { echo "no bootstrap-$ARCH.zip asset found in recent releases"; exit 1; }
	log "downloading stock bootstrap: $url"
	curl -fL --progress-bar -o "$STOCK_ZIP" "$url"
fi
log "extracting stock bootstrap..."
unzip -q "$STOCK_ZIP" -d "$WORKDIR/tree"

# Stock zips remove symlinks into SYMLINKS.txt; recreate them so the
# package-removal step sees a real tree.
log "materializing stock symlinks..."
while IFS='←' read -r target link; do
	[ -n "$target" ] || continue
	link="${link#./}"
	mkdir -p "$WORKDIR/tree/$(dirname "$link")"
	ln -sf "$target" "$WORKDIR/tree/$link"
done < "$WORKDIR/tree/SYMLINKS.txt"

# ---------------------------------------------------------------------------
# 2. remove apt/dpkg
# ---------------------------------------------------------------------------
log "stripping apt/dpkg packages: $APT_PKGS"
for pkg in $APT_PKGS; do
	lf="$WORKDIR/tree/var/lib/dpkg/info/$pkg.list"
	if [ -f "$lf" ]; then
		while read -r f; do
			f="${f#/}"
			f="${f#data/data/com.termux/files/usr/}"
			f="${f#./}"
			case "$f" in ""|".") continue;; esac
			# only files/symlinks; directories are pruned later
			if [ -f "$WORKDIR/tree/$f" ] || [ -L "$WORKDIR/tree/$f" ]; then
				rm -f "$WORKDIR/tree/$f"
			fi
		done < "$lf"
	fi
	rm -f "$WORKDIR/tree"/var/lib/dpkg/info/"$pkg".*
done
# apt/dpkg state and caches are useless without the tools
rm -rf "$WORKDIR/tree/etc/apt" \
	"$WORKDIR/tree/var/lib/dpkg" \
	"$WORKDIR/tree/var/lib/apt" \
	"$WORKDIR/tree/var/cache/apt" \
	"$WORKDIR/tree/var/log/apt" \
	"$WORKDIR/tree/share/termux-keyring"
# prune directories emptied by the removal
find "$WORKDIR/tree" -type d -empty -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. fetch + inject dependency debs from the termux repo
# ---------------------------------------------------------------------------
extract_deb() {
	# $1 = deb path, extracts data.tar.* into $WORKDIR/tree
	local tmp="$WORKDIR/deb-x"
	local deb="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
	rm -rf "$tmp"; mkdir -p "$tmp"
	(cd "$tmp" && ar x "$deb" && \
		for d in data.tar.xz data.tar.gz data.tar.zst data.tar.bz2 data.tar; do
			[ -f "$d" ] && tar xf "$d" && break
		done && \
		tar -C data/data/com.termux/files/usr -cf - . | tar -C "$WORKDIR/tree" -xf -)
	rm -rf "$tmp"
}

fetch_termux_deb() {
	# $1 = package name; downloads from termux apt repo into $WORKDIR/debs
	local pkg="$1" pkgs="$WORKDIR/Packages-$ARCH"
	[ -f "$pkgs" ] || curl -fsSL -o "$pkgs" "$TERMUX_REPO/dists/stable/main/binary-$ARCH/Packages"
	local fn
	fn=$(awk -v p="$pkg" '/^Package: /{if ($2 == p) f=1; else f=0} f && /^Filename: /{print $2; exit}' "$pkgs")
	[ -n "$fn" ] || { echo "cannot resolve $pkg in termux repo"; return 1; }
	local dest="$WORKDIR/debs/$(basename "$fn")"
	[ -f "$dest" ] || { log "downloading dep: $pkg"; curl -fsSL -o "$dest" "$TERMUX_REPO/$fn"; }
	extract_deb "$dest"
}

log "injecting runtime dependencies: $DEPS"
for dep in $DEPS; do fetch_termux_deb "$dep"; done

# ---------------------------------------------------------------------------
# 4. apk-tools deb (local, or latest CI artifact)
# ---------------------------------------------------------------------------
if [ -z "$APKTOOLS_DEB" ]; then
	shopt -s nullglob
	g=( "$WORKDIR"/debs/apk-tools_*_"$ARCH".deb ./apk-tools_*_"$ARCH".deb )
	shopt -u nullglob
	if [ ${#g[@]} -gt 0 ]; then
		APKTOOLS_DEB="${g[0]}"
	else
		log "downloading apk-tools deb from latest CI run (needs gh)..."
		run_id=$(gh run list --workflow=termux.yml --branch=master \
			--json databaseId,conclusion --jq '[.[] | select(.conclusion=="success")][0].databaseId')
		gh run download "$run_id" --name "apk-tools-$ARCH" --dir "$WORKDIR/debs"
		APKTOOLS_DEB=$(ls "$WORKDIR"/debs/apk-tools_*_"$ARCH".deb)
	fi
fi
log "injecting apk-tools: $APKTOOLS_DEB"
extract_deb "$(readlink -f "$APKTOOLS_DEB")"

# ---------------------------------------------------------------------------
# 5. replace the second stage (dpkg-based) with an apk-based one
# ---------------------------------------------------------------------------
log "replacing bootstrap second stage with apk variant..."
ss=$(find "$WORKDIR/tree" -name 'termux-bootstrap-second-stage.sh' | head -1)
if [ -n "$ss" ]; then
	cat > "$ss" <<- EOF
	#!$TERMUX_PREFIX/bin/bash
	# apk-based bootstrap second stage
	PREFIX=$TERMUX_PREFIX
	SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
	# run once: atomic lock via symlink
	ln -s . "\$SELF_DIR/\$(basename "\$0").lock" 2>/dev/null || exit 0
	# initialize the apk database
	"\$PREFIX/bin/apk" add --initdb >/dev/null 2>&1 || true
	exit 0
	EOF
fi

# ---------------------------------------------------------------------------
# 6. pkg compatibility shim (apt-style verbs -> apk)
# ---------------------------------------------------------------------------
log "installing pkg shim..."
cat > "$WORKDIR/tree/bin/pkg" <<- EOF
#!$TERMUX_PREFIX/bin/sh
# compatibility shim mapping 'pkg' verbs to apk
case "\$1" in
	install)         shift; exec apk add "\$@" ;;
	reinstall)       shift; exec apk add --force-reinstall "\$@" ;;
	remove|uninstall) shift; exec apk del "\$@" ;;
	autoremove)      shift; exec apk del "\$@" ;;
	search)          shift; exec apk search "\$@" ;;
	show|info)       shift; exec apk info "\$@" ;;
	files)           shift; exec apk info -L "\$@" ;;
	list-installed)  exec apk list -I ;;
	list-all)        exec apk list -a ;;
	update)          exec apk update ;;
	upgrade)         shift || :; exec apk upgrade "\$@" ;;
	clean|autoclean) exec apk cache clean ;;
	*) echo "pkg -> apk shim; unknown verb '\$1', try: install, remove, search, update, upgrade" >&2; exit 64 ;;
esac
EOF

# ---------------------------------------------------------------------------
# 7. regenerate SYMLINKS.txt and rezip
# ---------------------------------------------------------------------------
log "regenerating SYMLINKS.txt..."
(cd "$WORKDIR/tree" && rm -f SYMLINKS.txt && \
	find . -type l -print0 | sort -z | \
	while IFS= read -r -d '' link; do \
		echo "$(readlink "$link")←$link" >> SYMLINKS.txt; \
		rm -f "$link"; \
	done)

log "creating $OUT..."
rm -f "$OUT"
(cd "$WORKDIR/tree" && zip -q -r9 "$OUT" ./)

log "done."
echo
echo "== validation =="
unzip -l "$OUT" | grep -E "SYMLINKS|bin/apk$|bin/pkg$|etc/apk/repositories|keys/apk" | head
if unzip -l "$OUT" | grep -qE "bin/(apt|dpkg)"; then
	echo "WARNING: apt/dpkg files still present!" >&2
else
	echo "apt/dpkg stripped OK"
fi
echo
echo "Bootstrap ready: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Flash it on a device with a termux-app build that loads a custom"
echo "bootstrap zip (e.g. put it in the app's bootstrap assets or use the"
echo "termux-app 'install custom bootstrap' mechanism at first launch)."
