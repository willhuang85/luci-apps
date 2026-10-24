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
  TITLE:=Tether: use a phone (USB or Wi-Fi hotspot) as backup internet
  DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +rpcd-mod-iwinfo +ucode-mod-fs +ucode-mod-uci \
	+ucode-mod-ubus +kmod-usb-net-ipheth +usbmuxd +kmod-usb-net-cdc-ncm +kmod-usb-net-rndis
  PKGARCH:=all
endef

define Package/luci-app-tether/description
  A simple LuCI page to switch the router's internet to a phone when the
  main connection is down: an iPhone or Android phone over a USB cable, or
  any phone's hotspot over Wi-Fi. Shows whether the main internet works again
  and switches back with one click.
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
endef

define Package/luci-app-tether/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# like LuCI's own packages: reload (not restart) rpcd, which keeps
	# everyone logged in and gives open sessions the new app's permissions
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	/etc/init.d/usbmuxd enable 2>/dev/null
	/etc/init.d/usbmuxd start 2>/dev/null
	echo "luci-app-tether: reload the LuCI page, then open Network -> Phone Tethering"
}
exit 0
endef

# Hand the internet back to the main connection before the app is gone.
define Package/luci-app-tether/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ "$$(uci -q get tether.settings.active)" = 1 ]; then
		ubus call luci.tether stop >/dev/null 2>&1
		sleep 2
	fi
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-tether))
