# InitBox Raspberry Pi 3 / 4 / 5 Setup

This branch contains setup scripts and documentation for preparing Raspberry Pi 3, Raspberry Pi 4, and Raspberry Pi 5 devices as InitBox field appliances.

This branch is dedicated to the full Pi 3 / 4 / 5 InitBox stack.

---

## Operating Model

InitBox devices are prepared in a lab environment where Internet access is available.

After setup and verification, the Raspberry Pi is deployed in the field as a preconfigured appliance.

Field deployment should not depend on Internet access for package installation.

The intended workflow is:

1. Prepare the Raspberry Pi in the lab.
2. Make sure the Pi has Internet access.
3. Clone or update the `pi-3-4-5` branch.
4. Confirm required dashboard source files exist in the repo.
5. Run the installer for the `pi-3-4-5` profile.
6. Run installer sanity checks.
7. Prepare the Debian package cache.
8. Install the required modules.
9. Allow dashboard assets and npm dependencies to be downloaded or built once during lab setup.
10. Reboot if required.
11. Verify all required services.
12. Test role-based startup.
13. Test uninstall behavior for at least one module.
14. Test offline or field rerun behavior if required.
15. Run field diagnostics.
16. Deploy the prepared device in the field.

All required packages and first-time dashboard assets should be installed or cached during lab preparation.

---

## Offline / Field Rerun Model

The Pi 3 / 4 / 5 branch uses a lab-first cache model.

During lab setup with Internet:

* Debian packages are downloaded and kept on the Pi.
* Module installs use the package helper.
* `ttyd` is built once and cached on the Pi.
* Node.js 22 is installed or upgraded when required.
* Node-RED is installed locally under `/home/initbox/.node-red`.
* `node-red-dashboard` is installed locally under `/home/initbox/.node-red`.
* Repository-owned dashboard assets are copied into the Node-RED runtime directory.

During field or offline reruns:

* Debian packages install from the local cache.
* Existing Node.js is reused.
* Existing local Node-RED installation is reused.
* Existing `node-red-dashboard` installation is reused.
* Cached `ttyd` binary is reused if `ttyd` is missing from the PATH.
* Repository-owned dashboard assets are copied again from the repo.
* The field rerun does not depend on Internet access once the lab cache has been prepared and dashboard has been installed once.

Package cache helper:

```text
scripts/lib/packages.sh
```

Package list:

```text
scripts/packages.txt
```

Default package cache root:

```text
/opt/initbox-package-cache
```

Default Debian package cache:

```text
/opt/initbox-package-cache/apt
```

Default dashboard asset cache:

```text
/opt/initbox-package-cache/dashboard
```

Dashboard cached assets include:

```text
/opt/initbox-package-cache/dashboard/ttyd
```

Dashboard source-of-truth assets are stored at the repository `scripts/` root:

```text
scripts/flows.json
scripts/settings.js
scripts/logo.png
```

Do not place dashboard assets under `scripts/pi-3-4-5/`. That directory is for Pi 3 / 4 / 5 module scripts only.

At install time, these are copied to:

```text
/home/initbox/.node-red/flows.json
/home/initbox/.node-red/settings.js
/home/initbox/.node-red/public/logo.png
```

Important limitation:

```text
A fully offline dashboard install is possible only after dashboard was installed once in the lab with Internet.
```

This is because Node.js, Node-RED, and npm dependencies must exist locally before a field/offline rerun can reuse them.

---

## Supported Hardware Profile

This branch supports only this hardware profile:

```text
pi-3-4-5
```

The profile definition is stored in:

```text
profiles/pi-3-4-5.conf
```

Expected profile behavior:

```text
Dashboard support: yes
Web Terminal support: yes
Primary management interface: dashboard
```

Default recommended modules:

```text
isi fms hotspot dashboard rtc sniffer-bridge
```

The `web-terminal` module name may remain supported as a compatibility alias, but on this branch Web Terminal is bundled into the dashboard module.

---

## Supported Hardware

This branch is intended for:

```text
Raspberry Pi 3
Raspberry Pi 4
Raspberry Pi 5
```

## Feature Summary

The Pi 3 / 4 / 5 branch supports:

* Hotspot
* Dashboard
* Web Terminal
* Debian package cache
* Dashboard asset cache
* Role-based service startup
* Module install and uninstall from the installer menu
* ISI simulator
* FMS/CAN replay
* RTC sync
* Sniffer / bridge capture
* Field diagnostics
* Repository update script

---

## Repository Layout

Expected branch layout:

```text
README.md

profiles/
  README.md
  pi-3-4-5.conf

scripts/
  initbox-installer.sh
  initbox-status.sh
  update-repo.sh
  packages.txt
  flows.json
  settings.js
  logo.png

  lib/
    profile.sh
    modules.sh
    state.sh
    packages.sh

  pi-3-4-5/
    module-dashboard.sh
    module-fms.sh
    module-hotspot.sh
    module-isi.sh
    module-rtc.sh
    module-ws-br0.sh
```

---

## Lab Setup Requirements

Before running the installer, confirm:

* The Raspberry Pi is in the lab.
* Internet access is available.
* Raspberry Pi OS has been installed.
* SSH or local console access is available.
* The correct branch is checked out: `pi-3-4-5`.
* The correct profile is used: `pi-3-4-5`.
* The Pi has stable power.
* Required RTC hardware is connected if RTC is needed.
* Required CAN/MCP2515 hardware is connected if FMS is needed.
* Required Ethernet/sniffer cabling is connected if sniffer or ISI is needed.

During setup, the installer may:

* Run `apt-get update`
* Run `apt-get upgrade`
* Download Debian packages into the local package cache
* Install Debian packages from cache or Internet
* Install or upgrade Node.js 22 when required
* Build and cache `ttyd`
* Install local Node-RED under `/home/initbox/.node-red`
* Install `node-red-dashboard`
* Copy repo-owned `flows.json`, `settings.js`, and `logo.png`
* Configure networking
* Configure systemd services
* Modify boot or hardware settings
* Require a reboot

