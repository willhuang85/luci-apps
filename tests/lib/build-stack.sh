#!/bin/sh
# Builds and installs libubox, ubus, uci, ucode and rpcd at the exact
# revisions of the given OpenWrt release (into /usr, so run as root on a
# throwaway machine). Used by the integration tests.
#
#   OPENWRT_VERSION=25.12.2 sudo -E ./tests/lib/build-stack.sh
set -e

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.2}"
WORK="${WORK:-$(mktemp -d)}"
RAW="https://raw.githubusercontent.com/openwrt/openwrt/v${OPENWRT_VERSION}"

# name, GitHub repo, Makefile path in openwrt.git, extra cmake flags
build() {
	name="$1" repo="$2" mk="$3"; shift 3
	rev=$(curl -fsSL "$RAW/$mk" | sed -n 's/^PKG_SOURCE_VERSION:=//p')
	[ -n "$rev" ] || { echo "Cannot find $name revision for OpenWrt $OPENWRT_VERSION"; exit 1; }
	echo "== $name @ $rev"
	rm -rf "$WORK/$name"
	git init -q "$WORK/$name"
	git -C "$WORK/$name" fetch -q --depth 1 "https://github.com/$repo.git" "$rev"
	git -C "$WORK/$name" checkout -q FETCH_HEAD
	cmake -S "$WORK/$name" -B "$WORK/$name/build" -DCMAKE_INSTALL_PREFIX=/usr "$@" >/dev/null
	make -C "$WORK/$name/build" -j"$(nproc)" install >/dev/null
	ldconfig
}

build libubox openwrt/libubox package/libs/libubox/Makefile -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
build ubus openwrt/ubus package/system/ubus/Makefile -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
build uci openwrt/uci package/system/uci/Makefile -DBUILD_LUA=OFF
build ucode jow-/ucode package/utils/ucode/Makefile -DUBUS_SUPPORT=ON -DUCI_SUPPORT=ON -DULOOP_SUPPORT=ON \
	-DSOCKET_SUPPORT=ON -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF -DDIGEST_SUPPORT=OFF -DLOG_SUPPORT=OFF
build rpcd openwrt/rpcd package/system/rpcd/Makefile -DUCODE_SUPPORT=ON -DFILE_SUPPORT=OFF -DIWINFO_SUPPORT=OFF -DRPCSYS_SUPPORT=OFF
