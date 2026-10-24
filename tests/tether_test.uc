// Exercises the luci-app-tether rpcd plugin against in-memory uci/ubus mocks
// and a fake /sys tree in $TETHER_SYSFS.
// Run: TETHER_SYSFS=$(mktemp -d) TETHER_USBMUXD=$TETHER_SYSFS/usbmuxd ucode -L 'tests/mocks/*.uc' tests/tether_test.uc

'use strict';

import { mkdir, symlink, writefile } from 'fs';

const SYS = getenv('TETHER_SYSFS');

if (!SYS)
	die('TETHER_SYSFS must point to an empty directory\n');

function mkdirs(path) {
	let cur = '';

	for (let p in split(path, '/')) {
		if (!length(p))
			continue;

		cur += '/' + p;
		mkdir(cur);
	}
}

// a plugged in iPhone: USB device plus ipheth network device eth2
function plug_iphone(carrier) {
	mkdirs(`${SYS}/bus/usb/devices/1-1`);
	writefile(`${SYS}/bus/usb/devices/1-1/idVendor`, '05ac\n');
	writefile(`${SYS}/bus/usb/devices/1-1/product`, 'iPhone\n');
	mkdirs(`${SYS}/bus/usb/drivers/ipheth`);
	mkdirs(`${SYS}/class/net/eth2/device`);
	mkdirs(`${SYS}/class/net/eth2/statistics`);
	symlink('../../../../bus/usb/drivers/ipheth', `${SYS}/class/net/eth2/device/driver`);
	writefile(`${SYS}/class/net/eth2/carrier`, carrier ? '1\n' : '0\n');
	writefile(`${SYS}/class/net/eth2/statistics/rx_bytes`, '1048576\n');
	writefile(`${SYS}/class/net/eth2/statistics/tx_bytes`, '2048\n');
	mkdirs(`${SYS}/module/ipheth`);
}

mkdirs(`${SYS}/class/net/eth0/device`);
mkdirs(`${SYS}/bus/usb/devices`);

global.__uci_store = {
	network: {
		lan: { '.type': 'interface', '.name': 'lan', '.index': 1, proto: 'static' },
		wan: { '.type': 'interface', '.name': 'wan', '.index': 2, proto: 'dhcp', device: 'eth0' },
		wan6: { '.type': 'interface', '.name': 'wan6', '.index': 3, proto: 'dhcpv6', device: '@wan' },
		backup: { '.type': 'interface', '.name': 'backup', '.index': 4, proto: 'dhcp', metric: '20' }
	},
	firewall: {
		z1: { '.type': 'zone', '.name': 'z1', '.index': 5, name: 'lan', network: [ 'lan' ] },
		z2: { '.type': 'zone', '.name': 'z2', '.index': 6, name: 'wan', network: [ 'wan', 'wan6', 'backup' ] }
	},
	wireless: {
		radio0: { '.type': 'wifi-device', '.name': 'radio0', '.index': 7, band: '2g' },
		radio1: { '.type': 'wifi-device', '.name': 'radio1', '.index': 8, band: '5g' },
		radio2: { '.type': 'wifi-device', '.name': 'radio2', '.index': 9, band: '6g', disabled: '1' },
		home: { '.type': 'wifi-iface', '.name': 'home', '.index': 11, device: 'radio1', mode: 'ap', ssid: 'Cafe' }
	},
	tether: {
		settings: { '.type': 'settings', '.name': 'settings', '.index': 10, active: '0', method: 'usb' }
	}
};

global.__wifi = {
	ifaces: [
		{ interface: 'wan', up: true, l3_device: 'eth0', 'ipv4-address': [ { address: '203.0.113.7', mask: 24 } ],
			route: [ { target: '0.0.0.0', mask: 0, nexthop: '203.0.113.1' } ] },
		{ interface: 'wan6', up: true }
	],
	devices: {
		radio0: { scan: [
			{ ssid: 'Neighbour', signal: -80, channel: 1, encryption: { enabled: true, wpa: [ 2 ], authentication: [ 'psk' ] } },
			{ ssid: 'Will’s iPhone', signal: -40, channel: 6, encryption: { enabled: true, wpa: [ 2, 3 ], authentication: [ 'psk', 'sae' ] } }
		] },
		radio1: { scan: [
			{ ssid: 'Will’s iPhone', signal: -55, channel: 149, encryption: { enabled: true, wpa: [ 2, 3 ], authentication: [ 'psk', 'sae' ] } },
			{ ssid: 'Cafe', signal: -70, channel: 36, encryption: { enabled: false } },
			{ ssid: '', signal: -60, channel: 40 }
		] }
	}
};

