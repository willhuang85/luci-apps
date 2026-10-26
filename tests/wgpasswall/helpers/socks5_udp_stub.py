#!/usr/bin/env python3
# Minimal SOCKS5 server with UDP ASSOCIATE, plus a UDP echo "VPN server",
# for testing wgpasswall-relay.
# Usage: socks5_udp_stub.py <socks_port> <echo_port> [<generation file>]
# With a generation file, an association silently drops its UDP once the
# file's content changes, while its TCP connection stays open: like Xray
# keeping a UDP session on a dead upstream. New associations work.
# CONNECT (the relay's check of the node) answers any HTTP request with 204,
# unless "<generation file>.nodedown" exists: then the node is "dead" and
# CONNECT gets no answer. With "<generation file>.nodedown" or ".vpndown"
# (the VPN server down, the node fine) no UDP gets through either.
import os, selectors, socket, struct, sys, threading

socks_port, echo_port = int(sys.argv[1]), int(sys.argv[2])
gen_file = sys.argv[3] if len(sys.argv) > 3 else None


def generation():
    try:
        with open(gen_file) as f:
            return f.read()
    except (TypeError, OSError):
        return None


def flag(name):
    return bool(gen_file) and os.path.exists(gen_file + "." + name)


def echo():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", echo_port))
    while True:
        data, addr = s.recvfrom(65535)
        s.sendto(b"pong:" + data, addr)


def parse_addr(buf, off):
    atyp = buf[off]
    if atyp == 1:
        return socket.inet_ntoa(buf[off + 1:off + 5]), struct.unpack(">H", buf[off + 5:off + 7])[0], off + 7
    if atyp == 3:
        n = buf[off + 1]
        host = buf[off + 2:off + 2 + n].decode()
        return socket.gethostbyname(host), struct.unpack(">H", buf[off + 2 + n:off + 4 + n])[0], off + 4 + n
    raise ValueError("unsupported atyp")


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


def session(conn):
    try:
        ver, nmethods = recv_exact(conn, 2)
        recv_exact(conn, nmethods)
        conn.sendall(b"\x05\x00")
        req = recv_exact(conn, 4)
        if req[1] == 1:
            if req[3] == 3:
                recv_exact(conn, recv_exact(conn, 1)[0] + 2)
            else:
                recv_exact(conn, 6 if req[3] == 1 else 18)
            if flag("nodedown"):
                conn.recv(512)      # never answers, like a node that is down
                return
            conn.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
            conn.recv(4096)
            conn.sendall(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
            return
        assert req[1] == 3, "only CONNECT and UDP ASSOCIATE"
        rest = recv_exact(conn, 6 if req[3] == 1 else 18)
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("127.0.0.1", 0))
        conn.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", udp.getsockname()[1]))
        client = None
        born = generation()
        sel = selectors.DefaultSelector()
        sel.register(conn, selectors.EVENT_READ, "ctrl")
        sel.register(udp, selectors.EVENT_READ, "udp")
        while True:
            for key, _ in sel.select():
                if key.data == "ctrl":
                    if not conn.recv(512):
                        return
                    continue
                data, addr = udp.recvfrom(65535)
                if generation() != born or flag("nodedown") or flag("vpndown"):
                    continue        # upstream "dead"
                if addr[0] == "127.0.0.1" and addr[1] == echo_port:
                    hdr = b"\x00\x00\x00\x01" + socket.inet_aton(addr[0]) + struct.pack(">H", addr[1])
                    udp.sendto(hdr + data, client)
                else:
                    client = addr
                    host, port, off = parse_addr(data, 3)
                    udp.sendto(data[off:], (host, port))
    except Exception:
        pass
    finally:
        conn.close()


threading.Thread(target=echo, daemon=True).start()
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", socks_port))
srv.listen(5)
print("ready", flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=session, args=(c,), daemon=True).start()
