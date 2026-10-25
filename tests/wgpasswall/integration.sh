#!/bin/sh
# Loads the plugin into a real rpcd on a real ubus and drives it through
# ubus calls, using the libubox/ubus/uci/ucode/rpcd revisions of the given
# OpenWrt release. Must run as root (installs into /usr and /etc/config);
# meant for throwaway CI machines.
#
#   OPENWRT_VERSION=25.12.2 sudo -E ./tests/wgpasswall/integration.sh
#
# Set SKIP_BUILD=1 when the stack is already installed (tests/lib/build-stack.sh).
set -e

export OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.2}"
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$(mktemp -d)}"
[ -n "$SKIP_BUILD" ] || "$SRC/tests/lib/build-stack.sh"

# stop the daemons this script starts, so the next test script can run
PIDS=""
cleanup() {
	status=$?
	[ -n "$PIDS" ] && kill $PIDS 2>/dev/null
	pkill -f passwall-stub-daemon 2>/dev/null
	sleep 1
	rm -f /var/run/ubus/ubus.sock
	exit $status
}
trap cleanup EXIT

R="$SRC/luci-app-wireguard-passwall/root"

echo "== installing package files"
install -D -m 0644 "$R/usr/share/rpcd/ucode/luci.wgpasswall" /usr/share/rpcd/ucode/luci.wgpasswall
install -D -m 0644 "$R/usr/share/ucode/wgpasswall/conf.uc" /usr/share/ucode/wgpasswall/conf.uc
install -D -m 0644 "$R/etc/config/wgpasswall" /etc/config/wgpasswall
printf "config interface 'lan'\n\toption proto 'static'\n\toption device 'br-lan'\n\nconfig interface 'wan'\n\toption proto 'dhcp'\n" > /etc/config/network
printf "config zone\n\toption name 'lan'\n\nconfig zone\n\toption name 'wan'\n" > /etc/config/firewall
mkdir -p /var/run

ubusd >"$WORK/ubusd.log" 2>&1 &
PIDS="$PIDS $!"
sleep 1
rpcd >"$WORK/rpcd.log" 2>&1 &
PIDS="$PIDS $!"

for i in 1 2 3 4 5 6 7 8 9 10; do
	ubus list luci.wgpasswall >/dev/null 2>&1 && break
	sleep 1
done

fail() {
	echo "FAIL: $*"
	echo "--- rpcd log"; cat "$WORK/rpcd.log"
	exit 1
}

ubus list luci.wgpasswall >/dev/null 2>&1 || fail "rpcd did not register luci.wgpasswall"

PRIV='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='
PUB='xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg='
CONF=$(printf '[Interface]\nPrivateKey = %s\nAddress = 10.2.0.2/32\nDNS = 10.2.0.1\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n' "$PRIV" "$PUB")

echo "== status"
ubus call luci.wgpasswall status >/dev/null || fail "status"

echo "== parse"
ubus call luci.wgpasswall parse "$(jq -n --arg c "$CONF" '{conf: $c}')" | jq -e '.full_tunnel == true' >/dev/null || fail "parse"

echo "== save"
ubus call luci.wgpasswall save "$(jq -n --arg c "$CONF" '{label: "CI VPN", conf: $c}')" | jq -e '.id == "wgc_civpn"' >/dev/null || fail "save"
[ "$(uci -q get network.wgc_civpn.proto)" = wireguard ] || fail "interface not written"
[ "$(uci -q get network.wgpasswall_rule_vpn.lookup)" = 51820 ] || fail "routing rule not written"
[ "$(uci -q get firewall.wgpasswall_zone.name)" = wgpasswall ] || fail "firewall zone not written"

echo "== get"
ubus call luci.wgpasswall get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("AllowedIPs = 0.0.0.0/0")' >/dev/null || fail "get"

echo "== kill switch"
ubus call luci.wgpasswall set_killswitch '{"enabled":true}' >/dev/null || fail "set_killswitch"
[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 1 ] || fail "kill switch not enabled"

echo "== Passwall modes"
# a minimal Passwall install: config, rule lists and an init script stub
cat > /etc/config/passwall <<'PW'

config global
	option enabled '0'
	option localhost_proxy '0'
	option client_proxy '1'
	option use_proxy_list '1'

config global_forwarding
	option udp_proxy_drop_ports '443,51820'