---

## Clone This Branch

On the Pi:

```bash
cd /home/initbox
git clone --branch pi-3-4-5 https://github.com/psi1703/RaspberryPi.git
cd RaspberryPi
```

If the repository already exists, update it after changes have been committed on GitHub:

```bash
cd /home/initbox/RaspberryPi
sudo ./scripts/update-repo.sh
```

The update script defaults to:

```text
origin/pi-3-4-5
```

It performs a hard sync, repairs script permissions, sets `git config core.fileMode false`, and runs basic validation.

Dry run:

```bash
./scripts/update-repo.sh --dry-run
```

---

## Run the Installer

From the repository root:

```bash
cd /home/initbox/RaspberryPi
sudo ./scripts/initbox-installer.sh pi-3-4-5
```

The installer will:

* Load the Pi 3 / 4 / 5 hardware profile.
* Show a clear numeric main menu.
* Repair required repository permissions.
* Create install logs.
* Create the legacy module log path.
* Grant passwordless sudo to the operator user.
* Run baseline `apt-get update` when Internet is available.
* Run baseline `apt-get upgrade` when Internet is available.
* Prepare the package cache when requested.
* Show package cache status when requested.
* Install supported modules when selected.
* Uninstall supported modules when selected.
* Record install state.
* Record module availability flags for dashboard visibility.

Installer log:

```text
/var/log/initbox/install.log
```

Legacy module log:

```text
/home/initbox/pi_logs/initbox-install.log
```

Install state:

```text
/etc/initbox/install-state.env
```

Dashboard module flags:

```text
/etc/initbox-mods.conf
```

The dashboard reads these flags to decide which module controls are visible. Module install and uninstall actions should update their own flag and restart `pi-nodered.service` if it exists so the UI refreshes immediately.

Expected flag ownership:

| Flag        | Owner module                  |
| ----------- | ----------------------------- |
| `DASHBOARD` | `module-dashboard.sh`         |
| `HOTSPOT`   | `module-hotspot.sh`           |
| `RTC`       | `module-rtc.sh`               |
| `WSBR0`     | `module-ws-br0.sh`            |
| `ISI`       | `module-isi.sh`               |
| `FMS`       | `module-fms.sh`               |

---

## Installer Menu Options

The installer menu includes:

```text
Main menu
---------
 1) Install module
 2) Uninstall module
 3) Run sanity checks
 4) Prepare/download package cache
 5) Show package cache status
 6) Show install log
 7) Show install state
 8) Quit
```

Choosing `1` shows the supported modules to install.

Choosing `2` shows the supported modules to uninstall.

The module list is based on the `DEFAULT_MODULES` value in:

```text
profiles/pi-3-4-5.conf
```

Run sanity checks before installing modules:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5 c
```

Prepare the Debian package cache in the lab:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5 p
```

Show package cache status:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5 k
```

Show install log:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5 l
```

Show install state:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5 s
```

The sanity check verifies:

* Required repository files exist.
* The loaded profile is `pi-3-4-5`.
* Required profile values are set.
* Dashboard support is enabled.
* `scripts/packages.txt` exists.
* `scripts/lib/packages.sh` exists.
* Supported modules have script mappings.
* Supported module scripts exist.
* Shell syntax is valid.
* ShellCheck runs if installed.

---

## Package Cache Preparation

Run this in the lab while the Pi still has Internet:

```bash
cd /home/initbox/RaspberryPi
sudo ./scripts/initbox-installer.sh pi-3-4-5 p
```

This downloads Debian packages listed in:

```text
scripts/packages.txt
```

into:

```text
/opt/initbox-package-cache/apt
```

The cache helper is:

```text
scripts/lib/packages.sh
```

Useful package helper commands:

```bash
sudo ./scripts/lib/packages.sh status
sudo ./scripts/lib/packages.sh download scripts/packages.txt
sudo ./scripts/lib/packages.sh install dnsmasq hostapd dhcpcd5
sudo ./scripts/lib/packages.sh install-cache dnsmasq hostapd dhcpcd5
```

Normal module scripts call the helper automatically.

The expected behavior is:

* With Internet: install using `apt-get` and keep packages cached.
* Without Internet: install from local package cache only.
* Packages are not purged by module uninstall actions.
* `purge` is treated as an uninstall compatibility alias.

If offline installation fails, the cache is incomplete. Return to lab Internet and rerun:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5 p
```

---

## Dashboard Asset Cache

The dashboard module has extra assets beyond Debian packages.

Dashboard module script:

```text
scripts/pi-3-4-5/module-dashboard.sh
```

Dashboard cache directory:

```text
/opt/initbox-package-cache/dashboard
```

Cached `ttyd` binary:

```text
/opt/initbox-package-cache/dashboard/ttyd
```

Repository-owned dashboard assets:

```text
scripts/flows.json
scripts/settings.js
scripts/logo.png
```

These are the source-of-truth files copied into the Node-RED runtime during dashboard install.

Runtime dashboard assets:

```text
/home/initbox/.node-red/flows.json
/home/initbox/.node-red/settings.js
/home/initbox/.node-red/public/logo.png
```

During the first lab install with Internet:

* Node.js 22 is installed or upgraded when required.
* `ttyd` is built from GitHub source.
* The installed `ttyd` binary is copied into the dashboard cache.
* Node-RED is installed locally under `/home/initbox/.node-red`.
* `node-red-dashboard` is installed locally under `/home/initbox/.node-red`.
* Repo-owned `flows.json` is copied to `/home/initbox/.node-red/flows.json`.
* Repo-owned `settings.js` is copied to `/home/initbox/.node-red/settings.js`.
* Repo-owned `logo.png` is copied to `/home/initbox/.node-red/public/logo.png`.
* Generated or hostname-specific Node-RED flow files are discarded.
* `pi-nodered.service` is installed as the only InitBox Node-RED service.
* `nodered.service` is stopped, disabled, masked, and not used.

