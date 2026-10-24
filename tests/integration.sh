#!/bin/sh
# Loads the plugin into a real rpcd on a real ubus and drives it through
# ubus calls, using the libubox/ubus/uci/ucode/rpcd revisions of the given
# OpenWrt release. Fake iwinfo / network.wireless / hostapd objects stand in
# for the Wi-Fi hardware. Must run as root (installs into /usr and
# /etc/config); meant for throwaway CI machines.
#
#   OPENWRT_VERSION=25.12.2 sudo -E ./tests/integration.sh
#
# Set SKIP_BUILD=1 when the stack is already installed.
set -e

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.2}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d)}"
RAW="https://raw.githubusercontent.com/openwrt/openwrt/v${OPENWRT_VERSION}"

# name, GitHub repo, Makefile path in openwrt.git, extra cmake flags
build() {
	name="$1" repo="$2" mk="$3"; shift 3
	rev=$(curl -fsSL "$RAW/$mk" | sed -n 's/^PKG_SOURCE_VERSION:=//p')
	[ -n "$rev" ] || { echo "Cannot find $name revision for OpenWrt $OPENWRT_VERSION"; exit 1; }
	echo "== $name @ $rev"
	git init -q "$WORK/$name"
	git -C "$WORK/$name" fetch -q --depth 1 "https://github.com/$repo.git" "$rev"
	git -C "$WORK/$name" checkout -q FETCH_HEAD
	cmake -S "$WORK/$name" -B "$WORK/$name/build" -DCMAKE_INSTALL_PREFIX=/usr "$@" >/dev/null
	make -C "$WORK/$name/build" -j"$(nproc)" install >/dev/null
	ldconfig
}

if [ -z "$SKIP_BUILD" ]; then
	build libubox openwrt/libubox package/libs/libubox/Makefile -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
	build ubus openwrt/ubus package/system/ubus/Makefile -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
	build uci openwrt/uci package/system/uci/Makefile -DBUILD_LUA=OFF
	build ucode jow-/ucode package/utils/ucode/Makefile -DUBUS_SUPPORT=ON -DUCI_SUPPORT=ON -DULOOP_SUPPORT=ON \
		-DSOCKET_SUPPORT=ON -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF -DDIGEST_SUPPORT=OFF -DLOG_SUPPORT=OFF
	build rpcd openwrt/rpcd package/system/rpcd/Makefile -DUCODE_SUPPORT=ON -DFILE_SUPPORT=OFF -DIWINFO_SUPPORT=OFF -DRPCSYS_SUPPORT=OFF
fi

R="$SRC/luci-app-tether/root"

echo "== installing package files"
install -D -m 0644 "$R/usr/share/rpcd/ucode/luci.tether" /usr/share/rpcd/ucode/luci.tether
install -D -m 0644 "$R/usr/share/ucode/tether/schedule.uc" /usr/share/ucode/tether/schedule.uc
install -D -m 0755 "$R/usr/libexec/tether-schedule" /usr/libexec/tether-schedule
install -D -m 0644 "$R/etc/config/tether" /etc/config/tether
# rc.common is not available here; call the tool the init script would call
printf '#!/bin/sh\n[ "$1" = reload ] && exec /usr/libexec/tether-schedule sync\n' > /etc/init.d/tether
chmod +x /etc/init.d/tether
printf "config interface 'lan'\n\toption proto 'static'\n\toption ipaddr '192.168.1.1'\n\toption netmask '255.255.255.0'\n\nconfig interface 'wan'\n\toption proto 'dhcp'\n" > /etc/config/network
printf "config zone\n\toption name 'lan'\n\nconfig zone\n\toption name 'wan'\n" > /etc/config/firewall
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
printf '0 4 * * * /bin/true # keep me\n' > /etc/crontabs/root

ubusd >"$WORK/ubusd.log" 2>&1 &
sleep 1
FAKE_LOG="$WORK/fake.log" ucode "$SRC/tests/helpers/fake_wifi.uc" >"$WORK/fake_wifi.out" 2>&1 &
rpcd >"$WORK/rpcd.log" 2>&1 &

for i in 1 2 3 4 5 6 7 8 9 10; do
	ubus list luci.tether >/dev/null 2>&1 && ubus list iwinfo >/dev/null 2>&1 && break
	sleep 1
done

fail() {
	echo "FAIL: $*"
	echo "--- rpcd log"; cat "$WORK/rpcd.log"
	echo "--- fake wifi"; cat "$WORK/fake_wifi.out"
	exit 1
}

ubus list luci.tether >/dev/null 2>&1 || fail "rpcd did not register luci.tether"
ubus list iwinfo >/dev/null 2>&1 || fail "fake iwinfo not running"

echo "== get"
ubus call luci.tether get | jq -e '(.radios | length == 2) and .main.ssid == "OpenWrt" and (.radios[1].widths | map(.htmode) == ["HE20","HE40","HE80"]) and (.radios[1].channels[1].dfs)' >/dev/null || fail "get"

