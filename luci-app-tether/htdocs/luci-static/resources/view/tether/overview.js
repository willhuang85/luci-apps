'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

const callStatus = rpc.declare({ object: 'luci.tether', method: 'status' });
const callCheckMain = rpc.declare({ object: 'luci.tether', method: 'check_main' });
const callSetWifi = rpc.declare({ object: 'luci.tether', method: 'set_wifi', params: [ 'ssid', 'key', 'encryption', 'radio' ] });
const callStart = rpc.declare({ object: 'luci.tether', method: 'start', params: [ 'method' ] });
const callStop = rpc.declare({ object: 'luci.tether', method: 'stop' });

// Wi-Fi details come straight from iwinfo, like on LuCI's own pages: iwinfo
// is served by rpcd, which the luci.tether backend runs in, so the backend
// must not call it itself (rpcd would wait for itself).
const callIwinfoInfo = rpc.declare({ object: 'iwinfo', method: 'info', params: [ 'device' ] });
const callIwinfoScan = rpc.declare({ object: 'iwinfo', method: 'scan', params: [ 'device' ], expect: { results: [] } });

const PHONE_SSID = /iphone|ipad|pixel|galaxy|android|oneplus|redmi|xiaomi|motorola|moto [a-z]/i;

const METHODS = {
	usb: { icon: '🔌', title: _('USB cable'), desc: _('Most reliable, and charges the phone. iPhone or Android.') },
	wifi: { icon: '📶', title: _('Wi-Fi hotspot'), desc: _('No cable: the router joins the phone\'s hotspot. Any phone.') }
};

const SECURITY = [
	[ 'sae-mixed', _('WPA2/WPA3 (default on most phones)') ],
	[ 'sae', _('WPA3') ],
	[ 'psk2', _('WPA2') ],
	[ 'none', _('Open (no password)') ]
];

// Check the main internet this often while tethering (seconds).
const CHECK_INTERVAL = 30;

