// Publishes stand-ins for the ubus objects a Wi-Fi router has (iwinfo,
// network.wireless, hostapd.<ifname>) so the integration test can run the
// plugin in a real rpcd without Wi-Fi hardware. Logs calls to $FAKE_LOG.

'use strict';

import * as ubus from 'ubus';
import * as uloop from 'uloop';
import { open } from 'fs';

const log = open(getenv('FAKE_LOG') ?? '/tmp/fake_wifi.log', 'a');

function note(s) {
	log.write(s + '\n');
	log.flush();
}

const RADIOS = {
	radio0: {
		info: { htmodes: [ 'HT20', 'HT40', 'HE20', 'HE40' ], hardware: { name: 'Fake 2.4 GHz' } },
		freqlist: [ { band: 2, channel: 1, mhz: 2412, restricted: false }, { band: 2, channel: 6, mhz: 2437, restricted: false } ],
		txpowerlist: [ { dbm: 17, mw: 50 }, { dbm: 20, mw: 100 } ]
	},
	radio1: {
		info: { htmodes: [ 'HT20', 'HT40', 'VHT20', 'VHT40', 'VHT80', 'HE20', 'HE40', 'HE80' ], hardware: { name: 'Fake 5 GHz' } },
		freqlist: [ { band: 5, channel: 36, mhz: 5180, restricted: false }, { band: 5, channel: 100, mhz: 5500, restricted: false, flags: [ 'RADAR' ] } ],
		txpowerlist: [ { dbm: 23, mw: 199 } ]
	},
	'phy1-ap0': {
		info: { channel: 36, frequency: 5180, txpower: 23, htmode: 'HE80' },
		assoclist: [ { mac: 'AA:BB:CC:DD:EE:01', signal: -50, connected_time: 600, rx: { rate: 1200000, bytes: 1 }, tx: { rate: 960000, bytes: 2 } } ]
	}
};

function dev(req) {
	return RADIOS[req.args.device] ?? {};
}

uloop.init();

const conn = ubus.connect();
const dev_args = { device: '' };

conn.publish('iwinfo', {
	info: { args: dev_args, call: (req) => dev(req).info ?? {} },
	freqlist: { args: dev_args, call: (req) => ({ results: dev(req).freqlist ?? [] }) },
	txpowerlist: { args: dev_args, call: (req) => ({ results: dev(req).txpowerlist ?? [] }) },
	assoclist: { args: { device: '', mac: '' }, call: (req) => ({ results: dev(req).assoclist ?? [] }) },
	countrylist: { args: dev_args, call: () => ({ results: [ { code: 'DE', iso3166: 'DE', country: 'Germany' }, { code: 'US', iso3166: 'US', country: 'United States' } ] }) }
});

conn.publish('network.wireless', {
	status: {
		call: () => ({
			radio0: { up: true, interfaces: [ { section: 'default_radio0', ifname: 'phy0-ap0' } ] },
			radio1: { up: true, interfaces: [ { section: 'default_radio1', ifname: 'phy1-ap0' } ] }
		})
	}
});

conn.publish('hostapd.phy1-ap0', {
	del_client: {
		args: { addr: '', reason: 0, deauth: false, ban_time: 0 },
		call: (req) => { note(`del_client ${req.args.addr}`); return {}; }
	}
});

uloop.run();
