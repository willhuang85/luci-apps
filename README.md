# luci-apps

Simple, consumer-router style apps for OpenWrt's LuCI web interface. Each app is a separate package; install the ones you want. Works on **OpenWrt 25.12** and **OpenWrt 24.10**, and on ImmortalWrt releases based on them.

| App | Menu | What it does |
|---|---|---|
| [**Wi-Fi Setup**](luci-app-wifisetup/README.md) (`luci-app-wifisetup`) | Services → Wi-Fi Setup | Network name, password and security for all bands, guest network, channels / width / power, connected devices with block, QR code sharing, Wi-Fi schedule |
| [**Phone Tethering**](luci-app-tether/README.md) (`luci-app-tether`) | Services → Phone Tethering | When the main internet is down, use an iPhone's or Android phone's mobile data over USB or its Wi-Fi hotspot; switch back when the main connection works again |
| [**WireGuard + Passwall**](luci-app-wireguard-passwall/README.md) (`luci-app-wireguard-passwall`) | Services → WireGuard + Passwall | WireGuard VPN client with networks: put wired ports and Wi-Fi networks on a VPN network or a Passwall network; one-click connect, kill switch, VPN carried through Passwall |

| Wi-Fi Setup | Phone Tethering | WireGuard + Passwall |
|---|---|---|
| <img src="docs/screenshots/wifisetup/overview.png" alt="Wi-Fi Setup page" width="280"> | <img src="docs/screenshots/tether/main-down.png" alt="Phone Tethering page" width="280"> | <img src="docs/screenshots/wgpasswall/overview.png" alt="WireGuard + Passwall page" width="280"> |

