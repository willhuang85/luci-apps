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
cat > /etc/config/network <<'NET'
config device 'brlan'
	option name 'br-lan'
	option type 'bridge'
	list ports 'lan1'
	list ports 'lan2'

config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option proto 'static'
	option device 'br-lan'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'

config interface 'wan'
	option proto 'dhcp'
NET
printf "config zone\n\toption name 'lan'\n\nconfig zone\n\toption name 'wan'\n\nconfig zone\n\toption name 'guestwifi'\n\tlist network 'guestwifi'\n" > /etc/config/firewall
printf "config dnsmasq\n\nconfig dhcp 'lan'\n\toption interface 'lan'\n" > /etc/config/dhcp
cat > /etc/config/wireless <<'WIFI'
config wifi-iface 'default_radio0'
	option mode 'ap'
	option ssid 'Home'
	option network 'lan'

config wifi-iface 'wifinet2'
	option mode 'ap'
	option ssid 'Home Passwall'
	option network 'wgproxy'
	option disabled '1'
WIFI
mkdir -p /var/run
# no Passwall yet (left over from an earlier run)
rm -f /etc/config/passwall /etc/init.d/passwall /etc/wgpasswall/devices-dns.nft
nft delete table inet passwall 2>/dev/null || true

ubusd >"$WORK/ubusd.log" 2>&1 &
PIDS="$PIDS $!"
sleep 1
rpcd >"$WORK/rpcd.log" 2>&1 &
PIDS="$PIDS $!"

for i in 1 2 3 4 5 6 7 8 9 10; do
	ubus list luci.wgpasswall >/dev/null 2>&1 && break
	sleep 1
done

# waits until the firewall reloads / Passwall restarts the app queued are done
wait_queue() {
	for i in $(seq 1 120); do
		pgrep -f '^/bin/sh -c [(]mkdir -p /var/lock; exec 9>' >/dev/null || return 0
		sleep 0.5
	done
	fail "queued firewall reloads / Passwall restarts did not finish"
}

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
[ "$(uci -q get network.wgpasswall_rule_vpn_wgvpn.lookup)" = 51820 ] || fail "routing rule for the VPN network not written"
[ "$(uci -q get network.wgpasswall_rule_vpn_loopback.in)" = loopback ] || fail "routing rule for the router's own traffic not written"
[ "$(uci -q get firewall.wgpasswall_zone.name)" = wgpasswall ] || fail "firewall zone not written"

echo "== the VPN network"
[ "$(uci -q get network.wgpasswall_vpn_dev.name)" = br-wgvpn ] || fail "VPN network bridge not created"
[ "$(uci -q get network.wgvpn.device)" = br-wgvpn ] || fail "VPN network interface not created"
[ "$(uci -q get network.wgvpn.ipaddr)" = 192.168.20.1 ] || fail "VPN network subnet: $(uci -q get network.wgvpn.ipaddr)"
[ "$(uci -q get dhcp.wgvpn.interface)" = wgvpn ] || fail "VPN network has no DHCP"
[ "$(uci -q get firewall.wgpasswall_vpn_zone.name)" = wgvpn ] || fail "VPN network zone not created"
[ "$(uci -q get firewall.wgpasswall_fwd.src)" = wgvpn ] || fail "VPN network cannot reach the tunnel"
uci -q get network.wgproxy >/dev/null && fail "Passwall network created without Passwall"
ubus call luci.wgpasswall status | jq -e '.networks.lan.ports == ["lan1","lan2"] and .networks.lan.ssids == ["Home"] and .networks.vpn.exists and (.networks.proxy.exists | not)' >/dev/null || \
	fail "status networks: $(ubus call luci.wgpasswall status | jq -c .networks)"

echo "== get"
ubus call luci.wgpasswall get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("AllowedIPs = 0.0.0.0/0")' >/dev/null || fail "get"

