// Exercises the rpcd plugin against in-memory uci/ubus mocks.
// Run: ucode -L 'tests/wgpasswall/mocks/*.uc' -L 'luci-app-wireguard-passwall/root/usr/share/ucode/*.uc' tests/wgpasswall/backend_test.uc

'use strict';

global.__uci_store = {
	network: {
		lan: { '.type': 'interface', '.name': 'lan', '.index': 1000, proto: 'static', device: 'br-lan' },
		wan: { '.type': 'interface', '.name': 'wan', '.index': 1001, proto: 'dhcp' }
	},
	firewall: {
		z1: { '.type': 'zone', '.name': 'z1', '.index': 1002, name: 'lan' },
		z2: { '.type': 'zone', '.name': 'z2', '.index': 1003, name: 'wan' }
	},
	wgpasswall: {
		settings: { '.type': 'settings', '.name': 'settings', '.index': 1004, killswitch: '0' }
	}
};

const plugin = loadfile(sourcepath(0, true) + '/../../luci-app-wireguard-passwall/root/usr/share/rpcd/ucode/luci.wgpasswall')();
const m = plugin['luci.wgpasswall'];
const st = global.__uci_store;

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

r = call('save', { label: 'My Home VPN!', conf: text });
check('save ok', r.id == 'wgc_myhomevpn' && !r.error);
check('iface created', st.network.wgc_myhomevpn?.proto == 'wireguard');
check('iface not auto', st.network.wgc_myhomevpn?.auto == '0');
check('peer split routes', join(',', filter(values(st.network), (s) => s['.type'] == 'wireguard_wgc_myhomevpn')[0]?.allowed_ips ?? []) == '0.0.0.0/1,128.0.0.0/1');
check('zone created', st.firewall.wgpasswall_zone?.name == 'wgpasswall' && st.firewall.wgpasswall_zone?.network?.[0] == 'wgc_myhomevpn');
check('forwarding', st.firewall.wgpasswall_fwd?.src == 'lan' && st.firewall.wgpasswall_fwd?.dest == 'wgpasswall');
check('ks disabled', st.firewall.wgpasswall_killswitch?.enabled == '0');
check('ip4table', st.network.wgc_myhomevpn?.ip4table == '51820' && st.network.wgc_myhomevpn?.ip6table == '51820');
check('wg fwmark', st.network.wgc_myhomevpn?.fwmark == '0xca6c');
check('rule main', st.network.wgpasswall_rule_main?.['.type'] == 'rule' && st.network.wgpasswall_rule_main?.lookup == 'main' &&
	st.network.wgpasswall_rule_main?.suppress_prefixlength == '0' && st.network.wgpasswall_rule_main?.priority == '30100');
check('rule vpn', st.network.wgpasswall_rule_vpn?.mark == '0x0/0xff' && st.network.wgpasswall_rule_vpn?.lookup == '51820' &&
	st.network.wgpasswall_rule_vpn?.priority == '30110');
check('rule6', st.network.wgpasswall_rule6_vpn?.['.type'] == 'rule6' && st.network.wgpasswall_rule6_main?.lookup == 'main');
check('rules after passwall', +st.network.wgpasswall_rule_main.priority > 999);
check('label stored', st.wgpasswall.wgc_myhomevpn?.label == 'My Home VPN!');

r = call('save', { label: 'My Home VPN', conf: text, connect: true });
check('second id unique', r.id == 'wgc_myhomevpn2');
check('second connected', st.network.wgc_myhomevpn2.auto == '1');
check('ifup called', 'network.interface.up wgc_myhomevpn2' in global.__ubus_calls);

r = call('connect', { id: 'wgc_myhomevpn' });
check('connect exclusive', st.network.wgc_myhomevpn.auto == '1' && st.network.wgc_myhomevpn2.auto == '0');

r = call('get', { id: 'wgc_myhomevpn' });
check('get round-trips full tunnel', index(r.conf, 'AllowedIPs = 0.0.0.0/0') >= 0 && r.label == 'My Home VPN!');

