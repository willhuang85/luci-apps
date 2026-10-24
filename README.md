# luci-app-wgclient

A simple WireGuard VPN **client** for OpenWrt's LuCI web interface.

- **Import** the `.conf` file from your VPN provider (drag & drop, file picker or paste) with a live check of the file before saving
- **One-click connect / disconnect**, only one profile is active at a time
- **Live status**: handshake, uptime, traffic, server and tunnel address
- **Kill switch** toggle: LAN devices can only reach the internet through the VPN
- Edit, export and delete profiles; works on desktop and phone
- **Works with Passwall / Xray / sing-box**, which can even wrap the WireGuard tunnel (see below)

Built and tested for **OpenWrt 25.12** (apk package manager).

## Install on your router

1. Get the package
   - From the [Releases](../../releases) page (created when a `v*` tag is pushed), or
   - From the **Actions** tab → latest *Build package* run → artifact `luci-app-wgclient-openwrt-25.12.2` (it's a zip with the `.apk` inside).
2. Copy it to the router (`-O` is needed because OpenWrt has no SFTP server by default):
   ```sh
   scp -O luci-app-wgclient-*.apk root@192.168.1.1:/tmp/
   ```
3. Install it on the router. The package is built by CI, not signed by OpenWrt, so allow it explicitly:
   ```sh
   ssh root@192.168.1.1
   apk update
   apk add --allow-untrusted /tmp/luci-app-wgclient-*.apk
   ```
   `apk update` lets apk pull the dependencies (`wireguard-tools`, `kmod-wireguard`, ...) from the official feeds.
4. **Log out of LuCI and log back in**, then open **VPN → WireGuard Client**. LuCI decides which menu entries you may see when you log in, so an already open session won't show the new entry.

> **Use SSH, not LuCI's "Upload Package…" button.** OpenWrt 25.12 only signs repository indexes, never single `.apk` files, so every self-built package fails with `UNTRUSTED signature` unless `--allow-untrusted` is passed — and the LuCI upload dialog has no way to pass it.

### Troubleshooting

- **Installed but no menu entry** – log out of LuCI and back in (and reload the page with Ctrl+F5). Still nothing? Check `apk info -e luci-app-wgclient`, run `/etc/init.d/rpcd restart` and verify `ubus list luci.wgclient` prints the object.
- **`UNTRUSTED signature`** – you installed through LuCI's upload button or forgot `--allow-untrusted`; use the `apk add` command above.
- **`wget ... Failed to send request: Operation not permitted`** during `apk update` – the router itself cannot reach the package mirror; a firewall rule is dropping the router's own outgoing traffic (not related to this app). `apk` needs the mirror to fetch `wireguard-tools` and `kmod-wireguard`. Check with:
  ```sh
  ping -c 3 1.1.1.1                 # basic connectivity
  nslookup downloads.openwrt.org    # DNS
  ip rule                           # look for "prohibit"/"blackhole"
  nft list ruleset | grep -inE 'drop|reject' | head -30
  ```
  If a proxy app such as Passwall runs with "Localhost proxy", stop it briefly (`/etc/init.d/passwall stop`), run `apk update`, install, then start it again.

To uninstall: `apk del luci-app-wgclient` (the kill switch is turned off automatically so you don't lose internet access).

## Using it

1. Click the drop zone or **+ Import**, pick your `.conf` file, give it a name.
2. Check the preview ("Looks good", server, routing) and press **Save & connect**.
3. Optional: turn on the **Kill switch**.

The status card turns green once the server answered with a handshake. A profile that is connected stays connected after a reboot.

### What the kill switch does

When on, a firewall rule rejects all traffic forwarded from the `lan` zone to the `wan` zone. Traffic to the VPN zone is still allowed, so:

- VPN connected → everything works through the tunnel.
- VPN drops or is disconnected → LAN devices have **no internet** until a VPN connects again. Nothing leaks over your normal connection.

The router itself can still reach the internet (it needs that to contact the VPN server), and access to LuCI/SSH from the LAN is not affected. The zone names can be changed in `/etc/config/wgclient` if yours differ from `lan`/`wan`.

### Good to know

- **DNS**: the DNS servers from the `.conf` are added to the router's resolver, but the router's dnsmasq may still also use your ISP's DNS servers. For strict DNS privacy, set the VPN's DNS server under *Network → DHCP and DNS → Forwards* and disable *Use DNS servers advertised by peer* on the `wan` interface.
- **IPv6**: if your provider's config only contains IPv4 `AllowedIPs`, LAN IPv6 traffic bypasses the VPN unless the kill switch is on.
- `PreUp`/`PostUp`/`Table` lines from wg-quick have no meaning on OpenWrt and are ignored (you'll see a note when importing).

## Using it together with Passwall / Xray

The app is built to run next to transparent proxies (Passwall, Passwall 2, HomeProxy, OpenClash) and lets them **wrap the WireGuard tunnel**, i.e. send WireGuard's encrypted UDP packets through an Xray/sing-box proxy (useful when WireGuard is blocked or throttled).

How it stays out of the proxy's way:

- The VPN routes live in their own routing table (`51820`) instead of replacing the default route.
- Only *unmarked* traffic is routed into the VPN. Passwall's Xray and sing-box mark their own connections with `255`, so the proxy's connection to its server always leaves via WAN and never loops into the tunnel.
- WireGuard's own packets carry the mark `0xca6c`. That also keeps them out of the VPN table, and because the low byte isn't `0xff`, Passwall's router-traffic rules still pick them up and can wrap them.
- The ip rules use priority 30100/30110, after Passwall's TPROXY rule (priority 999).
- Passwall only intercepts *new* connections, and at boot WireGuard is up long before Passwall starts. The `wgclient` service therefore watches Passwall's nftables rules and, whenever Passwall (re)starts, moves each tunnel to a new random source port. That starts a fresh connection Passwall can catch; the server follows the new port automatically.

### One switch: "Tunnel through Passwall"

With Passwall (not Passwall 2) installed, the app shows a **Tunnel through Passwall** card. Pick a node and turn it on, and the app:

- switches Passwall on with that node, sets **Localhost Proxy** on and **Client Proxy** off (LAN traffic goes into WireGuard, WireGuard's packets go into the proxy), and makes sure **Use Proxy List** is on
- adds your VPN servers' IPs to Passwall's proxy list (`/etc/passwall/rules/proxy_ip`, under a marker line) and comments them out of its direct list
- removes the VPN server's port from Passwall's blocked UDP ports, if it was there
- lowers the tunnel MTU to 1280 for the proxy overhead
- enables and restarts the Passwall service

Every value is saved first. Turning the switch off (or uninstalling the app) restores Passwall's settings, rule lists, service state and your MTUs. The card and the status panel show whether the tunnel is really wrapped, read from Passwall's mark on the connection.

### Manual setup

To wrap the tunnel with Passwall by hand:

1. Import and connect your WireGuard profile here as usual.
2. In Passwall enable **Localhost proxy** (proxy the router's own traffic) with UDP proxying turned on, and pick a node that supports UDP (VLESS, VMess, Trojan, Shadowsocks, ...).
3. Make sure the WireGuard server's address goes through the proxy. In *Global* mode it does; in rule-based modes add the server IP/domain to the proxy list, and keep it out of the direct list.
4. If some sites stall, set `MTU = 1280` in the profile (Edit) because the proxy adds overhead.
5. Check it (the app's status panel does this for you): `grep <server-ip> /proc/net/nf_conntrack` should show the WireGuard connection with `mark=1347639089` (Passwall's mark). `mark=0` means it still goes out directly; run `/etc/init.d/wgclient restart` or Disconnect/Connect the profile.

Alternatively, point the profile's `Endpoint` at a local Xray `dokodemo-door` inbound (e.g. `127.0.0.1:51821`) that forwards to the real server through the proxy.

Notes: traffic that Passwall itself proxies for LAN devices goes through Xray and therefore *not* through WireGuard; traffic Passwall sends *direct* goes through the VPN. The kill switch only blocks LAN traffic forwarded straight to WAN, so it does not interfere with Passwall. The routing table, rule priority and marks can be changed in `/etc/config/wgclient` if another app already uses them.

## How it works

Each profile is a normal netifd WireGuard interface named `wgc_<name>` in `/etc/config/network` (peers in `wireguard_wgc_<name>` sections) with `ip4table`/`ip6table 51820` and `fwmark 0xca6c`, so you can also see it under *Network → Interfaces*. The app creates:

| UCI section | Purpose |
|---|---|
| `firewall.wgclient_zone` | Zone `wgclient` with all profiles, masquerading on |
| `firewall.wgclient_fwd` | Forwarding `lan` → `wgclient` |
| `firewall.wgclient_killswitch` | Rule `lan` → `wan` REJECT, enabled by the toggle |
| `network.wgclient_rule_main` / `wgclient_rule6_main` | `lookup main suppress_prefixlength 0` keeps LAN and other specific routes |
| `network.wgclient_rule_vpn` / `wgclient_rule6_vpn` | Unmarked traffic → VPN table 51820 |
| `wgclient.<iface>` | Display name of each profile |

Full-tunnel `AllowedIPs` (`0.0.0.0/0`, `::/0`) are stored as two `/1` halves so the tunnel can never replace a default route; exports turn them back into `/0`.

Code layout:

```
luci-app-wgclient/
├── Makefile                                       OpenWrt package definition
├── htdocs/luci-static/resources/view/wgclient/
│   └── overview.js                                the web UI
└── root/
    ├── etc/config/wgclient                        settings (kill switch, zone names)
    └── usr/share/
        ├── luci/menu.d/luci-app-wgclient.json     menu entry (VPN → WireGuard Client)
        ├── rpcd/acl.d/luci-app-wgclient.json      permissions
        ├── rpcd/ucode/luci.wgclient               backend (ubus object luci.wgclient)
        └── ucode/wgclient/conf.uc                 .conf parser / writer
```

## Building

The GitHub Actions workflow (`.github/workflows/build.yml`) runs on every push:

1. **test** – builds ucode, rpcd and friends at the exact revisions of the OpenWrt release, loads the backend into a real rpcd, runs the parser and backend tests, syntax-checks JS/JSON.
2. **build** – downloads the official OpenWrt 25.12.2 SDK, builds the package and uploads the `.apk` as an artifact. The package is architecture independent, so one build works on every router.
3. **release** – on a `v*` tag (e.g. `git tag v1.0.0 && git push --tags`), attaches the `.apk` to a GitHub release.

Build for another OpenWrt release via *Actions → Build package → Run workflow* and enter the version.

Build locally with an OpenWrt SDK:

```sh
ln -s "$PWD/luci-app-wgclient" /path/to/openwrt-sdk/package/
cd /path/to/openwrt-sdk
make defconfig && make package/luci-app-wgclient/compile V=s
```

Run the tests (needs a [ucode](https://github.com/jow-/ucode) build, ideally the revision your OpenWrt release ships):

```sh
UCODE_DIR=/path/to/ucode/build ./tests/run.sh
```

`tests/integration.sh` builds libubox, ubus, uci, ucode and rpcd at the revisions used by the OpenWrt release and drives the real plugin over ubus. It installs into `/usr` and `/etc/config`, so only run it on a throwaway machine or container (CI does this on every push).

## License

Apache-2.0
