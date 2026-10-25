// Exercises the rpcd plugin against in-memory uci/ubus mocks.
// Run: ucode -L 'tests/wgpasswall/mocks/*.uc' -L 'luci-app-wireguard-passwall/root/usr/share/ucode/*.uc' tests/wgpasswall/backend_test.uc

'use strict';

import { readfile } from 'fs';

global.__uci_store = {
	network: {
		brlan: { '.type': 'device', '.name': 'brlan', '.index': 998, name: 'br-lan', type: 'bridge', ports: [ 'lan1', 'lan2' ] },
		loopback: { '.type': 'interface', '.name': 'loopback', '.index': 999, proto: 'static', device: 'lo' },
		lan: { '.type': 'interface', '.name': 'lan', '.index': 1000, proto: 'static', device: 'br-lan', ipaddr: '192.168.1.1', netmask: '255.255.255.0' },
		wan: { '.type': 'interface', '.name': 'wan', '.index': 1001, proto: 'dhcp' },
		// a network on the first subnet the VPN network would pick
		other: { '.type': 'interface', '.name': 'other', '.index': 1002, proto: 'static', ipaddr: '192.168.20.1/24' }
	},
	firewall: {
		z1: { '.type': 'zone', '.name': 'z1', '.index': 1003, name: 'lan' },
		z2: { '.type': 'zone', '.name': 'z2', '.index': 1004, name: 'wan' }
	},
	wireless: {
		home: { '.type': 'wifi-iface', '.name': 'home', '.index': 1005, mode: 'ap', ssid: 'Home', network: [ 'lan' ] },
		vpnwifi: { '.type': 'wifi-iface', '.name': 'vpnwifi', '.index': 1006, mode: 'ap', ssid: 'Home VPN', network: [ 'wgvpn' ] },
		off: { '.type': 'wifi-iface', '.name': 'off', '.index': 1007, mode: 'ap', ssid: 'Old', network: [ 'wgvpn' ], disabled: '1' }
	},
	dhcp: {},
	wgpasswall: {
		// settings of an earlier version: the modes and chosen devices
		settings: { '.type': 'settings', '.name': 'settings', '.index': 1008, killswitch: '0', mode: 'vpn_passwall',
			scope: 'devices', vpn_device: [ 'AA:BB:CC:DD:EE:FF' ], pw_node: 'n1' }
	}
};

// left by an earlier version
global.__uci_store.firewall.wgpasswall_devices = { '.type': 'rule', '.name': 'wgpasswall_devices', '.index': 1009, target: 'MARK' };
global.__uci_store.network.wgpasswall_rule_vpn_lan = { '.type': 'rule', '.name': 'wgpasswall_rule_vpn_lan', '.index': 1010, in: 'lan' };

const plugin = loadfile(sourcepath(0, true) + '/../../luci-app-wireguard-passwall/root/usr/share/rpcd/ucode/luci.wgpasswall')();
const m = plugin['luci.wgpasswall'];
const st = global.__uci_store;
const dns_nft = () => readfile(getenv('WGPASSWALL_DNS_NFT')) ?? '';

let failures = 0, total = 0;

function check(name, cond) {
	total++;

	if (!cond) {
		failures++;
		warn(`FAIL: ${name}\n`);
	}
}

function call(method, args) {
	return m[method].call({ args: args ?? {} });
}

const PRIV = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const PUB = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';
const text = `[Interface]\nPrivateKey = ${PRIV}\nAddress = 10.2.0.2/32\nDNS = 10.2.0.1\n\n[Peer]\nPublicKey = ${PUB}\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n`;

let r = call('parse', { conf: text });
check('parse summary', r.full_tunnel && r.endpoint == '1.2.3.4:51820');
check('parse error', call('parse', { conf: 'junk' }).error != null);
check('parse: keepalive missing', r.keepalive_missing == 1);

r = call('save', { label: 'My Home VPN!', conf: text });
check('save ok', r.id == 'wgc_myhomevpn' && !r.error);
check('iface created', st.network.wgc_myhomevpn?.proto == 'wireguard');
check('iface not auto', st.network.wgc_myhomevpn?.auto == '0');
check('peer split routes', join(',', filter(values(st.network), (s) => s['.type'] == 'wireguard_wgc_myhomevpn')[0]?.allowed_ips ?? []) == '0.0.0.0/1,128.0.0.0/1');
check('label stored', st.wgpasswall.wgc_myhomevpn?.label == 'My Home VPN!');

