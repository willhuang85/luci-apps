// Exercises the rpcd plugin against in-memory uci/ubus mocks.
// Run: ucode -L 'tests/mocks/*.uc' -L 'luci-app-wifisetup/root/usr/share/ucode/*.uc' tests/backend_test.uc

'use strict';

// A fresh OpenWrt dual band router: radios off, open "OpenWrt" networks.
global.__uci_store = {
	network: {
		lan: { '.type': 'interface', '.name': 'lan', '.index': 1, proto: 'static', ipaddr: '192.168.1.1/24' },
		wan: { '.type': 'interface', '.name': 'wan', '.index': 2, proto: 'dhcp' },
		iot: { '.type': 'interface', '.name': 'iot', '.index': 3, proto: 'static', ipaddr: '192.168.3.1', netmask: '255.255.255.0' }
	},
	firewall: {
		z1: { '.type': 'zone', '.name': 'z1', '.index': 4, name: 'lan' },
		z2: { '.type': 'zone', '.name': 'z2', '.index': 5, name: 'wan' }
	},
	dhcp: {},
	wireless: {
		radio0: { '.type': 'wifi-device', '.name': 'radio0', '.index': 10, type: 'mac80211', band: '2g', channel: '1', htmode: 'HE20', disabled: '1' },
		default_radio0: { '.type': 'wifi-iface', '.name': 'default_radio0', '.index': 11, device: 'radio0', network: 'lan', mode: 'ap', ssid: 'OpenWrt', encryption: 'none' },
		radio1: { '.type': 'wifi-device', '.name': 'radio1', '.index': 12, type: 'mac80211', band: '5g', channel: '36', htmode: 'HE80', disabled: '1' },
		default_radio1: { '.type': 'wifi-iface', '.name': 'default_radio1', '.index': 13, device: 'radio1', network: 'lan', mode: 'ap', ssid: 'OpenWrt', encryption: 'none' },
		radio2: { '.type': 'wifi-device', '.name': 'radio2', '.index': 14, type: 'mac80211', band: '6g', channel: 'auto', htmode: 'HE160' },
		sta: { '.type': 'wifi-iface', '.name': 'sta', '.index': 15, device: 'radio1', network: 'wwan', mode: 'sta', ssid: 'Upstream' }
	},
	wifisetup: {
		settings: { '.type': 'settings', '.name': 'settings', '.index': 20 }
	}
};

global.__wifi = {
	devices: {
		radio0: {
			info: { htmodes: [ 'HT20', 'HT40', 'VHT20', 'VHT40', 'VHT80', 'HE20', 'HE40', 'HE80' ], hardware: { name: 'MediaTek MT7981' } },
			freqlist: [ { band: 2, channel: 1, mhz: 2412 }, { band: 2, channel: 6, mhz: 2437 }, { band: 2, channel: 13, mhz: 2472, restricted: true } ],
			txpowerlist: [ { dbm: 10, mw: 10 }, { dbm: 20, mw: 100 } ]
		},
		radio1: {
			info: { htmodes: [ 'HT20', 'HT40', 'VHT20', 'VHT40', 'VHT80', 'VHT160', 'HE20', 'HE40', 'HE80', 'HE160' ] },
			freqlist: [ { band: 5, channel: 36, mhz: 5180 }, { band: 5, channel: 100, mhz: 5500, flags: [ 'RADAR' ] } ]
		},
		radio2: {
			info: { htmodes: [ 'HT20', 'VHT80', 'HE20', 'HE80', 'HE160', 'EHT320' ] }
		},
		'phy1-ap0': {
			info: { channel: 36, frequency: 5180, txpower: 23, htmode: 'HE80' },
			assoclist: [ { mac: 'aa:bb:cc:dd:ee:01', signal: -55, connected_time: 120, rx: { rate: 866700, bytes: 1000 }, tx: { rate: 650000, bytes: 2000 } } ]
		},
		'phy0-ap1': {
			assoclist: [ { mac: 'aa:bb:cc:dd:ee:02', signal: -70, connected_time: 30 } ]
		}
	}
};

const plugin = loadfile(sourcepath(0, true) + '/../luci-app-wifisetup/root/usr/share/rpcd/ucode/luci.wifisetup')();
const m = plugin['luci.wifisetup'];
const st = global.__uci_store;
const W = st.wireless;

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

