TERMUX_PKG_HOMEPAGE="https://gitlab.alpinelinux.org/apk-tools"
TERMUX_PKG_DESCRIPTION="Alpine Package Keeper for Termux"
TERMUX_PKG_LICENSE="GPL-2.0-only"
TERMUX_PKG_MAINTAINER="BOBBUBO"
TERMUX_PKG_VERSION=3.0.8
TERMUX_PKG_SRCURL="git+https://github.com/BOBBUBO/apk-tools.git"
TERMUX_PKG_GIT_BRANCH=master
TERMUX_PKG_DEPENDS="openssl, zlib, zstd"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="-Ddocs=disabled -Dlua=disabled -Dpython=disabled -Dtests=disabled"
TERMUX_PKG_CONFFILES="etc/apk/repositories"

termux_step_post_make_install() {
	# Trust the custom apk repo out of the box
	install -Dm644 "$TERMUX_PKG_BUILDER_DIR/apk-termux@local.rsa.pub" \
		"$TERMUX_PREFIX/etc/apk/keys/apk-termux@local.rsa.pub"
	install -Dm644 "$TERMUX_PKG_BUILDER_DIR/repositories" \
		"$TERMUX_PREFIX/etc/apk/repositories"
}

termux_step_create_debscripts() {
	cat > ./postinst <<- EOF
		#!$TERMUX_PREFIX/bin/sh
		# Initialize the apk database ($PREFIX/lib/apk/db) if missing
		[ -f "$TERMUX_PREFIX/lib/apk/db/installed" ] || \
			"$TERMUX_PREFIX/bin/apk" add --initdb >/dev/null 2>&1 || true
	EOF
	chmod 755 ./postinst
}
