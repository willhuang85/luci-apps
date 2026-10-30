// Exercises the luci-app-tether rpcd plugin against in-memory uci/ubus mocks
// and a fake /sys tree in $TETHER_SYSFS.
// Run: TETHER_SYSFS=$(mktemp -d) TETHER_USBMUXD=$TETHER_SYSFS/usbmuxd ucode -L 'tests/mocks/*.uc' tests/tether_test.uc

'use strict';

import { mkdir, symlink, unlink, writefile } from 'fs';

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

// A phone on USB, laid out like the kernel does: the USB device (vendor,
// product) with an interface directory whose driver is the tethering
// driver, and a network device whose "device" link points at that interface.
function plug(usb, vendor, product, driver, netdev, carrier) {
	const intf = `${SYS}/bus/usb/devices/${usb}/${usb}:1.0`;

	mkdirs(intf);
	mkdirs(`${SYS}/bus/usb/drivers/${driver}`);
	mkdirs(`${SYS}/module/${driver}`);
	writefile(`${SYS}/bus/usb/devices/${usb}/idVendor`, vendor + '\n');
	writefile(`${SYS}/bus/usb/devices/${usb}/product`, product + '\n');

	if (!netdev)
		return;

	symlink(`../../../drivers/${driver}`, `${intf}/driver`);
	mkdirs(`${SYS}/class/net/${netdev}/statistics`);
	symlink(`../../../bus/usb/devices/${usb}/${usb}:1.0`, `${SYS}/class/net/${netdev}/device`);
	writefile(`${SYS}/class/net/${netdev}/carrier`, carrier ? '1\n' : '0\n');
	writefile(`${SYS}/class/net/${netdev}/statistics/rx_bytes`, '1048576\n');
	writefile(`${SYS}/class/net/${netdev}/statistics/tx_bytes`, '2048\n');
}

function unplug_netdev(netdev) {
	unlink(`${SYS}/class/net/${netdev}/device`);
}

function plug_iphone(carrier) {
	plug('1-1', '05ac', 'iPhone', 'ipheth', 'eth2', carrier);
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
check('no phone', r.usb.phone == null && r.usb.netdev == null && !r.usb.carrier);
check('usb support missing', !r.usb.supported && !r.usb.iphone_support && !r.usb.android_support);
check('main interfaces', join(',', map(r.main, (i) => i.interface)) == 'wan,wan6,backup');
check('main state', r.main[0].up && r.main[0].address == '203.0.113.7' && r.main[0].gateway == '203.0.113.1' && r.main[1].ipv6_only);
check('wifi not configured', !r.wifi.configured && r.wifi.sta_ifname == null);
check('own networks listed for the search', join(',', r.own_ssids) == 'Cafe');
check('radios', length(r.radios) == 3 && r.radios[1].label == '5 GHz' && !r.radios[2].enabled);
check('usb start needs support', index(call('start', { method: 'usb' }).error ?? '', 'not installed') >= 0);
check('wifi start needs hotspot', call('start', { method: 'wifi' }).error != null);
check('bad method', call('start', { method: 'carrier pigeon' }).error != null);
check('nothing changed yet', N.tether_usb == null && N.wan.metric == null);

// --- iPhone over USB
plug_iphone(true);
r = call('status');
check('iphone seen', r.usb.phone?.name == 'iPhone' && r.usb.phone?.kind == 'iphone' && r.usb.netdev == 'eth2' && r.usb.carrier && !r.usb.iphone_support);

check('usb needs usbmuxd', index(call('start', { method: 'usb' }).error ?? '', 'usbmuxd') >= 0);
writefile(getenv('TETHER_USBMUXD'), '');
check('usb supported', call('status').usb.supported);

// --- Wi-Fi hotspot
// the hotspot search itself runs in the browser (iwinfo scan)
check('no backend scan', m.scan == null);

check('control characters', call('set_wifi', { ssid: 'a\nb', key: 'abcdefgh', encryption: 'sae-mixed', radio: 'radio0' }).error != null);
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
check('wifi configured', r.wifi.configured && r.wifi.ssid == 'Will’s iPhone' && r.wifi.band_label == '2.4 GHz' && r.wifi.sta_ifname == null);
// the password stays on the router; an empty one keeps it for the same hotspot
check('status has no password', r.wifi.key == null && r.wifi.has_key);
check('empty password keeps it', call('set_wifi', { ssid: 'Will’s iPhone', key: '', encryption: 'sae-mixed', radio: 'radio0' }).result &&
	W.tether_sta.key == 'hotspot-pass');
check('other hotspot needs one', call('set_wifi', { ssid: 'Other', key: '', encryption: 'sae-mixed', radio: 'radio0' }).error != null &&
	W.tether_sta.ssid == 'Will’s iPhone');

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
check('wifi up', r.active && r.method == 'wifi' && r.wifi.sta_ifname == 'phy0-sta0' && r.wifi.address == '172.20.10.2' && r.wifi.uptime == 300);

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

// --- Android phone over USB (Pixel 9: NCM)
unplug_netdev('eth2');
writefile(`${SYS}/bus/usb/devices/1-1/idVendor`, '0000\n');	// iPhone gone
plug('2-1', '18d1', 'Pixel 9', 'cdc_ncm', null);			// plugged in, USB tethering still off
r = call('status');
check('pixel recognised before tethering', r.usb.phone?.name == 'Pixel 9' && r.usb.phone?.kind == 'android' && r.usb.netdev == null && !r.usb.carrier);
check('android support', r.usb.android_support && r.usb.supported);
plug('2-1', '18d1', 'Pixel 9', 'cdc_ncm', 'usb0', true);		// USB tethering switched on
r = call('status');
check('pixel tethering link', r.usb.netdev == 'usb0' && r.usb.carrier && r.usb.phone?.name == 'Pixel 9' && r.usb.phone?.kind == 'android');
r = call('start', { method: 'usb' });
check('pixel start', r.result && N.tether_usb.device == 'usb0' && N.tether_usb.auto == '1');
call('stop');

// an iPhone wins when both are plugged in
symlink('../../../bus/usb/devices/1-1/1-1:1.0', `${SYS}/class/net/eth2/device`);
check('iphone preferred', call('status').usb.netdev == 'eth2');
unplug_netdev('eth2');

// older Androids use RNDIS; unknown makers still work once tethering is on
unplug_netdev('usb0');
plug('3-1', 'abcd', 'Phone X', 'rndis_host', 'usb1', true);
r = call('status');
check('rndis phone', r.usb.netdev == 'usb1' && r.usb.phone?.name == 'Phone X' && r.usb.phone?.kind == 'android');
unplug_netdev('usb1');

// a USB network adapter with another driver is not a phone
plug('4-1', '0bda', 'USB Ethernet', 'r8152', 'eth3', true);
check('other usb nic ignored', call('status').usb.netdev == null);

check('stop when inactive is harmless', call('stop').result && N.wan.metric == null);

// --- main internet check (no ping target reachable from the test box)
st.tether.settings.check_host = '1.1.1.1; reboot';
check('check host validated', call('check_main').error != null);
st.tether.settings.check_host = '-f';
check('check host is never a ping option', call('check_main').error != null);
delete st.tether.settings.check_host;
global.__wifi.ifaces[0].up = false;
r = call('check_main');
check('check main down', !r.ok && r.reason == 'down');

// rpcd serves iwinfo itself: calling it from the plugin would block rpcd
check('never calls iwinfo', !length(filter(global.__ubus_calls, (c) => index(c, 'iwinfo.') == 0)));

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