echo "== main network"
ubus call luci.tether set_network '{"net":"main","ssid":"short","key":"x","encryption":"sae-mixed"}' | jq -e '.error' >/dev/null || fail "short password accepted"
ubus call luci.tether set_network '{"net":"main","ssid":"CI Home","key":"correct horse","encryption":"sae-mixed","hidden":false}' | jq -e '.result' >/dev/null || fail "set main"
[ "$(uci -q get wireless.default_radio0.ssid)" = "CI Home" ] || fail "ssid not written"
[ "$(uci -q get wireless.default_radio1.key)" = "correct horse" ] || fail "key not written"
[ "$(uci -q get wireless.default_radio1.encryption)" = sae-mixed ] || fail "encryption not written"

echo "== bands"
ubus call luci.tether set_radio '{"id":"radio1","enabled":true,"channel":"100","width":80,"txpower":0}' | jq -e '.result' >/dev/null || fail "set_radio"
[ "$(uci -q get wireless.radio1.channel)" = 100 ] || fail "channel"
[ "$(uci -q get wireless.radio1.htmode)" = HE80 ] || fail "htmode"
uci -q get wireless.radio1.disabled >/dev/null && fail "radio still disabled"
ubus call luci.tether set_radio '{"id":"radio0","enabled":true,"channel":"auto","width":40,"txpower":17}' | jq -e '.result' >/dev/null || fail "set_radio 2g"
[ "$(uci -q get wireless.radio0.txpower)" = 17 ] || fail "txpower"
ubus call luci.tether set_region '{"country":"DE"}' | jq -e '.result' >/dev/null || fail "set_region"
[ "$(uci -q get wireless.radio0.country)" = DE ] || fail "country"

echo "== guest network"
ubus call luci.tether set_network '{"net":"guest","enabled":true,"ssid":"CI Guest","key":"welcome123","encryption":"psk2","isolate":true,"bands":["radio0","radio1"]}' | jq -e '.result' >/dev/null || fail "set guest"
[ "$(uci -q get wireless.tether_guest_radio1.network)" = guestwifi ] || fail "guest iface"
[ "$(uci -q get network.guestwifi.ipaddr)" = 192.168.3.1 ] || fail "guest subnet"
[ "$(uci -q get network.tether_guest_dev.name)" = br-guestwifi ] || fail "guest bridge"
[ "$(uci -q get dhcp.guestwifi.interface)" = guestwifi ] || fail "guest dhcp"
[ "$(uci -q get firewall.tether_guest_zone.input)" = REJECT ] || fail "guest zone"
[ "$(uci -q get firewall.tether_guest_fwd.dest)" = wan ] || fail "guest forwarding"
ubus call luci.tether get | jq -e '.guest.enabled and .guest.ssid == "CI Guest"' >/dev/null || fail "guest read back"

echo "== status, kick, block"
ubus call luci.tether status | jq -e '.radios.radio1.channel == 36 and .clients[0].mac == "AA:BB:CC:DD:EE:01" and .clients[0].network == "main"' >/dev/null || fail "status"
ubus call luci.tether kick '{"mac":"aa:bb:cc:dd:ee:01"}' | jq -e '.result' >/dev/null || fail "kick"
grep -q 'del_client aa:bb:cc:dd:ee:01' "$WORK/fake.log" || fail "hostapd del_client not called"
ubus call luci.tether block '{"mac":"aa:bb:cc:dd:ee:01","name":"Laptop"}' | jq -e '.result' >/dev/null || fail "block"
[ "$(uci -q get wireless.default_radio0.macfilter)" = deny ] || fail "macfilter"
uci -q get wireless.tether_guest_radio0.maclist | grep -q AA:BB:CC:DD:EE:01 || fail "guest maclist"
ubus call luci.tether unblock '{"mac":"AA:BB:CC:DD:EE:01"}' | jq -e '.result' >/dev/null || fail "unblock"
uci -q get wireless.default_radio0.macfilter >/dev/null && fail "macfilter left"

echo "== schedule"
ubus call luci.tether set_schedule '{"enabled":true,"off":"23:00","on":"06:30","days":["mon","fri"]}' | jq -e '.result' >/dev/null || fail "set_schedule"
grep -qx '0 23 \* \* 1,5 /usr/libexec/tether-schedule off # tether-schedule' /etc/crontabs/root || { cat /etc/crontabs/root; fail "cron off line"; }
grep -qx '30 6 \* \* \* /usr/libexec/tether-schedule on # tether-schedule' /etc/crontabs/root || fail "cron on line"
grep -q 'keep me' /etc/crontabs/root || fail "other cron lines lost"
ubus call luci.tether set_schedule '{"enabled":false,"off":"23:00","on":"06:30","days":["mon"]}' >/dev/null || fail "disable schedule"
grep -q tether-schedule /etc/crontabs/root && fail "cron lines left"
grep -q 'keep me' /etc/crontabs/root || fail "other cron lines lost on disable"

echo "== qr code"
ubus call luci.tether qrcode '{"net":"guest"}' | jq -e '.text == "WIFI:T:WPA;S:CI Guest;P:welcome123;;"' >/dev/null || fail "qr text"
if [ -x /usr/bin/qrencode ]; then
	ubus call luci.tether qrcode '{"net":"main"}' | jq -e '.svg | startswith("<?xml")' >/dev/null || fail "qr svg"
fi

echo "== guest off"
ubus call luci.tether set_network '{"net":"guest","enabled":false}' | jq -e '.result' >/dev/null || fail "guest off"
[ "$(uci -q get wireless.tether_guest_radio0.disabled)" = 1 ] || fail "guest not disabled"

echo "All integration checks passed"