const plugin = loadfile(sourcepath(0, true) + '/../luci-app-tether/root/usr/share/rpcd/ucode/luci.tether')();
const m = plugin['luci.tether'];
const st = global.__uci_store;
const N = st.network;

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

// --- nothing plugged in
let r = call('status');
check('inactive', !r.active && r.method == 'usb');
check('no iphone', r.usb.iphone == null && r.usb.netdev == null && !r.usb.carrier);
check('usb support missing', !r.usb.supported && !r.usb.driver);
check('main interfaces', join(',', map(r.main, (i) => i.interface)) == 'wan,wan6,backup');
check('main state', r.main[0].up && r.main[0].address == '203.0.113.7' && r.main[0].gateway == '203.0.113.1' && r.main[1].ipv6_only);
check('wifi not configured', !r.wifi.configured && !r.wifi.connected);
check('radios', length(r.radios) == 3 && r.radios[1].label == '5 GHz' && !r.radios[2].enabled);
check('usb start needs support', index(call('start', { method: 'usb' }).error ?? '', 'not installed') >= 0);
check('wifi start needs hotspot', call('start', { method: 'wifi' }).error != null);
check('bad method', call('start', { method: 'carrier pigeon' }).error != null);
check('nothing changed yet', N.tether_usb == null && N.wan.metric == null);

// --- iPhone over USB
plug_iphone(true);
r = call('status');
check('iphone seen', r.usb.iphone?.name == 'iPhone' && r.usb.netdev == 'eth2' && r.usb.carrier && r.usb.driver);

check('usb needs usbmuxd', index(call('start', { method: 'usb' }).error ?? '', 'usbmuxd') >= 0);
writefile(getenv('TETHER_USBMUXD'), '');
check('usb supported', call('status').usb.supported);

// --- Wi-Fi hotspot
r = call('scan');
check('scan dedupes bands', length(filter(r.results, (n) => n.ssid == 'Will’s iPhone')) == 1);
check('scan iphone first', r.results[0].ssid == 'Will’s iPhone' && r.results[0].iphone && r.results[0].radio == 'radio0');
check('scan encryption', r.results[0].encryption == 'sae-mixed' && filter(r.results, (n) => n.ssid == 'Neighbour')[0].encryption == 'psk2');
check('scan skips own network', length(filter(r.results, (n) => n.ssid == 'Cafe')) == 0);
check('scan skips hidden', length(filter(r.results, (n) => n.ssid == '')) == 0);

check('short password', call('set_wifi', { ssid: 'Will’s iPhone', key: 'abc', encryption: 'sae-mixed', radio: 'radio0' }).error != null);
check('bad radio', call('set_wifi', { ssid: 'Will’s iPhone', key: 'abcdefgh', encryption: 'sae-mixed', radio: 'lan' }).error != null);
check('bad encryption', call('set_wifi', { ssid: 'X', key: 'abcdefgh', encryption: 'wep', radio: 'radio0' }).error != null);
r = call('set_wifi', { ssid: 'Will’s iPhone', key: 'hotspot-pass', encryption: 'sae-mixed', radio: 'radio0' });
check('wifi saved', r.result && !r.error);
const W = st.wireless;
check('sta section', W.tether_sta?.mode == 'sta' && W.tether_sta?.device == 'radio0' && W.tether_sta?.network == 'tether_wifi' &&
	W.tether_sta?.key == 'hotspot-pass' && W.tether_sta?.disabled == '1');
check('interfaces created', N.tether_wifi?.proto == 'dhcp' && N.tether_wifi?.auto == '0' && N.tether_usb?.device == 'eth2');
check('in wan zone', join(',', st.firewall.z2.network) == 'wan,wan6,backup,tether_usb,tether_wifi');
check('main untouched by setup', N.wan.metric == null);
r = call('status');
check('wifi configured', r.wifi.configured && r.wifi.ssid == 'Will’s iPhone' && r.wifi.band_label == '2.4 GHz' && !r.wifi.connected);

