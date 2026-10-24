# luci-tether

Two simple, consumer-router style apps for OpenWrt's LuCI web interface. Built and tested for **OpenWrt 25.12** (apk package manager); install either or both.

| App | Menu | What it does |
|---|---|---|
| [**Wi-Fi Setup**](luci-app-wifisetup/README.md) (`luci-app-wifisetup`) | Network → Wi-Fi Setup | Network name, password and security for all bands, guest network, channels / width / power, connected devices with block, QR code sharing, Wi-Fi schedule |
| [**iPhone Tethering**](luci-app-tether/README.md) (`luci-app-tether`) | Network → iPhone Tethering | When the main internet is down, use the iPhone's mobile data over USB or its Wi-Fi hotspot; switch back when the main connection works again |

| Wi-Fi Setup | iPhone Tethering |
|---|---|
| <img src="docs/screenshots/wifisetup/overview.png" alt="Wi-Fi Setup page" width="420"> | <img src="docs/screenshots/tether/main-down.png" alt="iPhone Tethering page" width="420"> |

<sub>Screenshots show sample data; colours and fonts follow your LuCI theme.</sub>

## Install on your router

1. Get the packages
   - From the [Releases](../../releases) page (a release with both packages is published on every merge into `main`), or
   - From the **Actions** tab → latest *Build packages* run → artifact `luci-tether-openwrt-25.12.2` (a zip with the `.apk` files inside).
2. Copy the ones you want to the router (`-O` is needed because OpenWrt has no SFTP server by default):
   ```sh
   scp -O luci-app-wifisetup-*.apk luci-app-tether-*.apk root@192.168.1.1:/tmp/
   ```
3. Install them on the router. The packages are built by CI, not signed by OpenWrt, so allow them explicitly:
   ```sh
   ssh root@192.168.1.1
   apk update
   apk add --allow-untrusted /tmp/luci-app-wifisetup-*.apk /tmp/luci-app-tether-*.apk
   ```
   `apk update` lets apk pull the dependencies it doesn't find on the router (`qrencode`, `usbmuxd`, `kmod-usb-net-ipheth`, the ucode modules, ...) from the official feeds, so the router needs internet access for the install. Install the tethering app **before** you need it.
4. **Log out of LuCI and log back in**, then open the pages under **Network**. LuCI decides which menu entries you may see when you log in, so an already open session won't show new entries.

### Installing from LuCI (signed packages)

OpenWrt only trusts packages signed with a key in `/etc/apk/keys`. Unsigned self-built packages fail with `UNTRUSTED signature` unless `--allow-untrusted` is passed, which LuCI's **Upload Package…** dialog cannot do. CI therefore signs the packages with your own key:

**Once, on GitHub:** create a signing key on your computer and store it as a repository secret.

```sh
openssl ecparam -name prime256v1 -genkey -noout -out apk-signing-key.pem
```

GitHub → repository → *Settings → Secrets and variables → Actions → New repository secret*: name `APK_SIGNING_KEY`, value: the contents of `apk-signing-key.pem`. Keep the file somewhere safe and private (you can reuse the key of your other apps). Every build after that is signed, and the artifact / release additionally contains `luci-tether.pem` (the public key) and `packages.adb` (a signed package index).

**Releases:** every merge into `main` publishes a GitHub release `r<N>` (e.g. `r12`), where `N` is the number of commits on `main` and also the package release (`luci-app-tether-1.0.0-r12.apk`). Bump `PKG_VERSION` in an app's Makefile for a new version of that app. The latest release's files are always at:

```
https://github.com/willhuang85/luci-tether/releases/latest/download/<file>
```

**Once, on the router:** trust the public key.

```sh
wget -O /etc/apk/keys/luci-tether.pem \
  https://github.com/willhuang85/luci-tether/releases/latest/download/luci-tether.pem
```

Then install from **System → Software → Upload Package…** with no extra flags. Or add the release as a package feed, so the apps show up and update in *System → Software* like any other package:

```sh
echo "https://github.com/willhuang85/luci-tether/releases/latest/download/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
```

> While the repository is private, GitHub only serves release files to logged-in users, so the `wget` and feed commands don't work. Download `luci-tether.pem` and the `.apk` files from the release page in your browser, `scp -O luci-tether.pem root@192.168.1.1:/etc/apk/keys/` and use *Upload Package…*.

### Troubleshooting

- **Installed but no menu entry** – log out of LuCI and back in (and reload the page with Ctrl+F5). Still nothing? Check `apk info -e luci-app-wifisetup` (or `luci-app-tether`), run `/etc/init.d/rpcd restart` and verify `ubus list 'luci.*'` lists `luci.wifisetup` / `luci.tether`.
- **`UNTRUSTED signature`** – see *Installing from LuCI* above, or use `apk add --allow-untrusted`.
- App specific: see the [Wi-Fi Setup](luci-app-wifisetup/README.md#troubleshooting) and [iPhone Tethering](luci-app-tether/README.md#troubleshooting) READMEs.

## Building

The GitHub Actions workflow (`.github/workflows/build.yml`) runs on every push:

1. **test** – builds ucode, rpcd and friends at the exact revisions of the OpenWrt release, loads both backends into a real rpcd next to fake `iwinfo` / `network.wireless` / `network.interface` / `hostapd` objects (and a fake `/sys` with a plugged-in iPhone) and walks through every feature, runs the unit tests, syntax-checks JS/JSON/shell.
2. **build** – downloads the official OpenWrt 25.12.2 SDK, builds both packages and uploads the `.apk` files as an artifact. The packages are architecture independent, so one build works on every router.
3. **release** – on every push to `main` (and on pushed `v*` tags), publishes the `.apk` files (plus, when signed, `packages.adb` and the public key) as a GitHub release.

Build for another OpenWrt release via *Actions → Build packages → Run workflow* and enter the version.

Build locally with an OpenWrt SDK:

```sh
ln -s "$PWD/luci-app-wifisetup" "$PWD/luci-app-tether" /path/to/openwrt-sdk/package/
cd /path/to/openwrt-sdk
make defconfig && make package/luci-app-wifisetup/compile package/luci-app-tether/compile V=s
```

Run the tests (needs a [ucode](https://github.com/jow-/ucode) build, ideally the revision your OpenWrt release ships):

```sh
UCODE_DIR=/path/to/ucode/build ./tests/run.sh
```

`tests/integration.sh` builds libubox, ubus, uci, ucode and rpcd at the revisions used by the OpenWrt release and drives the real plugins over ubus. It installs into `/usr` and `/etc/config`, so only run it on a throwaway machine or container (CI does this on every push).

## License

Apache-2.0