// --- get on a fresh router
let r = call('get');
check('three radios', length(r.radios) == 3);
check('radio band labels', r.radios[0].label == '2.4 GHz' && r.radios[1].label == '5 GHz' && r.radios[2].label == '6 GHz');
check('radio disabled', !r.radios[0].enabled && r.radios[2].enabled);
check('channels filtered', length(r.radios[0].channels) == 2 && r.radios[0].channels[1].channel == 6);
check('dfs flagged', r.radios[1].channels[1].dfs && !r.radios[1].channels[0].dfs);
check('2g widths', join(',', map(r.radios[0].widths, (w) => w.htmode)) == 'HE20,HE40');
check('5g widths', join(',', map(r.radios[1].widths, (w) => w.htmode)) == 'HE20,HE40,HE80,HE160');
check('6g widths', join(',', map(r.radios[2].widths, (w) => w.htmode)) == 'HE20,HE80,HE160,EHT320');
check('current width', r.radios[1].width == 80 && r.radios[1].channel == '36' && r.radios[2].channel == 'auto');
check('txpowers', length(r.radios[0].txpowers) == 2 && r.radios[0].txpower == null);
check('main found', r.main.ssid == 'OpenWrt' && r.main.encryption == 'none' && r.main.same_name);
check('station ignored', r.main.ssids.radio1 == 'OpenWrt');
check('no guest', !r.guest.enabled);
check('countries', r.countries[1].code == 'DE');
check('schedule default', !r.schedule.enabled && r.schedule.off == '23:00' && length(r.schedule.days) == 7);

// --- main network
check('short key rejected', call('set_network', { net: 'main', ssid: 'Home', key: 'short', encryption: 'sae-mixed' }).error != null);
check('empty ssid rejected', call('set_network', { net: 'main', ssid: '', key: 'longenough', encryption: 'sae-mixed' }).error != null);
check('long ssid rejected', call('set_network', { net: 'main', ssid: 'abcdefghijklmnopqrstuvwxyz0123456', key: 'longenough', encryption: 'psk2' }).error != null);
check('bad encryption', call('set_network', { net: 'main', ssid: 'Home', key: 'longenough', encryption: 'wep' }).error != null);
check('emoji key rejected', call('set_network', { net: 'main', ssid: 'Home', key: 'pässwörd123', encryption: 'psk2' }).error != null);
check('hex psk accepted', !call('set_network', { net: 'main', ssid: 'Home', key: sprintf('%064d', 7), encryption: 'psk2' }).error);
check('hex sae rejected', call('set_network', { net: 'main', ssid: 'Home', key: sprintf('%064d', 7), encryption: 'sae' }).error != null);

r = call('set_network', { net: 'main', ssid: 'Home', key: 'correct horse', encryption: 'sae-mixed', hidden: false });
check('main saved', r.result && !r.error);
check('main ssid', W.default_radio0.ssid == 'Home' && W.default_radio1.ssid == 'Home');
check('main key', W.default_radio0.key == 'correct horse' && W.default_radio0.encryption == 'sae-mixed');
check('6g main created', W.wifisetup_main_radio2?.device == 'radio2' && W.wifisetup_main_radio2?.network == 'lan' && W.wifisetup_main_radio2?.mode == 'ap');
check('6g forced wpa3', W.wifisetup_main_radio2.encryption == 'sae' && W.wifisetup_main_radio2.key == 'correct horse');
check('station untouched', W.sta.ssid == 'Upstream' && W.sta.encryption == null);

r = call('get');
check('main read back', r.main.ssid == 'Home' && r.main.encryption == 'sae-mixed' && r.main.key == 'correct horse');

r = call('set_network', { net: 'main', ssid: 'Home', key: 'correct horse', encryption: 'sae-mixed', same_name: false,
	ssids: { radio0: 'Home 2G', radio1: 'Home 5G' }, hidden: true });
check('split names', W.default_radio0.ssid == 'Home 2G' && W.default_radio1.ssid == 'Home 5G' && W.wifisetup_main_radio2.ssid == 'Home');
check('hidden', W.default_radio0.hidden == '1');
check('split read back', !call('get').main.same_name);
call('set_network', { net: 'main', ssid: 'Home', key: 'correct horse', encryption: 'sae-mixed' });
check('same name again', W.default_radio0.ssid == 'Home' && W.default_radio0.hidden == null && call('get').main.same_name);

W.default_radio0.ieee80211w = '0';
call('set_network', { net: 'main', ssid: 'Open Cafe', key: '', encryption: 'none' });
check('open network', W.default_radio0.encryption == 'none' && W.default_radio0.key == null);
check('ieee80211w reset on change', W.default_radio0.ieee80211w == null);
check('6g open -> owe', W.wifisetup_main_radio2.encryption == 'owe');
call('set_network', { net: 'main', ssid: 'Home', key: 'correct horse', encryption: 'sae-mixed' });