const CSS = `
/* Argon: the theme's own card surface, corners and shadow (light and dark) */
.tt.argon .tt-card { background: var(--surface-color, transparent); border-color: transparent; border-radius: var(--radius-card, 12px);
	box-shadow: var(--section-shadow, none); }
.tt { --tt-ok: #1a9c4a; --tt-warn: #d68b00; --tt-bad: #d23f31; --tt-muted: rgba(127,127,127,.85);
	--tt-line: rgba(127,127,127,.25); --tt-tint: rgba(127,127,127,.07); max-width: 960px; }
.tt * { box-sizing: border-box; }
.tt-card { border: 1px solid var(--tt-line); border-radius: 12px; padding: 20px; margin: 0 0 16px; background: var(--tt-tint); }
.tt-hero { display: flex; align-items: center; gap: 20px; flex-wrap: wrap; }
.tt-orb { width: 64px; height: 64px; border-radius: 50%; flex: none; display: flex; align-items: center; justify-content: center;
	font-size: 30px; color: #fff; background: var(--tt-muted); }
.tt-orb.ok { background: var(--tt-ok); box-shadow: 0 0 0 6px rgba(26,156,74,.18); }
.tt-orb.warn { background: var(--tt-warn); box-shadow: 0 0 0 6px rgba(214,139,0,.18); }
.tt-orb.bad { background: var(--tt-bad); box-shadow: 0 0 0 6px rgba(210,63,49,.18); }
.tt-hero-text { flex: 1 1 240px; min-width: 0; }
.tt-hero-title { font-size: 1.5em; font-weight: 600; line-height: 1.2; overflow-wrap: anywhere; }
.tt-sub { color: var(--tt-muted); margin-top: 4px; overflow-wrap: anywhere; }
.tt-h { font-size: 1.1em; font-weight: 600; margin: 0; }
.tt-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.tt-grow { flex: 1 1 auto; min-width: 0; }
.tt-big { font-size: 1.1em; padding: 10px 22px !important; height: auto !important; line-height: 1.3 !important; }
.tt-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; margin-top: 16px; }
.tt-actions .btn, .tt-actions .cbi-button { margin: 0; }
.tt-note { margin-top: 12px; padding: 10px 12px; border-radius: 8px; border-left: 4px solid var(--tt-warn); background: rgba(214,139,0,.1); }
.tt-note.bad { border-left-color: var(--tt-bad); background: rgba(210,63,49,.1); }
.tt-note.ok { border-left-color: var(--tt-ok); background: rgba(26,156,74,.1); }
.tt-note.info { border-left-color: var(--tt-muted); background: transparent; }
.tt-methods { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px; margin-top: 12px; }
.tt-method { height: auto; line-height: inherit; display: flex; flex-direction: column; text-align: left; border: 2px solid var(--tt-line); border-radius: 10px;
	padding: 12px; background: transparent; color: inherit; cursor: pointer; font: inherit; }
.tt-method:hover { border-color: var(--tt-muted); }
.tt-method.active { border-color: var(--tt-ok); background: rgba(26,156,74,.08); }
.tt-method-title { font-weight: 600; margin-top: 4px; }
.tt-method-icon { font-size: 22px; line-height: 1; }
.tt-steps { list-style: none; margin: 12px 0 0; padding: 0; }
.tt-steps li { display: flex; gap: 10px; align-items: flex-start; padding: 6px 0; }
.tt-step-icon { width: 22px; height: 22px; border-radius: 50%; flex: none; display: inline-flex; align-items: center; justify-content: center;
	font-size: 13px; border: 2px solid var(--tt-line); color: var(--tt-muted); }
.tt-step-icon.ok { background: var(--tt-ok); border-color: var(--tt-ok); color: #fff; }
.tt-step-icon.wait { border-color: var(--tt-warn); color: var(--tt-warn); }
.tt-step-title { font-weight: 600; }
.tt-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 12px; margin-top: 16px; }
.tt-stat { border: 1px solid var(--tt-line); border-radius: 8px; padding: 10px 12px; }
.tt-stat-label { font-size: .8em; color: var(--tt-muted); text-transform: uppercase; letter-spacing: .04em; }
.tt-stat-value { font-size: 1.1em; font-weight: 600; margin-top: 2px; overflow-wrap: anywhere; }
.tt-form { display: grid; grid-template-columns: minmax(120px, max-content) minmax(0, 1fr); gap: 12px 16px; align-items: center; margin-top: 12px; }
.tt-form > label { font-weight: 600; }
.tt-form input, .tt-form select { width: 100%; max-width: 380px; }
.tt-hint { font-size: .85em; color: var(--tt-muted); margin-top: 4px; }
.tt-hint.bad { color: var(--tt-bad); }
.tt-scan { margin-top: 12px; max-height: 260px; overflow-y: auto; }
.tt-scan button { height: auto; line-height: inherit; display: flex; width: 100%; gap: 12px; align-items: center; text-align: left; background: transparent; color: inherit;
	border: 1px solid var(--tt-line); border-radius: 8px; padding: 8px 12px; margin: 0 0 6px; cursor: pointer; font: inherit; }
.tt-scan button:hover { border-color: var(--tt-ok); }
.tt-tips { margin: 8px 0 0 18px; padding: 0; }
.tt-tips li { margin: 4px 0; list-style-type: disc; }
@media (max-width: 600px) {
	.tt-card { padding: 14px; }
	.tt-form { grid-template-columns: 1fr; gap: 6px; }
	.tt-hero .tt-big { width: 100%; }
}
`;

function notifyError(err) {
	ui.addNotification(null, E('p', {}, err?.message ?? String(err)), 'danger');
}

function check(res) {
	if (res?.error)
		throw new Error(res.error);

	return res;
}

function formatBytes(n) {
	if (n == null)
		return '-';

	const units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
	let i = 0;

	n = +n;

	while (n >= 1000 && i < units.length - 1) {
		n /= 1000;
		i++;
	}

	return n.toFixed(i ? 1 : 0) + ' ' + units[i];
}

function formatDuration(sec) {
	if (!sec)
		return '-';

	const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60;

	return h ? '%dh %dm'.format(h, m) : '%dm %ds'.format(m, sec % 60);
}

function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

