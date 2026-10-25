# WireGuard + Passwall (luci-app-wireguard-passwall)

A simple WireGuard VPN **client** for OpenWrt's LuCI web interface that can also carry the VPN through a [Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) proxy node.

- **Import** the `.conf` file from your VPN provider (drag & drop, file picker or paste) with a live check of the file before saving
- **One-click connect / disconnect**, only one profile is active at a time
- **Live status**: handshake, uptime, traffic, server and tunnel address
- **Kill switch** toggle: LAN devices can only reach the internet through the VPN
- Edit, export and delete profiles; works on desktop and phone
- **Modes** (with Passwall installed): VPN, VPN carried through a Passwall node, Passwall only, and Off, switched with one click (see below)

Menu: **Services → WireGuard + Passwall**. Installation: see the [main README](../README.md).

<p align="center">
  <img src="../docs/screenshots/wgpasswall/overview.png" alt="Connected in VPN through Passwall mode" width="720">
</p>

| Import with a live check | Everything off | On a phone |
|---|---|---|
| <img src="../docs/screenshots/wgpasswall/import.png" alt="Import dialog" width="280"> | <img src="../docs/screenshots/wgpasswall/mode-off.png" alt="Off mode" width="280"> | <img src="../docs/screenshots/wgpasswall/mobile.png" alt="Phone layout" width="180"> |

<sub>Screenshots show sample data; colours and fonts follow your LuCI theme.</sub>

## Using it

1. Click the drop zone or **+ Import**, pick your `.conf` file, give it a name.
2. Check the preview ("Looks good", server, routing) and press **Save & connect**.
3. Optional: turn on the **Kill switch**.

The status card turns green once the server answered with a handshake. A profile that is connected stays connected after a reboot.

### What the kill switch does

When on, a firewall rule rejects all traffic forwarded from the `lan` zone to the `wan` zone. Traffic to the VPN zone is still allowed, so:

- VPN connected → everything works through the tunnel.
- VPN drops or is disconnected → LAN devices have **no internet** until a VPN connects again. Nothing leaks over your normal connection.

The router itself can still reach the internet (it needs that to contact the VPN server), and access to LuCI/SSH from the LAN is not affected. The zone names can be changed in `/etc/config/wgpasswall` if yours differ from `lan`/`wan`.

### Good to know