During later offline reruns:

* `ttyd` is restored from the cached binary if missing.
* Local Node-RED is reused if already installed.
* Local `node-red-dashboard` is reused if already installed.
* Repo-owned `flows.json`, `settings.js`, and `logo.png` are copied again.
* If Node-RED was never installed before going offline, dashboard install cannot complete fully offline.

Verify dashboard cache:

```bash
ls -lah /opt/initbox-package-cache/dashboard
command -v ttyd || true
sudo -u initbox bash -lc 'test -x ~/.node-red/node_modules/.bin/node-red && echo node-red-local-ok'
sudo -u initbox bash -lc 'cd ~/.node-red && npm list node-red-dashboard --depth=0'
```

Verify runtime dashboard files:

```bash
ls -l /home/initbox/.node-red/flows.json
ls -l /home/initbox/.node-red/settings.js
ls -l /home/initbox/.node-red/public/logo.png
```

---

## Recommended Module Installation Order

Recommended order:

```text
1. Prepare package cache
2. Hotspot
3. Dashboard
4. RTC
5. Sniffer / Bridge
6. ISI
7. FMS
```

Reasoning:

* Package cache makes later field/offline reruns safer.
* Hotspot provides Wi-Fi access and local DNS.
* Dashboard provides Node-RED, Web Terminal, portal redirect, and role control.
* RTC provides time sync helpers used by ZEITNEHMER.
* Sniffer / Bridge provides `br0` and capture support.
* ISI depends on `br0` for namespace traffic.
* FMS depends on CAN hardware and `can0`.

Use the installer menu:

```text
1) Install module
```

Then select the module number.

To remove a module, use:

```text
2) Uninstall module
```

Then select the module number.

Module uninstall actions remove services and helper files created by that module, but do not purge Debian packages. The `purge` action is treated as an uninstall compatibility alias.

---

## Role-Based Startup Model

Pi 3 / 4 / 5 uses role-based startup.

The dashboard owns the role file:

```text
/etc/pi_roles.conf
```

The role file is the runtime source of truth for enabling and disabling role-managed services.

Supported role words:

```text
isi
fms
sniff
wireshark
sniffer
sniffer-bridge
```

Example role file:

```bash
ROLES="isi fms sniff"
```

The dashboard module installs:

```text
/usr/local/bin/pi-servsync.sh
/usr/local/bin/pi-rolectl.sh
/etc/systemd/system/pi-servsync.service
```

`pi-servsync.service` applies `/etc/pi_roles.conf` to relevant services.

Role behavior:

| Role             | Service behavior                                                |
| ---------------- | --------------------------------------------------------------- |
| `isi`            | Starts `bridge-check.service` and `isirunall.service`           |
| `fms`            | Starts `fms.service`                                            |
| `sniff`          | Starts `bridge-check.service` and `wireshark-autostart.service` |
| `wireshark`      | Same as `sniff`                                                 |
| `sniffer`        | Same as `sniff`                                                 |
| `sniffer-bridge` | Same as `sniff`                                                 |

When no relevant role is enabled, role-managed services should stop or exit cleanly.

---

## Module: Hotspot

Script:

```text
scripts/pi-3-4-5/module-hotspot.sh
```

The hotspot module installs and configures:

* `hostapd`
* `dnsmasq`
* `dhcpcd5`
* static `wlan0` hotspot IP
* wildcard captive DNS
* local dashboard name resolution

Package-cache dependencies:

```text
dnsmasq
hostapd
dhcpcd5
iproute2
iptables
rfkill
```

Default hotspot SSID format:

```text
initbox_<BOXNO>
```

Box number file:

```text
/etc/pi-boxno
```

Default hotspot password is controlled by:

```text
HOTSPOT_PASS
```

Default value in the script:

```text
TomatoH34d
```

Typical hotspot subnet by model:

| Hardware       | Subnet            |
| -------------- | ----------------- |
| Raspberry Pi 3 | `192.168.30.0/24` |
| Raspberry Pi 4 | `192.168.40.0/24` |
| Raspberry Pi 5 | `192.168.50.0/24` |

The hotspot module writes or manages:

```text
/etc/hostapd/hostapd.conf
/etc/dnsmasq.d/initbox-hotspot.conf
/etc/dhcpcd.conf
/etc/pi-boxno
```

The DNS configuration resolves captive-portal and general DNS requests to the hotspot IP, so clients can reach the dashboard using:

```text
http://initbox.wlan/
```

Hotspot owns DNS. The dashboard module must not write or append managed blocks to:

```text
/etc/dnsmasq.d/initbox-hotspot.conf
```

The clean ownership model is:

```text
module-hotspot.sh
  owns hostapd, dnsmasq, dhcpcd, wlan0 addressing, DHCP, DNS, and captive DNS names

module-dashboard.sh
  owns Node-RED, ttyd, portal.service, and the port-80 dashboard landing service
```

Recommended clean dnsmasq model:

```text
dhcp-option=3,<hotspot-ip>
dhcp-option=6,<hotspot-ip>
address=/initbox.wlan/<hotspot-ip>
address=/#/<hotspot-ip>
```

The `address=/#/<hotspot-ip>` catch-all intentionally resolves captive portal checks to InitBox while the client is connected to the hotspot.

Hotspot service checks:

```bash
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager
systemctl status dhcpcd --no-pager
journalctl -u hostapd -n 100 --no-pager
journalctl -u dnsmasq -n 100 --no-pager
```

Hotspot network checks:

```bash
ip addr show wlan0
sudo dnsmasq --test
sudo grep -nE '^(interface|bind|dhcp-range|address=/#)' /etc/dnsmasq.d/initbox-hotspot.conf
```

---

## Module: Dashboard and Web Terminal

Script:

```text
scripts/pi-3-4-5/module-dashboard.sh
```

Required repo-owned dashboard files:

