'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

const callStatus = rpc.declare({ object: 'luci.wgpasswall', method: 'status' });
const callParse = rpc.declare({ object: 'luci.wgpasswall', method: 'parse', params: [ 'conf' ] });
const callGet = rpc.declare({ object: 'luci.wgpasswall', method: 'get', params: [ 'id' ] });
const callSave = rpc.declare({ object: 'luci.wgpasswall', method: 'save', params: [ 'id', 'label', 'conf', 'connect' ] });
const callRemove = rpc.declare({ object: 'luci.wgpasswall', method: 'remove', params: [ 'id' ] });
const callConnect = rpc.declare({ object: 'luci.wgpasswall', method: 'connect', params: [ 'id' ] });
const callDisconnect = rpc.declare({ object: 'luci.wgpasswall', method: 'disconnect', params: [ 'id' ] });
const callSetKillswitch = rpc.declare({ object: 'luci.wgpasswall', method: 'set_killswitch', params: [ 'enabled' ] });
const callSetMode = rpc.declare({ object: 'luci.wgpasswall', method: 'set_mode', params: [ 'mode', 'node', 'id' ] });
const callReapply = rpc.declare({ object: 'luci.wgpasswall', method: 'reapply' });
const callSetDevices = rpc.declare({ object: 'luci.wgpasswall', method: 'set_devices', params: [ 'scope', 'devices' ] });

const MODE_INFO = {
	vpn: { icon: '🔒', title: _('VPN'), desc: _('All devices use the WireGuard VPN.') },
	vpn_passwall: { icon: '🔀', title: _('VPN through Passwall'), desc: _('The VPN, hidden inside a Passwall proxy connection.') },
	passwall: { icon: '🌐', title: _('Passwall only'), desc: _('No VPN; Passwall proxies your devices.') },
	off: { icon: '⏻', title: _('Off'), desc: _('No VPN and no proxy: your regular internet connection.') }
};

// Mode descriptions while only chosen devices use the VPN
const MODE_DESC_DEVICES = {
	vpn: _('Your chosen devices use the WireGuard VPN.'),
	vpn_passwall: _('Chosen devices: the VPN hidden inside Passwall. Others: Passwall.')
};

// What the backend found out of step with the current mode (status.drift)
const DRIFT_TEXT = {
	pw_settings: _('Passwall\'s settings were changed outside this page (main switch, node or Client Proxy).'),
	pw_acl: _('Passwall\'s rule for the devices that use the VPN is missing or out of date.'),
	fw_rules: _('Firewall rules of this page are saved but not active.'),
	fw_missing: _('Firewall rules of this page were removed.')
};

const MAC_RE = /^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$/;

// A handshake older than this means the peer is not answering anymore.
const HANDSHAKE_TIMEOUT = 180;

