// SPDX-License-Identifier: Apache-2.0
//
// Parser / serializer for wg-quick style WireGuard configuration files,
// including the obfuscation settings of AmneziaWG 2.0 (iface.awg).
// Kept free of uci/ubus dependencies so it can be unit tested on any host.

'use strict';

const KEY_RE = /^[A-Za-z0-9+\/]{42}[AEIMQUYcgkosw480]=$/;

// wg-quick options that have no meaning for an OpenWrt netifd interface.
const IGNORED_IFACE_KEYS = {
	table: 'Table', preup: 'PreUp', postup: 'PostUp', predown: 'PreDown',
	postdown: 'PostDown', saveconfig: 'SaveConfig', fwmark: 'FwMark'
};

// AmneziaWG 2.0 [Interface] settings, in .conf order: lower case key ->
// [ name in the .conf, kind ]. u16: 0..65535; range: a 32-bit number or a
// range "a-b"; text: a packet template such as "<b 0x...><r 16>".
const AWG_KEYS = {
	jc: [ 'Jc', 'u16' ], jmin: [ 'Jmin', 'u16' ], jmax: [ 'Jmax', 'u16' ],
	s1: [ 'S1', 'u16' ], s2: [ 'S2', 'u16' ], s3: [ 'S3', 'u16' ], s4: [ 'S4', 'u16' ],
	h1: [ 'H1', 'range' ], h2: [ 'H2', 'range' ], h3: [ 'H3', 'range' ], h4: [ 'H4', 'range' ],
	i1: [ 'I1', 'text' ], i2: [ 'I2', 'text' ], i3: [ 'I3', 'text' ], i4: [ 'I4', 'text' ], i5: [ 'I5', 'text' ]
};

function valid_awg(kind, val) {
	if (kind == 'u16')
		return match(val, /^[0-9]{1,5}$/) != null && +val <= 65535;

	if (kind == 'range') {
		const m = match(val, /^([0-9]{1,10})(-([0-9]{1,10}))?$/);

		return m != null && +m[1] <= 4294967295 && (m[3] == null || (+m[3] <= 4294967295 && +m[3] >= +m[1]));
	}

	return length(val) > 0 && length(val) <= 8192;
}

// true for a profile with AmneziaWG settings
function is_awg(cfg) {
	return length(keys(cfg?.iface?.awg ?? {})) > 0;
}

function split_list(value) {
	return filter(map(split(value ?? "", /[, \t]+/), (s) => trim(s)), (s) => length(s) > 0);
}

function is_key(value) {
	return type(value) == 'string' && match(value, KEY_RE) != null;
}

function is_ip(value) {
	return type(value) == 'string' && iptoarr(value) != null;
}

function is_cidr(value) {
	const m = match(value, /^([^\/]+)(\/([0-9]+))?$/);

	if (!m)
		return false;

	const addr = iptoarr(m[1]);

	if (!addr)
		return false;

	if (m[3] == null)
		return true;

	const prefix = +m[3];

	return prefix >= 0 && prefix <= ((length(addr) == 4) ? 32 : 128);
}

function parse_endpoint(value) {
	let m, host, port;

	if ((m = match(value, /^\[([^\]]+)\](:([0-9]+))?$/)) != null) {
		host = m[1];
		port = m[3];
	}
	else if (length(split(value, ':')) > 2) {
		// bare IPv6 literal without brackets and therefore without port
		host = value;
	}
	else if ((m = match(value, /^([^:]+)(:([0-9]+))?$/)) != null) {
		host = m[1];
		port = m[3];
	}

	if (!host || !match(host, /^[A-Za-z0-9.:_-]+$/))
		return null;

	port = (port != null) ? +port : 51820;

	if (port < 1 || port > 65535)
		return null;

	return { host, port };
}

/*
 * Full-tunnel configs are stored as two /1 halves instead of 0.0.0.0/0 so the
 * tunnel can never replace a default route, even if its routes end up in the
 * main table (e.g. when edited by hand); more specific routes always win
 * regardless of metrics (same trick as OpenVPN's "def1"). Cryptokey routing
 * is unaffected by the split.
 */