```text
scripts/flows.json
scripts/settings.js
scripts/logo.png
```

The dashboard module installs and configures:

* Node.js 22 when required
* local Node-RED under `/home/initbox/.node-red`
* `node-red-dashboard`
* repo-owned `flows.json`
* repo-owned `settings.js`
* repo-owned `logo.png`
* `pi-nodered.service`
* ttyd Web Terminal
* `ttyd.service`
* captive portal landing service on port `80` that redirects users to the Node-RED dashboard UI
* `portal.service`
* role sync helper
* `pi-servsync.service`
* `/etc/pi_roles.conf`
* `/usr/local/bin/pi-stats.sh`

Package-cache dependencies:

```text
ca-certificates
curl
git
build-essential
cmake
libjson-c-dev
libwebsockets-dev
iptables
nodejs
npm
```

Dashboard URLs:

```text
http://initbox.wlan/
http://initbox.wlan:1880/ui
```

The preferred user-facing URL is:

```text
http://initbox.wlan/
```

The dashboard module installs `portal.service`, which listens on port `80` and redirects normal HTTP and captive-portal probe requests to the dashboard UI:

```text
http://<hotspot-ip>:1880/ui
```

The dashboard module does not manage dnsmasq. Captive DNS must already be provided by the hotspot module.

Windows "Action needed" captive portal behavior is only reliable when the client has no other active Internet path. During bench testing, disconnect Ethernet, VPN, and other Internet adapters before testing the hotspot captive portal.

Web Terminal URL:

```text
http://initbox.wlan:7681
```

The dashboard is the primary management interface for this branch.

Node-RED service model:

```text
pi-nodered.service is the only InitBox Node-RED service.
nodered.service must not be used.
Node-RED must not run from /root/.node-red.
```

Dashboard service checks:

```bash
systemctl status pi-nodered --no-pager
systemctl status nodered --no-pager || true
systemctl status ttyd --no-pager
systemctl status portal --no-pager
systemctl status pi-servsync --no-pager
journalctl -u pi-nodered -n 100 --no-pager
journalctl -u ttyd -n 100 --no-pager
journalctl -u portal -n 100 --no-pager
journalctl -u pi-servsync -n 100 --no-pager
```

Expected Node-RED checks:

```bash
ps -ef | grep -E 'node-red|red.js' | grep -v grep || true
sudo ss -lntp | grep ':1880' || true
sudo journalctl -u pi-nodered -n 80 --no-pager
```

Expected result:

```text
Node-RED runs as initbox.
Node-RED uses /home/initbox/.node-red.
Node-RED loads /home/initbox/.node-red/settings.js.
Node-RED loads /home/initbox/.node-red/flows.json.
nodered.service is inactive or masked.
```

Check listening ports:

```bash
ss -tulpn | grep -E ':80|:1880|:7681'
```

Expected ports:

```text
80     captive portal landing service to dashboard
1880   Node-RED
7681   ttyd Web Terminal
```

---

## Module: RTC

Script:

```text
scripts/pi-3-4-5/module-rtc.sh
```

The RTC module installs and configures:

* I2C enablement
* DS3231 RTC overlay
* `/usr/local/bin/rtc-sync.sh`
* `rtc-sync.service`
* `rtc-sync.timer`

Package-cache dependencies:

```text
i2c-tools
util-linux-extra
python3-smbus
curl
```

The RTC module supports these COPILOT time inputs:

```bash
/usr/local/bin/rtc-sync.sh --iso8601 2026-06-12T14:23:00Z
/usr/local/bin/rtc-sync.sh --iso 2026-06-12T14:23:00Z
/usr/local/bin/rtc-sync.sh --datetime 12.06.2026-14:23:00
```

Boot config changes may require one reboot before `/dev/rtc0` appears.

RTC checks:

```bash
timedatectl
hwclock -r
i2cdetect -y 1
ls -l /dev/rtc0
systemctl status rtc-sync --no-pager
systemctl status rtc-sync.timer --no-pager
journalctl -u rtc-sync -n 100 --no-pager
```

---

## Module: Sniffer / Bridge

Script:

```text
scripts/pi-3-4-5/module-ws-br0.sh
```

The sniffer bridge module installs and configures:

* `tshark`
* `dumpcap` capabilities
* `/usr/local/bin/wireshark.sh`
* `/usr/local/bin/log-prep.sh`
* `/usr/local/bin/bridge-check.sh`
* `wireshark-autostart.service`
* `bridge-check.service`

Package-cache dependencies:

```text
tshark
zip
libcap2-bin
bridge-utils
iproute2
```

Capture directory:

```text
/usr/tracefiles
```

Capture interface:

```text
br0
```

Startup is role-based.

Sniffer capture starts only when `/etc/pi_roles.conf` contains one of:

```text
sniff
wireshark
sniffer
sniffer-bridge
```

The bridge service starts when `/etc/pi_roles.conf` contains either:

```text
isi
```

or one of the sniffer roles:

```text
sniff
wireshark
sniffer
sniffer-bridge
```

Bridge behavior:

* If no ISI/sniffer role is enabled, `br0` is removed or left inactive.
* If one wired interface has carrier and ISI is enabled, that interface is bridged for ISI.
* If two or more wired interfaces have carrier, all active wired interfaces are bridged for sniffer/ISI use.
* `br0` is pure L2; host IP is not required on the bridge.

Sniffer service checks:

```bash
systemctl status bridge-check --no-pager
systemctl status wireshark-autostart --no-pager
journalctl -u bridge-check -n 100 --no-pager
journalctl -u wireshark-autostart -n 100 --no-pager
```

Bridge checks:

```bash
ip link show br0
bridge link
ip addr
```

Capture file checks:

```bash
ls -lah /usr/tracefiles
```

Prepare capture files for collection:

```bash
sudo /usr/local/bin/log-prep.sh
```

Expected `log-prep.sh` behavior:

