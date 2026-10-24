'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

const callGet = rpc.declare({ object: 'luci.wifisetup', method: 'get' });
const callStatus = rpc.declare({ object: 'luci.wifisetup', method: 'status' });
const callSetNetwork = rpc.declare({ object: 'luci.wifisetup', method: 'set_network',
	params: [ 'net', 'ssid', 'key', 'encryption', 'hidden', 'same_name', 'ssids', 'enabled', 'isolate', 'bands' ] });
const callSetRadio = rpc.declare({ object: 'luci.wifisetup', method: 'set_radio', params: [ 'id', 'enabled', 'channel', 'htmode', 'txpower' ] });
const callSetRegion = rpc.declare({ object: 'luci.wifisetup', method: 'set_region', params: [ 'country' ] });
const callKick = rpc.declare({ object: 'luci.wifisetup', method: 'kick', params: [ 'mac', 'ifname' ] });
const callBlock = rpc.declare({ object: 'luci.wifisetup', method: 'block', params: [ 'mac', 'name' ] });
const callUnblock = rpc.declare({ object: 'luci.wifisetup', method: 'unblock', params: [ 'mac' ] });
const callSetSchedule = rpc.declare({ object: 'luci.wifisetup', method: 'set_schedule', params: [ 'enabled', 'off', 'on', 'days' ] });
const callQrcode = rpc.declare({ object: 'luci.wifisetup', method: 'qrcode', params: [ 'net' ] });

// Radio details come straight from iwinfo, like on LuCI's own pages: iwinfo
// is served by rpcd, which the luci.wifisetup backend runs in, so the
// backend must not call it itself (rpcd would wait for itself).
const callIwinfoInfo = rpc.declare({ object: 'iwinfo', method: 'info', params: [ 'device' ] });
const callIwinfoFreqlist = rpc.declare({ object: 'iwinfo', method: 'freqlist', params: [ 'device' ], expect: { results: [] } });
const callIwinfoTxpowerlist = rpc.declare({ object: 'iwinfo', method: 'txpowerlist', params: [ 'device' ], expect: { results: [] } });
const callIwinfoCountrylist = rpc.declare({ object: 'iwinfo', method: 'countrylist', params: [ 'device' ], expect: { results: [] } });
const callIwinfoAssoclist = rpc.declare({ object: 'iwinfo', method: 'assoclist', params: [ 'device' ], expect: { results: [] } });

const STANDARDS = [ 'EHT', 'HE', 'VHT', 'HT' ];
const GHZ = { '2g': 2, '5g': 5, '6g': 6, '60g': 60 };

const SECURITY = [
	{ value: 'sae-mixed', label: _('WPA2/WPA3 Personal (recommended)'), key: true, sae: true },
	{ value: 'sae', label: _('WPA3 Personal (most secure, newer devices only)'), key: true, sae: true },
	{ value: 'psk2', label: _('WPA2 Personal (for older devices)'), key: true },
	{ value: 'psk-mixed', label: _('WPA/WPA2 Personal (very old devices only)'), key: true },
	{ value: 'owe', label: _('Enhanced Open (no password, but encrypted)'), key: false, owe: true },
	{ value: 'none', label: _('Open (no password)'), key: false }
];

const DAYS = [
	[ 'mon', _('Mon') ], [ 'tue', _('Tue') ], [ 'wed', _('Wed') ], [ 'thu', _('Thu') ],
	[ 'fri', _('Fri') ], [ 'sat', _('Sat') ], [ 'sun', _('Sun') ]
];

// How long Wi-Fi needs to come back after a change, before we ask again.
const APPLY_WAIT = 6000;