config nodes 'realitynode'
	option type 'Xray'
	option protocol 'vless'
	option remarks 'Reality'
	option address 'reality.example.com'
	option port '443'

config acl_rule 'myacl'
	option enabled '1'
	option remarks 'my own rule'
	list sources '192.168.1.50'

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
# Passwall's restart takes a while (stop, then start); a firewall reload in
# the middle of it can leave Passwall's rules behind while Passwall is off,
# which cuts off the router's own connections. The stubs log when restarts
# begin and end and when the firewall reloads, so the test can check that
# the app never lets those overlap.
ln -sf "$(command -v sleep)" /tmp/passwall-stub-daemon
cat > /etc/init.d/passwall <<'PW'
#!/bin/sh
echo "$1" >> /tmp/passwall-init.log
[ "$1" = enabled ] && exit 1
if [ "$1" = restart ]; then
	echo "restart-begin" >> /tmp/order.log
	sleep 1
	# like Passwall's xray, dnsmasq, ...: daemons that keep running and
	# inherit the open files of whoever restarted Passwall
	/tmp/passwall-stub-daemon 3600 &
	echo "restart-end" >> /tmp/order.log
fi
exit 0
PW
cat > /etc/init.d/firewall <<'FW'
#!/bin/sh
echo "firewall-$1" >> /tmp/order.log
FW
chmod +x /etc/init.d/firewall
rm -f /tmp/order.log /tmp/passwall-init.log
chmod +x /etc/init.d/passwall
cat > /etc/init.d/wgpasswall <<'WG'
#!/bin/sh
echo "$1" >> /tmp/wgpasswall-init.log
WG
chmod +x /etc/init.d/wgpasswall
rm -f /tmp/wgpasswall-init.log
uci show passwall > "$WORK/passwall.orig"
cp /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig"
cp /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig"

ubus call luci.wgpasswall status | jq -e '.passwall.installed and (.passwall.nodes[1].id == "hy2node") and .mode == "vpn"' >/dev/null || fail "passwall not detected"
ubus call luci.wgpasswall set_mode '{"mode":"vpn","connect":false}' >/dev/null || fail "vpn mode while in vpn mode"
ubus call luci.wgpasswall set_mode '{"mode":"bogus"}' | jq -e '.error' >/dev/null || fail "unknown mode accepted"
ubus call luci.wgpasswall set_mode '{"mode":"vpn_passwall"}' | jq -e '.error' >/dev/null || fail "Passwall mode without a node must fail"

echo "== mode: VPN through Passwall"
ubus call luci.wgpasswall set_mode '{"mode":"vpn_passwall","node":"hy2node","id":"wgc_civpn"}' | jq -e '.mode == "vpn_passwall"' >/dev/null || fail "set vpn_passwall"

check_wrapped() {
	[ "$(uci -q get passwall.@global[0].enabled)" = 1 ] || fail "passwall not enabled"
	[ "$(uci -q get passwall.@global[0].node)" = hy2node ] || fail "node not set"
	[ "$(uci -q get passwall.@global[0].client_proxy)" = 0 ] || fail "client proxy not off"
	[ "$(uci -q get passwall.@global[0].localhost_proxy)" = 0 ] || fail "localhost proxy changed"
	[ "$(uci -q get passwall.@global_forwarding[0].udp_proxy_drop_ports)" = 443,51820 ] || fail "drop ports changed"
	cmp -s /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig" || fail "proxy list modified"
	cmp -s /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig" || fail "direct list modified"
	uci show network | grep -q "endpoint_host='127.0.0.1'" || fail "endpoint not pointed at the relay"
	uci show network | grep -q "endpoint_port='51821'" || fail "relay port not set"
	uci show network | grep -q "wgpasswall_orig_host='1.2.3.4'" || fail "original endpoint not kept"
	ubus call luci.wgpasswall get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("Endpoint = 1.2.3.4:51820")' >/dev/null || fail "editor does not show the real server"
	ubus call luci.wgpasswall status | jq -e '.profiles[0].endpoint == "1.2.3.4:51820"' >/dev/null || fail "status does not show the real server"
	[ "$(uci -q get network.wgc_civpn.mtu)" = 1280 ] || fail "MTU not lowered"
	[ "$(uci -q get network.wgc_civpn.auto)" = 1 ] || fail "profile not connected"
	[ "$(uci -q get network.wgpasswall_rule_vpn_lan.in)" = lan ] || fail "VPN rule not limited to LAN traffic"
	uci -q get network.wgpasswall_rule_vpn >/dev/null && fail "router traffic still routed into the wrapped tunnel"
	[ "$(uci -q get network.wgpasswall_rule6_vpn_lan.in)" = lan ] || fail "IPv6 VPN rule not limited to LAN traffic"
	[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 1 ] || fail "kill switch not active"
	ubus call luci.wgpasswall get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("MTU") | not' >/dev/null || fail "editor shows lowered MTU"
	ubus call luci.wgpasswall status | jq -e '.mode == "vpn_passwall" and .passwall.enabled' >/dev/null || fail "status mode"
}
check_wrapped
sleep 1; grep -qx restart /tmp/wgpasswall-init.log || fail "relay service not restarted on mode change"

