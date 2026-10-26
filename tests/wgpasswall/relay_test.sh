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
	python3 "$SRC/tests/wgpasswall/helpers/socks5_udp_stub.py" $SOCKS $ECHO "$T/generation" > "$T/stub.log" 2>&1 &
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

# WireGuard's view (wg show all dump): the peer behind relay L1 and its
# latest handshake
handshake() {
	printf 'wgc_test\tPUB\t(none)\t127.0.0.1:%s\t0.0.0.0/0\t%s\t0\t0\t25\n' $L1 "$1" > "$T/wg.dump"
}
handshake "$(date +%s)"
echo 1 > "$T/generation"

start_stub
WGPASSWALL_RELAY_CONFIG="$T/relay.json" WGPASSWALL_RELAY_STATUS="$T/status.json" \
	WGPASSWALL_RELAY_WG_DUMP="$T/wg.dump" WGPASSWALL_RELAY_CHECK_MS=500 WGPASSWALL_RELAY_GRACE=2 \
	WGPASSWALL_RELAY_HANDSHAKE_MAX=5 WGPASSWALL_RELAY_RECENT_TX=2 WGPASSWALL_RELAY_SENDING_MIN=4 \
	WGPASSWALL_RELAY_PW_CHECK_AFTER=2 WGPASSWALL_RELAY_PROBE_GAP=1 WGPASSWALL_RELAY_PW_RESTART_GAP=1000 \
	WGPASSWALL_RELAY_PW_RESTART="echo restart >> $T/pw-restarts" WGPASSWALL_RELAY_UCODE="$(command -v ucode)" \
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

echo "== healthy tunnel is left alone"
for i in 1 2 3 4; do handshake "$(date +%s)"; ping_relay $L1 busy >/dev/null; sleep 1; done
! grep -q '"resets": [1-9]' "$T/status.json" || fail "relay reconnected a working tunnel"

echo "== traffic resumes after an idle spell: WireGuard gets time to handshake"
sleep 3				# idle: nothing sent
handshake $(( $(date +%s) - 100 ))	# so the last handshake is old by now
sleep 1
for i in 1 2; do [ "$(ping_relay $L1 resume)" = "pong:resume" ] || fail "working tunnel lost after idle"; sleep 0.5; done
for i in 1 2 3 4 5 6; do		# WireGuard handshakes again and keeps it fresh
	handshake "$(date +%s)"; ping_relay $L1 busy >/dev/null; sleep 1
done
! grep -q '"resets": [1-9]' "$T/status.json" || fail "relay reconnected right after an idle spell"

echo "== proxy's upstream dies but the association stays open"
echo 2 > "$T/generation"
[ "$(ping_relay $L1 lost)" = "timeout" ] || fail "stub did not simulate the dead upstream"
handshake $(( $(date +%s) - 100 ))
for i in $(seq 1 12); do
	r=$(ping_relay $L1 retry)
	[ "$r" = "pong:retry" ] && break
done
[ "$r" = "pong:retry" ] || fail "relay did not recover from a dead upstream"
sleep 2.5
grep -q '"resets": [1-9]' "$T/status.json" || fail "status does not count the reconnect"
grep -q "no handshake through the proxy" "$T/relay.log" || fail "reconnect not logged"

echo "== idle tunnel (nothing sent) is left alone"
handshake 0
sleep 7
before=$(grep -o '"resets": [0-9]*' "$T/status.json" | head -1)
sleep 3
[ "$(grep -o '"resets": [0-9]*' "$T/status.json" | head -1)" = "$before" ] || fail "relay reconnected an idle tunnel"

# keeps WireGuard "sending" with an old handshake until the log has $1
dead_until() {
	for i in $(seq 1 25); do
		handshake $(( $(date +%s) - 100 ))
		ping_relay $L1 dead >/dev/null
		grep -q "$1" "$T/relay.log" && return 0
	done
	return 1
}

echo "== VPN server down, node fine: Passwall is left alone"
touch "$T/generation.vpndown"
dead_until "node answers" || fail "node not checked, or reported down"
[ ! -e "$T/pw-restarts" ] || fail "Passwall restarted although its node answers"

echo "== Passwall's node stuck: Passwall is restarted, once"
rm "$T/generation.vpndown"; touch "$T/generation.nodedown"
dead_until "restarting Passwall" || fail "Passwall not restarted for a stuck node"
for i in 1 2 3 4 5 6; do handshake $(( $(date +%s) - 100 )); ping_relay $L1 dead >/dev/null; done
[ "$(wc -l < "$T/pw-restarts")" = 1 ] || fail "Passwall restarted more than once: $(wc -l < "$T/pw-restarts")"
rm "$T/generation.nodedown"
for i in $(seq 1 12); do
	r=$(ping_relay $L1 back)
	[ "$r" = "pong:back" ] && break
done
[ "$r" = "pong:back" ] || fail "relay did not recover once the node works again"

echo "relay: all checks passed"
