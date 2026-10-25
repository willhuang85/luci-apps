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
  TITLE:=WireGuard + Passwall: VPN client with proxy modes and kill switch
  DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus \
	+ucode-mod-socket +ucode-mod-uloop +wireguard-tools +kmod-wireguard
  PKGARCH:=all
endef

define Package/luci-app-wireguard-passwall/description
  A simple LuCI interface to connect an OpenWrt router to a WireGuard VPN:
  import .conf files from your VPN provider, connect with one click and
  optionally block all non-VPN traffic from the LAN with a kill switch.
  With Passwall installed it adds modes to carry the VPN through a Passwall
  proxy node, to use Passwall alone, or to switch everything off.
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
	echo "luci-app-wireguard-passwall: reload the LuCI page, then open Services -> WireGuard + Passwall"
}
exit 0
endef

# Never leave the LAN locked out after the app is gone.
define Package/luci-app-wireguard-passwall/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# put Passwall back the way it was before any Passwall mode was used
	ubus call luci.wgpasswall set_mode '{"mode":"vpn","connect":false}' >/dev/null 2>&1
	uci -q set wgpasswall.settings.killswitch='0'
	uci -q commit wgpasswall
	if uci -q get firewall.wgpasswall_killswitch >/dev/null; then
		uci -q delete firewall.wgpasswall_killswitch
		uci -q commit firewall
		/etc/init.d/firewall reload >/dev/null 2>&1
	fi
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-wireguard-passwall))
