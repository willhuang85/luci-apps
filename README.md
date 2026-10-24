# luci-app-wgclient

A simple WireGuard VPN **client** for OpenWrt's LuCI web interface.

- **Import** the `.conf` file from your VPN provider (drag & drop, file picker or paste) with a live check of the file before saving
- **One-click connect / disconnect**, only one profile is active at a time
- **Live status**: handshake, uptime, traffic, server and tunnel address
- **Kill switch** toggle: LAN devices can only reach the internet through the VPN
- Edit, export and delete profiles; works on desktop and phone

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
4. Reload LuCI and open **VPN → WireGuard Client**.

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

## How it works

Each profile is a normal netifd WireGuard interface named `wgc_<name>` in `/etc/config/network` (peers in `wireguard_wgc_<name>` sections), so you can also see it under *Network → Interfaces*. The app creates:

| UCI section | Purpose |
|---|---|
| `firewall.wgclient_zone` | Zone `wgclient` with all profiles, masquerading on |
| `firewall.wgclient_fwd` | Forwarding `lan` → `wgclient` |
| `firewall.wgclient_killswitch` | Rule `lan` → `wan` REJECT, enabled by the toggle |
| `wgclient.<iface>` | Display name of each profile |

Full-tunnel `AllowedIPs` (`0.0.0.0/0`, `::/0`) are stored as two `/1` halves so the VPN routes always win over the WAN default route; exports turn them back into `/0`.

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

1. **test** – builds `ucode` and runs the parser and backend tests, syntax-checks JS/JSON.
2. **build** – downloads the official OpenWrt 25.12.2 SDK, builds the package and uploads the `.apk` as an artifact. The package is architecture independent, so one build works on every router.
3. **release** – on a `v*` tag (e.g. `git tag v1.0.0 && git push --tags`), attaches the `.apk` to a GitHub release.

Build for another OpenWrt release via *Actions → Build package → Run workflow* and enter the version.

Build locally with an OpenWrt SDK:

```sh
ln -s "$PWD/luci-app-wgclient" /path/to/openwrt-sdk/package/
cd /path/to/openwrt-sdk
./scripts/feeds update base luci && ./scripts/feeds install -a -p base && ./scripts/feeds install luci-base
make defconfig && make package/luci-app-wgclient/compile V=s
```

Run the tests (needs a [ucode](https://github.com/jow-/ucode) build):

```sh
UCODE_DIR=/path/to/ucode/build ./tests/run.sh
```

## License

Apache-2.0
