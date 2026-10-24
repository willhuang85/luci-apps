# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tether
PKG_VERSION:=1.0.0
# CI sets the release to the number of commits on the branch it builds
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=willhuang85

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-tether
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Tether: simple Wi-Fi setup (name, password, guest network, devices)
  DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +rpcd-mod-iwinfo +ucode-mod-fs +ucode-mod-uci \
	+ucode-mod-ubus +qrencode
  PKGARCH:=all
endef

define Package/luci-app-tether/description
  A clean, consumer-router style LuCI page for Wi-Fi: set the network name,
  password and security for all bands at once, run an isolated guest
  network, pick channels, width and power per band, see and block connected
  devices, share the network with a QR code and turn Wi-Fi off on a schedule.
endef

define Package/luci-app-tether/conffiles
/etc/config/tether
endef

define Build/Compile
endef

# Copy the trees and normalise permissions: cp -p keeps the modes of the
# checkout, and rpcd refuses to load world-writable ucode plugins.
define Package/luci-app-tether/install
	$(INSTALL_DIR) $(1)/www
	$(CP) ./htdocs/* $(1)/www/
	$(CP) ./root/* $(1)/
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0755 $(1)/etc/init.d/* $(1)/usr/libexec/*
endef

define Package/luci-app-tether/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
	/etc/init.d/rpcd restart
	# OpenWrt only enables new init scripts on fresh installs, not upgrades
	/etc/init.d/tether enable
	/etc/init.d/tether reload
	echo "luci-app-tether: log out of LuCI and back in, then open Network -> Wi-Fi Setup"
}
exit 0
endef

# Remove the schedule so Wi-Fi is never left switched off by cron.
define Package/luci-app-tether/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ -f /etc/crontabs/root ] && grep -q '# tether-schedule' /etc/crontabs/root; then
		sed -i '/# tether-schedule/d' /etc/crontabs/root
		/etc/init.d/cron restart >/dev/null 2>&1
	fi
	/sbin/wifi up >/dev/null 2>&1
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-tether))
