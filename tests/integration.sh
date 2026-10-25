#!/bin/sh
# Loads the plugin into a real rpcd on a real ubus and drives it through
# ubus calls, using the libubox/ubus/uci/ucode/rpcd revisions of the given
# OpenWrt release. Fake iwinfo / network.wireless / hostapd objects stand in
# for the Wi-Fi hardware. Must run as root (installs into /usr and
# /etc/config); meant for throwaway CI machines.
#
#   OPENWRT_VERSION=25.12.2 sudo -E ./tests/integration.sh
#
# Set SKIP_BUILD=1 when the stack is already installed (tests/lib/build-stack.sh).
set -e

export OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.2}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d)}"
[ -n "$SKIP_BUILD" ] || "$SRC/tests/lib/build-stack.sh"

# stop the daemons this script starts, so the next test script can run
PIDS=""
cleanup() {
	status=$?
	[ -n "$PIDS" ] && kill $PIDS 2>/dev/null
	sleep 1
	rm -f /var/run/ubus/ubus.sock
	exit $status
}
trap cleanup EXIT

R="$SRC/luci-app-wifisetup/root"

echo "== installing package files"
install -D -m 0644 "$R/usr/share/rpcd/ucode/luci.wifisetup" /usr/share/rpcd/ucode/luci.wifisetup
install -D -m 0644 "$R/usr/share/ucode/wifisetup/schedule.uc" /usr/share/ucode/wifisetup/schedule.uc
install -D -m 0755 "$R/usr/libexec/wifisetup-schedule" /usr/libexec/wifisetup-schedule
install -D -m 0644 "$R/etc/config/wifisetup" /etc/config/wifisetup
T="$SRC/luci-app-tether/root"
install -D -m 0644 "$T/usr/share/rpcd/ucode/luci.tether" /usr/share/rpcd/ucode/luci.tether
# iwinfo is served by rpcd itself on a real router: load the fake into rpcd too
install -D -m 0644 "$SRC/tests/helpers/fake_iwinfo.uc" /usr/share/rpcd/ucode/fake_iwinfo
install -D -m 0644 "$T/etc/config/tether" /etc/config/tether
# rc.common is not available here; call the tool the init script would call
printf '#!/bin/sh\n[ "$1" = reload ] && exec /usr/libexec/wifisetup-schedule sync\n' > /etc/init.d/wifisetup
chmod +x /etc/init.d/wifisetup
printf "config interface 'lan'\n\toption proto 'static'\n\toption ipaddr '192.168.1.1'\n\toption netmask '255.255.255.0'\n\nconfig interface 'wan'\n\toption proto 'dhcp'\n\nconfig interface 'wan6'\n\toption proto 'dhcpv6'\n\toption device '@wan'\n" > /etc/config/network
printf "config zone\n\toption name 'lan'\n\tlist network 'lan'\n\nconfig zone\n\toption name 'wan'\n\tlist network 'wan'\n\tlist network 'wan6'\n" > /etc/config/firewall
# a plugged in iPhone (ipheth network device eth9) in a fake /sys, laid out
# like the kernel does: the network device links to the USB interface
SYSFS="$WORK/sys"
mkdir -p "$SYSFS/bus/usb/devices/1-1/1-1:1.0" "$SYSFS/bus/usb/drivers/ipheth" "$SYSFS/class/net/eth9/statistics" "$SYSFS/module/ipheth"
echo 05ac > "$SYSFS/bus/usb/devices/1-1/idVendor"
echo iPhone > "$SYSFS/bus/usb/devices/1-1/product"
ln -s ../../../drivers/ipheth "$SYSFS/bus/usb/devices/1-1/1-1:1.0/driver"
ln -s ../../../bus/usb/devices/1-1/1-1:1.0 "$SYSFS/class/net/eth9/device"
echo 1 > "$SYSFS/class/net/eth9/carrier"
touch "$WORK/usbmuxd"
printf "config dnsmasq\n\toption domainneeded '1'\n" > /etc/config/dhcp
cat > /etc/config/wireless <<'WL'

config wifi-device 'radio0'
	option type 'mac80211'
	option band '2g'
	option channel '1'
	option htmode 'HE20'
	option disabled '1'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'OpenWrt'
	option encryption 'none'

config wifi-device 'radio1'
	option type 'mac80211'
	option band '5g'
	option channel '36'
	option htmode 'HE80'
	option disabled '1'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'OpenWrt'
	option encryption 'none'
