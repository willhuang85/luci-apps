// Publishes stand-ins for the ubus objects that other daemons serve on a
// Wi-Fi router (netifd: network.wireless, network.interface; hostapd:
// hostapd.<ifname>) so the integration tests can run the plugins in a real
// rpcd without Wi-Fi hardware or netifd. Logs calls to $FAKE_LOG. The fake
// iwinfo object is an rpcd plugin (fake_iwinfo.uc), as on a real router.

'use strict';

import * as ubus from 'ubus';
import * as uloop from 'uloop';
import { open } from 'fs';

const log = open(getenv('FAKE_LOG') ?? '/tmp/fake_wifi.log', 'a');

function note(s) {
	log.write(s + '\n');
	log.flush();
}

uloop.init();

const conn = ubus.connect();

conn.publish('network.wireless', {
	status: {
		call: () => ({
			radio0: { up: true, interfaces: [ { section: 'default_radio0', ifname: 'phy0-ap0' } ] },
			radio1: { up: true, interfaces: [ { section: 'default_radio1', ifname: 'phy1-ap0' } ] }
		})
	}
});

conn.publish('network.interface', {
	dump: {
		call: () => ({ interface: [
			{ interface: 'wan', up: true, l3_device: 'lo', 'ipv4-address': [ { address: '127.0.0.1', mask: 8 } ] },
			{ interface: 'wan6', up: true }
		] })
	}
});

conn.publish('hostapd.phy1-ap0', {
	del_client: {
		args: { addr: '', reason: 0, deauth: false, ban_time: 0 },
		call: (req) => { note(`del_client ${req.args.addr}`); return {}; }
	}
});

uloop.run();