echo "== wired ports"
ubus call luci.wgpasswall set_ports '{"ports":{"lan1":"vpn"}}' | jq -e '.ports.lan1 == "vpn"' >/dev/null || fail "set_ports"
[ "$(uci -q get network.brlan.ports)" = lan2 ] || fail "port not taken off the LAN"
[ "$(uci -q get network.wgpasswall_vpn_dev.ports)" = lan1 ] || fail "port not on the VPN network"
ubus call luci.wgpasswall set_ports '{"ports":{"lan1":"proxy"}}' | jq -e '.error' >/dev/null || fail "Passwall network without Passwall"
ubus call luci.wgpasswall set_ports '{"ports":{"wan":"vpn"}}' | jq -e '.error' >/dev/null || fail "port outside the networks moved"

echo "== kill switch"
ubus call luci.wgpasswall set_options '{"killswitch":true}' >/dev/null || fail "set_options"
[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 1 ] || fail "kill switch not enabled"
[ "$(uci -q get firewall.wgpasswall_killswitch.src)" = wgvpn ] || fail "kill switch not for the VPN network"
# no VPN connected: the router must not look up names for the VPN network either
grep -q 'iifname "br-wgvpn" .* th dport 53 counter reject' /etc/wgpasswall/devices-dns.nft || \
	{ cat /etc/wgpasswall/devices-dns.nft; fail "VPN network's DNS not refused while the kill switch holds it offline"; }
nft -c -f /etc/wgpasswall/devices-dns.nft || fail "DNS rules do not load"

echo "== Passwall"
# a minimal Passwall install: config, rule lists and an init script stub
cat > /etc/config/passwall <<'PW'

config global
	option enabled '0'
	option node 'hy2node'
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
	# what the app checks to see whether Passwall runs
	nft add table inet passwall
	nft add chain inet passwall PSW_OUTPUT_MANGLE
	echo "restart-end" >> /tmp/order.log
fi
exit 0
PW
cat > /etc/init.d/firewall <<'FW'
#!/bin/sh
echo "firewall-$1" >> /tmp/order.log
FW
cat > /etc/init.d/dnsmasq <<'DM'
#!/bin/sh
DM
chmod +x /etc/init.d/firewall /etc/init.d/dnsmasq
rm -f /tmp/order.log /tmp/passwall-init.log
chmod +x /etc/init.d/passwall
cat > /etc/init.d/wgpasswall <<'WG'
#!/bin/sh
echo "$1" >> /tmp/wgpasswall-init.log
WG
chmod +x /etc/init.d/wgpasswall
rm -f /tmp/wgpasswall-init.log
uci show passwall | sort > "$WORK/passwall.orig"
# Passwall's config as it was (options in any order)
pw_same() {
	uci show passwall | sort | cmp -s - "$WORK/passwall.orig"
}
cp /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig"
cp /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig"

# settings and Passwall rules of earlier versions: the modes, chosen devices
uci set wgpasswall.settings.mode=vpn_passwall; uci set wgpasswall.settings.scope=devices
uci add_list wgpasswall.settings.vpn_device=AA:BB:CC:DD:EE:01; uci set wgpasswall.settings.pw_node=realitynode; uci commit wgpasswall
uci set passwall.0wgpasswall_vpn_devices=acl_rule; uci set passwall.0wgpasswall_vpn_devices.mode=0
uci set passwall.0wgpasswall_direct_guestwifi=acl_rule; uci set passwall.0wgpasswall_direct_guestwifi.interface=guestwifi
uci set passwall.zzz_wgpasswall_lan_lan=acl_rule; uci set passwall.zzz_wgpasswall_lan_lan.interface=lan; uci commit passwall
uci set firewall.wgpasswall_devices=rule; uci set firewall.wgpasswall_devices.target=MARK; uci commit firewall

ubus call luci.wgpasswall status | jq -e '.passwall.installed and (.passwall.needed | not) and .passwall.node.id == "hy2node"' >/dev/null || fail "passwall not detected"
ubus call luci.wgpasswall reapply >/dev/null || fail "reapply after installing Passwall"
wait_queue
[ "$(uci -q get wgpasswall.settings.via_passwall)" = 1 ] || fail "VPN through Passwall mode not migrated"
uci -q get wgpasswall.settings.mode >/dev/null && fail "old mode left behind"
uci -q get wgpasswall.settings.vpn_device >/dev/null && fail "old device list left behind"
uci -q get firewall.wgpasswall_devices >/dev/null && fail "old device mark left behind"
for acl in 0wgpasswall_vpn_devices 0wgpasswall_direct_guestwifi zzz_wgpasswall_lan_lan; do
	uci -q get passwall.$acl >/dev/null && fail "old Passwall rule $acl left behind"
