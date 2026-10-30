#!/bin/sh
# Runs the ucode unit tests. Needs a ucode binary built from
# https://github.com/jow-/ucode; set UCODE_DIR to its build directory
# or have `ucode` in $PATH.
set -e

cd "$(dirname "$0")/.."

if [ -n "$UCODE_DIR" ]; then
	UCODE="$UCODE_DIR/ucode"
	export LD_LIBRARY_PATH="$UCODE_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
	UCODE=ucode
fi

SRC="$PWD/luci-app-wifisetup/root/usr/share/ucode/*.uc"
MOCKS="$PWD/tests/mocks/*.uc"

echo "== backends do not call rpcd's own ubus objects"
# rpcd is single threaded: a plugin calling an object that rpcd itself serves
# (iwinfo, session, uci, file, luci, luci-rpc, rc) waits for itself and
# blocks every LuCI request for the ubus timeout. Do those from the browser.
if grep -nE "ubus\.call\(\s*['\"\`](iwinfo|session|uci|file|luci|luci-rpc|rc)['\"\`]" luci-app-*/root/usr/share/rpcd/ucode/*; then
	echo "FAIL: a backend calls an object served by rpcd itself"
	exit 1
fi
echo ok

echo "== firewall reloads and Passwall restarts only under the shared lock"
# overlapping ones leave Passwall's rules behind (see run_locked)
if grep -nE "system\(.*/etc/init\.d/(firewall|passwall) (reload|restart|start|stop|enable|disable)([^a-z]|$)" luci-app-*/root/usr/share/rpcd/ucode/*; then
	echo "FAIL: use run_locked() for firewall reloads and Passwall restarts"
	exit 1
fi
echo ok

echo "== pages add router data as text, not HTML"
# LuCI's E() and ui.showModal() put a string into the page as HTML; SSIDs,
# hostnames, names and messages come from outside (nearby Wi-Fi networks,
# USB devices, Passwall subscriptions), so every page uses its own E() and
# showModal() that add strings as text.
for f in luci-app-*/htdocs/luci-static/resources/view/*/*.js; do
	grep -q '^const E = (tag, attr, data) =>' "$f" || { echo "FAIL: $f lacks the text-only E()"; exit 1; }
	if grep -n 'innerHTML\|insertAdjacentHTML\|outerHTML' "$f" || [ "$(grep -c 'ui\.showModal(' "$f")" != 1 ]; then
		echo "FAIL: $f inserts HTML or calls ui.showModal() directly"
		exit 1
	fi
done
echo ok

echo "== checkboxes keep the theme's own drawing"
# Bootstrap draws checkboxes with pseudo elements positioned against the
# input; position: static moves them away and the checkbox disappears
if grep -nE 'checkbox"\][^}]*position: *static' luci-app-*/htdocs/luci-static/resources/view/*/*.js; then
	echo "FAIL: do not make checkboxes position: static"
	exit 1
fi
echo ok

echo "== schedule"
"$UCODE" ${UCODE_DIR:+-L "$UCODE_DIR/*.so"} -L "$SRC" tests/schedule_test.uc
echo "== rpcd backend"
"$UCODE" ${UCODE_DIR:+-L "$UCODE_DIR/*.so"} -L "$MOCKS" -L "$SRC" tests/backend_test.uc
echo "== schedule tool compiles"
"$UCODE" ${UCODE_DIR:+-L "$UCODE_DIR/*.so"} -L "$SRC" -c -o /dev/null luci-app-wifisetup/root/usr/libexec/wifisetup-schedule
echo "== tether backend"
TETHER_SYSFS=$(mktemp -d)
TETHER_USBMUXD="$TETHER_SYSFS/usbmuxd" TETHER_SYSFS="$TETHER_SYSFS" \
	"$UCODE" ${UCODE_DIR:+-L "$UCODE_DIR/*.so"} -L "$MOCKS" tests/tether_test.uc
rm -rf "$TETHER_SYSFS"
echo "== WireGuard + Passwall"
UCODE_DIR="$UCODE_DIR" ./tests/wgpasswall/run.sh
