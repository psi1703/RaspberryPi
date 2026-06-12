# InitBox Raspberry Pi 3 / 4 / 5 Setup

This branch contains setup scripts and documentation for preparing Raspberry Pi 3, Raspberry Pi 4, and Raspberry Pi 5 devices as InitBox field appliances.

This branch is dedicated to the full Pi 3 / 4 / 5 InitBox stack.

The lightweight Raspberry Pi Zero W / Zero 2W build is maintained separately in the `pi-zero-W-2W` branch.

---

## Operating Model

InitBox devices are prepared in a lab environment where Internet access is available.

After setup and verification, the Raspberry Pi is deployed in the field as a preconfigured appliance.

Field deployment should not depend on Internet access for package installation.

The intended workflow is:

1. Prepare the Raspberry Pi in the lab.
2. Make sure the Pi has Internet access.
3. Clone or update the `pi-3-4-5` branch.
4. Run the installer for the `pi-3-4-5` profile.
5. Run installer sanity checks.
6. Prepare the Debian package cache.
7. Install the required modules.
8. Allow dashboard assets to be downloaded or built once during lab setup.
9. Reboot if required.
10. Verify all required services.
11. Test role-based startup.
12. Run field diagnostics.
13. Deploy the prepared device in the field.

All required packages and first-time dashboard assets should be installed or cached during lab preparation.

---

## Offline / Field Rerun Model

The Pi 3 / 4 / 5 branch uses a lab-first cache model.

During lab setup with Internet:

* Debian packages are downloaded and kept on the Pi.
* Module installs use the package helper.
* `ttyd` is built once and cached on the Pi.
* The Node-RED installer script is downloaded once and cached on the Pi.
* Node-RED and `node-red-dashboard` are installed once and then reused on later reruns.

During field or offline reruns:

* Debian packages install from the local cache.
* Existing Node-RED installation is reused.
* Existing `node-red-dashboard` installation is reused.
* Cached `ttyd` binary is reused if `ttyd` is missing from the PATH.
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
/opt/initbox-package-cache/dashboard/update-nodejs-and-nodered-deb.sh
```

Important limitation:

```text
A fully offline dashboard install is possible only after dashboard was installed once in the lab with Internet.
```

This is because Node-RED and npm dependencies must exist locally before a field/offline rerun can reuse them.

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

This branch is not intended for:

```text
Raspberry Pi Zero W
Raspberry Pi Zero 2W
```

Pi Zero work belongs in the separate `pi-zero-W-2W` branch.

---

## Feature Summary

The Pi 3 / 4 / 5 branch supports:

* Hotspot
* Dashboard
* Web Terminal
* Debian package cache
* Dashboard asset cache
* Role-based service startup
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

This branch should not contain:

```text
profiles/pi-zero2w.conf
scripts/pi-zero2w/
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
* Download the Node-RED installer script once
* Build and cache `ttyd`
* Install Node-RED
* Install `node-red-dashboard`
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
* Show supported modules.
* Repair required repository permissions.
* Create install logs.
* Create the legacy module log path.
* Grant passwordless sudo to the operator user.
* Run baseline `apt-get update` when Internet is available.
* Run baseline `apt-get upgrade` when Internet is available.
* Prepare the package cache when requested.
* Show package cache status when requested.
* Require explicit `RUN` confirmation before executing a module script.
* Record install state.

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

---

## Installer Menu Options

The installer menu includes:

```text
1-N) Install/select supported module
c) Run sanity checks
p) Prepare/download package cache
k) Show package cache status
l) Show install log path
s) Show install state
q) Quit
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

Cached Node-RED installer script:

```text
/opt/initbox-package-cache/dashboard/update-nodejs-and-nodered-deb.sh
```

During the first lab install with Internet:

* `ttyd` is built from GitHub source.
* The installed `ttyd` binary is copied into the dashboard cache.
* The official Node-RED installer script is downloaded into the dashboard cache.
* Node-RED is installed.
* `node-red-dashboard` is installed in `/home/initbox/.node-red`.

During later offline reruns:

* `ttyd` is restored from the cached binary if missing.
* Node-RED is reused if already installed.
* `node-red-dashboard` is reused if already installed.
* If Node-RED was never installed before going offline, dashboard install cannot complete fully offline.

Verify dashboard cache:

```bash
ls -lah /opt/initbox-package-cache/dashboard
command -v ttyd || true
command -v node-red || true
sudo -u initbox bash -lc 'cd ~/.node-red && npm list node-red-dashboard --depth=0'
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

