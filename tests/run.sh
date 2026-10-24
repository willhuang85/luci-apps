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

SRC="$PWD/luci-app-tether/root/usr/share/ucode/*.uc"
MOCKS="$PWD/tests/mocks/*.uc"

echo "== schedule"
"$UCODE" ${UCODE_DIR:+-L "$UCODE_DIR/*.so"} -L "$SRC" tests/schedule_test.uc
echo "== rpcd backend"
"$UCODE" ${UCODE_DIR:+-L "$UCODE_DIR/*.so"} -L "$MOCKS" -L "$SRC" tests/backend_test.uc
echo "== schedule tool compiles"
"$UCODE" ${UCODE_DIR:+-L "$UCODE_DIR/*.so"} -L "$SRC" -c -o /dev/null luci-app-tether/root/usr/libexec/tether-schedule
