# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wgclient
PKG_VERSION:=1.0.0
PKG_RELEASE:=12

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=willhuang85

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wgclient
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Easy WireGuard VPN client with kill switch
  DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus \
	+ucode-mod-socket +ucode-mod-uloop +wireguard-tools +kmod-wireguard
  PKGARCH:=all
endef

define Package/luci-app-wgclient/description
  A simple LuCI interface to connect an OpenWrt router to a WireGuard VPN:
  import .conf files from your VPN provider, connect with one click and
  optionally block all non-VPN traffic from the LAN with a kill switch.
endef

define Package/luci-app-wgclient/conffiles
/etc/config/wgclient
endef

define Build/Compile
endef

# Copy the trees and normalise permissions: cp -p keeps the modes of the
# checkout, and rpcd refuses to load world-writable ucode plugins.
define Package/luci-app-wgclient/install
	$(INSTALL_DIR) $(1)/www
	$(CP) ./htdocs/* $(1)/www/
	$(CP) ./root/* $(1)/
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0755 $(1)/etc/init.d/* $(1)/usr/libexec/*
endef

define Package/luci-app-wgclient/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
	/etc/init.d/rpcd restart
	# OpenWrt only enables new init scripts on fresh installs, not upgrades
	/etc/init.d/wgclient enable
	# re-apply a Passwall mode so changes in how it is set up take effect
	mode=$$(uci -q get wgclient.settings.mode)
	if [ "$$mode" = vpn_passwall ] || [ "$$mode" = passwall ]; then
		ubus -t 15 wait_for luci.wgclient 2>/dev/null &&
			ubus call luci.wgclient set_mode "{\"mode\":\"$$mode\",\"connect\":false}" >/dev/null 2>&1
	fi
	/etc/init.d/wgclient restart
	echo "luci-app-wgclient: log out of LuCI and back in, then open VPN -> WireGuard Client"
}
exit 0
endef

# Never leave the LAN locked out after the app is gone.
define Package/luci-app-wgclient/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# put Passwall back the way it was before any Passwall mode was used
	ubus call luci.wgclient set_mode '{"mode":"vpn","connect":false}' >/dev/null 2>&1
	uci -q set wgclient.settings.killswitch='0'
	uci -q commit wgclient
	if uci -q get firewall.wgclient_killswitch >/dev/null; then
		uci -q delete firewall.wgclient_killswitch
		uci -q commit firewall
		/etc/init.d/firewall reload >/dev/null 2>&1
	fi
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-wgclient))
