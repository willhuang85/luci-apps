#!/bin/sh
# Runs the proxy watcher with stub nft/wg/logger and only a minimal set of
# tools on PATH (OpenWrt's busybox has no od, hexdump, ...), simulating
# Passwall starting and restarting.
set -e

SRC="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT

mkdir "$T/bin"
cat > "$T/bin/nft" <<'STUB'
#!/bin/sh
[ "$5" = passwall ] && [ -f "$STATE" ] && { echo "table inet passwall { # handle $(cat "$STATE")"; echo "	chain PSW_OUTPUT_MANGLE { # handle 3"; exit 0; }
exit 1
STUB
cat > "$T/bin/wg" <<'STUB'
#!/bin/sh
case "$1" in show) echo "wgc_home lan_other";; set) echo "SET $2 $3 $4" >> "$CALLS";; esac
STUB
printf '#!/bin/sh\necho "LOG $*" >> "$CALLS"\n' > "$T/bin/logger"
chmod +x "$T/bin/"*
for c in sh head tr sleep cat; do ln -s "$(command -v $c)" "$T/bin/$c"; done

sed 's/sleep 3/sleep 0/' "$SRC/luci-app-wgclient/root/usr/libexec/wgclient-proxy-watch" > "$T/watch.sh"

export STATE="$T/state" CALLS="$T/calls"
PATH="$T/bin" WGCLIENT_WATCH_INTERVAL=1 sh "$T/watch.sh" &
PID=$!

calls() { [ -f "$CALLS" ] && grep -c '^SET' "$CALLS" || echo 0; }
fail() { echo "FAIL: $*"; cat "$CALLS" 2>/dev/null; exit 1; }

sleep 2;   [ "$(calls)" = 0 ] || fail "rebound without Passwall"
echo 7 > "$STATE"; sleep 2.5
[ "$(calls)" = 1 ] || fail "not rebound when Passwall started"
grep -q '^SET wgc_home listen-port 0$' "$CALLS" || fail "wrong wg call"
grep -q lan_other "$CALLS" && fail "touched an interface it does not own"
sleep 2;   [ "$(calls)" = 1 ] || fail "rebound without a Passwall restart"
echo 9 > "$STATE"; sleep 2.5
[ "$(calls)" = 2 ] || fail "not rebound when Passwall restarted"
kill -0 $PID 2>/dev/null || fail "watcher died"

echo "watcher: all checks passed"