WL
mkdir -p /var/run /etc/crontabs
# firewall reloads run in the background under a lock; log them
printf '#!/bin/sh\necho "firewall-$1" >> /tmp/order.log\n' > /etc/init.d/firewall
chmod +x /etc/init.d/firewall
rm -f /tmp/order.log
printf '0 4 * * * /bin/true # keep me\n' > /etc/crontabs/root

ubusd >"$WORK/ubusd.log" 2>&1 &
PIDS="$PIDS $!"
sleep 1
FAKE_LOG="$WORK/fake.log" ucode "$SRC/tests/helpers/fake_wifi.uc" >"$WORK/fake_wifi.out" 2>&1 &
PIDS="$PIDS $!"
TETHER_SYSFS="$SYSFS" TETHER_USBMUXD="$WORK/usbmuxd" rpcd >"$WORK/rpcd.log" 2>&1 &
PIDS="$PIDS $!"

for i in 1 2 3 4 5 6 7 8 9 10; do
	ubus list luci.wifisetup >/dev/null 2>&1 && ubus list luci.tether >/dev/null 2>&1 && ubus list iwinfo >/dev/null 2>&1 && break
	sleep 1
done

fail() {
	echo "FAIL: $*"
	echo "--- rpcd log"; cat "$WORK/rpcd.log"
	echo "--- fake wifi"; cat "$WORK/fake_wifi.out"
	exit 1
}

ubus list luci.wifisetup >/dev/null 2>&1 || fail "rpcd did not register luci.wifisetup"
ubus list iwinfo >/dev/null 2>&1 || fail "fake iwinfo not running"

echo "== get"
ubus -t 10 call luci.wifisetup get | jq -e '(.radios | length == 2) and .main.ssid == "OpenWrt" and .radios[1].htmode == "HE80" and .radios[1].band == "5g"' >/dev/null || fail "get"
# the page asks iwinfo (served by rpcd) for what the radios can do
ubus -t 10 call iwinfo info '{"device":"radio1"}' | jq -e '.htmodes | index("HE80")' >/dev/null || fail "iwinfo info"

echo "== main network"
ubus -t 10 call luci.wifisetup set_network '{"net":"main","ssid":"short","key":"x","encryption":"sae-mixed"}' | jq -e '.error' >/dev/null || fail "short password accepted"
ubus -t 10 call luci.wifisetup set_network '{"net":"main","ssid":"CI Home","key":"correct horse","encryption":"sae-mixed","hidden":false}' | jq -e '.result' >/dev/null || fail "set main"
[ "$(uci -q get wireless.default_radio0.ssid)" = "CI Home" ] || fail "ssid not written"
[ "$(uci -q get wireless.default_radio1.key)" = "correct horse" ] || fail "key not written"
[ "$(uci -q get wireless.default_radio1.encryption)" = sae-mixed ] || fail "encryption not written"

echo "== bands"
ubus -t 10 call luci.wifisetup set_radio '{"id":"radio1","enabled":true,"channel":"100","htmode":"HE80","txpower":0}' | jq -e '.result' >/dev/null || fail "set_radio"
[ "$(uci -q get wireless.radio1.channel)" = 100 ] || fail "channel"
[ "$(uci -q get wireless.radio1.htmode)" = HE80 ] || fail "htmode"
uci -q get wireless.radio1.disabled >/dev/null && fail "radio still disabled"
ubus -t 10 call luci.wifisetup set_radio '{"id":"radio0","enabled":true,"channel":"auto","htmode":"HE40","txpower":17}' | jq -e '.result' >/dev/null || fail "set_radio 2g"
[ "$(uci -q get wireless.radio0.txpower)" = 17 ] || fail "txpower"
ubus -t 10 call luci.wifisetup set_region '{"country":"DE"}' | jq -e '.result' >/dev/null || fail "set_region"
[ "$(uci -q get wireless.radio0.country)" = DE ] || fail "country"

