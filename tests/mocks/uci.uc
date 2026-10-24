// Minimal in-memory stand-in for the ucode "uci" module, used by tests.
'use strict';

let store = global.__uci_store ??= { firewall: {}, network: {}, wgclient: {} };
let counter = 0;

function section(pkg, sid) {
	return store[pkg]?.[sid];
}

const methods = {
	get: function(pkg, sid, opt) {
		const s = section(pkg, sid);

		if (!s)
			return null;

		return (opt == null) ? s['.type'] : s[opt];
	},

	set: function(pkg, sid, a, b) {
		store[pkg] ??= {};

		if (b == null) {
			if (section(pkg, sid))
				store[pkg][sid]['.type'] = a;
			else
				store[pkg][sid] = { '.type': a, '.name': sid, '.index': counter++ };

			return true;
		}

		const s = section(pkg, sid);

		if (!s)
			return false;

		s[a] = b;
		return true;
	},

	delete: function(pkg, sid, opt) {
		if (opt == null)
			delete store[pkg][sid];
		else if (section(pkg, sid))
			delete store[pkg][sid][opt];

		return true;
	},

	get_all: function(pkg, sid) {
		if (sid == null)
			return store[pkg] ? { ...store[pkg] } : null;

		const s = section(pkg, sid);

		return s ? { ...s } : null;
	},

	add: function(pkg, t) {
		const sid = sprintf('cfg%06x', counter);
		store[pkg][sid] = { '.type': t, '.name': sid, '.index': counter++ };
		return sid;
	},

	foreach: function(pkg, t, fn) {
		let list = sort(filter(values(store[pkg] ?? {}), (s) => t == null || s['.type'] == t),
			(a, b) => a['.index'] - b['.index']);

		for (let s in list)
			if (fn({ ...s }) === false)
				break;
	},

	save: function() { return true; },
	commit: function() { return true; }
};

export function cursor() {
	return proto({}, methods);
};