done
pw_same || { uci show passwall | sort | diff "$WORK/passwall.orig" -; fail "Passwall changed while nothing needs it"; }
# restarted once to drop the old rules, and not again
grep -q restart-end /tmp/order.log || fail "Passwall not restarted to drop the old rules"
: > /tmp/order.log
ubus call luci.wgpasswall reapply >/dev/null || fail "reapply again"
wait_queue
grep -q restart-begin /tmp/order.log && fail "Passwall restarted while nothing needs it"

echo "== the Passwall network"
[ "$(uci -q get network.wgproxy.device)" = br-wgproxy ] || fail "Passwall network not created"
[ "$(uci -q get network.wgproxy.ipaddr)" = 192.168.30.1 ] || fail "Passwall network subnet: $(uci -q get network.wgproxy.ipaddr)"
[ "$(uci -q get firewall.wgpasswall_proxy_zone.name)" = wgproxy ] || fail "Passwall network zone not created"
[ "$(uci -q get firewall.wgpasswall_proxy_wan.dest)" = wan ] || fail "Passwall network cannot reach the WAN"
ubus call luci.wgpasswall set_ports '{"ports":{"lan1":"proxy"}}' | jq -e '.ports.lan1 == "proxy"' >/dev/null || fail "set_ports proxy"
[ -z "$(uci -q get network.wgpasswall_vpn_dev.ports)" ] || fail "port still on the VPN network"
[ "$(uci -q get network.wgpasswall_proxy_dev.ports)" = lan1 ] || fail "port not on the Passwall network"
check_pw_network() {
	[ "$(uci -q get passwall.@global[0].enabled)" = 1 ] || fail "passwall not enabled"
	[ "$(uci -q get passwall.@global[0].node)" = hy2node ] || fail "Passwall's node changed"
	[ "$(uci -q get passwall.@global[0].client_proxy)" = 0 ] || fail "Client Proxy on: the LAN and a guest network would go through Passwall"
	[ "$(uci -q get passwall.@global[0].acl_enable)" = 1 ] || fail "access control off, the network's rule would be ignored"
	[ "$(uci -q get passwall.@global[0].tcp_proxy_mode)" = proxy ] || fail "tcp mode not proxy"
	[ "$(uci -q get passwall.@global[0].udp_proxy_mode)" = proxy ] || fail "udp mode not proxy"
	[ "$(uci -q get passwall.0wgpasswall_net_wgproxy.interface)" = wgproxy ] || fail "no Passwall rule for the Passwall network"
	[ "$(uci -q get passwall.0wgpasswall_net_wgproxy.mode)" = 1 ] || fail "Passwall network rule is not Proxy"
	[ "$(uci -q get passwall.0wgpasswall_net_wgproxy.enabled)" = 1 ] || fail "Passwall network rule not enabled"
	[ "$(uci -q get passwall.myacl.remarks)" = "my own rule" ] || fail "the user's own rule changed"
	[ "$(uci -q get passwall.@global_forwarding[0].udp_proxy_drop_ports)" = 443,51820 ] || fail "drop ports changed"
	cmp -s /etc/passwall/rules/proxy_ip "$WORK/proxy_ip.orig" || fail "proxy list modified"
	cmp -s /etc/passwall/rules/direct_ip "$WORK/direct_ip.orig" || fail "direct list modified"
}
check_pw_network
[ "$(uci -q get passwall.@global[0].localhost_proxy)" = 1 ] || fail "router's own traffic not through Passwall while disconnected"
wait_queue
grep -q restart-end /tmp/order.log || fail "Passwall not restarted"
grep -qx enable /tmp/passwall-init.log || fail "Passwall service not enabled"
ubus call luci.wgpasswall status | jq -e '.passwall.needed and .networks.proxy.ports == ["lan1"] and .drift == []' >/dev/null || \
	fail "status Passwall network: $(ubus call luci.wgpasswall status | jq -c '{passwall, drift}')"