// Backend status plus whether the router has joined the hotspot.
function loadStatus() {
	return callStatus().then((st) => {
		if (!st.wifi?.sta_ifname)
			return st;

		return L.resolveDefault(callIwinfoInfo(st.wifi.sta_ifname), {}).then((info) => {
			const bssid = info?.bssid ?? '00:00:00:00:00:00';

			st.wifi.connected = bssid != '00:00:00:00:00:00';
			st.wifi.signal = info?.signal ?? null;
			return st;
		});
	});
}

function scanEncryption(e) {
	if (!e?.enabled)
		return 'none';

	const auth = e.authentication ?? [];

	if (auth.includes('owe'))
		return 'owe';

	if (auth.includes('sae'))
		return auth.includes('psk') ? 'sae-mixed' : 'sae';

	return (e.wpa ?? []).includes(1) ? 'psk-mixed' : 'psk2';
}

// Wi-Fi networks seen by the switched on radios, phone hotspots first.
function scanHotspots(st) {
	const own = new Set(st.own_ssids ?? []);
	const best = {};

	return Promise.all((st.radios ?? []).filter((r) => r.enabled).map((r) =>
		L.resolveDefault(callIwinfoScan(r.id), []).then((list) => {
			for (let n of list ?? []) {
				if (!n.ssid || own.has(n.ssid))
					continue;

				const e = {
					ssid: n.ssid,
					signal: n.signal ?? -100,
					channel: n.channel,
					radio: r.id,
					band_label: r.label,
					encryption: scanEncryption(n.encryption),
					phone: PHONE_SSID.test(n.ssid)
				};

				// the same hotspot on two bands: keep the stronger one
				if (!best[n.ssid] || best[n.ssid].signal < e.signal)
					best[n.ssid] = e;
			}
		}))).then(() => Object.values(best).sort((a, b) => (a.phone != b.phone) ? (a.phone ? -1 : 1) : b.signal - a.signal));
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	busy: false,
	mainCheck: null,	// last check_main result
	checking: false,
	lastCheck: 0,

	load() {
		return loadStatus();
	},

	refresh() {
		return loadStatus().then((st) => {
			this.st = st;

			// keep an eye on the main connection while tethering
			if (st.active && Date.now() - this.lastCheck > CHECK_INTERVAL * 1000)
				this.checkMain(true);

			this.redraw();
		});
	},

	redraw() {
		if (!this.busy)
			dom.content(this.root, this.renderContent());
	},

	checkMain(quiet) {
		if (this.checking)
			return Promise.resolve();

		this.checking = true;
		this.lastCheck = Date.now();

		if (!quiet)
			this.redraw();

		return callCheckMain().then((res) => {
			this.mainCheck = res;
		}).catch(() => {
			this.mainCheck = null;
		}).finally(() => {
			this.checking = false;
			this.redraw();
		});
	},

	act(label, fn, wait) {
		if (this.busy)
			return Promise.resolve();

		this.busy = true;
		ui.showModal(null, [ E('p', { 'class': 'spinning' }, label) ]);

		return Promise.resolve().then(fn).then(check)
			.then(() => sleep(wait ?? 3000))
			.then(() => loadStatus().then((st) => { this.st = st; }))
			.catch(notifyError)
			.finally(() => {
				ui.hideModal();
				this.busy = false;
				this.redraw();
			});
	},

	selectedMethod() {
		return this.chosen ?? this.st.method ?? 'usb';
	},

	// Why the chosen method cannot be started yet, or null.
	blocker(method) {
		const st = this.st;

		if (method == 'usb' && !st.usb.supported)
			return _('USB tethering support is not installed on the router.');

		if (method == 'wifi' && !st.wifi.configured)
			return _('Enter the phone\'s hotspot name and password first.');

		return null;
	},

	handleStart(method) {
		const block = this.blocker(method);

		if (block)
			return notifyError(block);

		return this.act(_('Switching to the phone…'), () => callStart(method), method == 'wifi' ? 8000 : 4000);
	},

	handleStop() {
		return this.act(_('Switching back to the main internet…'), () => callStop(), 4000).then(() => this.checkMain(true));
	},

	/* --- Hero */

	tetherState() {
		const st = this.st, m = st.method;
		const t = st[m];

		if (t.up && t.address)
			return 'ok';

		return 'wait';
	},

	renderMainLine() {
		const st = this.st;
		const v4 = st.main.filter((i) => !i.ipv6_only);
		const c = this.mainCheck;
		let text;

		if (this.checking)
			text = _('checking…');
		else if (!c)
			text = v4.some((i) => i.up) ? _('connected, not tested') : _('not connected');
		else if (c.ok)
			text = (c.rtt < 1) ? _('working (<1 ms)') : _('working (%d ms)').format(Math.round(c.rtt));
		else if (c.reason == 'down')
			text = _('not connected');
		else
			text = _('not working (no answer from %s)').format(st.check_host);

		return E('div', { 'class': 'tt-row', style: 'margin-top:4px' }, [
			E('span', { 'class': 'tt-sub', style: 'margin:0' }, _('Main internet (%s): %s').format(v4.map((i) => i.interface).join(', ') || '-', text)),
			E('button', { 'class': 'btn cbi-button', disabled: this.checking ? '' : null, click: () => this.checkMain() }, [ _('Check') ])
		]);
	},

	renderHero() {
		const st = this.st;
		const c = this.mainCheck;

		if (!st.active) {
			const down = c && !c.ok;
			const method = this.selectedMethod();
			const block = this.blocker(method);

			return E('div', { 'class': 'tt-card' }, [
				E('div', { 'class': 'tt-hero' }, [
					E('div', { 'class': 'tt-orb' + (down ? ' bad' : (c?.ok ? ' ok' : '')) }, down ? '✕' : '🌐'),
					E('div', { 'class': 'tt-hero-text' }, [
						E('div', { 'class': 'tt-hero-title' }, down ? _('Your main internet is not working') : _('Using your main internet')),
						this.renderMainLine()
					]),
					E('button', {
						'class': 'btn cbi-button cbi-button-positive important tt-big',
						disabled: block ? '' : null,
						title: block,
						click: () => this.handleStart(method)
					}, [ _('Use phone (%s)').format(METHODS[method].title) ])
				]),
				E('div', { 'class': 'tt-methods' }, Object.keys(METHODS).map((m) => E('button', {
					'class': 'tt-method' + (m == method ? ' active' : ''),
					'aria-pressed': m == method ? 'true' : 'false',
					click: () => { this.chosen = m; this.redraw(); }
				}, [
					E('div', { 'class': 'tt-method-icon' }, METHODS[m].icon),
					E('div', { 'class': 'tt-method-title' }, METHODS[m].title),
					E('div', { 'class': 'tt-sub' }, METHODS[m].desc)
				]))),
				block ? E('div', { 'class': 'tt-note' }, block) : ''
			]);
		}

		const m = st.method, t = st[m], state = this.tetherState();
		const other = (m == 'usb') ? 'wifi' : 'usb';

		return E('div', { 'class': 'tt-card' }, [
			E('div', { 'class': 'tt-hero' }, [
				E('div', { 'class': 'tt-orb ' + state }, state == 'ok' ? '📱' : '…'),
				E('div', { 'class': 'tt-hero-text' }, [
					E('div', { 'class': 'tt-hero-title' }, state == 'ok'
						? _('Internet via %s (%s)').format(this.phoneName(), METHODS[m].title)
						: _('Waiting for the phone (%s)…').format(METHODS[m].title)),
					E('div', { 'class': 'tt-sub' }, state == 'ok'
						? _('All your devices use the phone\'s mobile data. Your main internet stays connected in the background.')
						: (m == 'usb' ? this.usbHint() : this.hotspotHint())),
					this.renderMainLine()
				]),
				E('div', { 'class': 'tt-actions', style: 'margin-top:0; flex-direction:column; align-items:stretch' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-negative important tt-big', click: () => this.handleStop() }, [ _('Back to main internet') ]),
					this.blocker(other) ? '' : E('button', { 'class': 'btn cbi-button', click: () => this.handleStart(other) },
						[ _('Use %s instead').format(METHODS[other].title) ])
				])
			]),
			c?.ok ? E('div', { 'class': 'tt-note ok tt-row' }, [
				E('span', { 'class': 'tt-grow' }, _('Your main internet works again.')),
				E('button', { 'class': 'btn cbi-button cbi-button-action', click: () => this.handleStop() }, [ _('Switch back') ])
			]) : '',
			state == 'ok' ? E('div', { 'class': 'tt-stats' }, [
				this.renderStat(_('Connected for'), formatDuration(t.uptime)),
				this.renderStat(_('Downloaded'), formatBytes(t.rx_bytes)),
				this.renderStat(_('Uploaded'), formatBytes(t.tx_bytes)),
				this.renderStat(_('Address'), t.address ?? '-'),
				m == 'wifi' && t.signal != null ? this.renderStat(_('Signal'), '%d dBm'.format(t.signal)) : ''
			]) : ''
		]);
	},

	renderStat(label, value) {
		return E('div', { 'class': 'tt-stat' }, [
			E('div', { 'class': 'tt-stat-label' }, label),
			E('div', { 'class': 'tt-stat-value' }, value)
		]);
	},

	/* --- USB */

	step(state, title, hint) {
		return E('li', {}, [
			E('span', { 'class': 'tt-step-icon ' + state }, state == 'ok' ? '✓' : (state == 'wait' ? '…' : '')),
			E('div', {}, [ E('div', { 'class': 'tt-step-title' }, title), hint ? E('div', { 'class': 'tt-sub', style: 'margin-top:0' }, hint) : '' ])
		]);
	},

	phoneName() {
		const m = this.st.method;

		return (m == 'usb' && this.st.usb.phone?.name) ? this.st.usb.phone.name : _('phone');
	},

	// What to do on the phone to start USB tethering, for the plugged in kind.
	usbHint() {
		switch (this.st.usb.phone?.kind) {
		case 'iphone':
			return _('Unlock the iPhone, tap "Trust" when it asks about this computer, and turn on Settings → Personal Hotspot → Allow Others to Join.');

		case 'android':
			return _('On the phone, turn on Settings → Network & internet → Hotspot & tethering → USB tethering. Android switches it off when unplugged, so do this every time.');

		default:
			return _('iPhone: unlock it, tap "Trust" and turn on Personal Hotspot. Android: turn on Settings → Network & internet → Hotspot & tethering → USB tethering.');
		}
	},

	hotspotHint() {
		return _('Turn on the phone\'s hotspot (iPhone: Settings → Personal Hotspot, Android: Settings → Network & internet → Hotspot & tethering → Wi-Fi hotspot) and keep that screen open until the router has joined.');
	},

	renderUsb() {
		const u = this.st.usb;
		const live = this.st.active && this.st.method == 'usb';
		const phone = u.phone;
		const install = 'apk update && apk add kmod-usb-net-ipheth usbmuxd kmod-usb-net-cdc-ncm kmod-usb-net-rndis';
		let note = '';

		if (!u.supported || (phone?.kind == 'iphone' && !u.iphone_support) || (phone?.kind == 'android' && !u.android_support))
			note = E('div', { 'class': 'tt-note bad' }, [
				_('The router is missing USB tethering support for this phone. Install it while your internet still works:'),
				E('pre', { style: 'margin:8px 0 0' }, install)
			]);

		const steps = [
			this.step(phone ? 'ok' : 'wait', phone ? _('%s plugged in').format(phone.name) : _('Plug the phone into the router\'s USB port'),
				phone ? null : _('Use a cable that can carry data, not only charge.')),
			this.step(u.carrier ? 'ok' : (phone ? 'wait' : ''), _('Tethering link'), u.carrier ? null : this.usbHint())
		];

		if (live)
			steps.push(this.step(u.up && u.address ? 'ok' : (u.carrier ? 'wait' : ''), _('Internet address'),
				u.address ? '%s'.format(u.address) : null));

		return E('div', { 'class': 'tt-card' }, [
			E('p', { 'class': 'tt-h' }, '🔌 ' + _('USB cable')),
			E('div', { 'class': 'tt-sub' }, _('iPhone or Android. The phone shows up here as soon as it is plugged in; tethering itself starts only when you switch to it.')),
			note,
			E('ul', { 'class': 'tt-steps' }, steps)
		]);
	},

	/* --- Wi-Fi hotspot */

	showWifiEditor() {
		const w = this.st.wifi;
		const radios = this.st.radios.filter((r) => r.enabled);
		const ssid = E('input', { type: 'text', 'class': 'cbi-input-text', maxlength: 32, value: w.ssid ?? '', placeholder: _('e.g. Will\'s iPhone, Pixel 9') });
		const key = E('input', { type: 'password', 'class': 'cbi-input-text', maxlength: 63, value: w.key ?? '', autocomplete: 'off' });
		const enc = E('select', { 'class': 'cbi-input-select' }, SECURITY.map(([ v, l ]) =>
			E('option', { value: v, selected: v == (w.encryption ?? 'sae-mixed') ? '' : null }, l)));
		const radio = E('select', { 'class': 'cbi-input-select' }, radios.map((r) =>
			E('option', { value: r.id, selected: r.id == (w.radio ?? radios.find((x) => x.band == '2g')?.id) ? '' : null }, r.label)));
		const hint = E('div', { 'class': 'tt-hint' });
		const list = E('div', { 'class': 'tt-scan' });
		const saveBtn = E('button', { 'class': 'btn cbi-button cbi-button-save important', click: () => save() }, [ _('Save') ]);
		const keyRow = [ E('label', {}, _('Password')), key ];

		const validate = () => {
			const keyed = enc.value != 'none';
			let err = null;

			keyRow.forEach((el) => el.style.display = keyed ? '' : 'none');

			if (!ssid.value.length)
				err = _('Enter the hotspot name, as shown in the phone\'s hotspot settings');
			else if (keyed && (key.value.length < 8 || key.value.length > 63))
				err = _('The password is shown in the phone\'s hotspot settings');

			hint.textContent = err ?? '';
			hint.className = 'tt-hint' + (err ? ' bad' : '');
			saveBtn.disabled = !!err || !radios.length;

			return !err;
		};

		[ ssid, key ].forEach((el) => el.addEventListener('input', validate));
		enc.addEventListener('change', validate);

		const scan = () => {
			dom.content(list, E('p', { 'class': 'spinning' }, _('Looking for hotspots… keep the hotspot screen open on the phone.')));

			return scanHotspots(this.st).then((results) => {
				if (!results.length)
					return dom.content(list, E('div', { 'class': 'tt-sub' }, _('No networks found. Is Personal Hotspot on?')));

				dom.content(list, results.slice(0, 15).map((n) => E('button', { type: 'button', click: () => {
					ssid.value = n.ssid;
					enc.value = SECURITY.some(([ v ]) => v == n.encryption) ? n.encryption : 'sae-mixed';
					radio.value = n.radio;
					dom.content(list, '');
					validate();
					key.focus();
				} }, [
					E('span', {}, n.phone ? '📱' : '📶'),
					E('span', { 'class': 'tt-grow' }, [ E('strong', {}, n.ssid), E('div', { 'class': 'tt-sub', style: 'margin:0' },
						'%s · %d dBm%s'.format(n.band_label, n.signal, n.encryption == 'none' ? ' · ' + _('open') : '')) ])
				])));
			}).catch((err) => dom.content(list, E('div', { 'class': 'tt-note bad' }, err.message)));
		};

		const save = () => {
			if (!validate())
				return;

			ui.hideModal();

			return this.act(_('Saving…'), () => callSetWifi(ssid.value, enc.value == 'none' ? '' : key.value, enc.value, radio.value),
				this.st.active && this.st.method == 'wifi' ? 8000 : 500);
		};

		ui.showModal(_('Phone hotspot'), [
			E('div', { 'class': 'tt' }, [
				E('div', { 'class': 'tt-row' }, [
					E('div', { 'class': 'tt-sub tt-grow', style: 'margin:0' }, _('Turn on the phone\'s hotspot, then search for it or type its name.')),
					E('button', { 'class': 'btn cbi-button', click: scan }, [ '🔍 ' + _('Search') ])
				]),
				list,
				E('div', { 'class': 'tt-form' }, [
					E('label', {}, _('Hotspot name')), ssid,
					E('label', {}, _('Security')), enc,
					...keyRow,
					E('label', {}, _('Band')), E('div', {}, [
						radio,
						E('div', { 'class': 'tt-hint' }, _('The router\'s own Wi-Fi on this band moves to the phone\'s channel while tethering. iPhones use 2.4 GHz when "Maximize Compatibility" is on; Android lets you pick the band in the hotspot settings.'))
					])
				]),
				hint
			]),
			E('div', { 'class': 'tt-actions' }, [
				E('button', { 'class': 'btn cbi-button', click: ui.hideModal }, [ _('Cancel') ]),
				saveBtn
			])
		], 'cbi-modal');

		validate();

		if (!w.configured)
			scan();
	},

	renderWifi() {
		const w = this.st.wifi;
		const live = this.st.active && this.st.method == 'wifi';
		let body;

		if (!w.configured) {
			body = E('div', { 'class': 'tt-note info tt-row' }, [
				E('span', { 'class': 'tt-grow' }, _('Not set up yet. Set it up now, while you don\'t need it, so it is ready when your internet goes down.')),
				E('button', { 'class': 'btn cbi-button cbi-button-action', click: () => this.showWifiEditor() }, [ _('Set up') ])
			]);
		}
		else {
			const steps = [
				this.step(live ? (w.connected ? 'ok' : 'wait') : '', w.connected ? _('Joined "%s"').format(w.ssid) : _('Join "%s" (%s)').format(w.ssid, w.band_label ?? '?'),
					live && !w.connected ? this.hotspotHint() : null)
			];

			if (live)
				steps.push(this.step(w.up && w.address ? 'ok' : (w.connected ? 'wait' : ''), _('Internet address'), w.address ?? null));

			body = E('div', {}, [
				E('ul', { 'class': 'tt-steps' }, steps),
				w.radio_disabled ? E('div', { 'class': 'tt-note bad' }, _('The %s band is switched off on this router. Turn it on or pick another band.').format(w.band_label)) : '',
				E('div', { 'class': 'tt-actions' }, [
					E('button', { 'class': 'btn cbi-button', click: () => this.showWifiEditor() }, [ _('Change hotspot') ])
				])
			]);
		}

		return E('div', { 'class': 'tt-card' }, [
			E('p', { 'class': 'tt-h' }, '📶 ' + _('Wi-Fi hotspot')),
			E('div', { 'class': 'tt-sub' }, _('The router joins the phone\'s hotspot like a laptop would. Works with any phone.')),
			body
		]);
	},

	renderTips() {
		return E('div', { 'class': 'tt-card' }, [
			E('p', { 'class': 'tt-h' }, '💡 ' + _('Good to know')),
			E('ul', { 'class': 'tt-tips' }, [
				E('li', {}, _('All devices on your network share the phone\'s mobile data; streaming and updates can use a lot of it.')),
				E('li', {}, _('Phones turn their Wi-Fi hotspot off after a while without devices. Over USB, an iPhone stays on while plugged in; Android needs USB tethering switched on again after each plug-in.')),
				E('li', {}, _('Tethering stays on until you switch back, even after a reboot. The router keeps checking your main internet and tells you here when it works again.')),
				E('li', {}, _('Only IPv4 goes through the phone; IPv6 of the main connection is paused meanwhile.'))
			])
		]);
	},

	renderContent() {
		const method = this.st.active ? this.st.method : this.selectedMethod();
		const cards = (method == 'usb') ? [ this.renderUsb(), this.renderWifi() ] : [ this.renderWifi(), this.renderUsb() ];

		return [ this.renderHero(), ...cards, this.renderTips() ];
	},

	render(st) {
		this.st = st;
		this.root = E('div', { 'class': 'tt' + (/\/argon$/.test(L.env.media ?? '') ? ' argon' : '') }, this.renderContent());

		poll.add(() => this.refresh(), 5);
		this.checkMain(true);

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('Phone Tethering')),
			E('div', { 'class': 'cbi-map-descr', style: 'margin-bottom:16px' },
				_('When your main internet is down, use your phone\'s mobile data for the whole network: over a USB cable or the phone\'s Wi-Fi hotspot.')),
			this.root
		]);
	}
});
