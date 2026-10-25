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
const callSetOptions = rpc.declare({ object: 'luci.wgpasswall', method: 'set_options', params: [ 'killswitch', 'via_passwall' ] });
const callSetPorts = rpc.declare({ object: 'luci.wgpasswall', method: 'set_ports', params: [ 'ports' ] });
const callReapply = rpc.declare({ object: 'luci.wgpasswall', method: 'reapply' });

// The networks a wired port or Wi-Fi network can be on (status.networks)
const NETWORKS = {
	lan: { icon: '🏠', title: _('Home network'), desc: _('Your regular internet connection, no VPN.') },
	vpn: { icon: '🔒', title: _('VPN network'), desc: _('Through the VPN.') },
	proxy: { icon: '🌐', title: _('Passwall network'), desc: _('Through Passwall.') }
};

// What the backend found out of step with the settings (status.drift)
const DRIFT_TEXT = {
	pw_settings: _('Passwall\'s settings were changed outside this page (main switch, Client Proxy, access control or proxy modes).'),
	pw_acl: _('Passwall\'s access control rule for the Passwall network is missing or out of date.'),
	fw_rules: _('Firewall rules of this page are saved but not active.'),
	fw_missing: _('The VPN network, its firewall zone or other firewall rules of this page were removed.')
};

// The status format this page reads (status.api); a different one means
// the app was updated and the browser still runs a cached copy of the page
const API_VERSION = 2;

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
.wgc-actions .btn:disabled { opacity: .45; cursor: not-allowed; }
.wgc-nets { margin-top: 12px; }
.wgc-net { display: flex; gap: 14px; padding: 14px 0; border-top: 1px solid var(--wgc-line); }
.wgc-net:first-child { border-top: 0; padding-top: 4px; }
.wgc-net-icon { font-size: 22px; line-height: 1.2; flex: none; width: 28px; text-align: center; }
.wgc-net-title { font-weight: 600; }
.wgc-net-title .wgc-badge { margin-left: 6px; }
.wgc-badge.ok { border-color: var(--wgc-ok); color: var(--wgc-ok); }
.wgc-badge.warn { border-color: var(--wgc-warn); color: var(--wgc-warn); }
.wgc-badge.bad { border-color: var(--wgc-bad); color: var(--wgc-bad); }
.wgc-chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
.wgc-chip { display: inline-flex; align-items: center; gap: 6px; border: 1px solid var(--wgc-line); border-radius: 16px; padding: 2px 10px; font-size: .9em; }
.wgc-chip.none { border-style: dashed; color: var(--wgc-muted); }
.wgc-opt { display: flex; align-items: center; gap: 16px; padding: 14px 0; border-top: 1px solid var(--wgc-line); }
.wgc-opt:first-of-type { border-top: 0; padding-top: 4px; }
.wgc-ports { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 10px 16px; align-items: center; margin-top: 12px; }
.wgc-ports select { width: 100%; max-width: 320px; }
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

// Adds "PersistentKeepalive = <sec>" to every [Peer] section of a .conf
// text that has none, at the end of the section.
function addKeepalive(text, sec) {
	const lines = text.replace(/\r\n/g, '\n').split('\n');
	const out = [];
	let inPeer = false, has = false;

	const close = () => {
		if (!inPeer || has)
			return;

		// before the trailing blank lines of the section
		let i = out.length;

		while (i > 0 && out[i - 1].trim() == '')
			i--;

		out.splice(i, 0, 'PersistentKeepalive = %d'.format(sec));
	};

	for (const line of lines) {
		const section = line.match(/^\s*\[([^\]]+)\]/);

		if (section) {
			close();
			inPeer = section[1].trim().toLowerCase() == 'peer';
			has = false;
		}
		else if (inPeer && /^\s*PersistentKeepalive\s*=/i.test(line)) {
			has = true;
		}

		out.push(line);
	}

	close();

	return out.join('\n');
}