// --- radios
r = call('set_radio', { id: 'radio1', enabled: true, channel: '100', width: 160, txpower: 0 });
check('radio enabled', !r.error && W.radio1.disabled == null && W.radio1.channel == '100' && W.radio1.htmode == 'HE160');
check('bad channel', call('set_radio', { id: 'radio1', enabled: true, channel: '13', width: 80 }).error != null);
check('restricted channel', call('set_radio', { id: 'radio0', enabled: true, channel: '13', width: 20 }).error != null);
check('bad width', call('set_radio', { id: 'radio0', enabled: true, channel: 'auto', width: 80 }).error != null);
check('bad radio', call('set_radio', { id: 'default_radio0', enabled: true }).error != null);
r = call('set_radio', { id: 'radio0', enabled: true, channel: 'auto', width: 40, txpower: 10 });
check('radio0 set', !r.error && W.radio0.channel == 'auto' && W.radio0.htmode == 'HE40' && W.radio0.txpower == '10');
call('set_radio', { id: 'radio0', enabled: true, channel: 'auto', width: 40, txpower: 0 });
check('txpower max', W.radio0.txpower == null);
call('set_radio', { id: 'radio2', enabled: false });
check('radio off', W.radio2.disabled == '1');

// re-enabling a radio whose main access point is gone copies the settings
delete W.wifisetup_main_radio2;
r = call('set_radio', { id: 'radio2', enabled: true });
check('main recreated', !r.error && W.wifisetup_main_radio2?.ssid == 'Home' && W.wifisetup_main_radio2?.encryption == 'sae' && W.radio2.disabled == null);

r = call('set_region', { country: 'de' });
check('region', !r.error && W.radio0.country == 'DE' && W.radio2.country == 'DE' && call('get').country == 'DE');
check('bad region', call('set_region', { country: 'Germany' }).error != null);

// --- guest network
r = call('set_network', { net: 'guest', enabled: true, ssid: 'Home Guest', key: 'welcome123', encryption: 'sae-mixed', isolate: true, bands: [ 'radio0', 'radio1' ] });
check('guest saved', r.result && !r.error);
check('guest ifaces', W.wifisetup_guest_radio0?.network == 'guestwifi' && W.wifisetup_guest_radio1?.ssid == 'Home Guest' && W.wifisetup_guest_radio0.isolate == '1');
check('guest bands', W.wifisetup_guest_radio0.disabled == null && W.wifisetup_guest_radio2?.disabled == '1');
check('guest 6g wpa3', W.wifisetup_guest_radio2.encryption == 'sae');
check('guest bridge', st.network.wifisetup_guest_dev?.name == 'br-guestwifi' && st.network.wifisetup_guest_dev?.type == 'bridge');
check('guest iface', st.network.guestwifi?.proto == 'static' && st.network.guestwifi?.device == 'br-guestwifi');
check('guest subnet avoids lan and iot', st.network.guestwifi?.ipaddr == '192.168.4.1');
check('guest dhcp', st.dhcp.guestwifi?.interface == 'guestwifi' && st.dhcp.guestwifi?.leasetime == '1h');
check('guest zone', st.firewall.wifisetup_guest_zone?.name == 'guestwifi' && st.firewall.wifisetup_guest_zone?.input == 'REJECT' &&
	st.firewall.wifisetup_guest_zone?.forward == 'REJECT');
check('guest forwarding', st.firewall.wifisetup_guest_fwd?.src == 'guestwifi' && st.firewall.wifisetup_guest_fwd?.dest == 'wan');
check('guest rules', st.firewall.wifisetup_guest_dhcp?.dest_port == '67-68' && st.firewall.wifisetup_guest_dns?.dest_port == '53');
check('main not on guest', W.default_radio0.network == 'lan');

r = call('get');
check('guest read back', r.guest.enabled && r.guest.ssid == 'Home Guest' && r.guest.isolate && r.guest.bands.radio1 && !r.guest.bands.radio2);
check('guest address', r.guest.address == '192.168.4.1');
check('main still main', r.main.ssid == 'Home');

r = call('set_network', { net: 'guest', enabled: false });
check('guest off', W.wifisetup_guest_radio0.disabled == '1' && W.wifisetup_guest_radio1.disabled == '1' && W.wifisetup_guest_radio0.ssid == 'Home Guest');
check('guest off read back', !call('get').guest.enabled && call('get').guest.ssid == 'Home Guest');
call('set_network', { net: 'guest', enabled: true, ssid: 'Home Guest', key: '', encryption: 'none', isolate: false, bands: [] });
check('guest all bands', W.wifisetup_guest_radio2.disabled == null && W.wifisetup_guest_radio0.encryption == 'none' && W.wifisetup_guest_radio0.isolate == null);
check('guest open 6g -> owe', W.wifisetup_guest_radio2.encryption == 'owe');
check('guest bad band', call('set_network', { net: 'guest', enabled: true, ssid: 'G', key: '', encryption: 'none', bands: [ 'lan' ] }).error != null);