echo "== Passwall only restarts when its settings change"
: > /tmp/order.log
ubus call luci.wgpasswall set_options '{"killswitch":true}' >/dev/null || fail "set_options"
wait_queue
grep -q restart-begin /tmp/order.log && fail "Passwall restarted without a change"

echo "== no node in Passwall"
uci delete passwall.@global[0].node; uci commit passwall
ubus call luci.wgpasswall status | jq -e '.drift | index("pw_no_node")' >/dev/null || fail "missing node not reported"
uci set passwall.@global[0].node=hy2node; uci commit passwall

echo "== Wi-Fi on the Passwall network"
uci set wireless.wifinet2.disabled=0; uci commit wireless
ubus call luci.wgpasswall status | jq -e '.networks.proxy.ssids == ["Home Passwall"]' >/dev/null || fail "SSID on the Passwall network not shown"
ubus call luci.wgpasswall set_ports '{"ports":{"lan1":"lan"}}' >/dev/null || fail "set_ports lan"
check_pw_network
uci set wireless.wifinet2.disabled=1; uci commit wireless

echo "== VPN connected directly"
ubus call luci.wgpasswall set_options '{"via_passwall":false}' >/dev/null || fail "via_passwall off"
ubus call luci.wgpasswall set_ports '{"ports":{"lan1":"vpn","lan2":"proxy"}}' >/dev/null || fail "set_ports vpn + proxy"
ubus call luci.wgpasswall connect '{"id":"wgc_civpn"}' >/dev/null || fail "connect"
check_direct_vpn() {
	[ "$(uci -q get network.wgc_civpn.auto)" = 1 ] || fail "profile not connected"
	[ "$(uci -q get network.wgpasswall_rule_vpn_wgvpn.in)" = wgvpn ] || fail "VPN network not routed into the tunnel"
	[ "$(uci -q get network.wgpasswall_rule_vpn_loopback.in)" = loopback ] || fail "router's own traffic not in the tunnel"
	[ "$(uci -q get network.wgpasswall_rule6_vpn_wgvpn.in)" = wgvpn ] || fail "IPv6 VPN rule"
	uci -q get network.wgpasswall_rule_vpn_lan >/dev/null && fail "LAN routed into the tunnel"
	[ "$(uci -q get network.@wireguard_wgc_civpn[0].endpoint_host)" = 1.2.3.4 ] || fail "endpoint not the real server"
	uci show network | grep -q "wgpasswall_orig_host" && fail "relay options left behind"
	uci -q get network.wgc_civpn.mtu >/dev/null && fail "MTU not restored"
	# the tunnel carries the router's own traffic, Passwall only the Passwall network
	[ "$(uci -q get passwall.@global[0].localhost_proxy)" = 0 ] || fail "router's own traffic through Passwall while the tunnel carries it"
	check_pw_network
	# DNS of the VPN network: the VPN's server through the tunnel
	uci -q get network.wgc_civpn.dns >/dev/null && fail "VPN DNS an upstream of the router's resolver"
	[ "$(uci -q get wgpasswall.wgc_civpn.dns)" = 10.2.0.1 ] || fail "VPN DNS not kept"
	[ "$(uci -q get firewall.wgpasswall_devices_dns.path)" = /etc/wgpasswall/devices-dns.nft ] || fail "DNS rules not included in the firewall"
	grep -q 'iifname "br-wgvpn" .* dnat ip to 10.2.0.1:53' /etc/wgpasswall/devices-dns.nft || \
		{ cat /etc/wgpasswall/devices-dns.nft; fail "VPN network's DNS not sent to the VPN's DNS server"; }
	nft -c -f /etc/wgpasswall/devices-dns.nft || fail "DNS rules do not load"
	# the profile only carries IPv4 (0.0.0.0/0)
	[ "$(uci -q get firewall.wgpasswall_no_ipv6.enabled)" = 1 ] || fail "IPv6 not blocked with an IPv4-only VPN"
	[ "$(uci -q get firewall.wgpasswall_no_ipv6.src)" = wgvpn ] || fail "IPv6 block not for the VPN network"
	[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 1 ] || fail "kill switch not active"
}
check_direct_vpn