When prompted by the installer, type:

```text
RUN
```

only when you are ready to execute the selected module.

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

The dashboard module installs and configures:

* Node-RED dashboard
* `pi-nodered.service`
* ttyd Web Terminal
* `ttyd.service`
* captive portal redirect from port `80` to Node-RED port `1880`
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

Web Terminal URL:

```text
http://initbox.wlan:7681
```

The dashboard is the primary management interface for this branch.

Dashboard service checks:

```bash
systemctl status pi-nodered --no-pager
systemctl status ttyd --no-pager
systemctl status portal --no-pager
systemctl status pi-servsync --no-pager
journalctl -u pi-nodered -n 100 --no-pager
journalctl -u ttyd -n 100 --no-pager
journalctl -u portal -n 100 --no-pager
journalctl -u pi-servsync -n 100 --no-pager
```

Check listening ports:

```bash
ss -tulpn | grep -E ':80|:1880|:7681'
```

Expected ports:

```text
80     captive portal redirect to dashboard
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
| Dashboard captive portal redirect |         `80` |
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
command -v node-red
command -v ttyd
sudo -u initbox bash -lc 'cd ~/.node-red && npm list node-red-dashboard --depth=0'
```

Then disconnect Internet and rerun one or more modules from the installer.

Expected behavior:

* Debian package installs use local cache.
* Hotspot reruns without Internet.
* RTC reruns without Internet.
* Sniffer/bridge reruns without Internet.
* ISI reruns without Internet.
* FMS reruns without Internet.
* Dashboard reruns without Internet only if Node-RED and `node-red-dashboard` were already installed once during lab setup.

---

## Final Field Deployment Sign-Off

Before the device leaves the lab:

* [ ] Correct branch is used: `pi-3-4-5`.
* [ ] Correct profile is used: `pi-3-4-5`.
* [ ] Installer sanity checks passed.
* [ ] Internet was available during lab setup.
* [ ] Package cache was prepared.
* [ ] Package cache status was checked.
* [ ] Dashboard asset cache was created.
* [ ] `ttyd` was installed or cached.
* [ ] Node-RED was installed.
* [ ] `node-red-dashboard` was installed.
* [ ] Required modules were installed.
* [ ] Device was reboot-tested.
* [ ] Required services are active.
* [ ] Required interfaces are present.
* [ ] Dashboard is reachable.
* [ ] Web Terminal is reachable.
* [ ] `/etc/pi_roles.conf` was tested.
* [ ] Role-based startup was tested.
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
command -v node-red || true
command -v ttyd || true
ls -lah /opt/initbox-package-cache/dashboard
sudo -u initbox bash -lc 'cd ~/.node-red && npm list node-red-dashboard --depth=0'
```

Expected for offline dashboard rerun:

```text
node-red installed
node-red-dashboard installed
ttyd installed or cached
Node-RED installer cached if first-time rerun is needed in lab
```

If Node-RED or `node-red-dashboard` was never installed before going offline, reconnect Internet in the lab and run the dashboard module once.

---

### Dashboard not reachable

Check:

```bash
systemctl status pi-nodered --no-pager
systemctl status portal --no-pager
ss -tulpn | grep -E ':80|:1880'
journalctl -u pi-nodered -n 100 --no-pager
```

Expected:

```text
pi-nodered.service active
portal.service active
port 80 available for captive portal redirect
port 1880 available for Node-RED
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
* Pi Zero W / Zero 2W work belongs in the `pi-zero-W-2W` branch.
* Lab setup requires Internet access.
* Field deployment assumes the Pi is already configured.
* Debian packages must be cached during lab preparation.
* Dashboard should be installed once in the lab so Node-RED and npm dependencies exist locally.
* Dashboard is the primary management interface.
* Web Terminal is bundled with the dashboard module.
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
