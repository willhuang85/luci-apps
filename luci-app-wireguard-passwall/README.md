# WireGuard + Passwall (luci-app-wireguard-passwall)

A simple WireGuard VPN **client** for OpenWrt's LuCI web interface that can also carry the VPN through a [Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) proxy node.

- **Import** the `.conf` file from your VPN provider (drag & drop, file picker or paste) with a live check of the file before saving
- **One-click connect / disconnect**, only one profile is active at a time
- **Live status**: handshake, uptime, traffic, server and tunnel address
- **Kill switch** toggle: LAN devices can only reach the internet through the VPN
- **All devices or only chosen ones** use the VPN, e.g. just your work laptops; in "VPN through Passwall" mode the other devices then go through Passwall
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

### Only some devices through the VPN

Under **Devices using the VPN** pick **Only chosen devices** and tick the devices that should use the VPN (the list shows the devices on your network with their names from DHCP; a device that is not around can be added by its MAC address). Everything else:

| Mode | Chosen devices | All other devices |
|---|---|---|
| **VPN** | through the VPN | regular internet connection |
| **VPN through Passwall** | through the VPN, carried through Passwall | through Passwall (Client Proxy on), without the VPN; a guest network directly |
| **Passwall only** / **Off** | like everyone else | like everyone else |

The kill switch then only holds back the chosen devices.

**DNS**: while a profile is connected, the chosen devices' DNS queries go to the VPN's DNS server, see *DNS* below.

In **VPN through Passwall** mode this switches on Passwall's access control (its rules only work with that switch on) and adds a "No Proxy" rule for the chosen devices ahead of your own rules. If you have access control rules of your own that are enabled, they apply too while this mode is on. Leaving the mode puts the switch back as it was.

Devices are recognised by their hardware (MAC) address, so it works for IPv4 and IPv6 and no fixed IP addresses are needed. Wired devices always keep theirs. Phones and laptops on Wi-Fi use a private address per network that stays the same, unless it is set to change ("Rotating" on Apple devices, "Change daily" on Windows) or you forget and rejoin the network; then tick the device again. A device behind another router shows up with that router's address.

### DNS

WireGuard itself knows nothing about DNS: the `DNS =` line of a `.conf` is used by WireGuard apps on phones and computers to set the device's DNS. On a router it would only become one more upstream server of the router's resolver, next to the one from the internet connection, which usually answers first, so devices would browse from the VPN but resolve from home.

So while a profile is connected (VPN and VPN through Passwall modes), the DNS queries of the devices that use the VPN (all devices on the LAN, or only the chosen ones) go to the VPN's DNS server from the `.conf` through the tunnel, whether they ask the router or any other server on port 53. Their IPv6 queries to the router are refused when the VPN has no IPv6 DNS server, so they fall back to IPv4. The VPN's DNS server is not used by the router's own resolver, which keeps using the internet connection's DNS (it has to look up the VPN server before the tunnel is up). Devices that don't use the VPN keep using the router's DNS.

- Devices using the VPN cannot look up the router's local names (`something.lan`); mDNS names (`something.local`) still work.
- Encrypted DNS done by a browser or the OS itself (DoH) is not touched; it goes through the VPN like the rest of their traffic.
- Without a `DNS =` line nothing is redirected and the devices use the router's DNS, outside the VPN.

### Good to know