echo "== VPN through Passwall"
ubus call luci.wgpasswall set_options '{"via_passwall":true}' >/dev/null || fail "via_passwall on"
check_wrapped() {
	uci show network | grep -q "endpoint_host='127.0.0.1'" || fail "endpoint not pointed at the relay"
	uci show network | grep -q "endpoint_port='51821'" || fail "relay port not set"
	uci show network | grep -q "wgpasswall_orig_host='1.2.3.4'" || fail "original endpoint not kept"
	ubus call luci.wgpasswall get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("Endpoint = 1.2.3.4:51820")' >/dev/null || fail "editor does not show the real server"
	ubus call luci.wgpasswall status | jq -e '.profiles[0].endpoint == "1.2.3.4:51820" and .via_passwall' >/dev/null || fail "status does not show the real server"
	[ "$(uci -q get network.wgc_civpn.mtu)" = 1280 ] || fail "MTU not lowered"
	ubus call luci.wgpasswall get '{"id":"wgc_civpn"}' | jq -e '.conf | contains("MTU") | not' >/dev/null || fail "editor shows lowered MTU"
	[ "$(uci -q get network.wgpasswall_rule_vpn_wgvpn.in)" = wgvpn ] || fail "VPN network not routed into the tunnel"
	uci -q get network.wgpasswall_rule_vpn_loopback >/dev/null && fail "router traffic routed into the wrapped tunnel"
	[ "$(uci -q get passwall.@global[0].localhost_proxy)" = 1 ] || fail "router's own traffic (and the relay) not through Passwall"
	[ "$(uci -q get passwall.@global[0].enabled)" = 1 ] || fail "passwall not enabled"
	[ "$(uci -q get passwall.@global[0].client_proxy)" = 0 ] || fail "Client Proxy on"
	[ "$(uci -q get firewall.wgpasswall_killswitch.enabled)" = 1 ] || fail "kill switch not active"
}
check_wrapped
sleep 1; grep -qx restart /tmp/wgpasswall-init.log || fail "relay service not restarted"
echo "-- through Passwall with nothing on the Passwall network"
ubus call luci.wgpasswall set_ports '{"ports":{"lan2":"lan"}}' >/dev/null || fail "set_ports lan"
check_wrapped
uci -q get passwall.0wgpasswall_net_wgproxy >/dev/null && fail "Passwall network rule with nothing on it"
[ "$(uci -q get passwall.@global[0].acl_enable)" = "" ] || fail "access control switched on without rules: $(uci -q get passwall.@global[0].acl_enable)"
ubus call luci.wgpasswall set_ports '{"ports":{"lan2":"proxy"}}' >/dev/null || fail "set_ports proxy again"
check_wrapped
check_pw_network

echo "== reapply after changes elsewhere"
wait_queue
ubus call luci.wgpasswall status | jq -e '.drift == []' >/dev/null || fail "drift reported right after applying: $(ubus call luci.wgpasswall status | jq -c .drift)"
uci set passwall.@global[0].client_proxy=1
uci delete passwall.0wgpasswall_net_wgproxy
uci delete firewall.wgpasswall_vpn_zone
uci commit passwall; uci commit firewall
ubus call luci.wgpasswall status | jq -e '(.drift | index("pw_settings")) and (.drift | index("pw_acl")) and (.drift | index("fw_missing"))' >/dev/null || \
	fail "changes made elsewhere not reported: $(ubus call luci.wgpasswall status | jq -c .drift)"
: > /tmp/order.log
ubus call luci.wgpasswall reapply | jq -e '.result' >/dev/null || fail "reapply"
check_wrapped
check_pw_network
[ "$(uci -q get firewall.wgpasswall_vpn_zone.name)" = wgvpn ] || fail "VPN network zone not back"
ubus call luci.wgpasswall status | jq -e '.drift == []' >/dev/null || fail "drift left after reapply"
wait_queue
grep -q firewall-reload /tmp/order.log && grep -q restart-end /tmp/order.log || fail "reapply did not reload the firewall and restart Passwall"