const CSS = `
.tw { --tw-ok: #1a9c4a; --tw-warn: #d68b00; --tw-bad: #d23f31; --tw-muted: rgba(127,127,127,.85);
	--tw-line: rgba(127,127,127,.25); --tw-tint: rgba(127,127,127,.07); max-width: 960px; }
.tw * { box-sizing: border-box; }
.tw-card { border: 1px solid var(--tw-line); border-radius: 12px; padding: 20px; margin: 0 0 16px; background: var(--tw-tint); }
.tw-hero { display: flex; align-items: center; gap: 20px; flex-wrap: wrap; }
.tw-orb { width: 64px; height: 64px; border-radius: 50%; flex: none; display: flex; align-items: center; justify-content: center;
	font-size: 30px; color: #fff; background: var(--tw-muted); }
.tw-orb.ok { background: var(--tw-ok); box-shadow: 0 0 0 6px rgba(26,156,74,.18); }
.tw-orb.warn { background: var(--tw-warn); box-shadow: 0 0 0 6px rgba(214,139,0,.18); }
.tw-orb.bad { background: var(--tw-bad); box-shadow: 0 0 0 6px rgba(210,63,49,.18); }
.tw-hero-text { flex: 1 1 240px; min-width: 0; }
.tw-hero-title { font-size: 1.5em; font-weight: 600; line-height: 1.2; overflow-wrap: anywhere; }
.tw-sub { color: var(--tw-muted); margin-top: 4px; overflow-wrap: anywhere; }
.tw-row { display: flex; align-items: center; gap: 16px; }
.tw-grow { flex: 1 1 auto; min-width: 0; }
.tw-h { font-size: 1.1em; font-weight: 600; margin: 0; }
.tw-switch { position: relative; display: inline-block; width: 52px; height: 30px; flex: none; cursor: pointer; }
.tw-switch input { position: absolute; opacity: 0; width: 0; height: 0; }
.tw-slider { position: absolute; inset: 0; border-radius: 30px; background: var(--tw-muted); transition: background .2s; }
.tw-slider::before { content: ""; position: absolute; width: 24px; height: 24px; left: 3px; top: 3px; border-radius: 50%;
	background: #fff; transition: transform .2s; box-shadow: 0 1px 3px rgba(0,0,0,.3); }
.tw-switch input:checked + .tw-slider { background: var(--tw-ok); }
.tw-switch input:checked + .tw-slider::before { transform: translateX(22px); }
.tw-switch input:focus-visible + .tw-slider { outline: 2px solid var(--tw-ok); outline-offset: 2px; }
.tw-switch input:disabled + .tw-slider { opacity: .5; cursor: wait; }
.tw-note { margin-top: 12px; padding: 10px 12px; border-radius: 8px; border-left: 4px solid var(--tw-warn); background: rgba(214,139,0,.1); }
.tw-note.bad { border-left-color: var(--tw-bad); background: rgba(210,63,49,.1); }
.tw-note.ok { border-left-color: var(--tw-ok); background: rgba(26,156,74,.1); }
.tw-note.info { border-left-color: var(--tw-muted); background: transparent; }
.tw-form { display: grid; grid-template-columns: minmax(140px, max-content) minmax(0, 1fr); gap: 12px 16px; align-items: center; margin-top: 16px; }
.tw-form > label { font-weight: 600; }
.tw-form .tw-full { grid-column: 1 / -1; }
.tw-form input[type=text], .tw-form input[type=password], .tw-form select { width: 100%; max-width: 420px; }
.tw-pw { display: flex; gap: 6px; max-width: 420px; }
.tw-pw input { flex: 1 1 auto; min-width: 0; font-family: monospace; }
.tw-pw .btn { margin: 0; flex: none; }
.tw-hint { font-size: .85em; color: var(--tw-muted); margin-top: 4px; }
.tw-hint.bad { color: var(--tw-bad); }
.tw-meter { height: 4px; border-radius: 2px; background: var(--tw-line); margin-top: 6px; max-width: 420px; overflow: hidden; }
.tw-meter > div { height: 100%; width: 0; transition: width .2s, background .2s; }
.tw-check { display: flex; align-items: center; gap: 8px; font-weight: normal; cursor: pointer; }
.tw-checks { display: flex; flex-wrap: wrap; gap: 8px 20px; }
.tw-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; margin-top: 16px; }
.tw-actions .btn, .tw-actions .cbi-button { margin: 0; }
.tw-band { display: flex; align-items: center; gap: 16px; padding: 12px 0; border-top: 1px solid var(--tw-line); }
.tw-link { background: none; border: 0; padding: 0; margin-top: 4px; color: inherit; text-decoration: underline; cursor: pointer; font: inherit; font-size: .9em; }
.tw-band:first-of-type { border-top: 0; }
.tw-band-name { font-weight: 600; font-size: 1.05em; }
.tw-dot { width: 12px; height: 12px; border-radius: 50%; background: var(--tw-muted); flex: none; }
.tw-dot.ok { background: var(--tw-ok); } .tw-dot.warn { background: var(--tw-warn); } .tw-dot.bad { background: var(--tw-bad); }
.tw-badge { display: inline-block; font-size: .75em; padding: 1px 8px; border-radius: 10px; margin-left: 8px;
	border: 1px solid var(--tw-line); vertical-align: middle; font-weight: normal; }
.tw-badge.guest { border-color: var(--tw-warn); color: var(--tw-warn); }
.tw-badge.bad { border-color: var(--tw-bad); color: var(--tw-bad); }
.tw-dev { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; padding: 12px 0; border-top: 1px solid var(--tw-line); }
.tw-dev:first-child { border-top: 0; }
.tw-dev-name { font-weight: 600; overflow-wrap: anywhere; }
.tw-dev-main { display: flex; align-items: center; gap: 14px; flex: 1 1 300px; min-width: 0; }
.tw-bars { display: inline-flex; align-items: flex-end; gap: 2px; height: 16px; flex: none; }
.tw-bars > span { width: 4px; background: var(--tw-line); border-radius: 1px; }
.tw-bars > span.on { background: var(--tw-ok); }
.tw-bars.weak > span.on { background: var(--tw-warn); }
.tw-days { display: flex; gap: 6px; flex-wrap: wrap; }
.tw-day { border: 2px solid var(--tw-line); border-radius: 18px; padding: 4px 10px; background: transparent; color: inherit;
	cursor: pointer; font: inherit; min-width: 48px; }
.tw-day[aria-pressed=true] { border-color: var(--tw-ok); background: rgba(26,156,74,.12); font-weight: 600; }
.tw-times { display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
.tw-times input { width: 9em; }
.tw-qr { text-align: center; }
.tw-qr img { width: 240px; max-width: 100%; height: auto; background: #fff; border-radius: 8px; padding: 8px; }
.tw-kv { display: grid; grid-template-columns: max-content 1fr; gap: 6px 12px; margin: 16px auto 0; max-width: 360px; text-align: left; }
.tw-kv > div:nth-child(odd) { color: var(--tw-muted); }
.tw-kv > div { overflow-wrap: anywhere; }
.tw-mono { font-family: monospace; }
@media (max-width: 600px) {
	.tw-card { padding: 14px; }
	.tw-form { grid-template-columns: 1fr; gap: 6px; }
	.tw-form > label { margin-top: 8px; }
	.tw-dev .tw-actions { width: 100%; justify-content: flex-start; margin-top: 0; }
}
`;

function securityInfo(value) {
	return SECURITY.find((s) => s.value == value) ?? SECURITY[SECURITY.length - 1];
}

function notifyError(err) {
	ui.addNotification(null, E('p', {}, err?.message ?? String(err)), 'danger');
}

function check(res) {
	if (res?.error)
		throw new Error(res.error);

	return res;
}

function utf8Length(s) {
	return new TextEncoder().encode(s).length;
}

function ssidError(ssid) {
	if (!ssid.length)
		return _('Enter a network name');

	if (utf8Length(ssid) > 32)
		return _('The network name is too long (max. 32 bytes)');

	return null;
}

function keyError(key, enc) {
	const sec = securityInfo(enc);

	if (!sec.key)
		return null;

	if ((enc == 'psk2' || enc == 'psk-mixed') && /^[0-9a-fA-F]{64}$/.test(key))
		return null;

	if (key.length < 8)
		return _('At least 8 characters');

	if (key.length > 63)
		return _('At most 63 characters');

	if (!/^[\x20-\x7e]+$/.test(key))
		return _('Use letters, digits, spaces and common symbols only (no accents or emoji)');

	return null;
}

