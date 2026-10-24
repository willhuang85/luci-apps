#!/bin/sh
# Loads the plugin into a real rpcd on a real ubus and drives it through
# ubus calls, using the libubox/ubus/uci/ucode/rpcd revisions of the given
# OpenWrt release. Must run as root (installs into /usr and /etc/config);
# meant for throwaway CI machines.
#
#   OPENWRT_VERSION=25.12.2 sudo -E ./tests/integration.sh
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

build libubox openwrt/libubox package/libs/libubox/Makefile -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
build ubus openwrt/ubus package/system/ubus/Makefile -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
build uci openwrt/uci package/system/uci/Makefile -DBUILD_LUA=OFF
build ucode jow-/ucode package/utils/ucode/Makefile -DUBUS_SUPPORT=ON -DUCI_SUPPORT=ON -DULOOP_SUPPORT=ON \
	-DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF -DDIGEST_SUPPORT=OFF -DSOCKET_SUPPORT=OFF -DLOG_SUPPORT=OFF
build rpcd openwrt/rpcd package/system/rpcd/Makefile -DUCODE_SUPPORT=ON -DFILE_SUPPORT=OFF -DIWINFO_SUPPORT=OFF -DRPCSYS_SUPPORT=OFF

echo "== installing package files"
R="$SRC/luci-app-wgclient/root"
install -D -m 0644 "$R/usr/share/rpcd/ucode/luci.wgclient" /usr/share/rpcd/ucode/luci.wgclient
install -D -m 0644 "$R/usr/share/ucode/wgclient/conf.uc" /usr/share/ucode/wgclient/conf.uc
install -D -m 0644 "$R/etc/config/wgclient" /etc/config/wgclient
printf "config interface 'lan'\n\toption proto 'static'\n\nconfig interface 'wan'\n\toption proto 'dhcp'\n" > /etc/config/network
printf "config zone\n\toption name 'lan'\n\nconfig zone\n\toption name 'wan'\n" > /etc/config/firewall
mkdir -p /var/run

ubusd >"$WORK/ubusd.log" 2>&1 &
sleep 1
rpcd >"$WORK/rpcd.log" 2>&1 &

for i in 1 2 3 4 5 6 7 8 9 10; do
	ubus list luci.wgclient >/dev/null 2>&1 && break
	sleep 1
done

fail() {
	echo "FAIL: $*"
	echo "--- rpcd log"; cat "$WORK/rpcd.log"
	exit 1
}

ubus list luci.wgclient >/dev/null 2>&1 || fail "rpcd did not register luci.wgclient"

PRIV='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='
PUB='xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg='
CONF=$(printf '[Interface]\nPrivateKey = %s\nAddress = 10.2.0.2/32\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n' "$PRIV" "$PUB")

echo "== status"
ubus call luci.wgclient status >/dev/null || fail "status"

echo "== parse"
ubus call luci.wgclient parse "$(jq -n --arg c "$CONF" '{conf: $c}')" | jq -e '.full_tunnel == true' >/dev/null || fail "parse"

echo "== save"
ubus call luci.wgclient save "$(jq -n --arg c "$CONF" '{label: "CI VPN", conf: $c}')" | jq -e '.id == "wgc_civpn"' >/dev/null || fail "save"
[ "$(uci -q get network.wgc_civpn.proto)" = wireguard ] || fail "interface not written"
[ "$(uci -q get network.wgclient_rule_vpn.lookup)" = 51820 ] || fail "routing rule not written"
[ "$(uci -q get firewall.wgclient_zone.name)" = wgclient ] || fail "firewall zone not written"

echo "== get"
ubus call luci.wgclient get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("AllowedIPs = 0.0.0.0/0")' >/dev/null || fail "get"

echo "== kill switch"
ubus call luci.wgclient set_killswitch '{"enabled":true}' >/dev/null || fail "set_killswitch"
[ "$(uci -q get firewall.wgclient_killswitch.enabled)" = 1 ] || fail "kill switch not enabled"

echo "== tunnel through Passwall"
# a minimal Passwall install: config, rule lists and an init script stub
cat > /etc/config/passwall <<'PW'

config global
	option enabled '0'
	option localhost_proxy '0'
	option client_proxy '1'
	option use_proxy_list '1'

config global_forwarding
	option udp_proxy_drop_ports '443,51820'

