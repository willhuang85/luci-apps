// Tests the schedule helpers (cron lines, off window).
// Run: ucode -L 'luci-app-tether/root/usr/share/ucode/*.uc' tests/schedule_test.uc

'use strict';

import * as sch from 'tether.schedule';

let failures = 0, total = 0;

function check(name, cond) {
	total++;

	if (!cond) {
		failures++;
		warn(`FAIL: ${name}\n`);
	}
}

// wday: Monday = 1 ... Sunday = 7
function at(wday, hh, mm) {
	return { wday, hour: hh, min: mm };
}

check('parse', sch.parse_time('7:05') == 425 && sch.parse_time('23:59') == 1439 && sch.parse_time('24:00') == null);
check('validate ok', sch.validate({ enabled: true, off: '23:00', on: '07:00', days: [ 'mon' ] }) == null);
check('validate day', sch.validate({ enabled: true, off: '23:00', on: '07:00', days: [ 'funday' ] }) != null);
check('disabled needs no days', sch.validate({ enabled: false, off: '23:00', on: '07:00', days: [] }) == null);

let s = { enabled: true, off: '23:00', on: '07:30', days: [ 'mon', 'tue', 'wed', 'thu', 'sun' ] };
let lines = sch.cron_lines(s);
check('cron off', lines[0] == '0 23 * * 0,1,2,3,4 /usr/libexec/tether-schedule off # tether-schedule');
check('cron on', lines[1] == '30 7 * * * /usr/libexec/tether-schedule on # tether-schedule');
check('cron every day', index(sch.cron_lines({ ...s, days: sch.DAYS })[0], ' * * * /usr') > 0);
check('cron disabled', length(sch.cron_lines({ ...s, enabled: false })) == 0);

const tab = '# mine\n0 3 * * * /bin/backup\n1 2 * * * /old # tether-schedule\n';
check('merge keeps others', sch.merge_crontab(tab, lines) == '# mine\n0 3 * * * /bin/backup\n' + join('\n', lines) + '\n');
check('merge removes', sch.merge_crontab(tab, []) == '# mine\n0 3 * * * /bin/backup\n');
check('merge empty', sch.merge_crontab(null, []) == '');

// overnight window, Sunday to Thursday nights
check('mon 23:30 off', sch.in_off_window(s, at(1, 23, 30)));
check('tue 03:00 off (mon night)', sch.in_off_window(s, at(2, 3, 0)));
check('tue 07:30 on', !sch.in_off_window(s, at(2, 7, 30)));
check('fri 23:30 on (not selected)', !sch.in_off_window(s, at(5, 23, 30)));
check('sat 03:00 on (fri not selected)', !sch.in_off_window(s, at(6, 3, 0)));
check('mon 02:00 off (sun night)', sch.in_off_window(s, at(1, 2, 0)));
check('fri 02:00 off (thu night)', sch.in_off_window(s, at(5, 2, 0)));

// daytime window
s = { enabled: true, off: '09:00', on: '17:00', days: [ 'sat' ] };
check('sat noon off', sch.in_off_window(s, at(6, 12, 0)));
check('sat 17:00 on', !sch.in_off_window(s, at(6, 17, 0)));
check('sun noon on', !sch.in_off_window(s, at(7, 12, 0)));
check('disabled', !sch.in_off_window({ ...s, enabled: false }, at(6, 12, 0)));

print(`${total - failures}/${total} passed\n`);
exit(failures ? 1 : 0);