echo "== nothing needs Passwall: its own settings come back"
ubus call luci.wgpasswall set_ports '{"ports":{"lan2":"lan"}}' >/dev/null || fail "set_ports lan"
ubus call luci.wgpasswall disconnect '{"id":"wgc_civpn"}' >/dev/null || fail "disconnect"
pw_same || { uci show passwall | sort | diff "$WORK/passwall.orig" -; fail "passwall config not restored"; }
# Passwall commands run in the background, queued behind earlier restarts
for i in $(seq 1 30); do grep -qx disable /tmp/passwall-init.log && break; sleep 0.5; done
grep -qx disable /tmp/passwall-init.log || fail "passwall service not disabled again"
wait_queue
: > /tmp/order.log
uci set passwall.@global[0].node=realitynode; uci commit passwall
ubus call luci.wgpasswall reapply >/dev/null || fail "reapply while Passwall is not needed"
[ "$(uci -q get passwall.@global[0].node)" = realitynode ] || fail "reapply changed Passwall while not needed"
ubus call luci.wgpasswall status | jq -e '.drift == []' >/dev/null || fail "Passwall's own settings reported as drift while not needed"
wait_queue
grep -q restart-begin /tmp/order.log && fail "Passwall restarted while not needed"
uci set passwall.@global[0].node=hy2node; uci commit passwall

echo "== firewall reloads and Passwall restarts never overlap"
# quick changes, as when clicking around in the UI
: > /tmp/order.log
ubus call luci.wgpasswall set_ports '{"ports":{"lan2":"proxy"}}' >/dev/null
ubus call luci.wgpasswall connect '{"id":"wgc_civpn"}' >/dev/null
ubus call luci.wgpasswall set_options '{"via_passwall":false}' >/dev/null
ubus call luci.wgpasswall set_ports '{"ports":{"lan2":"lan"}}' >/dev/null
wait_queue
[ "$(grep -c restart-begin /tmp/order.log)" -ge 3 ] || { cat /tmp/order.log; fail "Passwall not restarted for each change"; }
awk '/restart-begin/ { if (busy) { print "restarts overlap at line " NR; bad = 1 } busy = 1 }
     /restart-end/ { busy = 0 }
     /firewall-/ { if (busy) { print "firewall reload during a Passwall restart at line " NR; bad = 1 } }
     END { exit bad }' /tmp/order.log || { cat /tmp/order.log; fail "firewall reloads / Passwall restarts overlapped"; }
grep -q firewall-reload /tmp/order.log || fail "firewall never reloaded"

echo "== uninstall"
ubus call luci.wgpasswall set_ports '{"ports":{"lan1":"vpn","lan2":"proxy"}}' >/dev/null || fail "set_ports"
uci set wireless.wifinet2.disabled=0; uci commit wireless
ubus call luci.wgpasswall uninstall | jq -e '.result' >/dev/null || fail "uninstall"
[ "$(uci -q get network.brlan.ports)" = "lan2 lan1" ] || [ "$(uci -q get network.brlan.ports)" = "lan1 lan2" ] || fail "ports not back on the LAN: $(uci -q get network.brlan.ports)"
[ "$(uci -q get wireless.wifinet2.network)" = lan ] || fail "Wi-Fi not back on the LAN"
for s in network.wgvpn network.wgproxy network.wgpasswall_vpn_dev network.wgpasswall_proxy_dev dhcp.wgvpn dhcp.wgproxy \
	firewall.wgpasswall_vpn_zone firewall.wgpasswall_proxy_zone firewall.wgpasswall_killswitch firewall.wgpasswall_devices_dns; do
	uci -q get $s >/dev/null && fail "$s left behind"
done
[ "$(uci -q get network.wgc_civpn.auto)" = 0 ] || fail "profile still connected"
[ -e /etc/wgpasswall/devices-dns.nft ] && fail "DNS rules file left behind"
pw_same || { uci show passwall | sort | diff "$WORK/passwall.orig" -; fail "passwall config not restored"; }

echo "== remove"
ubus call luci.wgpasswall remove '{"id":"wgc_civpn"}' >/dev/null || fail "remove"
uci -q get network.wgc_civpn >/dev/null && fail "interface not removed"

echo "All integration checks passed"
