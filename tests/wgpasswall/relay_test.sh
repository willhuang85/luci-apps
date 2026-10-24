#!/bin/sh
# End-to-end test of wgpasswall-relay: a UDP client (standing in for
# WireGuard) talks to the relay, which forwards through a stub SOCKS5
# proxy to a UDP echo server (standing in for the VPN server). Also checks
# that the relay recovers when the proxy restarts. Needs ucode with the
# socket and uloop modules, and python3.
set -e

SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d)
SOCKS=41080 ECHO=41820 L1=41821 L2=41822

cleanup() { kill $STUB $RELAY 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; cat "$T/relay.log" 2>/dev/null; cat "$T/status.json" 2>/dev/null; exit 1; }

start_stub() {
	python3 "$SRC/tests/wgpasswall/helpers/socks5_udp_stub.py" $SOCKS $ECHO > "$T/stub.log" 2>&1 &
	STUB=$!
	for i in 1 2 3 4 5 6 7 8 9 10; do grep -q ready "$T/stub.log" 2>/dev/null && return; sleep 0.3; done
	fail "stub did not start"
}

ping_relay() {
	python3 - "$1" "$2" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(sys.argv[2].encode(), ("127.0.0.1", int(sys.argv[1])))
try:
    print(s.recvfrom(65535)[0].decode())
except socket.timeout:
    print("timeout")
PY
}

cat > "$T/relay.json" <<JSON
{ "socks": { "host": "127.0.0.1", "port": $SOCKS },
  "relays": [ { "listen": $L1, "host": "127.0.0.1", "port": $ECHO },
              { "listen": $L2, "host": "localhost", "port": $ECHO } ] }
JSON

start_stub
WGPASSWALL_RELAY_CONFIG="$T/relay.json" WGPASSWALL_RELAY_STATUS="$T/status.json" \
	ucode "$SRC/luci-app-wireguard-passwall/root/usr/libexec/wgpasswall-relay" > "$T/relay.log" 2>&1 &
RELAY=$!
sleep 1

[ "$(ping_relay $L1 hello)" = "pong:hello" ] || fail "IPv4 destination not relayed"
[ "$(ping_relay $L2 world)" = "pong:world" ] || fail "hostname destination not relayed"
sleep 2.5
grep -q '"up": true' "$T/status.json" || fail "status does not report the association"

echo "== proxy restart"
kill $STUB; wait $STUB 2>/dev/null || true
sleep 1
grep -q '"up": false' "$T/status.json" || sleep 2
grep -q '"up": false' "$T/status.json" || fail "status does not report the lost association"
start_stub
sleep 4
[ "$(ping_relay $L1 again)" = "pong:again" ] || fail "relay did not recover after proxy restart"
kill -0 $RELAY || fail "relay died"

echo "relay: all checks passed"
