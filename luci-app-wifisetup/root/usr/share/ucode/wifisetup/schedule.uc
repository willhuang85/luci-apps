// SPDX-License-Identifier: Apache-2.0
//
// Wi-Fi schedule: turn Wi-Fi off at `off` on the selected days and back on
// at `on`. Shared by the rpcd backend and /usr/libexec/wifisetup-schedule.

'use strict';

export const DAYS = [ 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun' ];

// cron day of week numbers (Sunday = 0)
const CRON_DOW = { mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 0 };

export const MARK = '# wifisetup-schedule';
export const TOOL = '/usr/libexec/wifisetup-schedule';

function as_list(v) {
	if (v == null)
		return [];

	return (type(v) == 'array') ? v : split(`${v}`, /\s+/);
}

// "HH:MM" -> minutes since midnight, or null
export function parse_time(s) {
	const m = match(s ?? '', /^([01]?[0-9]|2[0-3]):([0-5][0-9])$/);

	return m ? +m[1] * 60 + +m[2] : null;
};

function fmt_time(min) {
	return sprintf('%02d:%02d', min / 60, min % 60);
}

export function validate(a) {
	if (parse_time(a.off) == null || parse_time(a.on) == null)
		return 'Enter the times as HH:MM';

	if (parse_time(a.off) == parse_time(a.on))
		return 'The off and on times must differ';

	for (let d in a.days ?? [])
		if (!(d in DAYS))
			return 'Unknown day';

	if (a.enabled && !length(a.days ?? []))
		return 'Pick at least one day';

	return null;
};

export function load(uci) {
	const s = uci.get_all('wifisetup', 'schedule') ?? {};
	const days = filter(as_list(s.days ?? DAYS), (d) => d in DAYS);

	return {
		enabled: s.enabled == '1',
		off: (parse_time(s.off) != null) ? fmt_time(parse_time(s.off)) : '23:00',
		on: (parse_time(s.on) != null) ? fmt_time(parse_time(s.on)) : '07:00',
		days
	};
};

export function store(uci, a) {
	if (uci.get('wifisetup', 'schedule') == null)
		uci.set('wifisetup', 'schedule', 'schedule');

	uci.set('wifisetup', 'schedule', 'enabled', a.enabled ? '1' : '0');
	uci.set('wifisetup', 'schedule', 'off', fmt_time(parse_time(a.off)));
	uci.set('wifisetup', 'schedule', 'on', fmt_time(parse_time(a.on)));
	uci.set('wifisetup', 'schedule', 'days', filter(DAYS, (d) => d in a.days));
};

// Crontab lines for the schedule. Wi-Fi turns off on the selected days and
// on every day: turning it on when it already is does nothing.
export function cron_lines(s) {
	if (!s.enabled || !length(s.days))
		return [];

	const off = parse_time(s.off), on = parse_time(s.on);
	const dow = (length(s.days) == 7) ? '*' : join(',', sort(map(s.days, (d) => CRON_DOW[d])));

	return [
		sprintf('%d %d * * %s %s off %s', off % 60, off / 60, dow, TOOL, MARK),
		sprintf('%d %d * * * %s on %s', on % 60, on / 60, TOOL, MARK)
	];
};

// Replaces our lines in a crontab, keeping everything else.
export function merge_crontab(text, lines) {
	let out = filter(split(text ?? '', '\n'), (l) => length(l) && index(l, MARK) < 0);

	push(out, ...lines);

	return length(out) ? join('\n', out) + '\n' : '';
};

// Whether Wi-Fi should be off at the given time (a localtime() result,
// wday: Monday = 1 ... Sunday = 7).
export function in_off_window(s, tm) {
	if (!s.enabled || !length(s.days))
		return false;

	const off = parse_time(s.off), on = parse_time(s.on);
	const now = tm.hour * 60 + tm.min;
	const today = DAYS[tm.wday - 1];
	const yesterday = DAYS[(tm.wday + 5) % 7];

	if (off < on)
		return (today in s.days) && now >= off && now < on;

	// the off period runs past midnight
	return ((today in s.days) && now >= off) || ((yesterday in s.days) && now < on);
};
