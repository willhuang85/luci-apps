// Unit tests for wgclient/conf.uc
// Run: ucode -L luci-app-wgclient/root/usr/share/ucode tests/conf_test.uc

'use strict';

import * as conf from 'wgclient.conf';
import { wrapped_state } from 'wgclient.proxy';

let failures = 0, total = 0;

function check(name, cond) {
	total++;

	if (!cond) {
		failures++;
		warn(`FAIL: ${name}\n`);
	}
}

const PRIV = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const PUB = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';
const PSK = 'HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=';

const sample = `
# Exported from provider
[Interface]
PrivateKey = ${PRIV}
Address = 10.2.0.2/32, fd00::2/128
DNS = 10.2.0.1, vpn.example
MTU = 1420
PostUp = iptables -A FORWARD -j ACCEPT

[Peer]
PublicKey = ${PUB}
PresharedKey = ${PSK}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
`;

let r = conf.parse(sample);
check('sample parses', r.error == null);
check('private key', r.iface?.private_key == PRIV);
check('addresses', length(r.iface?.addresses) == 2);
check('dns server', r.iface?.dns?.[0] == '10.2.0.1');
check('dns search', r.iface?.dns_search?.[0] == 'vpn.example');
check('mtu', r.iface?.mtu == 1420);
check('PostUp warning', length(r.warnings) == 1);
check('peer pubkey', r.peers?.[0]?.public_key == PUB);
check('peer psk', r.peers?.[0]?.preshared_key == PSK);
check('endpoint host', r.peers?.[0]?.endpoint_host == 'vpn.example.com');
check('endpoint port', r.peers?.[0]?.endpoint_port == 51820);
check('keepalive', r.peers?.[0]?.persistent_keepalive == 25);
check('full tunnel', conf.is_full_tunnel(r.peers[0].allowed_ips));

// round trip
let r2 = conf.parse(conf.serialize(r));
check('round trip', r2.error == null && sprintf('%J', r2.peers) == sprintf('%J', r.peers) &&
	sprintf('%J', r2.iface) == sprintf('%J', r.iface));

// default route expansion
let ex = conf.expand_default_routes([ '0.0.0.0/0', '::/0', '10.0.0.0/8' ]);
check('expand', join(',', ex) == '0.0.0.0/1,128.0.0.0/1,::/1,8000::/1,10.0.0.0/8');
check('collapse', join(',', conf.collapse_default_routes(ex)) == '0.0.0.0/0,::/0,10.0.0.0/8');
check('split tunnel', !conf.is_full_tunnel([ '10.0.0.0/8' ]));
check('expanded is full', conf.is_full_tunnel(ex));

// endpoints
const ep = (e) => conf.parse(`[Interface]\nPrivateKey=${PRIV}\nAddress=10.0.0.2/24\n[Peer]\nPublicKey=${PUB}\nAllowedIPs=10.0.0.0/24\nEndpoint=${e}\n`);
check('ipv6 endpoint', ep('[2001:db8::1]:1234').peers?.[0]?.endpoint_host == '2001:db8::1');
check('ipv6 endpoint port', ep('[2001:db8::1]:1234').peers?.[0]?.endpoint_port == 1234);
check('endpoint no port', ep('1.2.3.4').peers?.[0]?.endpoint_port == 51820);
check('bad endpoint port', ep('1.2.3.4:99999').error != null);
check('bad endpoint host', ep('a b:1').error != null);
check('ipv6 serialize', index(conf.serialize(ep('[2001:db8::1]:1234')), 'Endpoint = [2001:db8::1]:1234') >= 0);
check('crlf', conf.parse(replace(sample, /\n/g, '\r\n')).error == null);
check('case insensitive keys', conf.parse(replace(replace(sample, 'PrivateKey', 'privatekey'), '[Peer]', '[peer]')).error == null);

// errors
check('empty', conf.parse('').error != null);
check('no iface', conf.parse(`[Peer]\nPublicKey=${PUB}\n`).error != null);
check('bad key', conf.parse(`[Interface]\nPrivateKey=abc\n`).error != null);
check('no peer', conf.parse(`[Interface]\nPrivateKey=${PRIV}\nAddress=10.0.0.2/32\n`).error != null);
check('no address', conf.parse(`[Interface]\nPrivateKey=${PRIV}\n[Peer]\nPublicKey=${PUB}\n`).error != null);
check('bad cidr', ep('1.2.3.4').error == null && conf.parse(`[Interface]\nPrivateKey=${PRIV}\nAddress=10.0.0.2/33\n[Peer]\nPublicKey=${PUB}\n`).error != null);
check('garbage line', conf.parse(`[Interface]\nfoo bar\n`).error != null);
check('unknown section', conf.parse(`[Foo]\n`).error != null);

// wrapped detection from conntrack
const MARK = 1347639089;
const stale = 'ipv4     2 udp      17 179 src=47.189.48.153 dst=192.168.42.174 sport=51820 dport=55743 packets=3285 bytes=1934280 src=192.168.42.174 dst=47.189.48.153 sport=55743 dport=51820 packets=2987 bytes=1232344 [ASSURED] mark=0 zone=0 use=2';
const fresh = 'ipv4     2 udp      17 175 src=192.168.42.174 dst=47.189.48.153 sport=40001 dport=51820 packets=12 bytes=2000 src=47.189.48.153 dst=192.168.42.174 sport=51820 dport=40001 packets=10 bytes=1500 [ASSURED] mark=1347639089 zone=0 use=2';
const direct = replace(fresh, 'mark=1347639089', 'mark=0');
check('stale entry ignored', wrapped_state(stale + '\n' + fresh, '47.189.48.153', 51820, 40001, MARK) === true);
check('fresh direct', wrapped_state(stale + '\n' + direct, '47.189.48.153', 51820, 40001, MARK) === false);
check('server-opened is direct', wrapped_state(stale, '47.189.48.153', 51820, 55743, MARK) === false);
check('no entry', wrapped_state(stale, '47.189.48.153', 51820, 40001, MARK) === null);
check('empty', wrapped_state(null, '1.2.3.4', 51820, 1, MARK) === null);

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