* Stops `wireshark-autostart.service`.
* Compresses `.pcap`, `.pcapng`, `.pcap.gz`, and `.pcapng.gz` files into a ZIP.
* Deletes original capture files after compression.
* Leaves ZIP files in `/usr/tracefiles`.
* Restarts `wireshark-autostart.service` only if a sniff role is enabled.

---

## Module: ISI

Script:

```text
scripts/pi-3-4-5/module-isi.sh
```

The ISI module installs and configures:

* `/usr/local/bin/isirunall.sh`
* `isirunall.service`
* ISI payload files for:

  * DRACHE
  * NIX
  * ZEITNEHMER

Package-cache dependencies:

```text
isc-dhcp-client
netcat-openbsd
iproute2
```

Payload files:

```text
/usr/local/bin/isi1.txt
/usr/local/bin/isi2.txt
/usr/local/bin/isi3.txt
```

The Pi 3 / 4 / 5 ISI module expects `br0` to be created by:

```text
bridge-check.service
```

ISI starts only when `/etc/pi_roles.conf` includes:

```text
isi
```

ZEITNEHMER supports both:

```text
DateTime
Time_ISO8601
```

RTC sync is delegated to:

```text
/usr/local/bin/rtc-sync.sh
```

ISI service checks:

```bash
systemctl status isirunall --no-pager
journalctl -u isirunall -n 100 --no-pager
ip link show br0
bridge link
```

If ISI is enabled but does not run, check:

```bash
cat /etc/pi_roles.conf
systemctl status bridge-check --no-pager
journalctl -u bridge-check -n 100 --no-pager
journalctl -u isirunall -n 100 --no-pager
```

---

## Module: FMS

Script:

```text
scripts/pi-3-4-5/module-fms.sh
```

The FMS module installs and configures:

* MCP2515 CAN overlay
* managed CAN0 block in `/etc/network/interfaces`
* `/usr/local/bin/fms.py`
* `fms.service`
* placeholder `/usr/local/bin/CAN.trc`

Package-cache dependencies:

```text
can-utils
ifupdown
python3
iproute2
```

FMS sends CAN frames only when `/etc/pi_roles.conf` includes:

```text
fms
```

CAN trace file:

```text
/usr/local/bin/CAN.trc
```

Replace the placeholder CAN trace file with the real trace file before enabling the `fms` role.

MCP2515 overlay changes require one reboot before `can0` appears.

FMS checks:

```bash
cat /etc/pi_roles.conf
ip -details link show can0
systemctl status fms --no-pager
journalctl -u fms -n 100 --no-pager
```

If `can0` is missing after installing the module, reboot once:

```bash
sudo reboot
```

Then recheck:

```bash
ip -details link show can0
systemctl status fms --no-pager
```

---

## Module Install and Uninstall Behavior

All supported modules should support:

```text
install
uninstall
purge
```

The `purge` action is treated as an uninstall compatibility alias.

Uninstall actions should:

* Stop and disable services created by the module.
* Remove systemd unit files created by the module.
* Remove helper scripts created by the module.
* Reset the related dashboard module flag in `/etc/initbox-mods.conf`.
* Restart `pi-nodered.service` when present so dashboard controls refresh immediately.
* Leave Debian packages installed.
* Leave package cache files in place.
* Avoid deleting unrelated user data.

Use the installer menu:

```text
1) Install module
2) Uninstall module
```

After uninstalling, verify:

```bash
cat /etc/initbox-mods.conf
cat /etc/initbox/install-state.env
systemctl --failed
```

---

## Role Verification

Check the current role file:

```bash
cat /etc/pi_roles.conf
```

Enable ISI, FMS, and sniffer:

```bash
sudo sh -c 'echo "ROLES=\"isi fms sniff\"" > /etc/pi_roles.conf'
sudo /usr/local/bin/pi-servsync.sh
```

Check results:

```bash
systemctl status pi-servsync --no-pager
systemctl status bridge-check --no-pager
systemctl status wireshark-autostart --no-pager
systemctl status isirunall --no-pager
systemctl status fms --no-pager
```

Disable all runtime roles:

```bash
sudo sh -c 'echo "ROLES=\"\"" > /etc/pi_roles.conf'
sudo /usr/local/bin/pi-servsync.sh
```

Expected behavior after disabling all roles:

* `bridge-check.service` stops unless ISI/sniffer role is enabled.
* `wireshark-autostart.service` stops unless sniffer role is enabled.
* `isirunall.service` stops unless ISI role is enabled.
* `fms.service` stops unless FMS role is enabled.

---

## Field Diagnostics

Run:

```bash
sudo ./scripts/initbox-status.sh
```

To include service logs:

```bash
sudo ./scripts/initbox-status.sh logs
```

The status command prints local diagnostics for:

* system information
* install state
* role file
* box number
* module flags
* hotspot configuration
* network interfaces
* bridge state
* CAN/FMS state
* RTC/time state
* dashboard state
* sniffer trace files
* failed services
* listening ports
* known service status
* installer logs

This command is read-only and designed to work without Internet access.

---

## Service Checks

Check failed services:

```bash
systemctl --failed
```

Check all InitBox services:

```bash
systemctl status dhcpcd --no-pager
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager
systemctl status pi-nodered --no-pager
systemctl status nodered --no-pager || true
systemctl status ttyd --no-pager
systemctl status portal --no-pager
systemctl status pi-servsync --no-pager
systemctl status bridge-check --no-pager
systemctl status wireshark-autostart --no-pager
systemctl status isirunall --no-pager
systemctl status fms --no-pager
systemctl status rtc-sync --no-pager
systemctl status rtc-sync.timer --no-pager
```

Recent logs:

```bash
journalctl -u dhcpcd -n 100 --no-pager
journalctl -u hostapd -n 100 --no-pager
journalctl -u dnsmasq -n 100 --no-pager
journalctl -u pi-nodered -n 100 --no-pager
journalctl -u ttyd -n 100 --no-pager
journalctl -u portal -n 100 --no-pager
journalctl -u pi-servsync -n 100 --no-pager
journalctl -u bridge-check -n 100 --no-pager
journalctl -u wireshark-autostart -n 100 --no-pager
journalctl -u isirunall -n 100 --no-pager
journalctl -u fms -n 100 --no-pager
journalctl -u rtc-sync -n 100 --no-pager
```

---

## Network Checks

General checks:

```bash
ip addr
ip route
ip link show
```

Hotspot checks:

```bash
ip addr show wlan0
systemctl status hostapd dnsmasq dhcpcd --no-pager
sudo dnsmasq --test
```

Bridge checks:

```bash
ip link show br0
bridge link
systemctl status bridge-check --no-pager
```

Wired interface checks:

```bash
ip link show
cat /sys/class/net/eth0/carrier 2>/dev/null || true
cat /sys/class/net/eth1/carrier 2>/dev/null || true
```

CAN checks:

```bash
ip -details link show can0
```

RTC checks:

```bash
timedatectl
hwclock -r
i2cdetect -y 1
ls -l /dev/rtc0
```

Package cache checks:

```bash
sudo ./scripts/lib/packages.sh status
ls -lah /opt/initbox-package-cache/apt
ls -lah /opt/initbox-package-cache/dashboard
```

Trace file checks:

```bash
ls -lah /usr/tracefiles
```

Listening ports:

```bash
ss -tulpn
```

Common expected ports:

| Feature                           | Typical port |
| --------------------------------- | -----------: |
| Dashboard captive portal landing service |         `80` |
| Node-RED                          |       `1880` |
| Web Terminal / ttyd               |       `7681` |

---

## Capture File Preparation

If sniffer capture is enabled, PCAP files are stored in:

```text
/usr/tracefiles
```

Prepare logs/captures for collection:

```bash
sudo /usr/local/bin/log-prep.sh
```

Expected behavior:

* Stops `wireshark-autostart.service`.
* Compresses capture files into a ZIP archive.
* Deletes original capture files after compression.
* Leaves ZIP files in `/usr/tracefiles`.
* Restarts `wireshark-autostart.service` only if a sniff role is enabled.

Check files:

```bash
ls -lah /usr/tracefiles
```

---

## Reboot Test

Before field deployment, reboot once:

```bash
sudo reboot
```

After the device comes back online, repeat:

```bash
systemctl --failed
ip addr
ip route
ip link show
ss -tulpn
sudo ./scripts/initbox-status.sh
sudo ./scripts/lib/packages.sh status
```

Confirm:

* Required services start automatically.
* Required interfaces return.
* Required ports are listening.
* Dashboard works.
* Web Terminal works.
* Role-based startup behaves correctly.
* Package cache exists.
* Dashboard cache exists after dashboard install.
* Logs do not show repeated failures.

---

## Offline Rerun Test

After lab setup is complete, test a simulated offline rerun.

First confirm cache exists:

```bash
sudo ./scripts/lib/packages.sh status
ls -lah /opt/initbox-package-cache/apt
ls -lah /opt/initbox-package-cache/dashboard
```

Confirm dashboard runtime exists:

```bash
command -v node || true
command -v ttyd || true
sudo -u initbox bash -lc 'test -x ~/.node-red/node_modules/.bin/node-red && echo node-red-local-ok'
sudo -u initbox bash -lc 'cd ~/.node-red && npm list node-red-dashboard --depth=0'
ls -l /home/initbox/.node-red/flows.json
ls -l /home/initbox/.node-red/settings.js
ls -l /home/initbox/.node-red/public/logo.png
```

Then disconnect Internet and rerun one or more modules from the installer.

Expected behavior:

* Debian package installs use local cache.
* Hotspot reruns without Internet.
* RTC reruns without Internet.
* Sniffer/bridge reruns without Internet.
* ISI reruns without Internet.
* FMS reruns without Internet.
* Dashboard reruns without Internet only if Node.js, Node-RED, and `node-red-dashboard` were already installed once during lab setup.

---

## Fresh Bake Validation

A fresh Raspberry Pi OS install is the best final validation before field deployment.

Use this flow:

1. Flash fresh Raspberry Pi OS.
2. Boot the Pi with Internet available.
3. Clone the `pi-3-4-5` branch.
4. Confirm required repo files exist.
5. Run installer sanity checks.
6. Prepare package cache.
7. Install hotspot.
8. Install dashboard.
9. Install RTC if required.
10. Install sniffer-bridge if required.
11. Install ISI if required.
12. Install FMS if required.
13. Reboot.
14. Verify services.
15. Test dashboard UI.
16. Test role-based startup.
17. Test uninstall for at least one module.
18. Reinstall the module.
19. Run diagnostics.
20. Perform offline rerun test if required.

Fresh bake checks:

```bash
cd /home/initbox/RaspberryPi

sudo ./scripts/initbox-installer.sh pi-3-4-5 c

ls -l scripts/flows.json
ls -l scripts/settings.js
ls -l scripts/logo.png

systemctl status pi-nodered --no-pager
systemctl status nodered --no-pager || true
journalctl -u pi-nodered -n 80 --no-pager

ls -l /home/initbox/.node-red/flows.json
ls -l /home/initbox/.node-red/settings.js
ls -l /home/initbox/.node-red/public/logo.png

cat /etc/initbox-mods.conf
cat /etc/initbox/install-state.env

ps -ef | grep -E 'node-red|red.js' | grep -v grep || true
sudo ss -lntp | grep ':1880' || true
```

Expected results:

```text
pi-nodered.service is active.
nodered.service is inactive or masked.
Node-RED runs as initbox.
Node-RED uses /home/initbox/.node-red.
flows.json exists under /home/initbox/.node-red.
settings.js exists under /home/initbox/.node-red.
logo.png exists under /home/initbox/.node-red/public.
Module flags reflect installed modules.
Installer state records the latest action.
```

---

## Final Field Deployment Sign-Off

