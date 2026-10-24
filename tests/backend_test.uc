// Exercises the rpcd plugin against in-memory uci/ubus mocks.
// Run: ucode -L 'tests/mocks/*.uc' -L 'luci-app-wgclient/root/usr/share/ucode/*.uc' tests/backend_test.uc

'use strict';

global.__uci_store = {
	network: {
		lan: { '.type': 'interface', '.name': 'lan', '.index': 1000, proto: 'static' },
		wan: { '.type': 'interface', '.name': 'wan', '.index': 1001, proto: 'dhcp' }
	},
	firewall: {
		z1: { '.type': 'zone', '.name': 'z1', '.index': 1002, name: 'lan' },
		z2: { '.type': 'zone', '.name': 'z2', '.index': 1003, name: 'wan' }
	},
	wgclient: {
		settings: { '.type': 'settings', '.name': 'settings', '.index': 1004, killswitch: '0' }
	}
};

const plugin = loadfile(sourcepath(0, true) + '/../luci-app-wgclient/root/usr/share/rpcd/ucode/luci.wgclient')();
const m = plugin['luci.wgclient'];
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
check('zone created', st.firewall.wgclient_zone?.name == 'wgclient' && st.firewall.wgclient_zone?.network?.[0] == 'wgc_myhomevpn');
check('forwarding', st.firewall.wgclient_fwd?.src == 'lan' && st.firewall.wgclient_fwd?.dest == 'wgclient');
check('ks disabled', st.firewall.wgclient_killswitch?.enabled == '0');
check('label stored', st.wgclient.wgc_myhomevpn?.label == 'My Home VPN!');

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

r = call('set_killswitch', { enabled: true });
check('ks on', r.killswitch && st.firewall.wgclient_killswitch.enabled == '1' && st.wgclient.settings.killswitch == '1');
check('status ks', call('status').killswitch_active);
call('set_killswitch', { enabled: false });
check('ks off', st.firewall.wgclient_killswitch.enabled == '0');

r = call('disconnect', { id: 'wgc_myhomevpn' });
check('disconnect', st.network.wgc_myhomevpn.auto == '0');

r = call('remove', { id: 'wgc_myhomevpn2' });
check('removed', st.network.wgc_myhomevpn2 == null && st.wgclient.wgc_myhomevpn2 == null);
check('zone updated', join(',', st.firewall.wgclient_zone.network) == 'wgc_myhomevpn');
check('remove bad id', call('remove', { id: 'lan' }).error != null);
check('connect bad id', call('connect', { id: 'wan' }).error != null);
check('save bad label', call('save', { label: '', conf: text }).error != null);

delete st.firewall.z2;
check('ks needs zones', call('set_killswitch', { enabled: true }).error != null && st.wgclient.settings.killswitch == '0');

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