function expand_default_routes(list) {
	let out = [];

	for (let ip in list) {
		if (ip == '0.0.0.0/0')
			push(out, '0.0.0.0/1', '128.0.0.0/1');
		else if (ip == '::/0')
			push(out, '::/1', '8000::/1');
		else
			push(out, ip);
	}

	return out;
}

function collapse_default_routes(list) {
	let out = [];
	let v4 = ('0.0.0.0/1' in list) && ('128.0.0.0/1' in list);
	let v6 = ('::/1' in list) && ('8000::/1' in list);

	for (let ip in list) {
		if (v4 && (ip == '0.0.0.0/1' || ip == '128.0.0.0/1')) {
			if (ip == '0.0.0.0/1')
				push(out, '0.0.0.0/0');
		}
		else if (v6 && (ip == '::/1' || ip == '8000::/1')) {
			if (ip == '::/1')
				push(out, '::/0');
		}
		else {
			push(out, ip);
		}
	}

	return out;
}

function is_full_tunnel(list) {
	list = collapse_default_routes(list ?? []);

	return ('0.0.0.0/0' in list) || ('::/0' in list);
}

/*
 * Parses the text of a .conf file. Returns
 *   { iface: {...}, peers: [...], warnings: [...] }
 * on success or
 *   { error: "message" }
 * on failure.
 */