Before the device leaves the lab:

* [ ] Correct branch is used: `pi-3-4-5`.
* [ ] Correct profile is used: `pi-3-4-5`.
* [ ] Installer sanity checks passed.
* [ ] Internet was available during lab setup.
* [ ] Package cache was prepared.
* [ ] Package cache status was checked.
* [ ] `scripts/flows.json` exists in the repo.
* [ ] `scripts/settings.js` exists in the repo.
* [ ] `scripts/logo.png` exists in the repo.
* [ ] Dashboard asset cache was created.
* [ ] `ttyd` was installed or cached.
* [ ] Node.js 22 was installed or confirmed.
* [ ] Node-RED was installed locally under `/home/initbox/.node-red`.
* [ ] `node-red-dashboard` was installed.
* [ ] Runtime `/home/initbox/.node-red/flows.json` was copied from the repo.
* [ ] Runtime `/home/initbox/.node-red/settings.js` was copied from the repo.
* [ ] Runtime `/home/initbox/.node-red/public/logo.png` was copied from the repo.
* [ ] `pi-nodered.service` is active.
* [ ] `nodered.service` is inactive or masked.
* [ ] Node-RED is running as `initbox`, not root.
* [ ] Required modules were installed.
* [ ] Device was reboot-tested.
* [ ] Required services are active.
* [ ] Required interfaces are present.
* [ ] Dashboard is reachable.
* [ ] Web Terminal is reachable.
* [ ] `/etc/pi_roles.conf` was tested.
* [ ] Role-based startup was tested.
* [ ] Installer uninstall menu was tested for at least one module.
* [ ] RTC was checked if installed.
* [ ] CAN/FMS was checked if required.
* [ ] Sniffer capture was checked if required.
* [ ] `log-prep.sh` was checked if sniffer is required.
* [ ] Offline rerun behavior was tested where required.
* [ ] Installer log was reviewed.
* [ ] Install state was reviewed.
* [ ] Field diagnostics command was run.
* [ ] Device is physically labelled.
* [ ] Access details are recorded securely.
* [ ] Field team knows which features are installed.

---

## Troubleshooting Principles

Start with local checks:

```bash
sudo ./scripts/initbox-status.sh
systemctl --failed
ip addr
ip route
ip link show
ss -tulpn
sudo ./scripts/lib/packages.sh status
```

Then check the relevant service:

```bash
systemctl status SERVICE_NAME --no-pager
journalctl -u SERVICE_NAME -n 100 --no-pager
```

Do not assume Internet access is available in the field.

If a package is missing in the field, the device was not fully prepared in the lab and should be returned to the lab or repaired using a controlled maintenance process.

---

## Common Troubleshooting

### Package cache is empty

Check:

```bash
sudo ./scripts/lib/packages.sh status
ls -lah /opt/initbox-package-cache/apt
```

Fix in the lab with Internet:

```bash
cd /home/initbox/RaspberryPi
sudo ./scripts/initbox-installer.sh pi-3-4-5 p
```

---

### Offline package install fails

Check:

```bash
sudo ./scripts/lib/packages.sh status
ls -lah /opt/initbox-package-cache/apt
```

The cache is incomplete. Reconnect Internet in the lab and rerun:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5 p
```

---

### Dashboard offline rerun fails

Check:

```bash
command -v node || true
command -v ttyd || true
ls -lah /opt/initbox-package-cache/dashboard
sudo -u initbox bash -lc 'test -x ~/.node-red/node_modules/.bin/node-red && echo node-red-local-ok'
sudo -u initbox bash -lc 'cd ~/.node-red && npm list node-red-dashboard --depth=0'
```

Expected for offline dashboard rerun:

```text
Node.js installed
local Node-RED installed under /home/initbox/.node-red
node-red-dashboard installed
ttyd installed or cached
```

If Node-RED or `node-red-dashboard` was never installed before going offline, reconnect Internet in the lab and run the dashboard module once.

---

### Dashboard not reachable

Check:

```bash
systemctl status pi-nodered --no-pager
systemctl status nodered --no-pager || true
systemctl status portal --no-pager
ss -tulpn | grep -E ':80|:1880'
journalctl -u pi-nodered -n 100 --no-pager
```

Expected:

```text
pi-nodered.service active
nodered.service inactive or masked
portal.service active
port 80 available for captive portal landing service
port 1880 available for Node-RED
```

Check runtime assets:

```bash
ls -l /home/initbox/.node-red/flows.json
ls -l /home/initbox/.node-red/settings.js
ls -l /home/initbox/.node-red/public/logo.png
```

Check captive portal landing service:

```bash
sudo ss -ltnp | grep ':80 '
curl -I http://initbox.wlan/
curl -I http://$(ip -4 addr show wlan0 | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)/
```

Expected result:

```text
portal.service active
port 80 listening
HTTP redirects to http://<hotspot-ip>:1880/ui
```

---

### Windows Action Needed opens MSN instead of InitBox

This usually means the Windows laptop still has another active Internet path, such as Ethernet, VPN, another Wi-Fi adapter, or a corporate network. Windows may use that path for its captive-portal check and open the real MSN/Microsoft page instead of the InitBox portal.

Check on Windows:

```cmd
ipconfig /all
nslookup www.msftconnecttest.com
nslookup www.msn.com
curl.exe -v http://www.msftconnecttest.com/connecttest.txt
```

Expected while testing only the InitBox hotspot:

```text
DNS Server: <hotspot-ip>
www.msftconnecttest.com -> <hotspot-ip>
www.msn.com -> <hotspot-ip>
curl connects from the hotspot client IP to the hotspot IP
```

If `nslookup` uses a corporate DNS server or `curl` connects from a corporate Ethernet IP, disconnect that network path and test again.

For bench testing:

```cmd
ipconfig /flushdns
```

Also disconnect Ethernet, VPN, and other Internet adapters before reconnecting to the InitBox hotspot.

The reliable manual fallback is:

```text
http://initbox.wlan/
```


---

### Node-RED starts from root

This is not allowed for InitBox.

Check:

```bash
ps -ef | grep -E 'node-red|red.js' | grep -v grep || true
systemctl status nodered --no-pager || true
systemctl status pi-nodered --no-pager
```

Expected:

```text
Node-RED runs as initbox.
pi-nodered.service owns the Node-RED process.
nodered.service is inactive or masked.
```

Repair by rerunning the dashboard module:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5
```