echo "== mode: Passwall only"
ubus call luci.wgpasswall set_mode '{"mode":"passwall"}' | jq -e '.mode == "passwall"' >/dev/null || fail "set passwall"
[ "$(uci -q get passwall.@global[0].enabled)" = 1 ] || fail "passwall not enabled"
[ "$(uci -q get passwall.@global[0].client_proxy)" = 1 ] || fail "client proxy not on"
[ "$(uci -q get passwall.@global[0].tcp_proxy_mode)" = proxy ] || fail "tcp mode not proxy"
[ "$(uci -q get passwall.@global[0].udp_proxy_mode)" = proxy ] || fail "udp mode not proxy"
[ "$(uci -q get passwall.@global[0].localhost_proxy)" = 0 ] || fail "localhost proxy not back to original"
[ "$(uci -q get passwall.@global_forwarding[0].udp_proxy_drop_ports)" = 443,51820 ] || fail "drop ports not back to original"
cmp -s /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig" || fail "proxy list still has VPN servers"
cmp -s /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig" || fail "direct list still modified"
[ "$(uci -q get network.wgc_civpn.auto)" = 0 ] || fail "profile not disconnected"
uci show network | grep -q "wgpasswall_orig_host" && fail "relay endpoint left in Passwall-only mode"
[ "$(uci -q get network.@wireguard_wgc_civpn[0].endpoint_host)" = 1.2.3.4 ] || fail "endpoint not restored"
uci -q get network.wgc_civpn.mtu >/dev/null && fail "MTU not restored"
[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 0 ] || fail "kill switch not paused"
[ "$(uci -q get network.wgpasswall_rule_vpn.lookup)" = 51820 ] || fail "normal VPN rule missing"
ubus call luci.wgpasswall connect '{"id":"wgc_civpn"}' | jq -e '.error' >/dev/null || fail "connect allowed in Passwall-only mode"
ubus call luci.wgpasswall status | jq -e '.mode == "passwall" and .killswitch_paused' >/dev/null || fail "status passwall mode"

echo "== mode: Off"
ubus call luci.wgpasswall set_mode '{"mode":"off"}' | jq -e '.mode == "off"' >/dev/null || fail "set off"
[ "$(uci -q get passwall.@global[0].enabled)" = 0 ] || fail "passwall not switched off"
[ "$(uci -q get passwall.@global[0].client_proxy)" = 1 ] || fail "off mode changed Client Proxy"
[ "$(uci -q get passwall.@global[0].tcp_proxy_mode)" = proxy ] || fail "off mode changed the proxy mode"
[ "$(uci -q get network.wgc_civpn.auto)" = 0 ] || fail "profile not disconnected in off mode"
[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 0 ] || fail "kill switch not paused in off mode"
[ "$(uci -q get network.wgpasswall_rule_vpn.lookup)" = 51820 ] || fail "normal VPN rule missing in off mode"
ubus call luci.wgpasswall connect '{"id":"wgc_civpn"}' | jq -e '.error' >/dev/null || fail "connect allowed in off mode"
ubus call luci.wgpasswall status | jq -e '.mode == "off" and .killswitch_paused' >/dev/null || fail "status off mode"
[ "$(uci -q get passwall.@global[0].node)" = hy2node ] || fail "picked node not kept selected in off mode"
ubus call luci.wgpasswall status | jq -e '.passwall.node == "hy2node"' >/dev/null || fail "status does not show the picked node in off mode"