// 0..4, a rough idea of how hard the password is to guess
function keyStrength(key) {
	if (key.length < 8)
		return 0;

	const classes = [ /[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/ ].filter((re) => re.test(key)).length;
	let score = (key.length >= 12) + (key.length >= 16) + (classes >= 2) + (classes >= 3);

	if (/^(.)\1+$/.test(key) || /^(password|12345678|qwertyui)/i.test(key))
		score = 0;

	return Math.max(1, Math.min(4, score));
}

function randomPassword() {
	const alphabet = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
	const buf = new Uint32Array(15);

	window.crypto.getRandomValues(buf);

	return Array.from(buf, (n, i) => ((i % 5 == 4) ? '-' : alphabet[n % alphabet.length])).join('').replace(/-$/, '');
}

function formatDuration(sec) {
	if (sec == null)
		return '-';

	const d = Math.floor(sec / 86400), h = Math.floor(sec / 3600) % 24, m = Math.floor(sec / 60) % 60;

	if (d)
		return '%dd %dh'.format(d, h);

	if (h)
		return '%dh %dm'.format(h, m);

	return '%dm'.format(Math.max(m, 1));
}

function formatRate(kbit) {
	if (!kbit)
		return null;

	return (kbit >= 1000) ? '%d Mbit/s'.format(Math.round(kbit / 1000)) : '%d kbit/s'.format(kbit);
}

function signalBars(dbm) {
	const n = (dbm >= -55) ? 4 : (dbm >= -67) ? 3 : (dbm >= -75) ? 2 : 1;
	const label = [ '', _('Weak'), _('Fair'), _('Good'), _('Excellent') ][n];

	return E('span', { 'class': 'tw-bars' + (n <= 1 ? ' weak' : ''), title: '%s (%d dBm)'.format(label, dbm) },
		[ 6, 9, 12, 16 ].map((h, i) => E('span', { 'class': i < n ? 'on' : '', style: 'height:%dpx'.format(h) })));
}

function switchEl(checked, onChange, label) {
	return E('label', { 'class': 'tw-switch', title: label }, [
		E('input', { type: 'checkbox', role: 'switch', 'aria-label': label, checked: checked ? '' : null, change: onChange }),
		E('span', { 'class': 'tw-slider' })
	]);
}

function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

// Channel widths the radio supports, each with the newest standard that can
// do it, e.g. [ { width: 20, htmode: 'HE20' }, { width: 80, htmode: 'HE80' } ].
function widthOptions(htmodes, band, current) {
	const best = {};

	for (let m of htmodes ?? []) {
		const p = /^(EHT|HE|VHT|HT)([0-9]+)$/.exec(m);

		if (!p)
			continue;

		const std = p[1], w = +p[2];

		if (band == '2g' && (std == 'VHT' || w > 40))
			continue;

		if (band == '6g' && (std == 'HT' || std == 'VHT'))
			continue;

		if (best[w] == null || STANDARDS.indexOf(std) < STANDARDS.indexOf(best[w]))
			best[w] = std;
	}

	const list = Object.keys(best).map(Number).sort((a, b) => a - b).map((w) => ({ width: w, htmode: best[w] + w }));

	if (!list.length && current) {
		const p = /^([A-Z]+?)([0-9]+)/.exec(current);

		if (p)
			list.push({ width: +p[2], htmode: p[1] + p[2] });
	}

	return list;
}

// Adds what each radio can do (from iwinfo) to the configuration.
function loadConfig() {
	return callGet().then((cfg) => Promise.all((cfg.radios ?? []).map((r) => Promise.all([
		L.resolveDefault(callIwinfoInfo(r.id), {}),
		L.resolveDefault(callIwinfoFreqlist(r.id), []),
		L.resolveDefault(callIwinfoTxpowerlist(r.id), [])
	]).then(([ info, freqs, powers ]) => {
		r.hardware = info?.hardware?.name ?? null;
		r.widths = widthOptions(info?.htmodes, r.band, r.htmode);
		r.channels = (freqs ?? []).filter((f) => (f.band == null || f.band == GHZ[r.band]) && !f.restricted).map((f) => ({
			channel: f.channel,
			mhz: f.mhz,
			dfs: (f.flags ?? []).includes('RADAR') || (r.band == '5g' && f.channel >= 52 && f.channel <= 144)
		}));
		r.txpowers = (powers ?? []).map((t) => ({ dbm: t.dbm, mw: t.mw }));
	}))).then(() => cfg.radios?.length ? L.resolveDefault(callIwinfoCountrylist(cfg.radios[0].id), []) : []).then((countries) => {
		cfg.countries = (countries ?? []).map((c) => ({ code: c.iso3166, name: c.country }));
		return cfg;
	}));
}

// Live state: radios and access points from the backend, channel and
// connected devices from iwinfo.
function loadStatus() {
	return callStatus().then((st) => {
		const radios = {};
		const clients = [];
		const blocked = new Set(st.blocked ?? []);

		for (let id in st.radios ?? {})
			radios[id] = Object.assign({ channel: null, frequency: null, txpower: null, width: null }, st.radios[id]);

		return Promise.all((st.ifaces ?? []).map((i) => {
			const rs = radios[i.radio];
			const first = rs && !rs.asked;

			if (first)
				rs.asked = true;

			return Promise.all([
				first ? L.resolveDefault(callIwinfoInfo(i.ifname), {}) : null,
				L.resolveDefault(callIwinfoAssoclist(i.ifname), [])
			]).then(([ info, assoc ]) => {
				if (info) {
					rs.channel = info.channel ?? null;
					rs.frequency = info.frequency ?? null;
					rs.txpower = info.txpower ?? null;
					rs.width = (/([0-9]+)/.exec(info.htmode ?? '') ?? [])[1] ?? null;
				}

				for (let c of assoc ?? []) {
					const mac = (c.mac ?? '').toUpperCase();
					const lease = st.leases?.[mac] ?? {};

					clients.push({
						mac,
						ifname: i.ifname,
						name: lease.name,
						ip: lease.ip,
						radio: i.radio,
						network: i.network,
						ssid: i.ssid,
						signal: c.signal,
						connected_time: c.connected_time,
						inactive: c.inactive,
						rx_rate: c.rx?.rate,
						tx_rate: c.tx?.rate,
						rx_bytes: c.rx?.bytes,
						tx_bytes: c.tx?.bytes,
						blocked: blocked.has(mac)
					});
				}
			});
		})).then(() => ({ radios, clients }));
	});
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	busy: false,

	load() {
		return Promise.all([ loadConfig(), L.resolveDefault(loadStatus(), { radios: {}, clients: [] }) ]);
	},

	// Re-renders the live parts only, so typing in a form is never disturbed.
	refreshStatus() {
		return loadStatus().then((st) => {
			this.status = st;

			if (this.busy)
				return;

			dom.content(this.heroEl, this.renderHero());
			dom.content(this.bandsEl, this.renderBandRows());
			dom.content(this.devicesEl, this.renderDevices());
		});
	},

	// Reads the configuration again after a change and redraws everything.
	reload() {
		return Promise.all([ loadConfig(), L.resolveDefault(loadStatus(), this.status) ]).then(([ cfg, st ]) => {
			this.cfg = cfg;
			this.status = st;
			dom.content(this.root, this.renderContent());
		});
	},

	/*
	 * Runs a change. Wi-Fi changes restart the radios a second after the
	 * router answered, which drops devices (maybe this browser) for a few
	 * seconds, so wait and then retry until the router answers again.
	 */
	act(label, fn, opts) {
		if (this.busy)
			return Promise.resolve();

		this.busy = true;
		ui.showModal(null, [ E('p', { 'class': 'spinning' }, label) ]);

		return Promise.resolve().then(fn).then(check).then(() => {
			if (!opts?.restartsWifi)
				return;

			ui.showModal(null, [
				E('p', { 'class': 'spinning' }, _('Applying… Wi-Fi restarts, devices reconnect in a few seconds.')),
				opts.reconnect ? E('p', {}, opts.reconnect) : ''
			]);

			return sleep(APPLY_WAIT);
		}).then(() => this.retry(() => this.reload(), opts?.restartsWifi ? 20 : 1)).catch(notifyError).finally(() => {
			ui.hideModal();
			this.busy = false;
		});
	},

	retry(fn, tries) {
		return fn().catch((err) => {
			if (tries <= 1)
				throw err;

			return sleep(3000).then(() => this.retry(fn, tries - 1));
		});
	},

	/* --- Hero */

	renderHero() {
		const cfg = this.cfg, st = this.status ?? { radios: {}, clients: [] };
		const radios = cfg.radios ?? [];
		const on = radios.filter((r) => r.enabled);
		const up = radios.filter((r) => st.radios?.[r.id]?.up);
		const main = cfg.main;
		const guests = (st.clients ?? []).filter((c) => c.network == 'guest').length;
		const total = (st.clients ?? []).length;

		let orb, title, sub, note = '';

		if (!radios.length) {
			orb = [ 'bad', '✕' ];
			title = _('No Wi-Fi hardware found');
			sub = _('This router has no Wi-Fi radios, or their driver is not installed.');
		}
		else if (!main || !on.length) {
			orb = [ '', '⏻' ];
			title = _('Wi-Fi is off');
			sub = main?.encryption == 'none'
				? _('Choose a network name and password below, then turn on a band.')
				: _('Turn on a band below to start broadcasting "%s".').format(main?.ssid ?? '');
		}
		else if (!up.length) {
			orb = [ 'warn', '…' ];
			title = _('Wi-Fi is starting…');
			sub = _('This can take a minute, longer on DFS channels.');
		}
		else {
			orb = [ 'ok', '📶' ];
			title = main.same_name ? main.ssid : Object.values(main.ssids).filter((v, i, a) => a.indexOf(v) == i).join(' / ');
			sub = [
				up.map((r) => r.label).join(' · '),
				total == 1 ? _('1 device connected') : _('%d devices connected').format(total),
				guests ? _('%d on the guest network').format(guests) : null
			].filter((x) => x).join(' — ');
		}

		if (main && on.length && main.encryption == 'none')
			note = E('div', { 'class': 'tw-note bad' }, _('Your Wi-Fi has no password: anyone nearby can join and use your network. Choose a security mode and password below.'));
		else if (cfg.schedule?.enabled)
			note = E('div', { 'class': 'tw-note info' }, _('Wi-Fi turns off at %s and back on at %s (schedule below).').format(cfg.schedule.off, cfg.schedule.on));

		return E('div', { 'class': 'tw-card' }, [
			E('div', { 'class': 'tw-hero' }, [
				E('div', { 'class': 'tw-orb ' + orb[0] }, orb[1]),
				E('div', { 'class': 'tw-hero-text' }, [
					E('div', { 'class': 'tw-hero-title' }, title),
					E('div', { 'class': 'tw-sub' }, sub)
				]),
				(main && on.length) ? E('button', { 'class': 'btn cbi-button', click: () => this.showQr('main') }, [ '▦ ' + _('Share') ]) : ''
			]),
			note
		]);
	},

	/* --- Network forms (main and guest) */

	// Password field with show/hide, generator and strength meter.
	passwordField(value, onInput) {
		const input = E('input', { type: 'password', 'class': 'cbi-input-text', value: value ?? '', autocomplete: 'new-password',
			spellcheck: 'false', maxlength: 64 });
		const show = E('button', { 'class': 'btn cbi-button', type: 'button', title: _('Show password'), click: (ev) => {
			ev.preventDefault();
			input.type = (input.type == 'password') ? 'text' : 'password';
			show.textContent = (input.type == 'password') ? _('Show') : _('Hide');
		} }, [ _('Show') ]);
		const gen = E('button', { 'class': 'btn cbi-button', type: 'button', title: _('Generate a strong password'), click: (ev) => {
			ev.preventDefault();
			input.value = randomPassword();
			input.type = 'text';
			show.textContent = _('Hide');
			input.dispatchEvent(new Event('input'));
		} }, [ _('Generate') ]);
		const bar = E('div');
		const meter = E('div', { 'class': 'tw-meter' }, bar);

		const update = () => {
			const s = keyStrength(input.value);

			bar.style.width = (s * 25) + '%';
			bar.style.background = [ '', 'var(--tw-bad)', 'var(--tw-warn)', 'var(--tw-ok)', 'var(--tw-ok)' ][s];
			bar.title = [ '', _('Weak'), _('Fair'), _('Good'), _('Strong') ][s];
		};

		input.addEventListener('input', () => { update(); onInput(); });
		update();

		return { input, el: E('div', {}, [ E('div', { 'class': 'tw-pw' }, [ input, show, gen ]), meter ]) };
	},

	securitySelect(value, onChange) {
		const f = this.cfg.features ?? {};

		return E('select', { 'class': 'cbi-input-select', change: onChange }, SECURITY.map((s) => {
			const missing = (s.sae && f.sae === false) || (s.owe && f.owe === false);

			return E('option', { value: s.value, selected: s.value == value ? '' : null, disabled: missing ? '' : null },
				missing ? _('%s – not supported by the installed wpad').format(s.label) : s.label);
		}));
	},

	renderNetworkForm(net) {
		const cfg = this.cfg;
		const isGuest = (net == 'guest');
		const cur = isGuest ? cfg.guest : (cfg.main ?? {});
		const radios = cfg.radios ?? [];
		const enc0 = cur.encryption ?? 'sae-mixed';

		// a new or open network starts out with the recommended security
		const startEnc = (!isGuest && enc0 == 'none' && (cur.ssid == 'OpenWrt' || !cur.ssid)) ? 'sae-mixed' : enc0;

		const ssid = E('input', { type: 'text', 'class': 'cbi-input-text', value: cur.ssid ?? (isGuest ? (cfg.main?.ssid ?? 'Home') + ' Guest' : ''),
			maxlength: 32, placeholder: isGuest ? _('e.g. Home Guest') : _('e.g. Home') });
		const ssidHint = E('div', { 'class': 'tw-hint' });
		const pw = this.passwordField(cur.key, () => validate());
		const keyHint = E('div', { 'class': 'tw-hint' });
		const keyRow = [ E('label', {}, _('Password')), E('div', {}, [ pw.el, keyHint ]) ];
		const security = this.securitySelect(startEnc, () => validate());
		const hidden = E('input', { type: 'checkbox', checked: cur.hidden ? '' : null });
		const saveBtn = E('button', { 'class': 'btn cbi-button cbi-button-save important', click: () => save() },
			[ (isGuest && !cur.enabled) ? _('Turn on guest network') : _('Save') ]);

		// main: one name for all bands or one per band
		const sameName = E('input', { type: 'checkbox', checked: (cur.same_name ?? true) ? '' : null });
		const perBand = {};
		const perBandRows = E('div', { 'class': 'tw-full tw-form', style: 'margin-top:0' });

		// guest: bands and isolation
		const bandBoxes = {};
		const isolate = E('input', { type: 'checkbox', checked: (cur.isolate ?? true) ? '' : null });

		if (!isGuest) {
			for (let r of radios) {
				perBand[r.id] = E('input', { type: 'text', 'class': 'cbi-input-text', maxlength: 32,
					value: cur.ssids?.[r.id] ?? cur.ssid ?? '' });
				perBand[r.id].addEventListener('input', () => validate());
				perBandRows.appendChild(E('label', {}, _('Name on %s').format(r.label)));
				perBandRows.appendChild(perBand[r.id]);
			}
		}
		else {
			for (let r of radios)
				bandBoxes[r.id] = E('input', { type: 'checkbox',
					checked: (radios.length == 1 || (cur.enabled ? cur.bands?.[r.id] : r.band != '6g')) ? '' : null,
					change: () => validate() });
		}

		const snapshot = () => JSON.stringify([ ssid.value, security.value, pw.input.value, hidden.checked, sameName.checked,
			isolate.checked, Object.keys(perBand).map((id) => perBand[id].value), Object.keys(bandBoxes).map((id) => bandBoxes[id].checked) ]);
		let initial = null;

		const validate = () => {
			const enc = security.value;
			const keyed = securityInfo(enc).key;
			const split = !isGuest && !sameName.checked;
			let ok = true;

			const se = ssidError(ssid.value);
			ssidHint.textContent = se ?? (isGuest ? '' : _('The name your devices see when they look for Wi-Fi.'));
			ssidHint.className = 'tw-hint' + (se ? ' bad' : '');
			ok = ok && !se;

			for (let id in perBand) {
				perBand[id].disabled = !split;
				ok = ok && (!split || !ssidError(perBand[id].value));
			}

			perBandRows.style.display = split ? '' : 'none';
			keyRow.forEach((el) => el.style.display = keyed ? '' : 'none');

			const ke = keyed ? keyError(pw.input.value, enc) : null;
			keyHint.textContent = ke ?? '';
			keyHint.className = 'tw-hint' + (ke ? ' bad' : '');
			ok = ok && !ke;

			if (isGuest)
				ok = ok && Object.values(bandBoxes).some((b) => b.checked);

			// a disabled guest network is turned on by saving it, even unchanged
			saveBtn.disabled = !ok || (snapshot() == initial && !(isGuest && !cur.enabled));

			return ok;
		};

		ssid.addEventListener('input', () => validate());
		sameName.addEventListener('change', () => validate());
		hidden.addEventListener('change', () => validate());
		isolate.addEventListener('change', () => validate());

		const save = () => {
			if (!validate())
				return;

			const enc = security.value;
			const keyed = securityInfo(enc).key;
			const args = {
				ssid: ssid.value,
				key: keyed ? pw.input.value : '',
				encryption: enc,
				hidden: hidden.checked
			};

			if (isGuest) {
				Object.assign(args, { enabled: true, isolate: isolate.checked,
					bands: Object.keys(bandBoxes).filter((id) => bandBoxes[id].checked) });
			}
			else {
				const ssids = {};

				for (let id in perBand)
					ssids[id] = perBand[id].value;

				Object.assign(args, { same_name: sameName.checked, ssids });
			}

			const changedCreds = !isGuest && (args.ssid != cur.ssid || args.key != (cur.key ?? '') || enc != cur.encryption);

			if (!isGuest && enc == 'none' &&
			    !confirm(_('Without a password anyone nearby can join your network and reach your devices. Continue?')))
				return;

			return this.act(_('Saving…'), () => callSetNetwork(net, args.ssid, args.key, args.encryption, args.hidden,
				args.same_name ?? true, args.ssids ?? {}, args.enabled ?? true, args.isolate ?? true, args.bands ?? []), {
				restartsWifi: true,
				reconnect: changedCreds
					? (keyed
						? _('If this browser is on Wi-Fi, connect it to "%s" with the new password, then this page continues by itself.').format(args.ssid)
						: _('If this browser is on Wi-Fi, connect it to "%s", then this page continues by itself.').format(args.ssid))
					: null
			});
		};

		const rows = [
			E('label', {}, _('Network name')),
			E('div', {}, [ ssid, ssidHint ]),
		];

		if (!isGuest && radios.length > 1)
			rows.push(E('div', { 'class': 'tw-full' }, E('label', { 'class': 'tw-check' }, [
				sameName, _('Use the same name on all bands (recommended: devices pick the best band by themselves)')
			])), perBandRows);

		rows.push(E('label', {}, _('Security')), security, ...keyRow);

		if (isGuest) {
			if (radios.length > 1)
				rows.push(E('label', {}, _('Bands')), E('div', { 'class': 'tw-checks' }, radios.map((r) =>
					E('label', { 'class': 'tw-check' }, [ bandBoxes[r.id], r.label ]))));

			rows.push(E('div', { 'class': 'tw-full' }, E('label', { 'class': 'tw-check' }, [
				isolate, _('Keep guests apart (guest devices cannot see each other)')
			])));
		}

		rows.push(E('div', { 'class': 'tw-full' }, E('label', { 'class': 'tw-check' }, [
			hidden, _('Hide network name (devices must enter the name by hand to join)')
		])));

		const form = E('div', {}, [
			E('div', { 'class': 'tw-form' }, rows),
			E('div', { 'class': 'tw-actions' }, [
				(!isGuest || cur.enabled) ? E('button', { 'class': 'btn cbi-button', click: () => this.showQr(net) }, [ '▦ ' + _('Share') ]) : '',
				saveBtn
			])
		]);

		initial = snapshot();
		validate();

		return form;
	},

	renderMain() {
		return E('div', { 'class': 'tw-card' }, [
			E('p', { 'class': 'tw-h' }, '📶 ' + _('Wi-Fi network')),
			E('div', { 'class': 'tw-sub' }, _('Name and password of your Wi-Fi, used on all bands.')),
			this.renderNetworkForm('main')
		]);
	},

	renderGuest() {
		const g = this.cfg.guest ?? {};
		const body = E('div', { style: g.enabled ? '' : 'display:none' }, [
			E('div', { 'class': 'tw-note info' }, g.address
				? _('Guests get internet access only: they cannot reach your devices or this router\'s settings. Guest devices get addresses from %s/24.').format(g.address.replace(/\.1$/, '.0'))
				: _('Guests get internet access only: they cannot reach your devices or this router\'s settings. The guest network gets its own address range.')),
			this.renderNetworkForm('guest')
		]);

		const toggle = (ev) => {
			if (ev.target.checked) {
				// shown first, saving turns it on
				body.style.display = '';
				return;
			}

			body.style.display = 'none';

			if (g.enabled)
				return this.act(_('Turning off the guest network…'), () => callSetNetwork('guest', '', '', 'none', false, true, {}, false, true, []),
					{ restartsWifi: true });
		};

		return E('div', { 'class': 'tw-card' }, [
			E('div', { 'class': 'tw-row' }, [
				E('div', { 'class': 'tw-grow' }, [
					E('p', { 'class': 'tw-h' }, '🧳 ' + _('Guest network')),
					E('div', { 'class': 'tw-sub' }, _('A separate Wi-Fi for visitors, with internet but no access to your devices.'))
				]),
				switchEl(g.enabled, toggle, _('Guest network'))
			]),
			body
		]);
	},

	/* --- Bands */

	handleRadioToggle(r, ev) {
		const enabled = ev.target.checked;

		if (!enabled && !confirm(_('Turn off %s? Devices connected on this band move to another band or lose Wi-Fi.').format(r.label))) {
			ev.target.checked = true;
			return;
		}

		if (enabled && this.cfg.main?.encryption == 'none' &&
		    !confirm(_('Your Wi-Fi "%s" has no password yet, so anyone nearby could join. Turn it on anyway? (Better: set a password in "Wi-Fi network" above first.)').format(this.cfg.main.ssid))) {
			ev.target.checked = false;
			return;
		}

		return this.act(enabled ? _('Turning on %s…').format(r.label) : _('Turning off %s…').format(r.label),
			() => callSetRadio(r.id, enabled, r.channel, '', r.txpower ?? 0), { restartsWifi: true });
	},

	showRadioSettings(r) {
		const channel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: 'auto', selected: r.channel == 'auto' ? '' : null }, _('Automatic (recommended)')),
			...r.channels.map((c) => E('option', { value: String(c.channel), selected: String(c.channel) == r.channel ? '' : null },
				'%d  (%d MHz)%s'.format(c.channel, c.mhz, c.dfs ? ' · DFS' : '')))
		]);

		// keep a configured channel visible even if the driver does not list it right now
		if (r.channel != 'auto' && !r.channels.some((c) => String(c.channel) == r.channel))
			channel.appendChild(E('option', { value: r.channel, selected: '' }, r.channel));

		const width = E('select', { 'class': 'cbi-input-select' }, r.widths.map((w) =>
			E('option', { value: w.htmode, selected: w.width == r.width ? '' : null },
				'%d MHz%s'.format(w.width, (r.band == '2g' && w.width == 20) || (r.band == '5g' && w.width == 80) ? ' (' + _('recommended') + ')' : ''))));

		const power = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: '0', selected: r.txpower == null ? '' : null }, _('Maximum (recommended)')),
			...r.txpowers.slice().reverse().map((t) => E('option', { value: String(t.dbm), selected: t.dbm == r.txpower ? '' : null },
				'%d dBm (%d mW)'.format(t.dbm, t.mw)))
		]);

		if (r.txpower != null && !r.txpowers.some((t) => t.dbm == r.txpower))
			power.appendChild(E('option', { value: String(r.txpower), selected: '' }, '%d dBm'.format(r.txpower)));

		const dfsNote = E('div', { 'class': 'tw-note', style: 'display:none' },
			_('DFS channels are shared with weather radar: after a change the router has to listen for radar for 1–10 minutes before Wi-Fi starts on this band, and it may switch channel by itself.'));
		const updateNote = () => dfsNote.style.display = r.channels.some((c) => String(c.channel) == channel.value && c.dfs) ? '' : 'none';

		channel.addEventListener('change', updateNote);
		updateNote();

		ui.showModal(_('%s settings').format(r.label), [
			E('div', { 'class': 'tw' }, [
				r.hardware ? E('div', { 'class': 'tw-sub' }, r.hardware) : '',
				E('div', { 'class': 'tw-form' }, [
					E('label', {}, _('Channel')), channel,
					E('label', {}, _('Channel width')), E('div', {}, [
						width,
						E('div', { 'class': 'tw-hint' }, r.band == '2g'
							? _('Wider is faster but more sensitive to interference; 20 MHz works best in busy areas.')
							: _('Wider is faster; narrower reaches further and copes better with neighbours.'))
					]),
					E('label', {}, _('Transmit power')), E('div', {}, [
						power,
						E('div', { 'class': 'tw-hint' }, _('Lower power reduces range, e.g. to keep the signal inside a small flat.'))
					])
				]),
				dfsNote
			]),
			E('div', { 'class': 'tw-actions' }, [
				E('button', { 'class': 'btn cbi-button', click: ui.hideModal }, [ _('Cancel') ]),
				E('button', { 'class': 'btn cbi-button cbi-button-save important', click: () => {
					ui.hideModal();
					this.act(_('Saving %s settings…').format(r.label),
						() => callSetRadio(r.id, r.enabled, channel.value, width.value || '', +power.value || 0), { restartsWifi: true });
				} }, [ _('Save') ])
			])
		], 'cbi-modal');
	},

	renderBandRows() {
		const radios = this.cfg.radios ?? [];
		const st = this.status?.radios ?? {};

		if (!radios.length)
			return E('div', { 'class': 'tw-sub' }, _('No Wi-Fi radios found.'));

		return radios.map((r) => {
			const live = st[r.id] ?? {};
			const channel = live.up && live.channel ? live.channel : (r.channel != 'auto' ? r.channel : null);
			let dot = '', text;

			if (!r.enabled) {
				text = _('Off');
			}
			else {
				dot = live.up ? 'ok' : 'warn';
				text = [
					live.up ? null : _('Starting…'),
					channel ? _('Channel %s').format(channel) + (r.channel == 'auto' ? ' (' + _('automatic') + ')' : '') : _('Automatic channel'),
					(live.up && live.width) ? '%d MHz'.format(live.width) : (r.width ? '%d MHz'.format(r.width) : null),
					r.txpower != null ? '%d dBm'.format(r.txpower) : null
				].filter((x) => x).join(' · ');
			}

			return E('div', { 'class': 'tw-band' }, [
				E('span', { 'class': 'tw-dot ' + dot }),
				E('div', { 'class': 'tw-grow' }, [
					E('div', { 'class': 'tw-band-name' }, r.label),
					E('div', { 'class': 'tw-sub' }, text),
					E('button', { 'class': 'tw-link', click: () => this.showRadioSettings(r) }, [ _('Channel, width and power…') ])
				]),
				switchEl(r.enabled, (ev) => this.handleRadioToggle(r, ev), _('%s on/off').format(r.label))
			]);
		});
	},

	// Describes only the bands this router has.
	bandsHint() {
		const radios = this.cfg.radios ?? [];
		const ghz = { '5g': '5', '6g': '6', '60g': '60' };
		const faster = [ ...new Set(radios.filter((r) => ghz[r.band]).map((r) => ghz[r.band])) ];

		if (radios.length == 1)
			return _('This router has one Wi-Fi band (%s).').format(radios[0].label);

		if (!radios.some((r) => r.band == '2g') || !faster.length)
			return _('Leave all bands on and devices pick the best one.');

		const speed = (faster.length == 1)
			? _('2.4 GHz reaches further, %s GHz is faster at short range.').format(faster[0])
			: _('2.4 GHz reaches further, %s GHz are faster at short range.')
				.format(faster.slice(0, -1).join(', ') + ' ' + _('and') + ' ' + faster[faster.length - 1]);

		return speed + ' ' + ((radios.length == 2)
			? _('Leave both on and devices pick the best one.')
			: _('Leave them all on and devices pick the best one.'));
	},

	renderBands() {
		const cfg = this.cfg;
		const region = E('select', { 'class': 'cbi-input-select', change: (ev) => {
			const c = ev.target.value;

			if (!confirm(_('Change the country to %s? Use the country the router is in: it decides which channels and how much power are legal.').format(c))) {
				ev.target.value = cfg.country ?? '';
				return;
			}

			return this.act(_('Changing country…'), () => callSetRegion(c), { restartsWifi: true });
		} }, [
			cfg.country ? '' : E('option', { value: '', selected: '' }, _('Not set')),
			...(cfg.countries ?? []).map((c) => E('option', { value: c.code, selected: c.code == cfg.country ? '' : null },
				c.code == '00' ? _('World (most restrictive)') : '%s (%s)'.format(c.name, c.code)))
		]);

		this.bandsEl = E('div', {}, this.renderBandRows());

		return E('div', { 'class': 'tw-card' }, [
			E('p', { 'class': 'tw-h' }, '📡 ' + _('Bands')),
			E('div', { 'class': 'tw-sub' }, this.bandsHint()),
			this.bandsEl,
			(cfg.countries ?? []).length ? E('div', { 'class': 'tw-row', style: 'margin-top:12px; flex-wrap:wrap; gap:8px' }, [
				E('span', { 'class': 'tw-sub', style: 'margin:0' }, _('Country')),
				region
			]) : ''
		]);
	},

	/* --- Devices */

	handleKick(c) {
		return this.act(_('Disconnecting %s…').format(c.name ?? c.mac), () => callKick(c.mac, c.ifname));
	},

	handleBlock(c) {
		if (!confirm(_('Block %s? It is disconnected and cannot join any of your Wi-Fi networks until you unblock it.').format(c.name ?? c.mac)))
			return;

		return this.act(_('Blocking %s…').format(c.name ?? c.mac), () => callBlock(c.mac, c.name ?? ''), { restartsWifi: true });
	},

	handleUnblock(b) {
		return this.act(_('Unblocking %s…').format(b.name || b.mac), () => callUnblock(b.mac), { restartsWifi: true });
	},

	renderDevices() {
		const clients = (this.status?.clients ?? []).filter((c) => !c.blocked)
			.sort((a, b) => (a.network == b.network) ? (a.name ?? '~' + a.mac).localeCompare(b.name ?? '~' + b.mac) : (a.network == 'main' ? -1 : 1));
		const blocked = this.cfg.blocked ?? [];
		const label = {};

		(this.cfg.radios ?? []).forEach((r) => label[r.id] = r.label);

		const list = clients.length ? clients.map((c) => E('div', { 'class': 'tw-dev' }, [
			E('div', { 'class': 'tw-dev-main' }, [ signalBars(c.signal), E('div', { 'class': 'tw-grow' }, [
				E('div', { 'class': 'tw-dev-name' }, [
					c.name ?? c.mac,
					c.network == 'guest' ? E('span', { 'class': 'tw-badge guest' }, _('Guest')) : '',
					c.network == 'other' && c.ssid ? E('span', { 'class': 'tw-badge' }, c.ssid) : ''
				]),
				E('div', { 'class': 'tw-sub' }, [
					label[c.radio] ?? c.radio,
					c.ip ? ' · ' + c.ip : '',
					c.name ? ' · ' + c.mac : '',
					' · ', _('connected %s').format(formatDuration(c.connected_time)),
					formatRate(c.rx_rate) ? ' · ↓ ' + formatRate(c.rx_rate) : '',
					formatRate(c.tx_rate) ? ' ↑ ' + formatRate(c.tx_rate) : ''
				])
			]) ]),
			E('div', { 'class': 'tw-actions', style: 'margin-top:0' }, [
				E('button', { 'class': 'btn cbi-button', title: _('Disconnect now; it can reconnect'), click: () => this.handleKick(c) }, [ _('Disconnect') ]),
				E('button', { 'class': 'btn cbi-button cbi-button-negative', title: _('Keep this device off the Wi-Fi'), click: () => this.handleBlock(c) }, [ _('Block') ])
			])
		])) : [ E('div', { 'class': 'tw-sub' }, _('No devices are connected to the Wi-Fi right now.')) ];

		return [
			E('div', { 'class': 'tw-row' }, [
				E('p', { 'class': 'tw-h tw-grow' }, '💻 ' + _('Connected devices') + (clients.length ? ' (%d)'.format(clients.length) : '')),
			]),
			E('div', { style: 'margin-top:8px' }, list),
			blocked.length ? E('div', { style: 'margin-top:16px' }, [
				E('p', { 'class': 'tw-h' }, '⛔ ' + _('Blocked devices')),
				...blocked.map((b) => E('div', { 'class': 'tw-dev' }, [
					E('div', { 'class': 'tw-grow' }, [
						E('div', { 'class': 'tw-dev-name' }, b.name || b.mac),
						b.name ? E('div', { 'class': 'tw-sub tw-mono' }, b.mac) : ''
					]),
					E('div', { 'class': 'tw-actions', style: 'margin-top:0' }, [
						E('button', { 'class': 'btn cbi-button', click: () => this.handleUnblock(b) }, [ _('Unblock') ])
					])
				]))
			]) : ''
		];
	},

	/* --- Schedule */

	renderSchedule() {
		const s = this.cfg.schedule ?? { enabled: false, off: '23:00', on: '07:00', days: DAYS.map((d) => d[0]) };
		const off = E('input', { type: 'time', 'class': 'cbi-input-text', value: s.off, required: '' });
		const on = E('input', { type: 'time', 'class': 'cbi-input-text', value: s.on, required: '' });
		const days = new Set(s.days);
		const saveBtn = E('button', { 'class': 'btn cbi-button cbi-button-save important', click: () => save(enabledNow) }, [ _('Save') ]);
		let enabledNow = s.enabled;

		const dayButtons = DAYS.map(([ id, name ]) => {
			const b = E('button', { 'class': 'tw-day', type: 'button', 'aria-pressed': days.has(id) ? 'true' : 'false', click: () => {
				days.has(id) ? days.delete(id) : days.add(id);
				b.setAttribute('aria-pressed', days.has(id) ? 'true' : 'false');
				validate();
			} }, name);

			return b;
		});

		const hint = E('div', { 'class': 'tw-hint' });
		const validate = () => {
			const ok = /^\d\d:\d\d$/.test(off.value) && /^\d\d:\d\d$/.test(on.value) && off.value != on.value && days.size > 0;

			saveBtn.disabled = !ok;
			hint.className = 'tw-hint' + (ok ? '' : ' bad');
			hint.textContent = !days.size ? _('Pick at least one day')
				: (off.value == on.value) ? _('The off and on times must differ')
				: (off.value > on.value) ? _('Wi-Fi is off overnight, from %s until %s the next morning, starting on the selected days.').format(off.value, on.value)
				: _('Wi-Fi is off from %s until %s on the selected days.').format(off.value, on.value);

			return ok;
		};

		off.addEventListener('input', validate);
		on.addEventListener('input', validate);

		const save = (enabled) => {
			if (enabled && !validate())
				return;

			return this.act(_('Saving schedule…'), () => callSetSchedule(enabled, off.value, on.value, DAYS.map((d) => d[0]).filter((d) => days.has(d))));
		};

		const body = E('div', { style: s.enabled ? '' : 'display:none' }, [
			E('div', { 'class': 'tw-form' }, [
				E('label', {}, _('Off at')), E('div', { 'class': 'tw-times' }, [ off, E('span', { 'class': 'tw-sub', style: 'margin:0' }, _('back on at')), on ]),
				E('label', {}, _('Days')), E('div', {}, [ E('div', { 'class': 'tw-days' }, dayButtons), hint ])
			]),
			E('div', { 'class': 'tw-note info' }, _('Uses the router\'s clock (System → System). Wired devices are not affected.')),
			E('div', { 'class': 'tw-actions' }, saveBtn)
		]);

		validate();

		return E('div', { 'class': 'tw-card' }, [
			E('div', { 'class': 'tw-row' }, [
				E('div', { 'class': 'tw-grow' }, [
					E('p', { 'class': 'tw-h' }, '🌙 ' + _('Schedule')),
					E('div', { 'class': 'tw-sub' }, _('Turn Wi-Fi off at night or during set hours.'))
				]),
				switchEl(s.enabled, (ev) => {
					enabledNow = ev.target.checked;
					body.style.display = enabledNow ? '' : 'none';

					// turning it on waits for Save, turning it off applies right away
					if (!enabledNow && s.enabled)
						return save(false);
				}, _('Schedule'))
			]),
			body
		]);
	},

	/* --- Sharing */

	showQr(net) {
		return callQrcode(net).then(check).then((res) => {
			const keyed = securityInfo(res.encryption).key;
			const pwEl = E('span', { 'class': 'tw-mono' }, '••••••••');
			let shown = false;

			ui.showModal(net == 'guest' ? _('Join the guest network') : _('Join the Wi-Fi'), [
				E('div', { 'class': 'tw tw-qr' }, [
					res.svg
						? E('img', { src: 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(res.svg), alt: _('QR code to join %s').format(res.ssid) })
						: E('div', { 'class': 'tw-note' }, _('Install the "qrencode" package to show a QR code here.')),
					res.svg ? E('div', { 'class': 'tw-sub' }, _('Point the phone\'s camera at the code to join.')) : '',
					E('div', { 'class': 'tw-kv' }, [
						E('div', {}, _('Network')), E('div', { 'class': 'tw-mono' }, res.ssid),
						E('div', {}, _('Password')), keyed ? E('div', {}, [
							pwEl, ' ',
							E('a', { href: '#', click: (ev) => {
								ev.preventDefault();
								shown = !shown;
								pwEl.textContent = shown ? res.key : '••••••••';
								ev.target.textContent = shown ? _('hide') : _('show');
							} }, _('show'))
						]) : E('div', {}, _('none')),
						E('div', {}, _('Security')), E('div', {}, securityInfo(res.encryption).label.replace(/ \(.*\)$/, '')),
						res.hidden ? E('div', {}, _('Hidden')) : '', res.hidden ? E('div', {}, _('yes, enter the name by hand')) : ''
					])
				]),
				E('div', { 'class': 'tw-actions' }, [
					E('button', { 'class': 'btn cbi-button important', click: ui.hideModal }, [ _('Close') ])
				])
			], 'cbi-modal');
		}).catch(notifyError);
	},

	renderContent() {
		this.heroEl = E('div', {}, this.renderHero());
		this.devicesEl = E('div', { 'class': 'tw-card' }, this.renderDevices());

		return [
			this.heroEl,
			(this.cfg.radios ?? []).length ? [
				this.renderMain(),
				this.renderGuest(),
				this.renderBands(),
				this.devicesEl,
				this.renderSchedule()
			] : ''
		].flat();
	},

	render([ cfg, status ]) {
		this.cfg = cfg;
		this.status = status;
		this.root = E('div', { 'class': 'tw' }, this.renderContent());

		poll.add(() => this.refreshStatus(), 5);

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Wi-Fi Setup')),
			E('div', { 'class': 'cbi-map-descr', style: 'margin-bottom:16px' },
				_('Your Wi-Fi name and password, a guest network for visitors, and the devices that are connected.')),
			this.root
		]);
	}
});