Choose:

```text
1) Install module
```

Then choose:

```text
dashboard
```

---

### Web Terminal not reachable

Check:

```bash
systemctl status ttyd --no-pager
ss -tulpn | grep 7681
journalctl -u ttyd -n 100 --no-pager
command -v ttyd || true
ls -lah /opt/initbox-package-cache/dashboard
```

Expected:

```text
ttyd.service active
port 7681 listening
ttyd installed or restorable from dashboard cache
```

---

### Role changes do not start services

Check:

```bash
cat /etc/pi_roles.conf
systemctl status pi-servsync --no-pager
journalctl -u pi-servsync -n 100 --no-pager
```

Manually apply roles:

```bash
sudo /usr/local/bin/pi-servsync.sh
```

---

### Sniffer does not start

Check role file:

```bash
cat /etc/pi_roles.conf
```

Expected one of:

```text
sniff
wireshark
sniffer
sniffer-bridge
```

Check services:

```bash
systemctl status bridge-check --no-pager
systemctl status wireshark-autostart --no-pager
journalctl -u bridge-check -n 100 --no-pager
journalctl -u wireshark-autostart -n 100 --no-pager
```

Check bridge and capture directory:

```bash
ip link show br0
bridge link
ls -lah /usr/tracefiles
```

---

### ISI does not start

Check role file:

```bash
cat /etc/pi_roles.conf
```

Expected:

```text
isi
```

Check services:

```bash
systemctl status bridge-check --no-pager
systemctl status isirunall --no-pager
journalctl -u bridge-check -n 100 --no-pager
journalctl -u isirunall -n 100 --no-pager
```

Check bridge:

```bash
ip link show br0
bridge link
```

---

### FMS does not send CAN frames

Check role file:

```bash
cat /etc/pi_roles.conf
```

Expected:

```text
fms
```

Check CAN interface:

```bash
ip -details link show can0
```

Check service:

```bash
systemctl status fms --no-pager
journalctl -u fms -n 100 --no-pager
```

Check CAN trace file:

```bash
ls -lh /usr/local/bin/CAN.trc
head -n 20 /usr/local/bin/CAN.trc
```

If `can0` is missing after MCP2515 overlay setup, reboot once.

---

### RTC does not appear

Check:

```bash
i2cdetect -y 1
ls -l /dev/rtc0
timedatectl
systemctl status rtc-sync --no-pager
journalctl -u rtc-sync -n 100 --no-pager
```

If the overlay was just added, reboot once.

---

## Development Checks

Run syntax checks before testing on hardware:

```bash
bash -n scripts/initbox-installer.sh
bash -n scripts/initbox-status.sh
bash -n scripts/update-repo.sh
bash -n scripts/lib/profile.sh
bash -n scripts/lib/modules.sh
bash -n scripts/lib/state.sh
bash -n scripts/lib/packages.sh
bash -n scripts/pi-3-4-5/module-dashboard.sh
bash -n scripts/pi-3-4-5/module-fms.sh
bash -n scripts/pi-3-4-5/module-hotspot.sh
bash -n scripts/pi-3-4-5/module-isi.sh
bash -n scripts/pi-3-4-5/module-rtc.sh
bash -n scripts/pi-3-4-5/module-ws-br0.sh
```

If ShellCheck is available:

```bash
shellcheck scripts/initbox-installer.sh scripts/initbox-status.sh scripts/update-repo.sh scripts/lib/*.sh scripts/pi-3-4-5/*.sh
```

---

## Design Rules

* This branch is for Raspberry Pi 3 / 4 / 5 only.
* Lab setup requires Internet access.
* Field deployment assumes the Pi is already configured.
* Debian packages must be cached during lab preparation.
* Dashboard should be installed once in the lab so Node.js, Node-RED, and npm dependencies exist locally.
* Dashboard is the primary management interface.
* Hotspot owns `/etc/dnsmasq.d/initbox-hotspot.conf`.
* Dashboard must not write dnsmasq configuration.
* Dashboard owns `portal.service` and `/usr/local/bin/initbox-dashboard-portal.py`.
* Web Terminal is bundled with the dashboard module.
* The installer main menu must use clear numeric choices for install, uninstall, checks, cache, logs, state, and quit.
* Module execution must not require typing `RUN`.
* Every supported module should support `install` and `uninstall`.
* Module uninstall must not purge Debian packages.
* Dashboard assets are repo-owned and must be copied from `scripts/`.
* Generated or hostname-specific Node-RED flow files must not be the source of truth.
* `pi-nodered.service` is the only supported InitBox Node-RED service.
* `nodered.service` must be stopped, disabled, masked, and not used by InitBox.
* Node-RED must run as `initbox`, not root.
* `/etc/pi_roles.conf` is the runtime source of truth for role-based startup.
* Role-managed services must stop or exit cleanly when their role is disabled.
* `pi-servsync.service` applies role changes to systemd services.
* `br0` is managed by `bridge-check.service`.
* ISI uses `br0`.
* ISI should not create Pi Zero-style bridges on this branch.
* Sniffer capture uses `br0`.
* `log-prep.sh` must only restart capture when a sniff role is enabled.
* FMS must only send CAN frames when the `fms` role is enabled.
* RTC sync must support both `DateTime` and `Time_ISO8601`.
* Installer behavior should be repeatable.
* Verification must be completed before field deployment.
* Logs should be kept for support.
* Install state should be recorded for support.
* Unnecessary changes to working module code should be avoided.