r = call('start', { method: 'wifi' });
check('wifi started', r.result && r.method == 'wifi');
check('sta enabled', W.tether_sta.disabled == null && N.tether_wifi.auto == '1' && N.tether_usb.auto == '0');
check('wan deprioritised', N.wan.metric == '1000' && N.backup.metric == '1020');
check('wan6 paused', N.wan6.auto == '0');
check('active', st.tether.settings.active == '1' && st.tether.settings.method == 'wifi');
check('state saved', join(',', st.tether.settings.saved) == 'wan|metric|-,wan6|auto|-,backup|metric|20');
check('zone not duplicated', length(st.firewall.z2.network) == 5);

// starting again (or switching method) must not stack the penalty
call('start', { method: 'wifi' });
check('no double penalty', N.wan.metric == '1000' && join(',', st.tether.settings.saved) == 'wan|metric|-,wan6|auto|-,backup|metric|20');

global.__wifi.status = { radio0: { up: true, interfaces: [ { section: 'tether_sta', ifname: 'phy0-sta0' } ] } };
global.__wifi.devices['phy0-sta0'] = { info: { bssid: '6A:1B:2C:3D:4E:5F', signal: -42, channel: 6 } };
push(global.__wifi.ifaces, { interface: 'tether_wifi', up: true, uptime: 300, l3_device: 'phy0-sta0', 'ipv4-address': [ { address: '172.20.10.2' } ] });
r = call('status');
check('wifi connected', r.active && r.method == 'wifi' && r.wifi.connected && r.wifi.signal == -42 && r.wifi.address == '172.20.10.2' && r.wifi.uptime == 300);

// band switched off
W.radio1.disabled = '1';
W.tether_sta.device = 'radio1';
check('disabled band refused', index(call('start', { method: 'wifi' }).error ?? '', '5 GHz') >= 0);
W.tether_sta.device = 'radio0';
delete W.radio1.disabled;

// --- back to the main internet
r = call('stop');
check('stopped', r.result && st.tether.settings.active == '0');
check('wan restored', N.wan.metric == null && N.backup.metric == '20' && N.wan6.auto == null);
check('saved cleared', st.tether.settings.saved == null);
check('tether off', N.tether_wifi.auto == '0' && N.tether_usb.auto == '0' && W.tether_sta.disabled == '1');
check('settings kept', W.tether_sta.ssid == 'Will’s iPhone');

// user had wan6 off already: it must stay off afterwards
N.wan6.auto = '0';
call('start', { method: 'wifi' });
call('stop');
check('manual auto kept', N.wan6.auto == '0');
delete N.wan6.auto;

// --- USB
r = call('start', { method: 'usb' });
check('usb started', r.result && r.method == 'usb' && N.tether_usb.auto == '1' && N.tether_wifi.auto == '0' && W.tether_sta.disabled == '1');
check('usb deprioritises', N.wan.metric == '1000');
push(global.__wifi.ifaces, { interface: 'tether_usb', up: true, uptime: 60, l3_device: 'eth2', 'ipv4-address': [ { address: '172.20.10.4' } ] });
r = call('status');
check('usb status', r.usb.up && r.usb.address == '172.20.10.4' && r.usb.rx_bytes == 1048576 && r.usb.tx_bytes == 2048);
r = call('start', { method: 'wifi' });
check('switch to wifi', r.result && N.tether_usb.auto == '0' && N.tether_wifi.auto == '1' && W.tether_sta.disabled == null && N.wan.metric == '1000');
call('stop');
check('restored after switch', N.wan.metric == null && N.wan6.auto == null);

check('stop when inactive is harmless', call('stop').result && N.wan.metric == null);

// --- main internet check (no ping target reachable from the test box)
st.tether.settings.check_host = '1.1.1.1; reboot';
check('check host validated', call('check_main').error != null);
delete st.tether.settings.check_host;
global.__wifi.ifaces[0].up = false;
r = call('check_main');
check('check main down', !r.ok && r.reason == 'down');

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
