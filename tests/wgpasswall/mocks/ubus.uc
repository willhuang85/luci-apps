// Minimal stand-in for the ucode "ubus" module, used by tests.
'use strict';

global.__ubus_calls ??= [];

export function connect() {
	return {
		call: function(obj, method, args) {
			push(global.__ubus_calls, `${obj}.${method}${args?.interface ? ' ' + args.interface : ''}`);

			if (obj == 'network.interface' && method == 'dump')
				return { interface: global.__ifaces ?? [] };

			return {};
		}
	};
};