echo "== mode: back to VPN through Passwall"
ubus call luci.wgpasswall set_mode '{"mode":"vpn_passwall"}' >/dev/null || fail "set vpn_passwall again (remembered node)"
check_wrapped

echo "== mode: Off straight from VPN through Passwall"
ubus call luci.wgpasswall set_mode '{"mode":"off"}' >/dev/null || fail "set off"
[ "$(uci -q get passwall.@global[0].enabled)" = 0 ] || fail "passwall not switched off"
[ "$(uci -q get passwall.@global[0].node)" = hy2node ] || fail "off mode changed the node"
[ "$(uci -q get passwall.@global[0].client_proxy)" = 0 ] || fail "off mode changed Client Proxy"
uci show network | grep -q "wgpasswall_orig_host='1.2.3.4'" || fail "off mode touched the relay endpoint"
[ "$(uci -q get network.wgc_civpn.auto)" = 0 ] || fail "profile not disconnected in off mode"
ubus call luci.wgpasswall set_mode '{"mode":"vpn_passwall"}' >/dev/null || fail "back on from off"
check_wrapped

echo "== only chosen devices use the VPN"
# a copy of Passwall's settings saved by an older version, before the app
# managed the access control switch
uci delete wgpasswall.passwall.pw_acl_enable 2>/dev/null; uci commit wgpasswall
ubus call luci.wgpasswall set_devices '{"scope":"devices","devices":[]}' | jq -e '.error' >/dev/null || fail "empty device list accepted"
ubus call luci.wgpasswall set_devices '{"scope":"devices","devices":["aa:bb:cc:dd:ee:01","AA:BB:CC:DD:EE:02"]}' | jq -e '.result' >/dev/null || fail "set_devices"
check_devices() {
	[ "$(uci -q get passwall.@global[0].client_proxy)" = 1 ] || fail "Passwall does not proxy the other devices"
	[ "$(uci -q get passwall.@global[0].tcp_proxy_mode)" = proxy ] || fail "tcp mode not proxy for the other devices"
	[ "$(uci -q get passwall.wgpasswall_vpn_devices.mode)" = 0 ] || fail "no 'No Proxy' rule for the VPN devices"
	[ "$(uci -q get passwall.@global[0].acl_enable)" = 1 ] || fail "Passwall's access control not switched on, so it ignores the rule"
	[ "$(uci -q get passwall.wgpasswall_vpn_devices.tcp_no_redir_ports)" = 1:65535 ] || fail "older Passwall would proxy the VPN devices' TCP"
	[ "$(uci -q get passwall.wgpasswall_vpn_devices.udp_no_redir_ports)" = 1:65535 ] || fail "older Passwall would proxy the VPN devices' UDP"
	[ "$(uci -q show passwall.wgpasswall_vpn_devices.sources)" = "passwall.wgpasswall_vpn_devices.sources='AA:BB:CC:DD:EE:01 AA:BB:CC:DD:EE:02'" ] || \
		fail "VPN devices not in the Passwall rule as one value: $(uci -q show passwall.wgpasswall_vpn_devices.sources)"
	# the way Passwall reads its rules (app.sh: acl_app / nftables.sh: load_acl)
	( eval "$(uci -q show passwall.wgpasswall_vpn_devices | cut -d'.' -sf 3-)" 2>&1 && [ "$sources" = "AA:BB:CC:DD:EE:01 AA:BB:CC:DD:EE:02" ] ) >/dev/null || \
		fail "Passwall cannot read the rule's sources"
	[ "$(uci show passwall | sed -n 's/^passwall\.\([^.=]*\)=acl_rule$/\1/p' | head -n 1)" = wgpasswall_vpn_devices ] || fail "VPN device rule not ahead of other access rules"
	[ "$(uci -q get network.wgpasswall_rule_vpn.mark)" = 0x1000000/0x1000000 ] || fail "VPN rule does not match the device mark"
	uci -q get network.wgpasswall_rule_vpn_lan >/dev/null && fail "LAN-wide VPN rule left behind"
	[ "$(uci -q get firewall.wgpasswall_devices.target)" = MARK ] || fail "no firewall rule marking the VPN devices"
	[ "$(uci -q get firewall.wgpasswall_devices.src_mac)" = "AA:BB:CC:DD:EE:01 AA:BB:CC:DD:EE:02" ] || fail "mark rule devices"
	[ "$(uci -q get firewall.wgpasswall_killswitch.src_mac)" = "AA:BB:CC:DD:EE:01 AA:BB:CC:DD:EE:02" ] || fail "kill switch not limited to the VPN devices"
	ubus call luci.wgpasswall status | jq -e '.scope == "devices"' >/dev/null || fail "status scope"
	# their DNS: the VPN's server through the tunnel, not the router's resolver
	uci -q get network.wgc_civpn.dns >/dev/null && fail "VPN DNS still an upstream of the router's resolver"
	[ "$(uci -q get wgpasswall.wgc_civpn.dns)" = 10.2.0.1 ] || fail "VPN DNS not kept for the devices"
	[ "$(uci -q get firewall.wgpasswall_devices_dns.path)" = /etc/wgpasswall/devices-dns.nft ] || fail "DNS rules not included in the firewall"
	grep -q "ether saddr { aa:bb:cc:dd:ee:01, aa:bb:cc:dd:ee:02 } .* dnat ip to 10.2.0.1:53" /etc/wgpasswall/devices-dns.nft || \
		{ cat /etc/wgpasswall/devices-dns.nft; fail "VPN devices' DNS not sent to the VPN's DNS server"; }
	nft -c -f /etc/wgpasswall/devices-dns.nft || fail "DNS rules do not load"
	ubus call luci.wgpasswall status | jq -e '.vpn_dns.v4 == "10.2.0.1"' >/dev/null || fail "status vpn_dns"
}
check_devices
ubus call luci.wgpasswall set_mode '{"mode":"passwall"}' >/dev/null || fail "Passwall only with chosen devices"
uci -q get passwall.wgpasswall_vpn_devices >/dev/null && fail "VPN devices skip Passwall in Passwall-only mode"
uci -q get passwall.@global[0].acl_enable >/dev/null && fail "access control switch not back to original in Passwall-only mode"
ubus call luci.wgpasswall set_mode '{"mode":"vpn_passwall"}' >/dev/null || fail "back to VPN through Passwall with chosen devices"
check_devices