// the modes of earlier versions
check('migrate: VPN through Passwall kept', st.wgpasswall.settings.via_passwall == '1');
check('migrate: old options gone', st.wgpasswall.settings.mode == null && st.wgpasswall.settings.scope == null &&
	st.wgpasswall.settings.vpn_device == null && st.wgpasswall.settings.pw_node == null);
check('migrate: device marking removed', st.firewall.wgpasswall_devices == null);
check('migrate: LAN rule removed', st.network.wgpasswall_rule_vpn_lan == null);
// without Passwall the tunnel goes directly
check('no Passwall: not through Passwall', !call('status').via_passwall);

// the VPN network
check('vpn net: bridge', st.network.wgpasswall_vpn_dev?.['.type'] == 'device' && st.network.wgpasswall_vpn_dev?.name == 'br-wgvpn' &&
	st.network.wgpasswall_vpn_dev?.type == 'bridge' && st.network.wgpasswall_vpn_dev?.bridge_empty == '1');
check('vpn net: interface on a free subnet', st.network.wgvpn?.proto == 'static' && st.network.wgvpn?.device == 'br-wgvpn' &&
	st.network.wgvpn?.ipaddr == '192.168.21.1' && st.network.wgvpn?.netmask == '255.255.255.0');
check('vpn net: dhcp', st.dhcp.wgvpn?.['.type'] == 'dhcp' && st.dhcp.wgvpn?.interface == 'wgvpn');
check('vpn net: zone', st.firewall.wgpasswall_vpn_zone?.name == 'wgvpn' && st.firewall.wgpasswall_vpn_zone?.network?.[0] == 'wgvpn' &&
	st.firewall.wgpasswall_vpn_zone?.input == 'ACCEPT' && st.firewall.wgpasswall_vpn_zone?.forward == 'REJECT');
check('vpn net: into the tunnel', st.firewall.wgpasswall_fwd?.src == 'wgvpn' && st.firewall.wgpasswall_fwd?.dest == 'wgpasswall');
check('vpn net: out directly when not connected', st.firewall.wgpasswall_vpn_wan?.src == 'wgvpn' && st.firewall.wgpasswall_vpn_wan?.dest == 'wan');
check('vpn net: LAN both ways', st.firewall.wgpasswall_vpn_lan?.dest == 'lan' && st.firewall.wgpasswall_lan_vpn?.src == 'lan' &&
	st.firewall.wgpasswall_lan_vpn?.dest == 'wgvpn');
check('no Passwall: no Passwall network', st.network.wgproxy == null && st.network.wgpasswall_proxy_dev == null && st.firewall.wgpasswall_proxy_zone == null);

check('zone created', st.firewall.wgpasswall_zone?.name == 'wgpasswall' && st.firewall.wgpasswall_zone?.network?.[0] == 'wgc_myhomevpn');
check('ks disabled', st.firewall.wgpasswall_killswitch?.enabled == '0');
check('ip4table', st.network.wgc_myhomevpn?.ip4table == '51820' && st.network.wgc_myhomevpn?.ip6table == '51820');
check('wg fwmark', st.network.wgc_myhomevpn?.fwmark == '0xca6c');
check('rule main', st.network.wgpasswall_rule_main?.['.type'] == 'rule' && st.network.wgpasswall_rule_main?.lookup == 'main' &&
	st.network.wgpasswall_rule_main?.suppress_prefixlength == '0' && st.network.wgpasswall_rule_main?.priority == '30100');
check('rule vpn: the VPN network', st.network.wgpasswall_rule_vpn_wgvpn?.mark == '0x0/0xff' && st.network.wgpasswall_rule_vpn_wgvpn?.lookup == '51820' &&
	st.network.wgpasswall_rule_vpn_wgvpn?.priority == '30110' && st.network.wgpasswall_rule_vpn_wgvpn?.in == 'wgvpn');
check('rule vpn: router itself', st.network.wgpasswall_rule_vpn_loopback?.mark == '0x0/0xff' && st.network.wgpasswall_rule_vpn_loopback?.in == 'loopback');
check('rule6', st.network.wgpasswall_rule6_vpn_wgvpn?.['.type'] == 'rule6' && st.network.wgpasswall_rule6_vpn_loopback?.in == 'loopback' &&
	st.network.wgpasswall_rule6_main?.lookup == 'main');

r = call('save', { label: 'My Home VPN', conf: text, connect: true });
check('second id unique', r.id == 'wgc_myhomevpn2');
check('second connected', st.network.wgc_myhomevpn2.auto == '1');
check('ifup called', 'network.interface.up wgc_myhomevpn2' in global.__ubus_calls);