- **IPv6**: while a profile that sends all IPv4 through the VPN (`0.0.0.0/0`) but has no `::/0` is connected, IPv6 internet traffic of the devices that use the VPN is refused (firewall rule `wgpasswall_no_ipv6`), so it cannot go around the VPN; apps use IPv4 instead. IPv6 inside your network keeps working.
- **What does not use the VPN** for devices that do: addresses reachable without the internet (your LAN, and the network on the router's WAN side, e.g. the home router it is plugged into) and Tailscale addresses (`100.x`). If the VPN interface is down, traffic uses the normal connection unless the kill switch is on.
- **Guest network** (e.g. from Wi-Fi Setup): it is a network and firewall zone of its own and always goes out directly, past both the VPN and Passwall, in every mode (handy for reaching local sites directly); the kill switch does not cover it. "All devices" means the devices in the `lan` zone. Where Passwall proxies the LAN with *Client Proxy*, which would take every network, the app adds a "No Proxy" access control rule for each network of the other zones (`0wgpasswall_direct_<network>`). Their DNS still goes to the router's resolver, which Passwall may configure.
- **The router's own traffic** (package updates, NTP, ...): through the VPN in **VPN** mode (with all or only chosen devices), through Passwall in the Passwall modes (the app turns on Passwall's *Localhost Proxy* there), direct when **Off**.
- **PersistentKeepalive**: on a router behind NAT, and in VPN through Passwall mode, an idle tunnel can go quiet until NAT or the proxy forgets it. When a `.conf` has none, the import / edit dialog offers to add `PersistentKeepalive = 15` (inside the ~30 s shortest UDP timeouts even if one keepalive is lost); it costs well under 1 MB a day.
- `PreUp`/`PostUp`/`Table` lines from wg-quick have no meaning on OpenWrt and are ignored (you'll see a note when importing).

## Using it together with Passwall / Xray

The app runs next to transparent proxies (Passwall, Passwall 2, HomeProxy, OpenClash) without them getting in each other's way: the VPN routes live in their own routing table (`51820`) and only *unmarked* traffic uses it, so a proxy core's own connections (Xray and sing-box mark them with `255`) never loop into the tunnel.

### Modes: VPN, VPN through Passwall, Passwall only

With Passwall (not Passwall 2) installed, the app shows a **Mode** picker and a Passwall node selector, so day to day you don't need to open Passwall at all. You still use Passwall itself to add or subscribe to nodes, read its logs and tune its own rules (direct/proxy/block lists, DNS, access control).

| Mode | WireGuard | Passwall |
|---|---|---|
| **VPN** | connected | exactly as you had it before you first picked a Passwall mode |
| **VPN through Passwall** | connected, carried through Passwall | on with the chosen node, Client Proxy off, Localhost Proxy on |
| **Passwall only** | disconnected | on with the chosen node, Client Proxy on (a guest network excepted), Localhost Proxy on, TCP/UDP default proxy mode Proxy |
| **Off** | disconnected | main switch off, everything else left as it is |

How **VPN through Passwall** works: each tunnel's endpoint is pointed at a small relay on the router (`127.0.0.1:51821`, `51822`, …), which forwards WireGuard's packets through Passwall's node SOCKS port (`node_socks_port`, default 1070) to the real VPN server, so your ISP only sees the proxy connection. The real server stays in the profile (the editor and status show it) and comes back when you leave the mode. Only traffic from LAN devices goes into the tunnel; the router's own traffic, including Passwall's DNS and the proxy's lookup of its server name, stays outside it, otherwise the proxy carrying the tunnel would wait for the tunnel to resolve its own server. It goes through Passwall instead (Localhost Proxy). The tunnel MTU is lowered to 1280 for the proxy overhead. The node must support UDP. If the proxy's own connection to its server dies while its local SOCKS port stays up (Xray can keep a busy UDP session on a dead upstream), the relay notices that WireGuard keeps sending but gets no handshake for 3 minutes, and reconnects through a fresh proxy session; it logs this (`logread | grep wgpasswall-relay`).

Details:

- Passwall's settings (and whether its service starts at boot) are saved the first time you leave **VPN** mode and restored when you return to it. Switching between the two Passwall modes keeps that saved copy. Passwall's own page shows whatever the current mode set, e.g. its main switch is ticked in both Passwall modes.
- In **Passwall only** the kill switch is paused, since Passwall sends some traffic directly on purpose; Connect is disabled until you pick a VPN mode.
- **Off** turns everything off in one click: VPN disconnected, Passwall's main switch off (its other settings untouched), relay stopped, kill switch paused, so devices use the regular internet connection. Pick another mode to turn things back on; Connect is disabled while off.
- Uninstalling the app switches back to **VPN** mode first, so Passwall is restored.
- **Reapply settings** (bottom of the page) applies the current mode again: Passwall's settings for it, the device rule, routing and firewall rules, then reloads the firewall and restarts Passwall. Use it after changing things on Passwall's own page. The page also warns ("Settings out of step") when Passwall's settings no longer match the mode or the app's firewall rules are saved but not active. In **VPN** mode Passwall is yours and left alone.

### Why not let Passwall's "Localhost Proxy" carry WireGuard?

Letting Passwall intercept WireGuard's packets transparently (Localhost Proxy plus the server in the proxy list) looks like it should work, and the proxy log even shows the packets arriving, but it falls apart within seconds: the replies the proxy injects back to WireGuard create a new connection-tracking entry that looks like it was opened by the server, after which Passwall treats WireGuard's packets as replies and lets them out directly. The relay avoids interception altogether.

## How it works

Each profile is a normal netifd WireGuard interface named `wgc_<name>` in `/etc/config/network` (peers in `wireguard_wgc_<name>` sections) with `ip4table`/`ip6table 51820` and `fwmark 0xca6c`, so you can also see it under *Network → Interfaces*. The app creates:

| UCI section | Purpose |
|---|---|
| `firewall.wgpasswall_zone` | Zone `wgpasswall` with all profiles, masquerading on |
| `firewall.wgpasswall_fwd` | Forwarding `lan` → `wgpasswall` |
| `firewall.wgpasswall_killswitch` | Rule `lan` → `wan` REJECT, enabled by the toggle (only for the chosen devices if the VPN is limited to them) |
| `firewall.wgpasswall_devices` | Only chosen devices: sets mark bit `0x1000000` (`device_mark`) on everything they send |
| `firewall.wgpasswall_no_ipv6` | Rule `lan` → `wan` IPv6 REJECT, enabled while the connected profile carries all IPv4 but no IPv6 |
| `firewall.wgpasswall_devices_dns` | Includes `/etc/wgpasswall/devices-dns.nft`, table `inet wgpasswall_dns` sending the DNS of the devices that use the VPN to the VPN's DNS server (before Passwall's DNS redirect) |
| `passwall.0wgpasswall_direct_<network>` | Where Client Proxy is on (Passwall only, VPN through Passwall with only chosen devices): access control rule "No Proxy" for each network outside the LAN, WAN and VPN zones, e.g. a guest network |
| `passwall.0wgpasswall_vpn_devices` | Only chosen devices, VPN through Passwall: access control rule "No Proxy" for them, ahead of your own rules |
| `network.wgpasswall_rule_main` / `wgpasswall_rule6_main` | `lookup main suppress_prefixlength 0` keeps LAN and other specific routes |
| `network.wgpasswall_rule_vpn_<lan network>` / `wgpasswall_rule6_vpn_<lan network>` | Unmarked traffic from the `lan` zone's networks → VPN table 51820 |
| `network.wgpasswall_rule_vpn_loopback` / `wgpasswall_rule6_vpn_loopback` | The router's own unmarked traffic → VPN table (not in VPN through Passwall mode) |
| `network.wgpasswall_rule_vpn` / `wgpasswall_rule6_vpn` | Only chosen devices: traffic with the device mark → VPN table (replaces the `lan` rules) |
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
