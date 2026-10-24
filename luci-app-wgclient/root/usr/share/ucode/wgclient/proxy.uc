// SPDX-License-Identifier: Apache-2.0
//
// Helpers for detecting whether a WireGuard tunnel is wrapped by a
// transparent proxy. Free of uci/ubus so they can be unit tested anywhere.

'use strict';

/*
 * Looks at /proc/net/nf_conntrack text for the tunnel's connection to its
 * server (ip:port) from its current local port (lport). Returns true if
 * that connection carries the proxy's mark, false if it leaves directly,
 * null if no such connection is listed.
 *
 * Only the connection using the current local port counts: after the
 * tunnel moved to a new port, the old direct connection lingers in the
 * table until it times out.
 */
function wrapped_state(text, ip, port, lport, proxy_mark) {
	for (let line in split(text ?? '', '\n')) {
		if (!match(line, /^ipv4 +[0-9]+ udp /))
			continue;

		const t = match(line, /src=([^ ]+) dst=([^ ]+) sport=([0-9]+) dport=([0-9]+)/);

		if (!t)
			continue;

		const mark = match(line, /mark=([0-9]+)/);

		// opened by us: wrapped if the proxy marked it
		if (t[2] == ip && t[4] == `${port}` && t[3] == `${lport}`)
			return mark != null && +mark[1] == proxy_mark;

		// opened by the server: the proxy treats our packets as replies and
		// never wraps them
		if (t[1] == ip && t[3] == `${port}` && t[4] == `${lport}`)
			return false;
	}

	return null;
}

export { wrapped_state };