- **DNS**: the DNS servers from the `.conf` are added to the router's resolver, but the router's dnsmasq may still also use your ISP's DNS servers. For strict DNS privacy, set the VPN's DNS server under *Network → DHCP and DNS → Forwards* and disable *Use DNS servers advertised by peer* on the `wan` interface.
- **IPv6**: if your provider's config only contains IPv4 `AllowedIPs`, LAN IPv6 traffic bypasses the VPN unless the kill switch is on.
- `PreUp`/`PostUp`/`Table` lines from wg-quick have no meaning on OpenWrt and are ignored (you'll see a note when importing).

## Using it together with Passwall / Xray

The app runs next to transparent proxies (Passwall, Passwall 2, HomeProxy, OpenClash) without them getting in each other's way: the VPN routes live in their own routing table (`51820`) and only *unmarked* traffic uses it, so a proxy core's own connections (Xray and sing-box mark them with `255`) never loop into the tunnel.

### Modes: VPN, VPN through Passwall, Passwall only

With Passwall (not Passwall 2) installed, the app shows a **Mode** picker and a Passwall node selector, so day to day you don't need to open Passwall at all. You still use Passwall itself to add or subscribe to nodes, read its logs and tune its own rules (direct/proxy/block lists, DNS, access control).

| Mode | WireGuard | Passwall |
|---|---|---|
| **VPN** | connected | exactly as you had it before you first picked a Passwall mode |
| **VPN through Passwall** | connected, carried through Passwall | on with the chosen node, Client Proxy off |
| **Passwall only** | disconnected | on with the chosen node, Client Proxy on, TCP/UDP default proxy mode Proxy |
| **Off** | disconnected | main switch off, everything else left as it is |

How **VPN through Passwall** works: each tunnel's endpoint is pointed at a small relay on the router (`127.0.0.1:51821`, `51822`, …), which forwards WireGuard's packets through Passwall's node SOCKS port (`node_socks_port`, default 1070) to the real VPN server, so your ISP only sees the proxy connection. The real server stays in the profile (the editor and status show it) and comes back when you leave the mode. Only traffic from LAN devices goes into the tunnel; the router's own traffic, including Passwall's DNS and the proxy's lookup of its server name, stays outside it, otherwise the proxy carrying the tunnel would wait for the tunnel to resolve its own server. The tunnel MTU is lowered to 1280 for the proxy overhead. The node must support UDP.

Details:

- Passwall's settings (and whether its service starts at boot) are saved the first time you leave **VPN** mode and restored when you return to it. Switching between the two Passwall modes keeps that saved copy. Passwall's own page shows whatever the current mode set, e.g. its main switch is ticked in both Passwall modes.
- In **Passwall only** the kill switch is paused, since Passwall sends some traffic directly on purpose; Connect is disabled until you pick a VPN mode.
- **Off** turns everything off in one click: VPN disconnected, Passwall's main switch off (its other settings untouched), relay stopped, kill switch paused, so devices use the regular internet connection. Pick another mode to turn things back on; Connect is disabled while off.
- Uninstalling the app switches back to **VPN** mode first, so Passwall is restored.

### Why not Passwall's "Localhost Proxy"?

Letting Passwall intercept WireGuard's packets transparently (Localhost Proxy plus the server in the proxy list) looks like it should work, and the proxy log even shows the packets arriving, but it falls apart within seconds: the replies the proxy injects back to WireGuard create a new connection-tracking entry that looks like it was opened by the server, after which Passwall treats WireGuard's packets as replies and lets them out directly. The relay avoids interception altogether.

## How it works

Each profile is a normal netifd WireGuard interface named `wgc_<name>` in `/etc/config/network` (peers in `wireguard_wgc_<name>` sections) with `ip4table`/`ip6table 51820` and `fwmark 0xca6c`, so you can also see it under *Network → Interfaces*. The app creates:

| UCI section | Purpose |
|---|---|
| `firewall.wgpasswall_zone` | Zone `wgpasswall` with all profiles, masquerading on |
| `firewall.wgpasswall_fwd` | Forwarding `lan` → `wgpasswall` |
| `firewall.wgpasswall_killswitch` | Rule `lan` → `wan` REJECT, enabled by the toggle |
| `network.wgpasswall_rule_main` / `wgpasswall_rule6_main` | `lookup main suppress_prefixlength 0` keeps LAN and other specific routes |
| `network.wgpasswall_rule_vpn` / `wgpasswall_rule6_vpn` | Unmarked traffic → VPN table 51820 (limited to LAN traffic in VPN through Passwall mode) |
| `wgpasswall.<iface>` | Display name of each profile |

Full-tunnel `AllowedIPs` (`0.0.0.0/0`, `::/0`) are stored as two `/1` halves so the tunnel can never replace a default route; exports turn them back into `/0`.

Code layout:

```
luci-app-wireguard-passwall/
├── Makefile                                       OpenWrt package definition
├── htdocs/luci-static/resources/view/wgpasswall/
│   └── overview.js                                the web UI
└── root/
    ├── etc/config/wgpasswall                        settings (kill switch, zone names)
    └── usr/share/
        ├── luci/menu.d/luci-app-wireguard-passwall.json     menu entry (Services → WireGuard + Passwall)
        ├── rpcd/acl.d/luci-app-wireguard-passwall.json      permissions
        ├── rpcd/ucode/luci.wgpasswall               backend (ubus object luci.wgpasswall)
        └── ucode/wgpasswall/conf.uc                 .conf parser / writer
    ├── usr/libexec/wgpasswall-relay                 WireGuard → SOCKS5 UDP relay (VPN through Passwall)
    └── etc/init.d/wgpasswall                        runs the relay
```

## Uninstalling

`apk del luci-app-wireguard-passwall` switches back to VPN mode first (so Passwall is restored) and turns the kill switch off, so you don't lose internet access.