const CSS = `
/* Argon: the theme's own card surface, corners and shadow (light and dark) */
.wgc.argon .wgc-card { background: var(--surface-color, transparent); border-color: transparent; border-radius: var(--radius-card, 12px);
	box-shadow: var(--section-shadow, none); }
.wgc { --wgc-ok: #1a9c4a; --wgc-warn: #d68b00; --wgc-bad: #d23f31; --wgc-muted: rgba(127,127,127,.85);
	--wgc-line: rgba(127,127,127,.25); --wgc-tint: rgba(127,127,127,.07); max-width: 960px; }
.wgc * { box-sizing: border-box; }
.wgc-card { border: 1px solid var(--wgc-line); border-radius: 12px; padding: 20px; margin: 0 0 16px; background: var(--wgc-tint); }
.wgc-hero { display: flex; align-items: center; gap: 20px; flex-wrap: wrap; }
.wgc-orb { width: 64px; height: 64px; border-radius: 50%; flex: none; display: flex; align-items: center; justify-content: center;
	font-size: 30px; color: #fff; background: var(--wgc-muted); }
.wgc-orb.ok { background: var(--wgc-ok); box-shadow: 0 0 0 6px rgba(26,156,74,.18); }
.wgc-orb.warn { background: var(--wgc-warn); box-shadow: 0 0 0 6px rgba(214,139,0,.18); }
.wgc-orb.bad { background: var(--wgc-bad); box-shadow: 0 0 0 6px rgba(210,63,49,.18); }
.wgc-hero-text { flex: 1 1 240px; min-width: 0; }
.wgc-hero-title { font-size: 1.5em; font-weight: 600; line-height: 1.2; }
.wgc-sub { color: var(--wgc-muted); margin-top: 4px; overflow-wrap: anywhere; }
.wgc-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 12px; margin-top: 16px; }
.wgc-stat { border: 1px solid var(--wgc-line); border-radius: 8px; padding: 10px 12px; }
.wgc-stat-label { font-size: .8em; color: var(--wgc-muted); text-transform: uppercase; letter-spacing: .04em; }
.wgc-stat-value { font-size: 1.1em; font-weight: 600; margin-top: 2px; overflow-wrap: anywhere; }
.wgc-row { display: flex; align-items: center; gap: 16px; }
.wgc-grow { flex: 1 1 auto; min-width: 0; }
.wgc-h { font-size: 1.1em; font-weight: 600; margin: 0; }
.wgc-switch { position: relative; display: inline-block; width: 52px; height: 30px; flex: none; cursor: pointer; }
.wgc-switch input { position: absolute; opacity: 0; width: 0; height: 0; }
.wgc-slider { position: absolute; inset: 0; border-radius: 30px; background: var(--wgc-muted); transition: background .2s; }
.wgc-slider::before { content: ""; position: absolute; width: 24px; height: 24px; left: 3px; top: 3px; border-radius: 50%;
	background: #fff; transition: transform .2s; box-shadow: 0 1px 3px rgba(0,0,0,.3); }
.wgc-switch input:checked + .wgc-slider { background: var(--wgc-ok); }
.wgc-switch input:checked + .wgc-slider::before { transform: translateX(22px); }
.wgc-switch input:focus-visible + .wgc-slider { outline: 2px solid var(--wgc-ok); outline-offset: 2px; }
.wgc-switch input:disabled + .wgc-slider { opacity: .5; cursor: wait; }
.wgc-note { margin-top: 12px; padding: 10px 12px; border-radius: 8px; border-left: 4px solid var(--wgc-warn); background: rgba(214,139,0,.1); }
.wgc-note.bad { border-left-color: var(--wgc-bad); background: rgba(210,63,49,.1); }
.wgc-note.ok { border-left-color: var(--wgc-ok); background: rgba(26,156,74,.1); }
.wgc-list-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 24px 0 12px; flex-wrap: wrap; }
.wgc-profile { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
.wgc-profile.active { border-color: var(--wgc-ok); box-shadow: inset 4px 0 0 var(--wgc-ok); }
.wgc-list > li { list-style-type: disc; }
.wgc.argon .wgc-profile.active { border-color: var(--wgc-ok); box-shadow: inset 4px 0 0 var(--wgc-ok), var(--section-shadow, none); }
.wgc-dot { width: 12px; height: 12px; border-radius: 50%; background: var(--wgc-muted); flex: none; }
.wgc-dot.ok { background: var(--wgc-ok); } .wgc-dot.warn { background: var(--wgc-warn); } .wgc-dot.bad { background: var(--wgc-bad); }
.wgc-name { font-weight: 600; font-size: 1.05em; overflow-wrap: anywhere; }
.wgc-badge { display: inline-block; font-size: .75em; padding: 1px 8px; border-radius: 10px; margin-left: 8px;
	border: 1px solid var(--wgc-line); vertical-align: middle; font-weight: normal; }
.wgc-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.wgc-actions .btn, .wgc-actions .cbi-button { margin: 0; }
.wgc-modes { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px; margin-top: 12px; }
.wgc-mode { height: auto; line-height: inherit; display: flex; flex-direction: column; justify-content: flex-start; text-align: left; border: 2px solid var(--wgc-line);
	border-radius: 10px; padding: 12px; background: transparent; color: inherit; cursor: pointer; font: inherit; }
.wgc-actions .btn:disabled { opacity: .45; cursor: not-allowed; }
.wgc-mode:hover { border-color: var(--wgc-muted); }
.wgc-mode.active { border-color: var(--wgc-ok); background: rgba(26,156,74,.08); }
.wgc-mode:disabled { opacity: .5; cursor: not-allowed; }
.wgc-mode-title { font-weight: 600; margin-top: 4px; }
.wgc-mode-icon { font-size: 22px; line-height: 1; }
@media (max-width: 600px) { .wgc-modes { grid-template-columns: 1fr 1fr; } }
.wgc-chips { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
.wgc-chip { display: inline-flex; align-items: center; gap: 6px; border: 1px solid var(--wgc-line); border-radius: 16px; padding: 3px 10px; }
.wgc-chip .wgc-dot { width: 8px; height: 8px; }
.wgc-devs { max-height: 50vh; overflow-y: auto; margin-top: 8px; }
.wgc-dev { display: flex; align-items: center; gap: 12px; padding: 8px 4px; border-bottom: 1px solid var(--wgc-line); cursor: pointer; font-weight: normal; }
.wgc-dev > input[type="checkbox"] { position: relative; top: 0; right: 0; margin: 0; flex: none; }
.wgc-drop { border: 2px dashed var(--wgc-line); border-radius: 12px; padding: 32px 16px; text-align: center; cursor: pointer;
	transition: border-color .15s, background .15s; }
.wgc-drop:hover, .wgc-drop.over { border-color: var(--wgc-ok); background: rgba(26,156,74,.06); }
.wgc-drop-icon { font-size: 36px; line-height: 1; margin-bottom: 8px; }
.wgc-modal label.wgc-field { display: block; font-weight: 600; margin: 14px 0 6px; }
.wgc-modal input[type=text], .wgc-modal textarea { width: 100%; }
.wgc-modal textarea { font-family: monospace; font-size: 12px; min-height: 220px; resize: vertical; }
.wgc-preview { margin-top: 12px; min-height: 1.5em; }
.wgc-preview ul { margin: 6px 0 0 18px; padding: 0; }
.wgc-kv { display: grid; grid-template-columns: max-content 1fr; gap: 4px 12px; margin-top: 8px; }
.wgc-kv > div:nth-child(odd) { color: var(--wgc-muted); }
.wgc-kv > div { overflow-wrap: anywhere; }
@media (max-width: 600px) {
	.wgc-card { padding: 14px; }
	.wgc-profile .wgc-actions { width: 100%; }
	.wgc-profile .wgc-actions > * { flex: 1 1 auto; }
}
`;

function formatBytes(n) {
	const units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	let i = 0;

	n = +n || 0;

	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}

	return n.toFixed(i ? 1 : 0) + ' ' + units[i];
}

function formatAge(sec) {
	if (sec == null)
		return _('Never');

	if (sec < 5)
		return _('Just now');

	if (sec < 60)
		return _('%d seconds ago').format(sec);

	if (sec < 3600)
		return _('%d minutes ago').format(Math.floor(sec / 60));

	return _('%d hours ago').format(Math.floor(sec / 3600));
}

function formatUptime(sec) {
	if (!sec)
		return '-';

	const d = Math.floor(sec / 86400), h = Math.floor(sec / 3600) % 24, m = Math.floor(sec / 60) % 60;

	if (d)
		return '%dd %dh %dm'.format(d, h, m);

	if (h)
		return '%dh %dm'.format(h, m);

	return '%dm %ds'.format(m, sec % 60);
}

// Derives a single user facing state for a profile.
function profileState(p) {
	if (p.up && p.handshake_age != null && p.handshake_age < HANDSHAKE_TIMEOUT)
		return { cls: 'ok', text: _('Connected') };

	if (p.up)
		return { cls: 'warn', text: p.latest_handshake ? _('Connection lost, retrying…') : _('Connecting…') };

	if (p.auto && p.pending)
		return { cls: 'warn', text: _('Connecting…') };

	if (p.auto && p.error)
		return { cls: 'bad', text: _('Failed to start (%s)').format(p.error) };

	if (p.auto)
		return { cls: 'warn', text: _('Starting…') };

	return { cls: '', text: _('Disconnected') };
}