// edit keeps auto state and id
r = call('save', { id: 'wgc_myhomevpn', label: 'Renamed', conf: replace(text, '10.2.0.2/32', '10.9.9.9/32') });
check('edit same id', r.id == 'wgc_myhomevpn' && st.network.wgc_myhomevpn.auto == '1');
check('edit applied', st.network.wgc_myhomevpn.addresses[0] == '10.9.9.9/32');
check('edit replaced peers', length(filter(values(st.network), (s) => s['.type'] == 'wireguard_wgc_myhomevpn')) == 1);

global.__ifaces = [ { interface: 'wgc_myhomevpn', up: true, uptime: 10 } ];
r = call('status');
check('status profiles', length(r.profiles) == 2);
check('status up', r.profiles[0].up && !r.profiles[1].up);
check('status label', r.profiles[0].label == 'Renamed');
check('status full tunnel', r.profiles[0].full_tunnel);
check('status zones', r.lan_zone_ok && r.wan_zone_ok);
check('no proxy apps', length(r.proxy_apps) == 0);
st.passwall = { main: { '.type': 'global', '.name': 'main', '.index': 2000 } };
check('passwall detected', call('status').proxy_apps[0] == 'Passwall');

// custom routing settings, invalid values fall back to defaults
st.wgpasswall.settings.route_table = '254';
st.wgpasswall.settings.bypass_mask = '0xff00';
call('connect', { id: 'wgc_myhomevpn' });
check('reserved table rejected', st.network.wgpasswall_rule_vpn.lookup == '51820');
check('custom mask', st.network.wgpasswall_rule_vpn.mark == '0x0/0xff00');
delete st.wgpasswall.settings.route_table;
delete st.wgpasswall.settings.bypass_mask;

r = call('set_killswitch', { enabled: true });
check('ks on', r.killswitch && st.firewall.wgpasswall_killswitch.enabled == '1' && st.wgpasswall.settings.killswitch == '1');
check('status ks', call('status').killswitch_active);
call('set_killswitch', { enabled: false });
check('ks off', st.firewall.wgpasswall_killswitch.enabled == '0');

r = call('disconnect', { id: 'wgc_myhomevpn' });
check('disconnect', st.network.wgc_myhomevpn.auto == '0');

r = call('remove', { id: 'wgc_myhomevpn2' });
check('removed', st.network.wgc_myhomevpn2 == null && st.wgpasswall.wgc_myhomevpn2 == null);
check('zone updated', join(',', st.firewall.wgpasswall_zone.network) == 'wgc_myhomevpn');
check('rules kept', st.network.wgpasswall_rule_vpn != null);
check('remove bad id', call('remove', { id: 'lan' }).error != null);
check('connect bad id', call('connect', { id: 'wan' }).error != null);
check('save bad label', call('save', { label: '', conf: text }).error != null);

// only chosen devices use the VPN
check('devices: bad mac', call('set_devices', { scope: 'devices', devices: [ 'nope' ] }).error != null);
check('devices: none chosen', call('set_devices', { scope: 'devices', devices: [] }).error != null);
check('devices: bad scope', call('set_devices', { scope: 'some' }).error != null);
call('set_killswitch', { enabled: true });
r = call('set_devices', { scope: 'devices', devices: [ 'aa:bb:cc:dd:ee:ff', 'AA:BB:CC:DD:EE:FF', '11:22:33:44:55:66' ] });
check('devices: saved', r.result && join(',', st.wgpasswall.settings.vpn_device) == 'AA:BB:CC:DD:EE:FF,11:22:33:44:55:66');
check('devices: rule by mark', st.network.wgpasswall_rule_vpn?.mark == '0x1000000/0x1000000' && st.network.wgpasswall_rule_vpn?.in == null &&
	st.network.wgpasswall_rule6_vpn?.mark == '0x1000000/0x1000000');
check('devices: mark rule', st.firewall.wgpasswall_devices?.target == 'MARK' && st.firewall.wgpasswall_devices?.set_mark == '0x1000000/0x1000000' &&
	st.firewall.wgpasswall_devices?.src == 'lan' && st.firewall.wgpasswall_devices?.dest == '*' && length(st.firewall.wgpasswall_devices?.src_mac) == 2 && st.firewall.wgpasswall_devices?.family == 'any');
check('devices: kill switch per device', join(',', st.firewall.wgpasswall_killswitch.src_mac ?? []) == 'AA:BB:CC:DD:EE:FF,11:22:33:44:55:66');
check('devices: status', call('status').scope == 'devices');

