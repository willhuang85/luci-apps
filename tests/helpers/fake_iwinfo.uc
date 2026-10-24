// rpcd ucode plugin standing in for rpcd-mod-iwinfo: on a real router the
// "iwinfo" ubus object is served by rpcd itself, so a backend plugin that
// calls it over ubus blocks rpcd (it waits for itself). Loading the fake into
// rpcd, like the real one, makes the integration tests catch that.

'use strict';

const RADIOS = {
	radio0: {
		info: { htmodes: [ 'HT20', 'HT40', 'HE20', 'HE40' ], hardware: { name: 'Fake 2.4 GHz' } },
		freqlist: [ { band: 2, channel: 1, mhz: 2412, restricted: false }, { band: 2, channel: 6, mhz: 2437, restricted: false } ],
		txpowerlist: [ { dbm: 17, mw: 50 }, { dbm: 20, mw: 100 } ],
		scan: [ { ssid: 'CI iPhone', signal: -45, channel: 6, encryption: { enabled: true, wpa: [ 2, 3 ], authentication: [ 'psk', 'sae' ] } } ]
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

const dev_args = { device: '' };

return {
	iwinfo: {
		info: { args: dev_args, call: (req) => dev(req).info ?? {} },
		freqlist: { args: dev_args, call: (req) => ({ results: dev(req).freqlist ?? [] }) },
		txpowerlist: { args: dev_args, call: (req) => ({ results: dev(req).txpowerlist ?? [] }) },
		assoclist: { args: { device: '', mac: '' }, call: (req) => ({ results: dev(req).assoclist ?? [] }) },
		scan: { args: dev_args, call: (req) => ({ results: dev(req).scan ?? [] }) },
		countrylist: { args: dev_args, call: () => ({ results: [ { code: 'DE', iso3166: 'DE', country: 'Germany' }, { code: 'US', iso3166: 'US', country: 'United States' } ] }) }
	}
};
