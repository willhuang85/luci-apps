// Minimal stand-in for the ucode "ubus" module, used by tests. Answers
// iwinfo, network.wireless and network.interface calls from global.__wifi.
'use strict';

global.__ubus_calls ??= [];

export function connect() {
	return {
		call: function(obj, method, args) {
			const w = global.__wifi ?? {};

			push(global.__ubus_calls, `${obj}.${method}${args?.device ? ' ' + args.device : ''}${args?.addr ? ' ' + args.addr : ''}`);

			if (obj == 'network.wireless' && method == 'status')
				return w.status ?? {};

			if (obj == 'network.interface' && method == 'dump')
				return { interface: w.ifaces ?? [] };

			if (obj == 'iwinfo') {
				const d = w.devices?.[args?.device] ?? {};

				switch (method) {
				case 'info': return d.info ?? {};
				case 'freqlist': return { results: d.freqlist ?? [] };
				case 'txpowerlist': return { results: d.txpowerlist ?? [] };
				case 'countrylist': return { results: [ { code: 'US', iso3166: 'US', country: 'United States' }, { code: 'DE', iso3166: 'DE', country: 'Germany' } ] };
				case 'assoclist': return { results: d.assoclist ?? [] };
				case 'scan': return { results: d.scan ?? [] };
				}
			}

			return {};
		}
	};
};