// "lan2" -> "LAN 2"
function portLabel(name) {
	const m = /^lan([0-9]*)$/i.exec(name ?? '');

	return m ? (m[1] ? _('LAN %s').format(m[1]) : _('LAN')) : name;
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

	handleKillswitch(ev) {
		const enabled = ev.target.checked;
		const d = this.data;
		const active = (d?.profiles ?? []).some((p) => profileState(p).cls == 'ok');
		const used = d?.networks?.vpn?.ports?.length || d?.networks?.vpn?.ssids?.length;

		if (enabled && !active && used &&
		    !confirm(_('No VPN is connected right now. With the kill switch on, devices on the VPN network have no internet access until a VPN connects. Continue?'))) {
			ev.target.checked = false;
			return;
		}

		return this.act(null, () => callSetOptions(enabled));
	},

	handleViaPasswall(ev) {
		const on = ev.target.checked;
		const msg = on
			? _('Carry the VPN through Passwall?\n\nWireGuard then reaches your VPN server through the node selected in Passwall (via a small relay on the router, with the tunnel MTU at 1280), which hides from your internet provider that you use a VPN. Passwall runs while the VPN is connected, and the router\'s own traffic goes out directly instead of through the VPN.')
			: _('Connect the VPN directly again?\n\nWireGuard then reaches your VPN server directly, and the router\'s own traffic goes through the VPN while it is connected.');

		if (!confirm(msg)) {
			ev.target.checked = !on;
			return;
		}

		return this.act(on ? _('Carrying the VPN through Passwall…') : _('Connecting the VPN directly…'), () => callSetOptions(undefined, on));
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

					if (res.keepalive_missing)
						preview.appendChild(E('div', { 'class': 'wgc-note' }, [
							E('div', {}, _('No PersistentKeepalive: behind NAT or a proxy (VPN carried through Passwall), an idle tunnel can go quiet and stall. 15 seconds stays well inside the shortest UDP timeouts (about 30 seconds), even if one keepalive is lost.')),
							E('button', { 'class': 'btn cbi-button', style: 'margin-top:8px', click: (ev) => {
								ev.preventDefault();
								confInput.value = addKeepalive(confInput.value, 15);
								validate();
							} }, [ _('Add PersistentKeepalive = 15') ])
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

		if (isNew)
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
		const vpnNet = data.networks?.vpn ?? {};
		const empty = !vpnNet.ports?.length && !vpnNet.ssids?.length;

		if (!live) {
			let sub;

			if (!profiles.length)
				sub = _('Import a WireGuard configuration file to get started.');
			else if (empty)
				sub = _('Connect a profile below, and put devices on the VPN network (Networks).');
			else if (data.killswitch_active)
				sub = _('The kill switch keeps devices on the VPN network offline until a VPN connects.');
			else
				sub = _('Devices on the VPN network use your regular internet connection until a VPN connects.');

			return E('div', { 'class': 'wgc-card' }, [
				E('div', { 'class': 'wgc-hero' }, [
					E('div', { 'class': 'wgc-orb' + ((data.killswitch_active && !empty) ? ' bad' : '') }, (data.killswitch_active && !empty) ? '⛔' : '⏻'),
					E('div', { 'class': 'wgc-hero-text' }, [
						E('div', { 'class': 'wgc-hero-title' }, _('VPN not connected')),
						E('div', { 'class': 'wgc-sub' }, sub)
					])
				])
			]);
		}

		const state = profileState(live);
		let sub;

		if (empty)
			sub = _('Nothing is on the VPN network yet: put a wired port or Wi-Fi network on it (Networks).');
		else if (!live.full_tunnel)
			sub = _('Devices on the VPN network send traffic for %s through the VPN.').format(live.allowed_ips.join(', '));
		else if (data.via_passwall)
			sub = _('Devices on the VPN network go through the VPN, carried through Passwall.');
		else if (data.router == 'vpn')
			sub = _('Devices on the VPN network, and the router itself, go through the VPN.');
		else
			sub = _('Devices on the VPN network go through the VPN.');

		return E('div', { 'class': 'wgc-card' }, [
			E('div', { 'class': 'wgc-hero' }, [
				E('div', { 'class': 'wgc-orb ' + state.cls }, state.cls == 'ok' ? '🔒' : '…'),
				E('div', { 'class': 'wgc-hero-text' }, [
					E('div', { 'class': 'wgc-hero-title' }, state.cls == 'ok'
						? _('Connected to %s').format(live.label)
						: '%s — %s'.format(live.label, state.text)),
					E('div', { 'class': 'wgc-sub' }, sub)
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
				data.via_passwall
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

	// Where devices go: the networks with their wired ports and Wi-Fi networks.
	renderNetworks(data) {
		const nets = data.networks ?? {};
		const pw = data.passwall ?? {};
		const live = data.profiles.find((p) => p.up) ?? data.profiles.find((p) => p.auto);

		const members = (n) => {
			const chips = [
				...(n.ports ?? []).map((p) => E('span', { 'class': 'wgc-chip', title: _('Wired port') }, [ '🔌 ', portLabel(p) ])),
				...(n.ssids ?? []).map((ssid) => E('span', { 'class': 'wgc-chip', title: _('Wi-Fi network') }, [ '📶 ', ssid ]))
			];

			return E('div', { 'class': 'wgc-chips' }, chips.length ? chips
				: [ E('span', { 'class': 'wgc-chip none' }, _('No ports or Wi-Fi networks')) ]);
		};

		const row = (key, badge, desc, extra) => {
			const n = nets[key] ?? {};

			return E('div', { 'class': 'wgc-net' }, [
				E('div', { 'class': 'wgc-net-icon' }, NETWORKS[key].icon),
				E('div', { 'class': 'wgc-grow' }, [
					E('div', { 'class': 'wgc-net-title' }, [ NETWORKS[key].title, badge ?? '' ]),
					E('div', { 'class': 'wgc-sub' }, [ desc, n.subnet ? ' · ' + n.subnet : '' ]),
					members(n),
					extra ?? ''
				])
			]);
		};

		const badge = (cls, text) => E('span', { 'class': 'wgc-badge ' + cls }, text);
		const vpnState = live ? profileState(live) : null;
		const rows = [
			row('lan', null, NETWORKS.lan.desc),
			row('vpn',
				vpnState?.cls == 'ok' ? badge('ok', _('Connected')) : vpnState ? badge('warn', vpnState.text)
					: data.killswitch_active ? badge('bad', _('Offline: kill switch')) : badge('', _('VPN not connected')),
				!live ? (data.killswitch_active ? _('Through the VPN; no internet while it is not connected.') : _('Through the VPN; your regular connection while it is not connected.'))
					: data.via_passwall ? _('Through %s, carried through Passwall.').format(live.label) : _('Through %s.').format(live.label))
		];

		if (pw.installed) {
			const used = nets.proxy?.ports?.length || nets.proxy?.ssids?.length;
			let b = null, note = '';

			if (used && !pw.node)
				b = badge('bad', _('No node'));
			else if (used && !pw.running)
				b = badge('warn', _('Starting…'));
			else if (used)
				b = badge('ok', _('Running'));

			if (!pw.node && (used || data.via_passwall))
				note = E('div', { 'class': 'wgc-note bad' }, [
					_('No node is selected in Passwall, so there is no internet through it. '),
					E('a', { href: L.url('admin/services/passwall') }, _('Choose a node in Passwall'))
				]);

			rows.push(row('proxy', b, pw.node ? _('Through Passwall, with its node %s.').format(pw.node.label) : _('Through Passwall.'), note));
		}

		// the router's own traffic: no ports or Wi-Fi, decided by Passwall's
		// Localhost Proxy and the VPN
		const router = {
			passwall: _('Through Passwall (its "Localhost Proxy" is on).'),
			vpn: _('Through the VPN.'),
			direct: _('Your regular internet connection.')
		}[data.router] ?? '';

		rows.push(E('div', { 'class': 'wgc-net' }, [
			E('div', { 'class': 'wgc-net-icon' }, '📟'),
			E('div', { 'class': 'wgc-grow' }, [
				E('div', { 'class': 'wgc-net-title' }, _('This router')),
				E('div', { 'class': 'wgc-sub' }, [ _('Its own traffic, e.g. package updates:'), ' ', router ]),
				pw.installed ? E('div', { 'class': 'wgc-sub', style: 'font-size:.9em' }, (data.router == 'passwall') ? [
					_('To keep it out of Passwall, turn off "Localhost Proxy" in '),
					E('a', { href: L.url('admin/services/passwall') }, _('Passwall')), '.'
				] : [
					_('To send it through Passwall (e.g. for package updates where the package servers are blocked), turn on "Localhost Proxy" in '),
					E('a', { href: L.url('admin/services/passwall') }, _('Passwall')),
					_('; it applies while Passwall runs.')
				]) : ''
			])
		]));

		return E('div', { 'class': 'wgc-card' }, [
			E('div', { 'class': 'wgc-row', style: 'flex-wrap:wrap' }, [
				E('div', { 'class': 'wgc-grow' }, [
					E('p', { 'class': 'wgc-h' }, '🧭 ' + _('Networks')),
					E('div', { 'class': 'wgc-sub' }, _('Each wired port and Wi-Fi network belongs to one network, which decides how its devices reach the internet.'))
				])
			]),
			E('div', { 'class': 'wgc-nets' }, rows),
			E('div', { 'class': 'wgc-actions', style: 'justify-content:flex-end; margin-top:8px' }, [
				E('a', { 'class': 'btn cbi-button', href: L.url('admin/services/wifisetup') }, [ '📶 ' + _('Wi-Fi networks…') ]),
				E('button', { 'class': 'btn cbi-button cbi-button-action', click: () => this.showPorts() }, [ '🔌 ' + _('Wired ports…') ])
			]),
			E('div', { 'class': 'wgc-sub', style: 'margin-top:10px; font-size:.9em' }, _('Wi-Fi networks and the network each one is on are set in Wi-Fi Setup. A guest network always uses your regular internet connection.'))
		]);
	},

	// Settings of the VPN network: kill switch, VPN through Passwall, DNS.
	renderVpnOptions(data) {
		const s = data.settings;
		const pw = data.passwall ?? {};
		const live = data.profiles.find((p) => p.up);
		const connected = data.profiles.some((p) => profileState(p).cls == 'ok');
		const toggle = (checked, label, handler) => E('label', { 'class': 'wgc-switch', title: label }, [
			E('input', { type: 'checkbox', role: 'switch', 'aria-label': label, checked: checked ? '' : null, change: ui.createHandlerFn(this, handler) }),
			E('span', { 'class': 'wgc-slider' })
		]);
		let ksNote = '', viaNote = '', info = [];

		if (!data.wan_zone_ok)
			ksNote = E('div', { 'class': 'wgc-note bad' }, _('The kill switch needs the firewall zone "%s", which does not exist.').format(s.wan_zone));
		else if (data.killswitch_active && !connected)
			ksNote = E('div', { 'class': 'wgc-note bad' }, _('No VPN is connected, so devices on the VPN network currently have no internet access.'));

		if (data.via_passwall && !pw.running && data.profiles.some((p) => p.auto))
			viaNote = E('div', { 'class': 'wgc-note' }, _('Passwall is starting… this can take up to a minute.'));
		else if (data.via_passwall && live?.proxied === true)
			viaNote = E('div', { 'class': 'wgc-note ok' }, _('Wrapped: WireGuard reaches the VPN server through Passwall.'));
		else if (data.via_passwall && live?.proxied === false)
			viaNote = E('div', { 'class': 'wgc-note bad' }, _('Waiting for Passwall: the relay cannot use Passwall\'s SOCKS port yet. It retries every few seconds; if this stays, check that Passwall is running and that its node supports UDP.'));
		else if (data.via_passwall && live)
			viaNote = E('div', { 'class': 'wgc-note' }, _('Starting the relay…'));

		if (data.vpn_dns)
			info.push(_('DNS of the VPN network goes to the VPN\'s DNS server (%s) through the tunnel.').format([ data.vpn_dns.v4, data.vpn_dns.v6 ].filter((a) => a).join(', ')));
		else if (data.profiles.some((p) => p.auto))
			info.push(_('The VPN profile has no DNS server, so the VPN network uses the router\'s DNS servers, outside the VPN.'));

		if (data.ipv6_blocked)
			info.push(_('IPv6 internet traffic of the VPN network is blocked: the profile only carries IPv4, so IPv6 would go around the VPN.'));

		return E('div', { 'class': 'wgc-card' }, [
			E('p', { 'class': 'wgc-h', style: 'margin-bottom:6px' }, '🔒 ' + _('VPN network settings')),
			E('div', { 'class': 'wgc-opt' }, [
				E('div', { 'class': 'wgc-grow' }, [
					E('div', { 'class': 'wgc-net-title' }, '🛡 ' + _('Kill switch')),
					E('div', { 'class': 'wgc-sub' }, _('While the VPN is not connected, devices on the VPN network get no internet (and no DNS) instead of using your regular connection.')),
					ksNote
				]),
				toggle(s.killswitch, _('Kill switch'), 'handleKillswitch')
			]),
			pw.installed ? E('div', { 'class': 'wgc-opt' }, [
				E('div', { 'class': 'wgc-grow' }, [
					E('div', { 'class': 'wgc-net-title' }, '🔀 ' + _('Carry the VPN through Passwall')),
					E('div', { 'class': 'wgc-sub' }, pw.node
						? _('WireGuard reaches your VPN server through Passwall\'s node (%s), hiding that you use a VPN. Slower, and only as reliable as the node.').format(pw.node.label)
						: _('WireGuard reaches your VPN server through the node selected in Passwall, hiding that you use a VPN.')),
					viaNote
				]),
				toggle(data.via_passwall, _('Carry the VPN through Passwall'), 'handleViaPasswall')
			]) : '',
			info.length ? E('div', { 'class': 'wgc-sub', style: 'margin-top:6px' }, info.map((t) => E('div', { style: 'margin-top:4px' }, t))) : ''
		]);
	},

	// Dialog to move wired ports between the networks.
	showPorts() {
		const nets = this.data?.networks ?? {};
		const keys = Object.keys(NETWORKS).filter((k) => nets[k]?.exists);
		const ports = [];

		for (let k of keys)
			for (let p of nets[k].ports ?? [])
				ports.push({ name: p, role: k });

		ports.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

		const selects = {};
		const saveBtn = E('button', { 'class': 'btn cbi-button cbi-button-positive important', disabled: '' }, [ _('Save') ]);
		const changed = () => ports.filter((p) => selects[p.name].value != p.role);
		const warn = E('div', { 'class': 'wgc-note', style: 'display:none' });

		const update = () => {
			const c = changed();

			saveBtn.disabled = !c.length;
			warn.style.display = c.length ? '' : 'none';
			dom.content(warn, [
				_('Devices on a port that moves get an address on the other network. If this computer is plugged into one of them, the page loses its connection: unplug the cable and plug it in again, then open the router at its address on that network: '),
				E('strong', {}, c.map((p) => '%s → %s'.format(portLabel(p.name), nets[selects[p.name].value]?.address ?? '?')).join(', '))
			]);
		};

		const rows = ports.map((p) => {
			selects[p.name] = E('select', { 'class': 'cbi-input-select', change: update }, keys.map((k) =>
				E('option', { value: k, selected: k == p.role ? '' : null }, '%s %s'.format(NETWORKS[k].icon, NETWORKS[k].title))));

			return [ E('label', { style: 'font-weight:600' }, '🔌 ' + portLabel(p.name)), selects[p.name] ];
		}).flat();

		saveBtn.addEventListener('click', () => {
			const map = {};

			for (let p of changed())
				map[p.name] = selects[p.name].value;

			ui.hideModal();
			return this.act(_('Moving ports…'), () => callSetPorts(map));
		});

		ui.showModal(_('Wired ports'), [
			E('div', { 'class': 'wgc wgc-modal' }, [
				E('div', { 'class': 'wgc-sub' }, _('Choose the network for each LAN port. A switch or access point plugged into a port puts all its devices on that network.')),
				ports.length ? E('div', { 'class': 'wgc-ports' }, rows)
					: E('div', { 'class': 'wgc-note' }, _('No LAN ports found: the home network has no bridge with ports ("br-lan").')),
				warn
			]),
			E('div', { 'class': 'right', style: 'margin-top:16px; display:flex; gap:8px; justify-content:flex-end; flex-wrap:wrap' }, [
				E('button', { 'class': 'btn cbi-button', click: ui.hideModal }, [ _('Cancel') ]),
				saveBtn
			])
		], 'cbi-modal');
	},

	handleReapply() {
		if (!confirm(_('Apply everything again?\n\nThe networks, routing, firewall rules and the Passwall settings this page uses are set again; then the firewall reloads and, if Passwall is in use, Passwall restarts. Devices on the VPN and Passwall networks lose the connection for a few seconds.')))
			return;

		return this.act(_('Reapplying settings…'), () => callReapply());
	},

	// Shown when something no longer matches what this page set up.
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

	// Shown when a transparent proxy app other than Passwall is installed.
	renderProxyInfo(data) {
		const apps = data.proxy_apps ?? [];

		if (data.passwall?.installed || !apps.length)
			return '';

		return E('div', { 'class': 'wgc-card' }, [
			E('p', { 'class': 'wgc-h' }, '🔀 ' + _('Works with %s').format(apps.join(', '))),
			E('div', { 'class': 'wgc-sub' }, _('The VPN uses its own routing table, so the proxy keeps working side by side:')),
			E('ul', { 'class': 'wgc-list', style: 'margin:8px 0 0 18px; padding:0' }, [
				E('li', {}, _('Connections made by the proxy core (Xray / sing-box) bypass the VPN, so they never loop into the tunnel.')),
				E('li', {}, _('Install Passwall to also get a Passwall network and to carry the VPN through Passwall.'))
			])
		]);
	},

	renderProfile(p) {
		const state = profileState(p);
		const isOn = p.up || p.auto;

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
					: E('button', { 'class': 'btn cbi-button cbi-button-positive', click: ui.createHandlerFn(this, 'handleConnect', p) }, [ _('Connect') ]),
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

	// Shown instead of the page when it does not match the backend.
	renderOutdated(data) {
		const newer = (data.api ?? 0) > API_VERSION;

		return E('div', { 'class': 'wgc-card' }, [
			E('p', { 'class': 'wgc-h' }, '🔄 ' + _('WireGuard + Passwall was updated')),
			E('div', { 'class': 'wgc-sub' }, newer
				? _('Your browser still shows the previous version of this page. Reload it to get the new one.')
				: _('This page is newer than the app on the router. Reload it, or update the app.')),
			E('div', { 'class': 'wgc-actions', style: 'margin-top:12px' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action important', click: () => this.reloadPage() }, [ _('Reload page') ])
			])
		]);
	},

	// Fetches this page's script past the browser's cache, then reloads:
	// LuCI asks for it under the LuCI version, which an app update does not
	// change, so a normal reload can keep the old copy. (The file was renamed
	// from overview.js for the same reason when the modes were replaced.)
	reloadPage() {
		const url = '%s/view/wgpasswall/networks.js%s'.format(L.env.base_url, L.env.resource_version ? '?v=' + L.env.resource_version : '');

		return fetch(url, { cache: 'reload' }).catch(() => null).then(() => location.reload());
	},

	renderContent(data) {
		const profiles = data.profiles ?? [];

		if (data.api != API_VERSION)
			return [ this.renderOutdated(data) ];

		return [
			this.renderHero(data),
			this.renderDrift(data),
			this.renderNetworks(data),
			this.renderVpnOptions(data),
			this.renderProxyInfo(data),
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
			E('div', { 'class': 'cbi-map-descr', style: 'margin-bottom:16px' }, _('Devices on the VPN network go through your WireGuard VPN, devices on the Passwall network through Passwall, and everything else uses your regular internet connection. Choose the network of each wired port here and of each Wi-Fi network in Wi-Fi Setup.')),
			this.root
		]);
	}
});