echo "== reapply after changes on Passwall's own page"
ubus call luci.wgpasswall status | jq -e '.drift == []' >/dev/null || fail "drift reported right after applying"
uci set passwall.@global[0].client_proxy=0
uci set passwall.@global[0].acl_enable=0
uci delete passwall.wgpasswall_vpn_devices
uci delete firewall.wgpasswall_devices
uci commit passwall; uci commit firewall
ubus call luci.wgpasswall status | jq -e '(.drift | index("pw_settings")) and (.drift | index("pw_acl")) and (.drift | index("fw_missing"))' >/dev/null || \
	fail "changes made elsewhere not reported: $(ubus call luci.wgpasswall status | jq -c .drift)"
: > /tmp/order.log
ubus call luci.wgpasswall reapply | jq -e '.result' >/dev/null || fail "reapply"
check_devices
ubus call luci.wgpasswall status | jq -e '.drift == []' >/dev/null || fail "drift left after reapply"
for i in $(seq 1 20); do grep -q restart-end /tmp/order.log && break; sleep 0.5; done
grep -q firewall-reload /tmp/order.log && grep -q restart-end /tmp/order.log || fail "reapply did not reload the firewall and restart Passwall"
ubus call luci.wgpasswall set_devices '{"scope":"all","devices":["AA:BB:CC:DD:EE:01"]}' | jq -e '.result' >/dev/null || fail "set_devices all"
uci -q get passwall.wgpasswall_vpn_devices >/dev/null && fail "VPN device rule left behind"
uci -q get passwall.@global[0].acl_enable >/dev/null && fail "access control switch left on"
uci -q get firewall.wgpasswall_devices >/dev/null && fail "mark rule left behind"
uci -q get firewall.wgpasswall_killswitch.src_mac >/dev/null && fail "kill switch still limited to devices"
uci -q get network.wgc_civpn.dns >/dev/null && fail "VPN DNS an upstream of the router's resolver with all devices"
grep -q 'iifname { "br-lan" } .* dnat ip to 10.2.0.1:53' /etc/wgpasswall/devices-dns.nft || \
	{ cat /etc/wgpasswall/devices-dns.nft; fail "LAN devices' DNS not sent to the VPN's DNS server"; }
check_wrapped
ubus call luci.wgpasswall set_devices '{"scope":"devices","devices":["AA:BB:CC:DD:EE:01"]}' >/dev/null || fail "set_devices again"