// --- status and clients
global.__wifi.status = {
	radio0: { up: true, interfaces: [ { section: 'default_radio0', ifname: 'phy0-ap0' }, { section: 'wifisetup_guest_radio0', ifname: 'phy0-ap1' } ] },
	radio1: { up: true, interfaces: [ { section: 'default_radio1', ifname: 'phy1-ap0' } ] },
	radio2: { up: false, interfaces: [] }
};
r = call('status');
check('status radios', r.radios.radio1.up && r.radios.radio1.channel == 36 && !r.radios.radio2.up);
check('status clients', length(r.clients) == 2);
const c1 = filter(r.clients, (c) => c.mac == 'AA:BB:CC:DD:EE:01')[0];
const c2 = filter(r.clients, (c) => c.mac == 'AA:BB:CC:DD:EE:02')[0];
check('client main', c1?.network == 'main' && c1?.radio == 'radio1' && c1?.rx_rate == 866700 && c1?.ssid == 'Home');
check('client guest', c2?.network == 'guest' && c2?.radio == 'radio0');

// --- kick / block
check('kick', call('kick', { mac: 'aa:bb:cc:dd:ee:01' }).result && 'hostapd.phy1-ap0.del_client aa:bb:cc:dd:ee:01' in global.__ubus_calls);
check('kick unknown', call('kick', { mac: '00:11:22:33:44:55' }).error != null);
check('kick bad mac', call('kick', { mac: 'nope' }).error != null);

r = call('block', { mac: 'aa:bb:cc:dd:ee:02', name: 'Tablet' });
check('block', !r.error && length(call('get').blocked) == 1 && call('get').blocked[0].name == 'Tablet');
check('macfilter main', W.default_radio0.macfilter == 'deny' && W.default_radio1.maclist?.[0] == 'AA:BB:CC:DD:EE:02');
check('macfilter guest', W.wifisetup_guest_radio0.macfilter == 'deny');
check('macfilter not on station', W.sta.macfilter == null);
call('block', { mac: 'AA:BB:CC:DD:EE:02' });
check('block idempotent', length(call('get').blocked) == 1);
check('status blocked flag', filter(call('status').clients, (c) => c.mac == 'AA:BB:CC:DD:EE:02')[0].blocked);

W.default_radio1.macfilter = 'allow';
W.default_radio1.maclist = [ '11:11:11:11:11:11' ];
call('block', { mac: 'aa:bb:cc:dd:ee:03' });
check('allow list kept', W.default_radio1.macfilter == 'allow' && W.default_radio1.maclist[0] == '11:11:11:11:11:11');
check('two blocked', length(W.default_radio0.maclist) == 2);

call('unblock', { mac: 'aa:bb:cc:dd:ee:02' });
call('unblock', { mac: 'aa:bb:cc:dd:ee:03' });
check('unblocked', length(call('get').blocked) == 0 && W.default_radio0.macfilter == null && W.default_radio0.maclist == null);
check('allow list survives unblock', W.default_radio1.macfilter == 'allow');

// --- schedule
check('schedule bad time', call('set_schedule', { enabled: true, off: '25:00', on: '07:00', days: [ 'mon' ] }).error != null);
check('schedule no days', call('set_schedule', { enabled: true, off: '23:00', on: '07:00', days: [] }).error != null);
check('schedule same times', call('set_schedule', { enabled: true, off: '07:00', on: '7:00', days: [ 'mon' ] }).error != null);
r = call('set_schedule', { enabled: true, off: '22:30', on: '6:15', days: [ 'sun', 'mon' ] });
check('schedule saved', !r.error && st.wifisetup.schedule?.enabled == '1' && st.wifisetup.schedule?.on == '06:15');
r = call('get').schedule;
check('schedule read back', r.enabled && r.off == '22:30' && join(',', r.days) == 'mon,sun');

// --- qr code text
r = call('qrcode', { net: 'main' });
check('qr text', r.text == 'WIFI:T:WPA;S:Home;P:correct horse;;');
W.default_radio0.ssid = 'My;Net';
W.default_radio0.key = 'a"b:c\\d';
check('qr escaping', call('qrcode', { net: 'main' }).text == 'WIFI:T:WPA;S:My\\;Net;P:a\\"b\\:c\\\\d;;');
check('qr guest open', call('qrcode', { net: 'guest' }).text == 'WIFI:T:nopass;S:Home Guest;;');

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