function parse(text) {
	if (type(text) != 'string' || !length(trim(text)))
		return { error: 'The configuration is empty' };

	if (length(text) > 65536)
		return { error: 'The configuration file is too large' };

	let iface = null, peers = [], warnings = [], section = null, cur = null;
	let lineno = 0;

	for (let line in split(replace(text, /\r/g, ''), '\n')) {
		lineno++;
		line = trim(replace(line, /#.*$/, ''));

		if (!length(line))
			continue;

		let m = match(line, /^\[([A-Za-z]+)\]$/);

		if (m) {
			section = lc(m[1]);

			if (section == 'interface') {
				if (iface)
					return { error: `Line ${lineno}: duplicate [Interface] section` };

				cur = iface = { addresses: [], dns: [], dns_search: [], awg: {} };
			}
			else if (section == 'peer') {
				cur = { allowed_ips: [] };
				push(peers, cur);
			}
			else {
				return { error: `Line ${lineno}: unknown section [${m[1]}]` };
			}

			continue;
		}

		m = match(line, /^([A-Za-z0-9]+)[ \t]*=[ \t]*(.*)$/);

		if (!m)
			return { error: `Line ${lineno}: cannot parse "${line}"` };

		if (!cur)
			return { error: `Line ${lineno}: "${m[1]}" outside of a section` };

		const key = lc(m[1]), val = trim(m[2]);

		if (section == 'interface') {
			switch (key) {
			case 'privatekey':
				if (!is_key(val))
					return { error: `Line ${lineno}: PrivateKey is not a valid WireGuard key` };

				iface.private_key = val;
				break;

			case 'address':
				for (let a in split_list(val)) {
					if (!is_cidr(a))
						return { error: `Line ${lineno}: invalid Address "${a}"` };

					push(iface.addresses, a);
				}
				break;

			case 'dns':
				for (let d in split_list(val)) {
					if (is_ip(d))
						push(iface.dns, d);
					else if (match(d, /^[A-Za-z0-9._-]+$/))
						push(iface.dns_search, d);
					else
						return { error: `Line ${lineno}: invalid DNS entry "${d}"` };
				}
				break;

			case 'mtu':
				if (!match(val, /^[0-9]+$/) || +val < 1280 || +val > 9200)
					return { error: `Line ${lineno}: MTU must be between 1280 and 9200` };

				iface.mtu = +val;
				break;

			case 'listenport':
				if (!match(val, /^[0-9]+$/) || +val < 1 || +val > 65535)
					return { error: `Line ${lineno}: invalid ListenPort` };

				iface.listen_port = +val;
				break;

			default:
				if (AWG_KEYS[key]) {
					if (!valid_awg(AWG_KEYS[key][1], val))
						return { error: `Line ${lineno}: invalid ${AWG_KEYS[key][0]} "${val}"` };

					iface.awg[key] = val;
				}
				else if (IGNORED_IFACE_KEYS[key])
					push(warnings, `${IGNORED_IFACE_KEYS[key]} is not supported on OpenWrt and was ignored`);
				else
					push(warnings, `Unknown option "${m[1]}" was ignored`);
			}
		}
		else {
			switch (key) {
			case 'publickey':
				if (!is_key(val))
					return { error: `Line ${lineno}: PublicKey is not a valid WireGuard key` };

				cur.public_key = val;
				break;

			case 'presharedkey':
				if (!is_key(val))
					return { error: `Line ${lineno}: PresharedKey is not a valid WireGuard key` };

				cur.preshared_key = val;
				break;

			case 'endpoint': {
				const ep = parse_endpoint(val);

				if (!ep)
					return { error: `Line ${lineno}: invalid Endpoint "${val}"` };

				cur.endpoint_host = ep.host;
				cur.endpoint_port = ep.port;
				break;
			}

			case 'allowedips':
				for (let a in split_list(val)) {
					if (!is_cidr(a))
						return { error: `Line ${lineno}: invalid AllowedIPs entry "${a}"` };

					push(cur.allowed_ips, a);
				}
				break;

			case 'persistentkeepalive':
				if (val == 'off')
					break;

				if (!match(val, /^[0-9]+$/) || +val > 65535)
					return { error: `Line ${lineno}: invalid PersistentKeepalive` };

				if (+val > 0)
					cur.persistent_keepalive = +val;
				break;

			default:
				push(warnings, `Unknown peer option "${m[1]}" was ignored`);
			}
		}
	}

	if (!iface)
		return { error: 'Missing [Interface] section' };

	if (!iface.private_key)
		return { error: 'The [Interface] section has no PrivateKey' };

	if (!length(iface.addresses))
		return { error: 'The [Interface] section has no Address' };

	if (!length(peers))
		return { error: 'At least one [Peer] section is required' };

	if (iface.awg.jmin != null && iface.awg.jmax != null && +iface.awg.jmin > +iface.awg.jmax)
		return { error: 'Jmin must not be larger than Jmax' };

	for (let i, p in peers) {
		if (!p.public_key)
			return { error: `[Peer] #${i + 1} has no PublicKey` };

		if (!length(p.allowed_ips))
			push(warnings, `[Peer] #${i + 1} has no AllowedIPs, no traffic will be routed to it`);

		if (!p.endpoint_host)
			push(warnings, `[Peer] #${i + 1} has no Endpoint, the tunnel can only be established by the remote side`);
	}

	return { iface, peers, warnings };
}

// Turns the structure returned by parse() back into wg-quick format.
function serialize(cfg) {
	let out = [ '[Interface]', `PrivateKey = ${cfg.iface.private_key}` ];

	if (length(cfg.iface.addresses))
		push(out, `Address = ${join(', ', cfg.iface.addresses)}`);

	const dns = [ ...(cfg.iface.dns ?? []), ...(cfg.iface.dns_search ?? []) ];

	if (length(dns))
		push(out, `DNS = ${join(', ', dns)}`);

	if (cfg.iface.mtu)
		push(out, `MTU = ${cfg.iface.mtu}`);

	if (cfg.iface.listen_port)
		push(out, `ListenPort = ${cfg.iface.listen_port}`);

	for (let key, k in AWG_KEYS)
		if (cfg.iface.awg?.[key] != null)
			push(out, `${k[0]} = ${cfg.iface.awg[key]}`);

	for (let p in cfg.peers) {
		push(out, '', '[Peer]', `PublicKey = ${p.public_key}`);

		if (p.preshared_key)
			push(out, `PresharedKey = ${p.preshared_key}`);

		if (length(p.allowed_ips))
			push(out, `AllowedIPs = ${join(', ', collapse_default_routes(p.allowed_ips))}`);

		if (p.endpoint_host) {
			const host = (index(p.endpoint_host, ':') >= 0) ? `[${p.endpoint_host}]` : p.endpoint_host;
			push(out, `Endpoint = ${host}:${p.endpoint_port ?? 51820}`);
		}

		if (p.persistent_keepalive)
			push(out, `PersistentKeepalive = ${p.persistent_keepalive}`);
	}

	return join('\n', out) + '\n';
}

export { AWG_KEYS, is_awg, expand_default_routes, collapse_default_routes, is_full_tunnel, parse, serialize };