echo "== mode: VPN restores Passwall"
ubus call luci.wgpasswall set_mode '{"mode":"vpn"}' | jq -e '.mode == "vpn"' >/dev/null || fail "set vpn"
uci show passwall | cmp -s - "$WORK/passwall.orig" || { uci show passwall | diff "$WORK/passwall.orig" -; fail "passwall config not restored"; }
cmp -s /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig" || fail "proxy list not restored"
cmp -s /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig" || fail "direct list not restored"
uci -q get network.wgc_civpn.mtu >/dev/null && fail "MTU not restored"
[ "$(uci -q get network.wgc_civpn.auto)" = 1 ] || fail "profile not connected in VPN mode"
[ "$(uci -q get network.@wireguard_wgc_civpn[0].endpoint_host)" = 1.2.3.4 ] || fail "endpoint not restored in VPN mode"
[ "$(uci -q get network.@wireguard_wgc_civpn[0].endpoint_port)" = 51820 ] || fail "endpoint port not restored"
uci show network | grep -q "wgpasswall_orig_host" && fail "relay options left behind"
[ "$(uci -q get network.wgpasswall_rule_vpn.lookup)" = 51820 ] || fail "VPN rule for all traffic not restored"
uci -q get network.wgpasswall_rule_vpn.in >/dev/null && fail "VPN rule still limited to LAN"
[ "$(uci -q get network.wgpasswall_rule_vpn.mark)" = 0x1000000/0x1000000 ] || fail "VPN mode does not keep the chosen devices"
ubus call luci.wgpasswall set_devices '{"scope":"all","devices":[]}' >/dev/null || fail "set_devices all in VPN mode"
[ "$(uci -q get network.wgpasswall_rule_vpn.mark)" = 0x0/0xff ] || fail "VPN rule for all traffic not restored"
uci -q get network.wgpasswall_rule_vpn_lan >/dev/null && fail "LAN-only VPN rule left behind"
[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 1 ] || fail "kill switch not resumed"
# Passwall commands run in the background, queued behind earlier restarts
for i in $(seq 1 30); do grep -qx disable /tmp/passwall-init.log && break; sleep 0.5; done
grep -qx disable /tmp/passwall-init.log || fail "passwall service not disabled again"
uci set passwall.@global[0].node=realitynode; uci commit passwall
ubus call luci.wgpasswall reapply >/dev/null || fail "reapply in VPN mode"
[ "$(uci -q get passwall.@global[0].node)" = realitynode ] || fail "reapply in VPN mode changed Passwall"
ubus call luci.wgpasswall status | jq -e '.drift == []' >/dev/null || fail "Passwall's own settings reported as drift in VPN mode"
uci delete passwall.@global[0].node; uci commit passwall

echo "== firewall reloads and Passwall restarts never overlap"
# quick mode changes, as when toggling in the UI
ubus call luci.wgpasswall set_mode '{"mode":"vpn_passwall"}' >/dev/null
ubus call luci.wgpasswall set_mode '{"mode":"off"}' >/dev/null
ubus call luci.wgpasswall set_killswitch '{"enabled":false}' >/dev/null
ubus call luci.wgpasswall set_mode '{"mode":"passwall"}' >/dev/null
ubus call luci.wgpasswall set_mode '{"mode":"vpn","connect":false}' >/dev/null
for i in $(seq 1 30); do
	[ "$(grep -c restart-begin /tmp/order.log)" = "$(grep -c restart-end /tmp/order.log)" ] && \
		[ "$(grep -c restart-begin /tmp/order.log)" -ge 4 ] && break
	sleep 1
done
sleep 2
awk '/restart-begin/ { if (busy) { print "restarts overlap at line " NR; bad = 1 } busy = 1 }
     /restart-end/ { busy = 0 }
     /firewall-/ { if (busy) { print "firewall reload during a Passwall restart at line " NR; bad = 1 } }
     END { exit bad }' /tmp/order.log || { cat /tmp/order.log; fail "firewall reloads / Passwall restarts overlapped"; }
grep -q firewall-reload /tmp/order.log || fail "firewall never reloaded"

echo "== remove"
ubus call luci.wgpasswall remove '{"id":"wgc_civpn"}' >/dev/null || fail "remove"
uci -q get network.wgc_civpn >/dev/null && fail "interface not removed"

echo "All integration checks passed"