r = call('connect', { id: 'wgc_myhomevpn' });
check('connect exclusive', st.network.wgc_myhomevpn.auto == '1' && st.network.wgc_myhomevpn2.auto == '0');

r = call('get', { id: 'wgc_myhomevpn' });
check('get round-trips full tunnel', index(r.conf, 'AllowedIPs = 0.0.0.0/0') >= 0 && r.label == 'My Home VPN!');

r = call('save', { id: 'wgc_myhomevpn', label: 'Renamed', conf: replace(text, '10.2.0.2/32', '10.9.9.9/32') });
check('edit same id', r.id == 'wgc_myhomevpn' && st.network.wgc_myhomevpn.auto == '1');
check('edit applied', st.network.wgc_myhomevpn.addresses[0] == '10.9.9.9/32');

global.__ifaces = [ { interface: 'wgc_myhomevpn', up: true, uptime: 10 } ];
r = call('status');
check('status profiles', length(r.profiles) == 2 && r.profiles[0].up && !r.profiles[1].up && r.profiles[0].label == 'Renamed');
check('status zones', r.wan_zone_ok);
check('status networks: LAN', join(',', r.networks.lan.ports) == 'lan1,lan2' && join(',', r.networks.lan.ssids) == 'Home' &&
	r.networks.lan.address == '192.168.1.1');
check('status networks: VPN (enabled Wi-Fi only)', r.networks.vpn.exists && length(r.networks.vpn.ports) == 0 &&
	join(',', r.networks.vpn.ssids) == 'Home VPN' && r.networks.vpn.address == '192.168.21.1');
check('status networks: no Passwall network', !r.networks.proxy.exists);
check('status passwall', !r.passwall.installed && !r.passwall.needed);

// wired ports
check('ports: unknown port', call('set_ports', { ports: { lan9: 'vpn' } }).error != null);
check('ports: unknown network', call('set_ports', { ports: { lan1: 'proxy' } }).error != null);
check('ports: nothing moved on error', join(',', st.network.brlan.ports) == 'lan1,lan2');
r = call('set_ports', { ports: { lan2: 'vpn' } });
check('ports: moved', r.result && join(',', st.network.brlan.ports) == 'lan1' && join(',', st.network.wgpasswall_vpn_dev.ports) == 'lan2' &&
	r.ports.lan2 == 'vpn' && r.ports.lan1 == 'lan');
check('ports: status', join(',', call('status').networks.vpn.ports) == 'lan2');
r = call('set_ports', { ports: { lan2: 'lan' } });
check('ports: back', join(',', st.network.brlan.ports) == 'lan1,lan2' && !length(st.network.wgpasswall_vpn_dev.ports));
call('set_ports', { ports: { lan2: 'vpn' } });

// kill switch: the VPN network only reaches the internet through the tunnel
r = call('set_options', { killswitch: true });
check('ks on', r.result && st.firewall.wgpasswall_killswitch.enabled == '1' && st.firewall.wgpasswall_killswitch.src == 'wgvpn' &&
	st.firewall.wgpasswall_killswitch.dest == 'wan' && st.wgpasswall.settings.killswitch == '1');
check('status ks', call('status').killswitch_active);
call('set_options', { killswitch: false });
check('ks off', st.firewall.wgpasswall_killswitch.enabled == '0');
check('via needs Passwall', call('set_options', { via_passwall: true }).error != null);

// DNS of the VPN network: the VPN's DNS server
check('dns: kept off the router resolver', st.network.wgc_myhomevpn.dns == null && join(',', st.wgpasswall.wgc_myhomevpn.dns) == '10.2.0.1');
check('dns: still in the profile', index(call('get', { id: 'wgc_myhomevpn' }).conf, 'DNS = 10.2.0.1') >= 0);
check('dns: status', call('status').vpn_dns?.v4 == '10.2.0.1');
check('dns: include', st.firewall.wgpasswall_devices_dns?.['.type'] == 'include' && st.firewall.wgpasswall_devices_dns?.path == getenv('WGPASSWALL_DNS_NFT'));
check('dns: redirect to VPN DNS', index(dns_nft(), 'iifname "br-wgvpn" meta l4proto { tcp, udp } meta nfproto ipv4 th dport 53 counter dnat ip to 10.2.0.1:53') >= 0);
check('dns: before Passwall', index(dns_nft(), 'priority dstnat - 10;') >= 0);
check('dns: router IPv6 DNS refused', index(dns_nft(), 'meta nfproto ipv6 ct original proto-dst 53 counter reject') >= 0);
check('ipv6: blocked for the VPN network (IPv4-only full tunnel)', st.firewall.wgpasswall_no_ipv6?.enabled == '1' &&
	st.firewall.wgpasswall_no_ipv6?.src == 'wgvpn' && st.firewall.wgpasswall_no_ipv6?.family == 'ipv6' && call('status').ipv6_blocked);