function readFile(file) {
	return new Promise((resolve, reject) => {
		if (file.size > 65536)
			return reject(new Error(_('This file is too large to be a WireGuard configuration.')));

		const reader = new FileReader();
		reader.onload = () => resolve(reader.result);
		reader.onerror = () => reject(reader.error);
		reader.readAsText(file);
	});
}

function labelFromFilename(name) {
	return (name || '').replace(/\.(conf|txt)$/i, '').replace(/[_-]+/g, ' ').trim().substring(0, 64);
}

function notifyError(err) {
	ui.addNotification(null, E('p', {}, err?.message ?? String(err)), 'danger');
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	busy: false,

	load() {
		return callStatus();
	},

	refresh() {
		return callStatus().then((data) => {
			this.data = data;

			if (!this.busy)
				dom.content(this.root, this.renderContent(data));
		});
	},

	// Runs an action with all controls disabled and refreshes afterwards.
	act(label, fn) {
		if (this.busy)
			return Promise.resolve();

		this.busy = true;
		this.root.querySelectorAll('button, input').forEach((el) => el.disabled = true);

		if (label)
			ui.showModal(null, [ E('p', { 'class': 'spinning' }, label) ]);

		return Promise.resolve().then(fn).then((res) => {
			if (res?.error)
				throw new Error(res.error);

			return res;
		}).catch(notifyError).finally(() => {
			if (label)
				ui.hideModal();

			this.busy = false;
			return this.refresh();
		});
	},

	handleConnect(p) {
		return this.act(_('Connecting to %s…').format(p.label), () => callConnect(p.id));
	},

	handleDisconnect(p) {
		return this.act(_('Disconnecting from %s…').format(p.label), () => callDisconnect(p.id));
	},

	handleMode(mode) {
		const cur = this.data?.mode ?? 'vpn';
		const node = this.root.querySelector('select[name="wgc-pw-node"]')?.value ?? '';
		let msg = {
			vpn: _('Switch to VPN mode?\n\nPasswall goes back to exactly the settings it had before you first used a Passwall mode, and your last VPN profile connects.'),
			vpn_passwall: _('Switch to "VPN through Passwall"?\n\nPasswall is switched on with the selected node, "Client Proxy" off and "Localhost Proxy" on. WireGuard reaches your VPN server through Passwall\'s SOCKS port via a small relay on the router, with the tunnel MTU at 1280. Traffic from your LAN devices goes through the VPN; the router\'s own traffic and DNS go through Passwall.\n\nYour current Passwall settings are saved and restored when you switch back to VPN mode.'),
			off: _('Turn everything off?\n\nThe VPN is disconnected, Passwall\'s main switch is turned off (its other settings stay as they are) and the kill switch is paused, so your devices use your regular internet connection. Pick another mode to turn things back on.'),
			passwall: _('Switch to "Passwall only"?\n\nThe VPN is disconnected and Passwall proxies your LAN devices and the router itself with the selected node (access control rules for the LAN, "Localhost Proxy" on, default proxy modes set to Proxy). A guest network goes out directly. The kill switch is paused in this mode.\n\nYour current Passwall settings are saved and restored when you switch back to VPN mode.')
		}[mode];

		if (mode == 'vpn_passwall' && this.data?.scope == 'devices')
			msg = _('Switch to "VPN through Passwall"?\n\nPasswall is switched on with the selected node. Your chosen devices go through the VPN, and WireGuard reaches your VPN server through Passwall\'s SOCKS port via a small relay on the router, with the tunnel MTU at 1280. All other LAN devices, and the router itself, are proxied by Passwall directly (access control rules, "Localhost Proxy" on, default proxy modes set to Proxy). A guest network goes out directly.\n\nYour current Passwall settings are saved and restored when you switch back to VPN mode.');

		if (mode == cur || !confirm(msg))
			return;

		return this.act(_('Switching to %s…').format(MODE_INFO[mode].title),
			() => callSetMode(mode, node, this.data?.last_profile ?? ''));
	},

	handleModeNode(ev) {
		const mode = this.data?.mode;

		if (mode != 'vpn_passwall' && mode != 'passwall')
			return;

		return this.act(_('Switching Passwall node…'), () => callSetMode(mode, ev.target.value, ''));
	},

	handleKillswitch(ev) {
		const enabled = ev.target.checked;
		const active = (this.data?.profiles ?? []).some((p) => profileState(p).cls == 'ok');

		if (enabled && !active &&
		    !confirm((this.data?.scope == 'devices')
				? _('No VPN is connected right now. Turning on the kill switch will cut internet access for your chosen devices until a VPN connects. Continue?')
				: _('No VPN is connected right now. Turning on the kill switch will cut internet access for all LAN devices until a VPN connects. Continue?'))) {
			ev.target.checked = false;
			return;
		}

		return this.act(null, () => callSetKillswitch(enabled));
	},

	handleDelete(p) {
		if (!confirm(_('Delete the profile "%s"? This cannot be undone.').format(p.label)))
			return;

		return this.act(_('Deleting %s…').format(p.label), () => callRemove(p.id));
	},

	handleExport(p) {
		return callGet(p.id).then((res) => {
			if (res?.error)
				throw new Error(res.error);

			const blob = new Blob([ res.conf ], { type: 'text/plain' });
			const a = E('a', {
				href: URL.createObjectURL(blob),
				download: (res.label.replace(/[^A-Za-z0-9._-]+/g, '_') || p.id) + '.conf'
			});

			document.body.appendChild(a);
			a.click();
			setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
		}).catch(notifyError);
	},

	handleEdit(p) {
		return callGet(p.id).then((res) => {
			if (res?.error)
				throw new Error(res.error);

			this.showEditor({ id: p.id, label: res.label, conf: res.conf });
		}).catch(notifyError);
	},

	handleFiles(files) {
		const file = files?.[0];

		if (!file)
			return;

		return readFile(file).then((text) => {
			this.showEditor({ label: labelFromFilename(file.name), conf: text });
		}).catch(notifyError);
	},

	pickFile() {
		const input = E('input', { type: 'file', accept: '.conf,.txt,text/plain', style: 'display:none' });

		input.addEventListener('change', () => {
			this.handleFiles(input.files);
			input.remove();
		});

		document.body.appendChild(input);
		input.click();
	},

	// Import / edit dialog: name + raw .conf text with a live validated preview.
	showEditor(opts) {
		const isNew = !opts.id;
		const nameInput = E('input', { type: 'text', 'class': 'cbi-input-text', maxlength: 64,
			placeholder: _('e.g. Home, Office, Mullvad Zurich'), value: opts.label ?? '' });
		const confInput = E('textarea', { 'class': 'cbi-input-textarea', spellcheck: 'false',
			placeholder: '[Interface]\nPrivateKey = …\nAddress = 10.0.0.2/32\nDNS = 10.0.0.1\n\n[Peer]\nPublicKey = …\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = vpn.example.com:51820' }, [ opts.conf ?? '' ]);
		const preview = E('div', { 'class': 'wgc-preview' });
		const buttons = [];
		let valid = false, timer = null, seq = 0;

		const setButtons = () => buttons.forEach((b) => b.disabled = !valid || !nameInput.value.trim());

		const validate = () => {
			const text = confInput.value;
			const mine = ++seq;

			if (!text.trim()) {
				valid = false;
				dom.content(preview, E('div', { 'class': 'wgc-sub' }, _('Paste the contents of your .conf file above or load it from a file.')));
				return setButtons();
			}

			return callParse(text).then((res) => {
				if (mine != seq)
					return;

				valid = !res.error;

				if (res.error) {
					dom.content(preview, E('div', { 'class': 'wgc-note bad' }, [ E('strong', {}, _('Invalid configuration: ')), res.error ]));
				}
				else {
					dom.content(preview, E('div', { 'class': 'wgc-note ok' }, [
						E('strong', {}, '✓ ' + _('Looks good')),
						E('div', { 'class': 'wgc-kv' }, [
							E('div', {}, _('Server')), E('div', {}, res.endpoint ?? _('none')),
							E('div', {}, _('Tunnel address')), E('div', {}, res.addresses.join(', ')),
							E('div', {}, _('DNS')), E('div', {}, res.dns.length ? res.dns.join(', ') : _('not set')),
							E('div', {}, _('Routing')), E('div', {}, res.full_tunnel
								? _('All internet traffic goes through the VPN')
								: _('Only %s through the VPN').format(res.allowed_ips.join(', ') || _('nothing')))
						]),
						res.warnings?.length ? E('ul', { 'class': 'wgc-list' }, res.warnings.map((w) => E('li', {}, w))) : ''
					]));
				}

				setButtons();
			});
		};

		confInput.addEventListener('input', () => {
			clearTimeout(timer);
			timer = setTimeout(validate, 300);
		});
		nameInput.addEventListener('input', setButtons);

		const save = (connect) => {
			const label = nameInput.value.trim();
			const conf = confInput.value;

			let failed = false;

			ui.hideModal();

			return this.act(connect ? _('Saving and connecting…') : _('Saving…'), () =>
				callSave(opts.id ?? '', label, conf, connect).then((res) => {
					failed = !!res?.error;

					if (!failed && res?.warnings?.length)
						ui.addNotification(null, E('div', {}, [
							E('p', {}, _('Profile saved with notes:')),
							E('ul', { 'class': 'wgc-list' }, res.warnings.map((w) => E('li', {}, w)))
						]), 'warning');

					return res;
				}, (err) => { failed = true; throw err; })
			).then(() => {
				// keep the user's input if saving did not work out
				if (failed)
					this.showEditor(Object.assign({}, opts, { label, conf }));
			});
		};

		const loadBtn = E('button', { 'class': 'btn cbi-button', click: (ev) => {
			ev.preventDefault();
			const input = E('input', { type: 'file', accept: '.conf,.txt,text/plain', style: 'display:none' });
			input.addEventListener('change', () => {
				const file = input.files?.[0];
				input.remove();

				if (!file)
					return;

				readFile(file).then((text) => {
					confInput.value = text;

					if (!nameInput.value.trim())
						nameInput.value = labelFromFilename(file.name);

					validate();
				}).catch(notifyError);
			});
			document.body.appendChild(input);
			input.click();
		} }, [ _('Load from file…') ]);

		if (isNew && this.data?.mode != 'passwall' && this.data?.mode != 'off')
			buttons.push(E('button', { 'class': 'btn cbi-button cbi-button-positive', click: () => save(true) }, [ _('Save & connect') ]));

		buttons.push(E('button', { 'class': 'btn cbi-button cbi-button-action' + (isNew ? '' : ' important'), click: () => save(false) }, [ _('Save') ]));

		ui.showModal(isNew ? _('Import WireGuard configuration') : _('Edit %s').format(opts.label), [
			E('div', { 'class': 'wgc wgc-modal' }, [
				E('label', { 'class': 'wgc-field' }, _('Name')),
				nameInput,
				E('div', { 'class': 'wgc-row', style: 'margin-top:14px' }, [
					E('label', { 'class': 'wgc-field wgc-grow', style: 'margin:0' }, _('Configuration')),
					loadBtn
				]),
				E('div', { style: 'margin-top:6px' }, confInput),
				preview
			]),
			E('div', { 'class': 'right', style: 'margin-top:16px; display:flex; gap:8px; justify-content:flex-end; flex-wrap:wrap' }, [
				E('button', { 'class': 'btn cbi-button', click: ui.hideModal }, [ _('Cancel') ]),
				...buttons
			])
		], 'cbi-modal');

		setButtons();
		validate();
		(nameInput.value ? confInput : nameInput).focus();
	},

	renderHero(data) {
		const profiles = data.profiles;
		const live = profiles.find((p) => p.up) ?? profiles.find((p) => p.auto);

		if (data.mode == 'off') {
			return E('div', { 'class': 'wgc-card' }, [
				E('div', { 'class': 'wgc-hero' }, [
					E('div', { 'class': 'wgc-orb' }, '⏻'),
					E('div', { 'class': 'wgc-hero-text' }, [
						E('div', { 'class': 'wgc-hero-title' }, _('Everything is off')),
						E('div', { 'class': 'wgc-sub' }, _('No VPN and no proxy: your devices use your regular internet connection.'))
					])
				])
			]);
		}

		if (data.mode == 'passwall') {
			const pw = data.passwall;
			const node = pw.nodes.find((n) => n.id == pw.node);

			return E('div', { 'class': 'wgc-card' }, [
				E('div', { 'class': 'wgc-hero' }, [
					E('div', { 'class': 'wgc-orb ' + (pw.running ? 'ok' : 'warn') }, pw.running ? '🌐' : '…'),
					E('div', { 'class': 'wgc-hero-text' }, [
						E('div', { 'class': 'wgc-hero-title' }, pw.running ? _('Passwall only') : _('Passwall is starting…')),
						E('div', { 'class': 'wgc-sub' }, _('Your devices go through Passwall (%s). The VPN is off.').format(node?.label ?? _('no node')))
					])
				])
			]);
		}

		if (!live) {
			return E('div', { 'class': 'wgc-card' }, [
				E('div', { 'class': 'wgc-hero' }, [
					E('div', { 'class': 'wgc-orb' + (data.killswitch_active ? ' bad' : '') }, data.killswitch_active ? '⛔' : '⏻'),
					E('div', { 'class': 'wgc-hero-text' }, [
						E('div', { 'class': 'wgc-hero-title' }, _('Not connected')),
						E('div', { 'class': 'wgc-sub' }, data.killswitch_active
							? _('The kill switch is blocking internet access for LAN devices until a VPN connects.')
							: profiles.length
								? _('Your traffic is using your regular internet connection. Pick a profile below to connect.')
								: _('Import a WireGuard configuration file to get started.'))
					])
				])
			]);
		}

		const state = profileState(live);

		return E('div', { 'class': 'wgc-card' }, [
			E('div', { 'class': 'wgc-hero' }, [
				E('div', { 'class': 'wgc-orb ' + state.cls }, state.cls == 'ok' ? '🔒' : '…'),
				E('div', { 'class': 'wgc-hero-text' }, [
					E('div', { 'class': 'wgc-hero-title' }, state.cls == 'ok'
						? _('Connected to %s').format(live.label)
						: '%s — %s'.format(live.label, state.text)),
					E('div', { 'class': 'wgc-sub' }, (data.scope == 'devices')
						? N_(data.settings.devices.length, 'Internet traffic from your chosen device is going through the VPN.', 'Internet traffic from your %d chosen devices is going through the VPN.').format(data.settings.devices.length)
						: live.full_tunnel
							? _('All internet traffic from your network is going through the VPN.')
							: _('Only traffic for %s is going through the VPN.').format(live.allowed_ips.join(', ')))
				]),
				E('button', { 'class': 'btn cbi-button cbi-button-negative', click: ui.createHandlerFn(this, 'handleDisconnect', live) }, [ _('Disconnect') ])
			]),
			E('div', { 'class': 'wgc-stats' }, [
				this.renderStat(_('Server'), live.endpoint ?? '-'),
				this.renderStat(_('Tunnel IP'), live.addresses.join(', ')),
				this.renderStat(_('Last handshake'), formatAge(live.handshake_age)),
				this.renderStat(_('Uptime'), formatUptime(live.uptime)),
				this.renderStat(_('Downloaded'), formatBytes(live.rx_bytes)),
				this.renderStat(_('Uploaded'), formatBytes(live.tx_bytes)),
				data.mode == 'vpn_passwall'
					? this.renderStat(_('Route'), live.proxied === true ? '✓ ' + _('Via Passwall') : live.proxied === false ? '⚠ ' + _('Waiting for Passwall') : _('Starting…'))
					: ''
			])
		]);
	},

	renderStat(label, value) {
		return E('div', { 'class': 'wgc-stat' }, [
			E('div', { 'class': 'wgc-stat-label' }, label),
			E('div', { 'class': 'wgc-stat-value' }, value)
		]);
	},

	renderKillswitch(data) {
		const s = data.settings;
		const connected = data.profiles.some((p) => profileState(p).cls == 'ok');
		let note = '';

		if (data.killswitch_paused)
			note = E('div', { 'class': 'wgc-note' }, data.mode == 'off'
				? _('Paused while everything is off. It comes back when you switch to a VPN mode.')
				: _('Paused while in "Passwall only" mode, because Passwall sends some traffic directly on purpose. It comes back when you switch to a VPN mode.'));
		else if (!data.lan_zone_ok || !data.wan_zone_ok)
			note = E('div', { 'class': 'wgc-note bad' }, _('The kill switch needs the firewall zones "%s" and "%s", but at least one of them does not exist.').format(s.lan_zone, s.wan_zone));
		else if (data.killswitch_active && !connected)
			note = E('div', { 'class': 'wgc-note bad' }, (data.scope == 'devices')
				? _('No VPN is connected, so your chosen devices currently have no internet access.')
				: _('No VPN is connected, so LAN devices currently have no internet access.'));
		else if (data.killswitch_active)
			note = E('div', { 'class': 'wgc-note ok' }, (data.scope == 'devices')
				? _('Protected: if the VPN drops, your chosen devices are cut off instead of leaking traffic.')
				: _('Protected: if the VPN drops, LAN devices are cut off instead of leaking traffic.'));

		return E('div', { 'class': 'wgc-card' }, [
			E('div', { 'class': 'wgc-row' }, [
				E('div', { 'class': 'wgc-grow' }, [
					E('p', { 'class': 'wgc-h' }, '🛡 ' + _('Kill switch')),
					E('div', { 'class': 'wgc-sub' }, (data.scope == 'devices')
						? _('Block internet traffic from your chosen devices that does not go through the VPN.')
						: _('Block all internet traffic from LAN devices that does not go through the VPN.'))
				]),
				E('label', { 'class': 'wgc-switch', title: _('Kill switch') }, [
					E('input', {
						type: 'checkbox',
						role: 'switch',
						'aria-label': _('Kill switch'),
						checked: s.killswitch ? '' : null,
						change: ui.createHandlerFn(this, 'handleKillswitch')
					}),
					E('span', { 'class': 'wgc-slider' })
				])
			]),
			note
		]);
	},

	// Mode picker: VPN / VPN through Passwall / Passwall only.
	renderMode(data) {
		const pw = data.passwall;
		const mode = data.mode ?? 'vpn';
		const live = data.profiles.find((p) => p.up);
		let note = '';

		if (!pw.nodes.length) {
			note = E('div', { 'class': 'wgc-note' }, [
				_('Add a node in Passwall to use the Passwall modes. '),
				E('a', { href: L.url('admin/services/passwall') }, _('Open Passwall'))
			]);
		}
		else if ((mode == 'vpn_passwall' || mode == 'passwall') && !pw.running) {
			note = E('div', { 'class': 'wgc-note' }, _('Passwall is starting… this can take up to a minute.'));
		}
		else if (mode == 'vpn_passwall' && live?.proxied === true) {
			note = E('div', { 'class': 'wgc-note ok' }, _('Wrapped: WireGuard reaches the VPN server through Passwall.'));
		}
		else if (mode == 'vpn_passwall' && live?.proxied === false) {
			note = E('div', { 'class': 'wgc-note bad' }, _('Waiting for Passwall: the relay cannot use Passwall\'s SOCKS port yet. It retries every few seconds; if this stays, check that Passwall is running and that its node supports UDP.'));
		}
		else if (mode == 'vpn_passwall' && live) {
			note = E('div', { 'class': 'wgc-note' }, _('Starting the relay…'));
		}

		const buttons = Object.keys(MODE_INFO).map((m) => E('button', {
			'class': 'wgc-mode' + (m == mode ? ' active' : ''),
			'aria-pressed': (m == mode) ? 'true' : 'false',
			disabled: ((m == 'vpn_passwall' || m == 'passwall') && !pw.nodes.length) ? '' : null,
			click: () => this.handleMode(m)
		}, [
			E('div', { 'class': 'wgc-mode-icon' }, MODE_INFO[m].icon),
			E('div', { 'class': 'wgc-mode-title' }, MODE_INFO[m].title),
			E('div', { 'class': 'wgc-sub' }, ((data.scope == 'devices') ? MODE_DESC_DEVICES[m] : null) ?? MODE_INFO[m].desc)
		]));

		const nodeSelect = E('select', {
			'class': 'cbi-input-select',
			name: 'wgc-pw-node',
			style: 'max-width:100%',
			change: ui.createHandlerFn(this, 'handleModeNode')
		}, pw.nodes.map((n) => E('option', { value: n.id, selected: (n.id == pw.node) ? '' : null }, n.label)));

		return E('div', { 'class': 'wgc-card' }, [
			E('p', { 'class': 'wgc-h' }, _('Mode')),
			E('div', { 'class': 'wgc-modes' }, buttons),
			pw.nodes.length ? E('div', { 'class': 'wgc-row', style: 'margin-top:12px; flex-wrap:wrap; gap:8px' }, [
				E('span', { 'class': 'wgc-sub', style: 'margin:0' }, _('Passwall node')),
				nodeSelect
			]) : '',
			note
		]);
	},

	// Who uses the VPN: all devices or only chosen ones (by MAC address).
	renderDevices(data) {
		const chosen = data.settings.devices ?? [];
		const scope = data.scope;
		const seen = {};
		let others = '';

		(data.lan_devices ?? []).forEach((d) => seen[d.mac] = d);

		let dns = '';

		if (data.mode == 'vpn' || data.mode == 'vpn_passwall')
			dns = data.vpn_dns
				? _('Their DNS goes to the VPN\'s DNS server (%s) through the tunnel.').format([ data.vpn_dns.v4, data.vpn_dns.v6 ].filter((a) => a).join(', '))
				: data.profiles.some((p) => p.auto)
					? _('The VPN profile has no DNS server, so their DNS goes to the router\'s DNS servers outside the VPN.')
					: '';

		if (scope == 'devices')
			others = (data.mode == 'vpn_passwall')
				? _('All other devices go through Passwall, without the VPN.')
				: (data.mode == 'vpn')
					? _('All other devices use your regular internet connection.')
					: _('This applies in the VPN modes.');

		const tile = (s, icon, title, desc) => E('button', {
			'class': 'wgc-mode' + (s == scope ? ' active' : ''),
			'aria-pressed': (s == scope) ? 'true' : 'false',
			click: () => (s == 'devices') ? this.showDevices() : this.handleScopeAll()
		}, [
			E('div', { 'class': 'wgc-mode-icon' }, icon),
			E('div', { 'class': 'wgc-mode-title' }, title),
			E('div', { 'class': 'wgc-sub' }, desc)
		]);

		return E('div', { 'class': 'wgc-card' }, [
			E('p', { 'class': 'wgc-h' }, _('Devices using the VPN')),
			E('div', { 'class': 'wgc-modes' }, [
				tile('all', '🏠', _('All devices'), _('Every device on your network.')),
				tile('devices', '💻', _('Only chosen devices'), _('For example your work laptops. Picked by their hardware (MAC) address.'))
			]),
			(scope == 'devices') ? E('div', { 'class': 'wgc-chips' }, [
				...chosen.map((mac) => E('span', { 'class': 'wgc-chip', title: mac }, [
					E('span', { 'class': 'wgc-dot' + (seen[mac] ? ' ok' : ''), title: seen[mac] ? _('On the network') : _('Not seen on the network right now') }),
					seen[mac]?.name ?? mac
				])),
				E('button', { 'class': 'btn cbi-button', click: () => this.showDevices() }, [ _('Change…') ])
			]) : '',
			dns ? E('div', { 'class': 'wgc-sub', style: 'margin-top:10px' }, dns) : '',
			data.ipv6_blocked ? E('div', { 'class': 'wgc-sub', style: 'margin-top:10px' },
				_('Their IPv6 internet traffic is blocked: the VPN profile only carries IPv4, so IPv6 would go around the VPN. Apps use IPv4 instead.')) : '',
			others ? E('div', { 'class': 'wgc-sub', style: 'margin-top:10px' }, others) : ''
		]);
	},

	handleReapply() {
		if (!confirm(_('Apply the current mode again?\n\nThe Passwall settings this mode uses, the routing and the firewall rules are set again; then the firewall reloads and, in the Passwall modes, Passwall restarts. Proxied devices lose the connection for a few seconds.')))
			return;

		return this.act(_('Reapplying settings…'), () => callReapply());
	},

	// Shown when something no longer matches what the current mode set up.
	renderDrift(data) {
		const issues = (data.drift ?? []).filter((d) => DRIFT_TEXT[d]);

		if (!issues.length)
			return '';

		return E('div', { 'class': 'wgc-card' }, [
			E('div', { 'class': 'wgc-row', style: 'flex-wrap:wrap' }, [
				E('div', { 'class': 'wgc-grow' }, [
					E('p', { 'class': 'wgc-h' }, '⚠ ' + _('Settings out of step')),
					E('ul', { 'class': 'wgc-list', style: 'margin:6px 0 0 18px; padding:0' }, issues.map((d) => E('li', {}, DRIFT_TEXT[d])))
				]),
				E('button', { 'class': 'btn cbi-button cbi-button-action important', click: ui.createHandlerFn(this, 'handleReapply') }, [ _('Reapply settings') ])
			])
		]);
	},

	handleScopeAll() {
		if (this.data?.scope != 'devices')
			return;

		if (!confirm(_('Use the VPN for all devices on your network again?')))
			return;

		return this.act(_('Saving…'), () => callSetDevices('all', this.data.settings.devices ?? []));
	},

	// Picker for the devices that use the VPN.
	showDevices() {
		const chosen = new Set(this.data?.settings?.devices ?? []);
		const devs = {};

		(this.data?.lan_devices ?? []).forEach((d) => devs[d.mac] = d);
		chosen.forEach((mac) => devs[mac] ??= { mac, ip: null, name: null, away: true });

		const list = E('div', { 'class': 'wgc-devs' });
		const saveBtn = E('button', { 'class': 'btn cbi-button cbi-button-positive important' }, [ _('Save') ]);
		const update = () => saveBtn.disabled = !chosen.size;

		const renderList = () => {
			const rows = Object.values(devs).sort((a, b) =>
				(chosen.has(b.mac) - chosen.has(a.mac)) || (a.name ?? '~' + a.mac).localeCompare(b.name ?? '~' + b.mac));

			dom.content(list, rows.length ? rows.map((d) => {
				const cb = E('input', { type: 'checkbox', checked: chosen.has(d.mac) ? '' : null });

				cb.addEventListener('change', () => { cb.checked ? chosen.add(d.mac) : chosen.delete(d.mac); update(); });

				return E('label', { 'class': 'wgc-dev' }, [
					cb,
					E('div', { 'class': 'wgc-grow' }, [
						E('div', { style: 'font-weight:600' }, d.name ?? _('Unnamed device')),
						E('div', { 'class': 'wgc-sub', style: 'margin:0' }, [ d.ip ?? _('not on the network right now'), ' · ', d.mac ])
					])
				]);
			}) : E('div', { 'class': 'wgc-sub' }, _('No devices found on your network. Add one by its MAC address below.')));
		};

		const macInput = E('input', { type: 'text', 'class': 'cbi-input-text', placeholder: 'AA:BB:CC:DD:EE:FF', style: 'flex:1 1 180px; min-width:0' });
		const addMac = (ev) => {
			ev?.preventDefault();
			const mac = macInput.value.trim().toUpperCase().replace(/-/g, ':');

			if (!MAC_RE.test(mac))
				return ui.addNotification(null, E('p', {}, _('Enter a MAC address like AA:BB:CC:DD:EE:FF.')), 'warning');

			devs[mac] ??= { mac, ip: null, name: null };
			chosen.add(mac);
			macInput.value = '';
			renderList();
			update();
		};

		macInput.addEventListener('keydown', (ev) => { if (ev.key == 'Enter') addMac(ev); });

		saveBtn.addEventListener('click', () => {
			const devices = [ ...chosen ];

			ui.hideModal();
			return this.act(_('Saving…'), () => callSetDevices('devices', devices));
		});

		ui.showModal(_('Devices using the VPN'), [
			E('div', { 'class': 'wgc wgc-modal' }, [
				E('div', { 'class': 'wgc-sub' }, (this.data?.mode == 'vpn_passwall')
					? _('The devices you tick go through the VPN; all others go through Passwall without the VPN.')
					: _('The devices you tick go through the VPN; all others use your regular internet connection.')),
				list,
				E('div', { 'class': 'wgc-row', style: 'margin-top:12px; flex-wrap:wrap; gap:8px' }, [
					macInput,
					E('button', { 'class': 'btn cbi-button cbi-button-add', click: addMac }, [ _('Add') ])
				]),
				E('div', { 'class': 'wgc-sub', style: 'margin-top:10px; font-size:.9em' }, _('Wired devices always keep their hardware address. Phones and laptops on Wi-Fi use a private address per network that stays the same, unless set to change ("Rotating" on Apple devices, "Change daily" on Windows) or you forget and rejoin the network. A device behind another router shows up with that router\'s address.'))
			]),
			E('div', { 'class': 'right', style: 'margin-top:16px; display:flex; gap:8px; justify-content:flex-end; flex-wrap:wrap' }, [
				E('button', { 'class': 'btn cbi-button', click: ui.hideModal }, [ _('Cancel') ]),
				saveBtn
			])
		], 'cbi-modal');

		renderList();
		update();
	},

	// Shown when a transparent proxy app is installed next to this one.
	renderProxyInfo(data) {
		if (data.passwall?.installed)
			return this.renderMode(data);

		const apps = data.proxy_apps ?? [];

		if (!apps.length)
			return '';

		return E('div', { 'class': 'wgc-card' }, [
			E('p', { 'class': 'wgc-h' }, '🔀 ' + _('Works with %s').format(apps.join(', '))),
			E('div', { 'class': 'wgc-sub' }, _('The VPN uses its own routing table, so the proxy keeps working side by side:')),
			E('ul', { 'class': 'wgc-list', style: 'margin:8px 0 0 18px; padding:0' }, [
				E('li', {}, _('Connections made by the proxy core (Xray / sing-box) bypass the VPN, so they never loop into the tunnel.')),
				E('li', {}, _('Install Passwall to also get the "VPN through Passwall" and "Passwall only" modes.'))
			])
		]);
	},

	renderProfile(p) {
		const state = profileState(p);
		const isOn = p.up || p.auto;
		const noVpn = this.data?.mode == 'passwall' || this.data?.mode == 'off';

		return E('div', { 'class': 'wgc-card wgc-profile' + (isOn ? ' active' : '') }, [
			E('span', { 'class': 'wgc-dot ' + state.cls, title: state.text }),
			E('div', { 'class': 'wgc-grow' }, [
				E('div', { 'class': 'wgc-name' }, [
					p.label,
					E('span', { 'class': 'wgc-badge' }, p.full_tunnel ? _('Full tunnel') : _('Split tunnel'))
				]),
				E('div', { 'class': 'wgc-sub' }, [
					state.text, ' · ', p.endpoint ?? _('no server'), ' · ', p.addresses.join(', ')
				])
			]),
			E('div', { 'class': 'wgc-actions' }, [
				isOn
					? E('button', { 'class': 'btn cbi-button cbi-button-negative', click: ui.createHandlerFn(this, 'handleDisconnect', p) }, [ _('Disconnect') ])
					: E('button', {
						'class': 'btn cbi-button cbi-button-positive',
						disabled: noVpn ? '' : null,
						title: noVpn ? _('Pick a VPN mode in the Mode card to connect') : null,
						click: ui.createHandlerFn(this, 'handleConnect', p)
					}, [ _('Connect') ]),
				E('button', { 'class': 'btn cbi-button', title: _('Edit'), click: ui.createHandlerFn(this, 'handleEdit', p) }, [ _('Edit') ]),
				E('button', { 'class': 'btn cbi-button', title: _('Download .conf'), click: ui.createHandlerFn(this, 'handleExport', p) }, [ _('Export') ]),
				E('button', { 'class': 'btn cbi-button cbi-button-remove', title: _('Delete'), click: ui.createHandlerFn(this, 'handleDelete', p) }, [ _('Delete') ])
			])
		]);
	},

	renderDropZone(big) {
		const zone = E('div', {
			'class': 'wgc-drop',
			role: 'button',
			tabindex: 0,
			click: () => this.pickFile(),
			keydown: (ev) => { if (ev.key == 'Enter' || ev.key == ' ') { ev.preventDefault(); this.pickFile(); } }
		}, [
			E('div', { 'class': 'wgc-drop-icon' }, '📄'),
			E('div', { 'class': 'wgc-h' }, big ? _('Import your first WireGuard configuration') : _('Drop a .conf file here')),
			E('div', { 'class': 'wgc-sub' }, _('Drag and drop a .conf file from your VPN provider, or click to choose one.')),
			E('div', { style: 'margin-top:12px' }, [
				E('button', { 'class': 'btn cbi-button', click: (ev) => { ev.stopPropagation(); this.showEditor({}); } }, [ _('Paste configuration instead') ])
			])
		]);

		zone.addEventListener('dragover', (ev) => { ev.preventDefault(); zone.classList.add('over'); });
		zone.addEventListener('dragleave', () => zone.classList.remove('over'));
		zone.addEventListener('drop', (ev) => {
			ev.preventDefault();
			zone.classList.remove('over');
			this.handleFiles(ev.dataTransfer?.files);
		});

		return zone;
	},

	renderContent(data) {
		const profiles = data.profiles ?? [];

		return [
			this.renderHero(data),
			this.renderDrift(data),
			this.renderKillswitch(data),
			this.renderProxyInfo(data),
			profiles.length ? this.renderDevices(data) : '',
			E('div', { 'class': 'wgc-list-head' }, [
				E('p', { 'class': 'wgc-h' }, _('VPN profiles')),
				profiles.length ? E('button', { 'class': 'btn cbi-button cbi-button-add', click: () => this.showEditor({}) }, [ '+ ' + _('Import') ]) : ''
			]),
			...profiles.map((p) => this.renderProfile(p)),
			this.renderDropZone(!profiles.length),
			E('div', { 'class': 'wgc-row', style: 'justify-content:flex-end; flex-wrap:wrap; gap:8px; margin-top:16px' }, [
				E('span', { 'class': 'wgc-sub', style: 'margin:0' }, _('Changed something in Passwall or the firewall?')),
				E('button', { 'class': 'btn cbi-button', click: ui.createHandlerFn(this, 'handleReapply') }, [ _('Reapply settings') ])
			])
		];
	},

	render(data) {
		this.data = data;
		this.root = E('div', { 'class': 'wgc' + (/\/argon$/.test(L.env.media ?? '') ? ' argon' : '') }, this.renderContent(data));

		poll.add(() => this.refresh(), 5);

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('WireGuard + Passwall')),
			E('div', { 'class': 'cbi-map-descr', style: 'margin-bottom:16px' }, _('Connect your whole network to a WireGuard VPN, optionally carried through a Passwall proxy node. Import the configuration file from your VPN provider, pick a mode and connect.')),
			this.root
		]);
	}
});