// DNS of the chosen devices: the VPN's DNS server, not the router's resolver
import { readfile } from 'fs';
const dns_nft = () => readfile(getenv('WGPASSWALL_DNS_NFT')) ?? '';
call('connect', { id: 'wgc_myhomevpn' });
check('dns: kept off the router resolver', st.network.wgc_myhomevpn.dns == null && join(',', st.wgpasswall.wgc_myhomevpn.dns) == '10.2.0.1');
check('dns: still in the profile', index(call('get', { id: 'wgc_myhomevpn' }).conf, 'DNS = 10.2.0.1') >= 0);
check('dns: status', call('status').vpn_dns?.v4 == '10.2.0.1');
check('dns: include', st.firewall.wgpasswall_devices_dns?.['.type'] == 'include' && st.firewall.wgpasswall_devices_dns?.type == 'nftables' &&
	st.firewall.wgpasswall_devices_dns?.path == getenv('WGPASSWALL_DNS_NFT'));
check('dns: redirect to VPN DNS', index(dns_nft(), 'ether saddr { aa:bb:cc:dd:ee:ff, 11:22:33:44:55:66 } meta l4proto { tcp, udp } meta nfproto ipv4 th dport 53 counter dnat ip to 10.2.0.1:53') >= 0);
check('dns: before Passwall', index(dns_nft(), 'priority dstnat - 10;') >= 0);
check('dns: router IPv6 DNS refused', index(dns_nft(), 'meta nfproto ipv6 ct original proto-dst 53 counter reject') >= 0);
call('disconnect', { id: 'wgc_myhomevpn' });
check('dns: no redirect while disconnected', index(dns_nft(), 'dnat') < 0 && index(dns_nft(), 'delete table inet wgpasswall_dns') >= 0);
call('connect', { id: 'wgc_myhomevpn' });
st.wgpasswall.settings.device_mark = '0x4000000';
call('set_devices', { scope: 'devices', devices: st.wgpasswall.settings.vpn_device });
check('devices: custom mark', st.network.wgpasswall_rule_vpn.mark == '0x4000000/0x4000000' && st.firewall.wgpasswall_devices.set_mark == '0x4000000/0x4000000');
delete st.wgpasswall.settings.device_mark;
r = call('set_devices', { scope: 'all', devices: [ '11:22:33:44:55:66' ] });
check('all: rule for all traffic', st.network.wgpasswall_rule_vpn.mark == '0x0/0xff');
check('all: mark rule removed', st.firewall.wgpasswall_devices == null && st.firewall.wgpasswall_killswitch.src_mac == null);
check('all: dns still kept off the router resolver', st.network.wgc_myhomevpn.dns == null && join(',', st.wgpasswall.wgc_myhomevpn.dns) == '10.2.0.1');
check('all: whole LAN gets the VPN DNS', index(dns_nft(), 'iifname { "br-lan" } meta l4proto { tcp, udp } meta nfproto ipv4 th dport 53 counter dnat ip to 10.2.0.1:53') >= 0);
global.__ifaces = [ { interface: 'lan', l3_device: 'br-home' }, { interface: 'wgc_myhomevpn', up: true } ];
call('connect', { id: 'wgc_myhomevpn' });
check('all: LAN device from netifd', index(dns_nft(), 'iifname { "br-home" }') >= 0);
check('off: mode set', call('set_mode', { mode: 'off' }).mode == 'off');
check('off: no dns redirect', index(dns_nft(), 'dnat') < 0);
call('set_mode', { mode: 'vpn', id: 'wgc_myhomevpn' });
check('all: chosen devices kept', join(',', st.wgpasswall.settings.vpn_device) == '11:22:33:44:55:66' && call('status').scope == 'all');
call('set_killswitch', { enabled: false });

call('remove', { id: 'wgc_myhomevpn' });
check('rules removed with last profile', st.network.wgpasswall_rule_main == null && st.network.wgpasswall_rule6_vpn == null);

delete st.firewall.z2;
check('ks needs zones', call('set_killswitch', { enabled: true }).error != null && st.wgpasswall.settings.killswitch == '0');

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