call('disconnect', { id: 'wgc_myhomevpn' });
check('disconnect', st.network.wgc_myhomevpn.auto == '0');
check('ipv6: not blocked while disconnected', st.firewall.wgpasswall_no_ipv6.enabled == '0');
check('dns: no redirect while disconnected', index(dns_nft(), 'dnat') < 0 && index(dns_nft(), 'delete table inet wgpasswall_dns') >= 0);
call('connect', { id: 'wgc_myhomevpn' });
call('save', { id: 'wgc_myhomevpn', label: 'Renamed', conf: replace(text, 'AllowedIPs = 0.0.0.0/0', 'AllowedIPs = 0.0.0.0/0, ::/0') });
check('ipv6: not blocked with ::/0', st.firewall.wgpasswall_no_ipv6.enabled == '0' && !call('status').ipv6_blocked);
call('save', { id: 'wgc_myhomevpn', label: 'Renamed', conf: replace(text, 'DNS = 10.2.0.1\n', '') });
check('dns: removed from the profile by editing', st.wgpasswall.wgc_myhomevpn.dns == null && call('status').vpn_dns == null && index(dns_nft(), 'dnat') < 0);
call('save', { id: 'wgc_myhomevpn', label: 'Renamed', conf: text });

// custom routing settings, invalid values fall back to defaults
st.wgpasswall.settings.route_table = '254';
st.wgpasswall.settings.bypass_mask = '0xff00';
call('connect', { id: 'wgc_myhomevpn' });
check('reserved table rejected', st.network.wgpasswall_rule_vpn_wgvpn.lookup == '51820');
check('custom mask', st.network.wgpasswall_rule_vpn_wgvpn.mark == '0x0/0xff00' && st.network.wgpasswall_rule_vpn_loopback.mark == '0x0/0xff00');
delete st.wgpasswall.settings.route_table;
delete st.wgpasswall.settings.bypass_mask;

r = call('remove', { id: 'wgc_myhomevpn2' });
check('removed', st.network.wgc_myhomevpn2 == null && st.wgpasswall.wgc_myhomevpn2 == null);
check('zone updated', join(',', st.firewall.wgpasswall_zone.network) == 'wgc_myhomevpn');
check('remove bad id', call('remove', { id: 'lan' }).error != null);
check('connect bad id', call('connect', { id: 'wan' }).error != null);
check('save bad label', call('save', { label: '', conf: text }).error != null);

call('remove', { id: 'wgc_myhomevpn' });
check('rules removed with last profile', st.network.wgpasswall_rule_main == null && st.network.wgpasswall_rule_vpn_wgvpn == null &&
	st.network.wgpasswall_rule_vpn_loopback == null);
check('vpn network stays', st.network.wgvpn != null && join(',', st.network.wgpasswall_vpn_dev.ports) == 'lan2');

// a removed network comes back
delete st.firewall.wgpasswall_vpn_zone;
check('drift: network removed', 'fw_missing' in call('status').drift);
call('reapply');
check('reapply: zone back', st.firewall.wgpasswall_vpn_zone?.name == 'wgvpn');

// uninstalling puts everything back on the LAN
r = call('uninstall');
check('uninstall', r.result);
check('uninstall: ports back', join(',', st.network.brlan.ports) == 'lan1,lan2');
check('uninstall: Wi-Fi back', join(',', st.wireless.vpnwifi.network) == 'lan' && join(',', st.wireless.off.network) == 'lan');
check('uninstall: networks gone', st.network.wgvpn == null && st.network.wgpasswall_vpn_dev == null && st.dhcp.wgvpn == null &&
	st.firewall.wgpasswall_vpn_zone == null && st.firewall.wgpasswall_vpn_wan == null && st.firewall.wgpasswall_fwd == null);
check('uninstall: rules gone', st.firewall.wgpasswall_killswitch == null && st.firewall.wgpasswall_no_ipv6 == null &&
	st.firewall.wgpasswall_devices_dns == null);

delete st.firewall.z2;
check('ks needs zones', call('set_options', { killswitch: true }).error != null && st.wgpasswall.settings.killswitch == '0');

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