<sub>Screenshots show sample data; colours and fonts follow your LuCI theme. Tested with the default Bootstrap theme and [Argon](https://github.com/jerrykuku/luci-theme-argon), light and dark.</sub>

## Install

Check your OpenWrt version with `cat /etc/openwrt_release`. OpenWrt **25.12** uses `apk` and `.apk` packages; OpenWrt **24.10** uses `opkg` and `.ipk` packages. Every [release](../../releases) has both.

The router needs internet access while installing, to download the apps' dependencies (`qrencode`, `usbmuxd`, `wireguard-tools`, ...) from the official OpenWrt feeds. Install Phone Tethering **before** your main internet goes down.

### Option 1: add the package feed (recommended)

Do this once; afterwards the apps install and update from **System → Software** like any other package.

**OpenWrt 25.12:**

```sh
wget -O /etc/apk/keys/luci-apps.pem \
  https://github.com/willhuang85/luci-apps/releases/latest/download/luci-apps.pem
echo "https://github.com/willhuang85/luci-apps/releases/latest/download/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list
apk update
apk add luci-app-wifisetup        # or luci-app-tether, luci-app-wireguard-passwall
```

**OpenWrt 24.10:**

```sh
wget -O /tmp/luci-apps-opkg.pub \
  https://github.com/willhuang85/luci-apps/releases/latest/download/luci-apps-opkg.pub
opkg-key add /tmp/luci-apps-opkg.pub
echo "src/gz luci_apps https://github.com/willhuang85/luci-apps/releases/latest/download" \
  >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-wifisetup   # or luci-app-tether, luci-app-wireguard-passwall
```

The key lets the router check that the packages really come from this repository.

### Option 2: install a downloaded package

Download the files for your version from the [latest release](../../releases/latest), then either upload them in **System → Software → Upload Package…**, or copy them to the router and install them there (`-O` is needed because OpenWrt has no SFTP server by default):

```sh
# OpenWrt 25.12
scp -O luci-app-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'apk update && apk add --allow-untrusted /tmp/luci-app-*.apk'

# OpenWrt 24.10
scp -O luci-app-*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg update && opkg install /tmp/luci-app-*.ipk'
```

On 25.12, **Upload Package…** only accepts the files once the router trusts the key (the `wget … luci-apps.pem` line in option 1); from the command line, `--allow-untrusted` does the same. On 24.10, uploading works as is.

### After installing

Reload the LuCI page (Ctrl+F5) and open the new page under **Services**. Installing doesn't log you out.

### Update and remove

| | OpenWrt 25.12 | OpenWrt 24.10 |
|---|---|---|
| Update (with the feed) | `apk update && apk upgrade luci-app-wifisetup` | `opkg update && opkg upgrade luci-app-wifisetup` |
| Remove | `apk del luci-app-wifisetup` | `opkg remove luci-app-wifisetup` |
| Is it installed? | `apk info -e luci-app-wifisetup` | `opkg list-installed \| grep luci-app` |

Or use **System → Software**. Removing an app first undoes what it changed that could cut you off (for example, tethering switches back to the main internet); each app's README says exactly what it undoes.

### Troubleshooting

- **Installed but no menu entry** – reload the page with Ctrl+F5. Still nothing? Check that the package is installed (table above), run `/etc/init.d/rpcd reload` and verify `ubus list 'luci.*'` lists `luci.wifisetup`, `luci.tether` or `luci.wgpasswall`.
- **`UNTRUSTED signature`** (25.12) – the router doesn't have the key yet: run the `wget … luci-apps.pem` line from option 1, or install with `apk add --allow-untrusted`.
- **`wget ... Failed to send request: Operation not permitted`** during `apk update` / `opkg update` – the router itself cannot reach the package mirror; a firewall rule is dropping the router's own outgoing traffic (not related to these apps). Check with:
  ```sh
  ping -c 3 1.1.1.1                 # basic connectivity
  nslookup downloads.openwrt.org    # DNS
  ip rule                           # look for "prohibit"/"blackhole"
  nft list ruleset | grep -inE 'drop|reject' | head -30
  ```
  If a proxy app such as Passwall runs with "Localhost proxy", stop it briefly (`/etc/init.d/passwall stop`), update and install, then start it again.
  If Passwall is already off but `ping 1.1.1.1` works while the update fails, Passwall's rules for the router's own traffic were left behind (its table is still listed by `nft list tables`): `nft delete table inet passwall` removes them, and Passwall recreates the table on its next start. These apps run their firewall reloads and Passwall restarts one at a time to avoid this; toggling Passwall from its own page at the same moment can still cause it.
- App specific: see the [Wi-Fi Setup](luci-app-wifisetup/README.md#troubleshooting), [Phone Tethering](luci-app-tether/README.md#troubleshooting) and [WireGuard + Passwall](luci-app-wireguard-passwall/README.md) READMEs.

## Contributing

Issues and pull requests are welcome. Every push and pull request is tested and built by GitHub Actions, so you can check a change without a router, and each run's artifacts contain packages you can install for testing.

### Layout

Each app is an OpenWrt package directory:

```
luci-app-<name>/
  Makefile                          package metadata, dependencies, install / remove scripts
  htdocs/.../view/<name>/*.js       the LuCI page (runs in the browser)
  root/usr/share/rpcd/ucode/luci.*  the backend: an rpcd ucode plugin, called by the page over ubus
  root/usr/share/rpcd/acl.d/        which backend methods the page may call
  root/usr/share/luci/menu.d/       the menu entry
  root/etc/config/<name>            default settings (uci)
```

Other helpers live next to them under `root/` (for example the WireGuard relay in `root/usr/libexec/`). The packages contain only scripts, so they are architecture independent (`PKGARCH:=all`).

### Tests

| Command | What it tests | Needs |
|---|---|---|
| `./tests/run.sh` | unit tests of all backends, plus static checks for the rules below | a [ucode](https://github.com/jow-/ucode) build (`UCODE_DIR=/path/to/build` or `ucode` in `$PATH`) |
| `sudo -E ./tests/integration.sh` | Wi-Fi Setup and Phone Tethering loaded into a real rpcd, with fake Wi-Fi hardware and a fake plugged-in iPhone | root, a throwaway machine or container |
| `sudo -E ./tests/wgpasswall/integration.sh` | WireGuard + Passwall in a real rpcd, with a stub Passwall | root, a throwaway machine or container |
| `./tests/wgpasswall/relay_test.sh` | the WireGuard → SOCKS5 relay end to end, against a stub proxy | ucode with the socket and uloop modules, python3 |

The integration tests build libubox, ubus, uci, ucode and rpcd at the exact revisions of an OpenWrt release (`tests/lib/build-stack.sh`) and install them into `/usr`; pick the release with `OPENWRT_VERSION=24.10.8` (default `25.12.2`). Test against the release's ucode, not the latest one: newer ucode accepts syntax that the router's ucode rejects.

### Rules the backends follow

`tests/run.sh` checks these:

- **Never call rpcd's own ubus objects** (`uci`, `file`, `session`, `iwinfo`, `luci`, `rc`, …) from a backend. rpcd is single threaded, so the call waits for itself and blocks all of LuCI. Use the ucode `uci` module directly, or do the call from the page.
- **Firewall reloads and Passwall restarts go through `run_locked()`**, so that two apps never restart them at the same time.

Also:

- Page scripts are minified when packages are built. LuCI reads the `'use strict'` and `'require …'` lines at the top of a view before running it; the build keeps them and fails if they get lost.
- rpcd ignores world-writable plugins; the Makefiles set file modes, and the build fails on world-writable files.

### Build packages locally

With the SDK of your OpenWrt release (from downloads.openwrt.org, any target):

```sh
ln -s "$PWD"/luci-app-* /path/to/openwrt-sdk/package/
cd /path/to/openwrt-sdk
make defconfig && make package/luci-app-wifisetup/compile V=s    # or any other app
```

The packages land in `bin/packages/`. No feeds need to be installed: the dependencies are only recorded, not built.

### CI and releases

`.github/workflows/build.yml` runs on every push and pull request, once per OpenWrt release (the `matrix` entries: 25.12.2 and 24.10.8):

1. **test** – all of the tests above.
2. **build** – builds the packages with the official SDK and uploads them as an artifact per OpenWrt release.
3. **release** – on pushes to `main` (and pushed `v*` tags): publishes both sets, the signed package indexes and the public keys as one GitHub release.

Releases are numbered `r<N>`, where `N` is the number of commits on `main`; it is also the package release (`luci-app-tether-1.0.0-r73.apk`), so nobody bumps `PKG_RELEASE` by hand. For a new version of an app, bump `PKG_VERSION` in its Makefile.

### Signing keys (for forks)

CI signs with two repository secrets (*Settings → Secrets and variables → Actions*). A fork without them still builds; its packages are unsigned and its releases can't be used as a package feed.

| Secret | For | Create with |
|---|---|---|
| `APK_SIGNING_KEY` | 25.12: the `.apk` files and `packages.adb` | `openssl ecparam -name prime256v1 -genkey -noout -out apk-signing-key.pem` |
| `OPKG_SIGNING_KEY` | 24.10: `Packages.sig` | `signify -G -n -c "luci-apps" -p luci-apps-opkg.pub -s luci-apps-opkg.sec` |

Store the whole private key file (`apk-signing-key.pem`, `luci-apps-opkg.sec`) as the secret's value and keep it somewhere safe. `signify` is `brew install signify-osx` on macOS and `signify-openbsd` on Debian/Ubuntu; its keys are the same as OpenWrt's `usign`. CI derives the public keys (`luci-apps.pem`, `luci-apps-opkg.pub`) from the secrets and publishes them with every release.

## License

Apache-2.0