echo "== guest network"
ubus -t 10 call luci.wifisetup set_network '{"net":"guest","enabled":true,"ssid":"CI Guest","key":"welcome123","encryption":"psk2","isolate":true,"bands":["radio0","radio1"]}' | jq -e '.result' >/dev/null || fail "set guest"
[ "$(uci -q get wireless.wifisetup_guest_radio1.network)" = guestwifi ] || fail "guest iface"
[ "$(uci -q get network.guestwifi.ipaddr)" = 192.168.3.1 ] || fail "guest subnet"
[ "$(uci -q get network.wifisetup_guest_dev.name)" = br-guestwifi ] || fail "guest bridge"
[ "$(uci -q get dhcp.guestwifi.interface)" = guestwifi ] || fail "guest dhcp"
[ "$(uci -q get firewall.wifisetup_guest_zone.input)" = REJECT ] || fail "guest zone"
[ "$(uci -q get firewall.wifisetup_guest_fwd.dest)" = wan ] || fail "guest forwarding"
ubus -t 10 call luci.wifisetup get | jq -e '.guest.enabled and .guest.ssid == "CI Guest"' >/dev/null || fail "guest read back"

echo "== more Wi-Fi networks"
ubus -t 10 call luci.wifisetup set_extra '{"ssid":"CI VPN","key":"correct horse","encryption":"sae-mixed","role":"vpn"}' | jq -e '.error' >/dev/null || fail "VPN network accepted without WireGuard + Passwall"
ubus -t 10 call luci.wifisetup set_extra '{"ssid":"CI Old","key":"correct horse","encryption":"psk2","hidden":false,"bands":["radio0"],"role":"lan"}' | jq -e '.id == "1"' >/dev/null || fail "set_extra"
[ "$(uci -q get wireless.wifisetup_x1_radio0.ssid)" = "CI Old" ] || fail "extra network not written"
[ "$(uci -q get wireless.wifisetup_x1_radio1.disabled)" = 1 ] || fail "extra network on a band not chosen"
ubus -t 10 call luci.wifisetup get | jq -e '.extras[0].ssid == "CI Old" and .extras[0].role == "lan" and .main.ssid == "CI Home"' >/dev/null || fail "get extras"
ubus -t 10 call luci.wifisetup remove_extra '{"id":"1"}' | jq -e '.result' >/dev/null || fail "remove_extra"
uci -q get wireless.wifisetup_x1_radio0 >/dev/null && fail "extra network not removed"

echo "== status, kick, block"
ubus -t 10 call luci.wifisetup status | jq -e '.radios.radio1.up and (.ifaces | map(.ifname + ":" + .network) == ["phy0-ap0:main","phy1-ap0:main"])' >/dev/null || fail "status"
ubus -t 10 call iwinfo assoclist '{"device":"phy1-ap0"}' | jq -e '.results[0].mac == "AA:BB:CC:DD:EE:01"' >/dev/null || fail "iwinfo assoclist"
ubus -t 10 call luci.wifisetup kick '{"mac":"aa:bb:cc:dd:ee:01","ifname":"phy1-ap0"}' | jq -e '.result' >/dev/null || fail "kick"
grep -q 'del_client aa:bb:cc:dd:ee:01' "$WORK/fake.log" || fail "hostapd del_client not called"
ubus -t 10 call luci.wifisetup block '{"mac":"aa:bb:cc:dd:ee:01","name":"Laptop"}' | jq -e '.result' >/dev/null || fail "block"
[ "$(uci -q get wireless.default_radio0.macfilter)" = deny ] || fail "macfilter"
uci -q get wireless.wifisetup_guest_radio0.maclist | grep -q AA:BB:CC:DD:EE:01 || fail "guest maclist"
ubus -t 10 call luci.wifisetup unblock '{"mac":"AA:BB:CC:DD:EE:01"}' | jq -e '.result' >/dev/null || fail "unblock"
uci -q get wireless.default_radio0.macfilter >/dev/null && fail "macfilter left"

echo "== schedule"
ubus -t 10 call luci.wifisetup set_schedule '{"enabled":true,"off":"23:00","on":"06:30","days":["mon","fri"]}' | jq -e '.result' >/dev/null || fail "set_schedule"
grep -qx '0 23 \* \* 1,5 /usr/libexec/wifisetup-schedule off # wifisetup-schedule' /etc/crontabs/root || { cat /etc/crontabs/root; fail "cron off line"; }
grep -qx '30 6 \* \* \* /usr/libexec/wifisetup-schedule on # wifisetup-schedule' /etc/crontabs/root || fail "cron on line"
grep -q 'keep me' /etc/crontabs/root || fail "other cron lines lost"
ubus -t 10 call luci.wifisetup set_schedule '{"enabled":false,"off":"23:00","on":"06:30","days":["mon"]}' >/dev/null || fail "disable schedule"
grep -q wifisetup-schedule /etc/crontabs/root && fail "cron lines left"
grep -q 'keep me' /etc/crontabs/root || fail "other cron lines lost on disable"