config nodes 'hy2node'
	option type 'Xray'
	option protocol 'hysteria'
	option remarks 'HY2'
	option address 'proxy.example.com'
	option port '443'
PW
mkdir -p /etc/passwall/rules
printf '8.8.4.4\n' > /etc/passwall/rules/proxy_ip
printf '223.5.5.5\n1.2.3.4\n' > /etc/passwall/rules/direct_ip
cat > /etc/init.d/passwall <<'PW'
#!/bin/sh
echo "$1" >> /tmp/passwall-init.log
[ "$1" = enabled ] && exit 1
exit 0
PW
chmod +x /etc/init.d/passwall
uci show passwall > "$WORK/passwall.orig"
cp /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig"
cp /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig"

ubus call luci.wgclient status | jq -e '.passwall.installed and (.passwall.nodes[0].id == "hy2node")' >/dev/null || fail "passwall not detected"
ubus call luci.wgclient set_passwall '{"enabled":false}' >/dev/null || fail "set_passwall off while off"
ubus call luci.wgclient set_passwall '{"enabled":true}' | jq -e '.error' >/dev/null || fail "enabling without a node must fail"
ubus call luci.wgclient set_passwall '{"enabled":true,"node":"hy2node"}' | jq -e '.enabled == true' >/dev/null || fail "set_passwall on"

[ "$(uci -q get passwall.@global[0].enabled)" = 1 ] || fail "passwall not enabled"
[ "$(uci -q get passwall.@global[0].node)" = hy2node ] || fail "node not set"
[ "$(uci -q get passwall.@global[0].localhost_proxy)" = 1 ] || fail "localhost proxy not on"
[ "$(uci -q get passwall.@global[0].client_proxy)" = 0 ] || fail "client proxy not off"
[ "$(uci -q get passwall.@global_forwarding[0].udp_proxy_drop_ports)" = 443 ] || fail "VPN port still dropped"
grep -qx '8.8.4.4' /etc/passwall/rules/proxy_ip || fail "user proxy entry lost"
grep -qx '1.2.3.4' /etc/passwall/rules/proxy_ip || fail "server not in proxy list"
grep -qx '# disabled by luci-app-wgclient: 1.2.3.4' /etc/passwall/rules/direct_ip || fail "server not disabled in direct list"
grep -qx '223.5.5.5' /etc/passwall/rules/direct_ip || fail "user direct entry lost"
[ "$(uci -q get network.wgc_civpn.mtu)" = 1280 ] || fail "MTU not lowered"
[ "$(uci -q get network.wgclient_rule_vpn_lan.in)" = lan ] || fail "VPN rule not limited to LAN traffic"
uci -q get network.wgclient_rule_vpn >/dev/null && fail "router traffic still routed into the wrapped tunnel"
[ "$(uci -q get network.wgclient_rule6_vpn_lan.in)" = lan ] || fail "IPv6 VPN rule not limited to LAN traffic"
ubus call luci.wgclient get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("MTU") | not' >/dev/null || fail "editor shows lowered MTU"
ubus call luci.wgclient status | jq -e '.passwall.enabled' >/dev/null || fail "status does not show passwall on"

echo "== Passwall off restores everything"
ubus call luci.wgclient set_passwall '{"enabled":false}' >/dev/null || fail "set_passwall off"
uci show passwall | cmp -s - "$WORK/passwall.orig" || { uci show passwall | diff "$WORK/passwall.orig" -; fail "passwall config not restored"; }
cmp -s /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig" || fail "proxy list not restored"
cmp -s /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig" || fail "direct list not restored"
uci -q get network.wgc_civpn.mtu >/dev/null && fail "MTU not restored"
[ "$(uci -q get network.wgclient_rule_vpn.lookup)" = 51820 ] || fail "VPN rule for all traffic not restored"
uci -q get network.wgclient_rule_vpn.in >/dev/null && fail "VPN rule still limited to LAN"
uci -q get network.wgclient_rule_vpn_lan >/dev/null && fail "LAN-only VPN rule left behind"
grep -qx disable /tmp/passwall-init.log || fail "passwall service not disabled again"

echo "== remove"
ubus call luci.wgclient remove '{"id":"wgc_civpn"}' >/dev/null || fail "remove"
uci -q get network.wgc_civpn >/dev/null && fail "interface not removed"

echo "All integration checks passed"
