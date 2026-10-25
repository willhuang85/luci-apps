# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wireguard-passwall
PKG_VERSION:=1.1.0
# CI sets the release to the number of commits on the branch it builds
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=willhuang85

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wireguard-passwall
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=WireGuard + Passwall: VPN and Passwall networks with a kill switch
  DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus \
	+ucode-mod-socket +ucode-mod-uloop +wireguard-tools +kmod-wireguard
  PKGARCH:=all
endef

define Package/luci-app-wireguard-passwall/description
  A simple LuCI interface to connect an OpenWrt router to a WireGuard VPN:
  import .conf files from your VPN provider and connect with one click.
  Wired ports and Wi-Fi networks are put on a VPN network, whose devices
  only go out through the VPN (optionally enforced by a kill switch), or,
  with Passwall installed, on a Passwall network; the VPN itself can also be
  carried through Passwall.
endef

define Package/luci-app-wireguard-passwall/conffiles
/etc/config/wgpasswall
endef

define Build/Compile
endef

# Copy the trees and normalise permissions: cp -p keeps the modes of the
# checkout, and rpcd refuses to load world-writable ucode plugins.
define Package/luci-app-wireguard-passwall/install
	$(INSTALL_DIR) $(1)/www
	$(CP) ./htdocs/* $(1)/www/
	$(CP) ./root/* $(1)/
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0755 $(1)/etc/init.d/* $(1)/usr/libexec/*
endef

define Package/luci-app-wireguard-passwall/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# like LuCI's own packages: reload (not restart) rpcd, which keeps
	# everyone logged in and gives open sessions the new app's permissions
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	# OpenWrt only enables new init scripts on fresh installs, not upgrades
	/etc/init.d/wgpasswall enable
	/etc/init.d/wgpasswall restart
	# set up the VPN (and Passwall) network, and bring settings of older
	# versions in line, once rpcd has loaded the new backend
	( sleep 5; ubus call luci.wgpasswall sync >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
	echo "luci-app-wireguard-passwall: reload the LuCI page, then open Services -> WireGuard + Passwall"
}
exit 0
endef

# Never leave the LAN locked out after the app is gone: wired ports and Wi-Fi
# networks go back to the LAN, and Passwall gets its own settings back.
define Package/luci-app-wireguard-passwall/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	ubus call luci.wgpasswall uninstall >/dev/null 2>&1 && exit 0
	# the backend did not answer: at least lift the kill switch and remove
	# the app's Passwall rules and DNS rules
	uci -q set wgpasswall.settings.killswitch='0'
	uci -q commit wgpasswall
	for s in $$(uci -q show passwall | sed -n -E "s/^passwall\.((0wgpasswall_|zzz_wgpasswall_lan_|wgpasswall_lan_|wgpasswall_vpn_devices)[A-Za-z0-9_]*)=acl_rule$$/\1/p"); do
		uci -q delete passwall.$$s
	done
	uci -q commit passwall
	nft delete table inet wgpasswall_dns 2>/dev/null
	rm -f /etc/wgpasswall/devices-dns.nft
	uci -q delete firewall.wgpasswall_killswitch
	uci -q delete firewall.wgpasswall_devices
	uci -q delete firewall.wgpasswall_devices_dns
	uci -q delete firewall.wgpasswall_no_ipv6
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-wireguard-passwall))