echo "== qr code"
ubus -t 10 call luci.wifisetup qrcode '{"net":"guest"}' | jq -e '.text == "WIFI:T:WPA;S:CI Guest;P:welcome123;;"' >/dev/null || fail "qr text"
if [ -x /usr/bin/qrencode ]; then
	ubus -t 10 call luci.wifisetup qrcode '{"net":"main"}' | jq -e '.svg | startswith("<?xml")' >/dev/null || fail "qr svg"
fi

echo "== guest off"
ubus -t 10 call luci.wifisetup set_network '{"net":"guest","enabled":false}' | jq -e '.result' >/dev/null || fail "guest off"
[ "$(uci -q get wireless.wifisetup_guest_radio0.disabled)" = 1 ] || fail "guest not disabled"

echo "== tether: status"
ubus list luci.tether >/dev/null 2>&1 || fail "rpcd did not register luci.tether"
ubus -t 10 call luci.tether status | jq -e '.active == false and .usb.supported and .usb.netdev == "eth9" and .usb.carrier and .usb.phone.name == "iPhone" and .usb.phone.kind == "iphone" and (.main | map(.interface) == ["wan","wan6"])' >/dev/null || fail "tether status"

echo "== tether: Wi-Fi hotspot"
ubus -t 10 call luci.tether status | jq -e '(.own_ssids | index("CI Home") != null) and (.own_ssids | index("CI Guest") != null) and .wifi.sta_ifname == null' >/dev/null || fail "tether own ssids"
ubus -t 10 call iwinfo scan '{"device":"radio0"}' | jq -e '.results[0].ssid == "CI iPhone"' >/dev/null || fail "iwinfo scan"
ubus -t 10 call luci.tether set_wifi '{"ssid":"CI iPhone","key":"hotspot-pass","encryption":"sae-mixed","radio":"radio0"}' | jq -e '.result' >/dev/null || fail "set_wifi"
[ "$(uci -q get wireless.tether_sta.mode)" = sta ] || fail "sta not written"
[ "$(uci -q get wireless.tether_sta.disabled)" = 1 ] || fail "sta enabled while off"
uci -q get firewall.@zone[1].network | grep -q tether_wifi || fail "tether_wifi not in wan zone"

echo "== tether: start USB"
ubus -t 10 call luci.tether start '{"method":"usb"}' | jq -e '.method == "usb"' >/dev/null || fail "start usb"
[ "$(uci -q get network.tether_usb.device)" = eth9 ] || fail "usb device"
[ "$(uci -q get network.tether_usb.auto)" = 1 ] || fail "usb not on"
[ "$(uci -q get network.wan.metric)" = 1000 ] || fail "wan not deprioritised"
[ "$(uci -q get network.wan6.auto)" = 0 ] || fail "wan6 not paused"
ubus -t 10 call luci.tether check_main | jq -e '.interface == "wan"' >/dev/null || fail "check_main"

# creating the guest network and adding the tether interfaces to the WAN
# zone changed the firewall: the locked background reload must have run
sleep 3
grep -q firewall-reload /tmp/order.log || fail "firewall not reloaded in the background"

echo "== tether: switch to Wi-Fi, then stop"
ubus -t 10 call luci.tether start '{"method":"wifi"}' | jq -e '.method == "wifi"' >/dev/null || fail "start wifi"
uci -q get wireless.tether_sta.disabled >/dev/null && fail "sta not enabled"
[ "$(uci -q get network.tether_usb.auto)" = 0 ] || fail "usb not off"
[ "$(uci -q get network.wan.metric)" = 1000 ] || fail "penalty stacked"
ubus -t 10 call luci.tether stop | jq -e '.result' >/dev/null || fail "stop"
uci -q get network.wan.metric >/dev/null && fail "wan metric not restored"
uci -q get network.wan6.auto >/dev/null && fail "wan6 not restored"
[ "$(uci -q get wireless.tether_sta.disabled)" = 1 ] || fail "sta still on"
[ "$(uci -q get tether.settings.active)" = 0 ] || fail "still active"

echo "All integration checks passed"
