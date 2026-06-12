# InitBox Raspberry Pi Zero W / Zero 2W Setup

This branch is dedicated to the lightweight InitBox build for Raspberry Pi Zero W and Raspberry Pi Zero 2W class devices.

The goal of this branch is clear separation from the heavier Raspberry Pi 3 / 4 / 5 design. The Zero profile uses Web Terminal, hotspot, ISI, FMS, and optional `br0` packet capture only. It must not install dashboard components.

Field deployment should not depend on Internet access. All package downloads, baseline operating-system updates, package-cache verification, and module installation should be completed in the lab before the device leaves for the field.

---

## Supported Hardware

| Profile     | Hardware                      | Dashboard | Management interface |
| ----------- | ----------------------------- | --------: | -------------------- |
| `pi-zero2w` | Raspberry Pi Zero W / Zero 2W |        No | Web Terminal & SSH         |

The profile file is:

```text
profiles/pi-zero2w.conf
```

---

## Operating Model

The intended workflow is:

1. Flash Raspberry Pi OS.
2. Boot the Pi in the lab with Internet access.
3. Clone this branch.
4. Run installer sanity checks.
5. Run the baseline OS update while Internet is available.
6. Preseed the offline package cache while Internet is available.
7. Verify the offline package cache.
8. Install the required modules.
9. Reboot.
10. Verify hotspot, Web Terminal, ISI, FMS, and optional packet capture.
11. Deploy the prepared device in the field.

All package downloads and operating-system updates must happen in the lab.

In the field, module installation should use only the local package cache.

---

## Clean Install After Reflash

Clone this branch and run the installer:

```bash
cd /home/initbox
git clone -b pi-zero-W-2W https://github.com/psi1703/RaspberryPi.git
cd RaspberryPi
sudo ./scripts/initbox-installer.sh pi-zero2w
```

The installer is expected to:

* repair repository script permissions;
* create installer logs;
* grant the operator user passwordless sudo when run as root;
* load the `pi-zero2w` profile;
* show only supported Pi Zero W / Zero 2W modules;
* run sanity checks;
* provide an explicit baseline update action;
* provide explicit package preseed and package verify actions;
* require explicit `RUN` confirmation before installing a module;
* record install state in `/etc/initbox/install-state.env`.

Passwordless sudo is installed before package and module operations so later module scripts can run consistently without repeated password prompts.

---

## Branch Policy

This branch is for Pi Zero W / Zero 2W only.

Required rules:

* Use Web Terminal, not dashboard.
* Keep `ttyd` on port `7681`.
* Keep port `80` owned by the lightweight captive HTTP redirect socket.
* Let `isirunall.service` own `br0` for ISI.
* Let the sniffer module capture `br0`; do not run a competing dynamic bridge manager on Pi Zero.
* Keep scripts ShellCheck-friendly and repeatable from a clean reflash.
* Do not purge packages during uninstall.
* Treat `purge` as a compatibility alias for uninstall.

---

## Repository Layout

```text
README.md
LICENSE

profiles/
  README.md
  pi-zero2w.conf

scripts/
  packages.txt
  initbox-installer.sh
  initbox-status.sh
  update-repo.sh
  lib/
    profile.sh
    modules.sh
    state.sh
    packages.sh
  pi-zero2w/
    module-fms.sh
    module-hotspot.sh
    module-isi.sh
    module-ttyd-portal.sh
    module-ws-br0.sh
```

Important module ownership:

| Module           | Script                                    | Ownership                                                              |
| ---------------- | ----------------------------------------- | ---------------------------------------------------------------------- |
| Hotspot          | `scripts/pi-zero2w/module-hotspot.sh`     | `hostapd`, `dnsmasq`, wlan0 hotspot IP, DHCP/DNS, wildcard captive DNS |
| Web Terminal     | `scripts/pi-zero2w/module-ttyd-portal.sh` | `ttyd`, port `7681`, port `80` captive redirect socket                 |
| ISI              | `scripts/pi-zero2w/module-isi.sh`         | `br0`, namespaces, veth pairs, DHCP inside namespaces, XML clients     |
| FMS              | `scripts/pi-zero2w/module-fms.sh`         | FMS/CAN support                                                        |
| Sniffer / Bridge | `scripts/pi-zero2w/module-ws-br0.sh`      | `tshark`, `/usr/tracefiles`, `log-prep.sh`, capture on `br0`           |

---

## Offline Package Cache Model

This branch uses a lab-preseeded local package cache.

Package list:

```text
scripts/packages.txt
```

Package helper:

```text
scripts/lib/packages.sh
```

Default cache directory:

```text
/opt/initbox/packages
```

The cache is prepared in the lab while Internet is available. Field installation should not need Internet.

The package list should contain only packages required for this Pi Zero branch:

```text
ca-certificates
curl
dnsmasq
hostapd
dhcpcd5
iproute2
iptables
rfkill
isc-dhcp-client
netcat-openbsd
bridge-utils
can-utils
ifupdown
zip
libcap2-bin
tshark
```

Do not include these in the default Pi Zero field package list:

```text
wireshark
wireshark-common
shellcheck
tcpdump
```

Notes:

* `tshark` is included because packet capture is a core requirement.
* `wireshark` and `wireshark-common` are not listed manually.
* `tcpdump` is not required when `tshark` is the selected packet-capture tool.
* `shellcheck` is a development tool, not a field runtime package.
* Python 3 is expected to already exist on Raspberry Pi OS and is not listed here.

The package helper must install only the package names requested by the module. It must not install every `.deb` file in `/opt/initbox/packages`.

Correct behavior:

```text
ISI module requests:
  isc-dhcp-client
  netcat-openbsd
  iproute2
  bridge-utils

Only those requested package names and their required dependencies are installed.
```

Incorrect behavior:

```text
apt-get install /opt/initbox/packages/*.deb
```

That installs the entire cache and must not be used for module installation.

---

## Lab Package Preparation

Run the installer:

```bash
sudo ./scripts/initbox-installer.sh pi-zero2w
```

Use the menu actions for:

```text
c  sanity checks
b  baseline OS update
p  preseed offline package cache
v  verify offline package cache
```

Recommended lab sequence:

```text
1. Run sanity checks.
2. Run baseline OS update.
3. Preseed the package cache.
4. Verify the package cache.
5. Install required modules.
6. Reboot.
7. Verify all services.
```

To rebuild the package cache cleanly:

```bash
sudo rm -rf /opt/initbox/packages
sudo ./scripts/initbox-installer.sh pi-zero2w p
sudo ./scripts/initbox-installer.sh pi-zero2w v
```

---

## Pi Zero Web Terminal and Captive Portal Model

The Pi Zero branch uses a lightweight captive portal design:

```text
Wi-Fi client
  -> hotspot DNS wildcard
  -> Raspberry Pi hotspot IP
  -> port 80 systemd socket responder
  -> HTTP 302 redirect to http://initbox.wlan:7681/
  -> ttyd Web Terminal
```

Service ownership is intentionally split:

```text
module-hotspot.sh
  owns hostapd
  owns dnsmasq
  owns wlan0 hotspot IP
  owns DHCP gateway option
  owns DHCP DNS option
  owns wildcard captive DNS

module-ttyd-portal.sh
  owns ttyd installation
  owns ttyd.service on port 7681
  owns initbox-captive-http.socket on port 80
  owns socket-activated HTTP 302 responder
```

Expected URLs:

```text
Captive portal URL: http://initbox.wlan/
Web Terminal URL:   http://initbox.wlan:7681/
```

Expected port ownership:

```text
port 80    systemd captive HTTP socket
port 7681  ttyd Web Terminal
```

Do not run `ttyd` directly on port `80`. Windows captive portal detection expects a normal HTTP response on port `80`; the Zero design provides that with a lightweight HTTP 302 responder.

`ttyd` is downloaded once in the lab and kept. It should not be deleted during uninstall.

---

## ISI simulator on Pi Zero W / Zero 2W

`module-isi.sh` installs `isirunall.service` and writes:

```text
/usr/local/bin/isirunall.sh
```

Safety rules:

* installing ISI does not immediately bridge Ethernet;
* installing ISI does not flush or enslave Ethernet ports;
* `isirunall.service` is enabled but stopped after install;
* runtime refuses to create `br0` unless a wired Ethernet port has carrier and a `10.x.x.x` IPv4 address;
* if the COPILOT network gate is not passed, Ethernet is left untouched;
* if `UPLINK_IF` is unset, all detected wired Ethernet ports are bridged after the gate passes;
* if `UPLINK_IF` is set, only that interface is bridged.

This protects normal lab Internet connectivity. The bridge should be created only when the device is connected to the COPILOT-side network.

The ISI runner:

* checks the COPILOT network gate;
* creates or reuses `br0` only after the gate passes;
* disables STP and sets `forward_delay 0`;
* attaches detected wired Ethernet adapters to `br0`;
* creates three namespaces: `ns1`, `ns2`, and `ns3`;
* creates deterministic veth MAC addresses;
* gets a fresh DHCP lease inside each namespace;
* discovers the COPILOT IP from DHCP;
* runs DRACHE from `ns1`;
* runs NIX from `ns2`;
* runs ZEITNEHMER from `ns3`.

Expected namespace roles:

| Namespace | App name   | Payload file              |
| --------- | ---------- | ------------------------- |
| `ns1`     | DRACHE     | `/usr/local/bin/isi1.txt` |
| `ns2`     | NIX        | `/usr/local/bin/isi2.txt` |
| `ns3`     | ZEITNEHMER | `/usr/local/bin/isi3.txt` |

ZEITNEHMER requests both time fields for compatibility:

```xml
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>DateTime,Time_ISO8601</Items><Cyclic>5</Cyclic></IsiGet>
```

Runtime behavior must be safe across different COPILOT versions:

```text
Time_ISO8601 present -> use Time_ISO8601
DateTime present     -> use DateTime
Neither present      -> log and continue
Bad timestamp        -> log and continue
Clock set failed     -> log and continue
```

DRACHE and NIX responses may be suppressed in the journal to avoid burying ZEITNEHMER logs. Use the sniffer module when you need to prove XML is flowing on `br0`.

---

## Pi Zero br0 Packet Capture

`module-ws-br0.sh` installs a lightweight packet-capture service for `br0`.

On Pi Zero W / Zero 2W:

* ISI owns and creates `br0`.
* The sniffer module does not create, flush, enslave, or manage Ethernet interfaces.
* The capture service waits for `br0` to exist.
* The capture service records traffic from `br0` after ISI creates the bridge.
* No dynamic `bridge-check.service` should manage `br0` on this branch.
* Packet capture uses `tshark`.

This separation is intentional. ISI controls bridge lifecycle because it knows when the COPILOT `10.x.x.x` network gate has passed. The sniffer module is passive and should only observe traffic on `br0`.

Capture files are stored in:

```text
/usr/tracefiles
```

The helper script:

```text
/usr/local/bin/log-prep.sh
```

prepares capture files for collection. It can:

* stop the sniffer service temporarily;
* zip existing `.pcap`, `.pcapng`, `.pcap.gz`, and `.pcapng.gz` files;
* delete the original capture files after ZIP creation;
* leave the ZIP archive in `/usr/tracefiles`;
* restart capture only when capture was already active before preparation.

`log-prep.sh` must not depend on `/etc/pi_roles.conf` or a legacy `sniff` role on this branch.

Correct restart policy:

```text
wireshark-autostart.service active before log-prep:
  stop service
  zip capture files
  delete original capture files
  restart service

wireshark-autostart.service inactive before log-prep:
  zip capture files if any exist
  delete original capture files after ZIP creation
  leave service inactive
```

Expected active-service log example:

```text
[log-prep] wireshark-autostart.service active before prep; stopping it
[log-prep] Compressing 2 file(s) into /usr/tracefiles/initbox_1_20260612.zip ...
[log-prep] Deleting original capture files ...
[log-prep] Files are stored at: /usr/tracefiles
[log-prep] Restarting wireshark-autostart.service because it was active before prep
[log-prep] ... preparation completed.
```

Expected inactive-service log example:

```text
[log-prep] wireshark-autostart.service inactive before prep; leaving it inactive after prep
[log-prep] Files are stored at: /usr/tracefiles
[log-prep] Not restarting wireshark-autostart.service because it was not active before prep
[log-prep] ... preparation completed.
```

The sniffer module should install only the packages it needs through the offline package helper:

```text
tshark
zip
libcap2-bin
```

The module may configure `wireshark-common` if it is installed as a dependency of `tshark`, but `wireshark-common` should not be listed manually in `scripts/packages.txt`.

The module should allow non-root packet capture by setting capabilities on `dumpcap`:

```text
cap_net_raw,cap_net_admin=eip
```

The `initbox` user should be added to the `wireshark` group when that group exists.

Uninstall behavior must be conservative:

* stop and disable the capture service;
* remove service files created by this module;
* remove helper scripts created by this module;
* leave captured trace files and ZIP archives in `/usr/tracefiles`;
* do not purge packages;
* treat `purge` as a compatibility alias for `uninstall`.

If `br0` does not exist yet, the sniffer service should wait rather than fail permanently. To create `br0`, connect the Pi to the COPILOT-side network and start ISI:

```bash
sudo systemctl restart isirunall.service
ip link show br0
```

Then check the capture service:

```bash
sudo systemctl status wireshark-autostart.service --no-pager
sudo journalctl -u wireshark-autostart.service -n 100 --no-pager
ls -lh /usr/tracefiles
```

To prepare capture files for collection:

```bash
sudo /usr/local/bin/log-prep.sh
ls -lh /usr/tracefiles
```

## Installer Menu

Run:

```bash
sudo ./scripts/initbox-installer.sh pi-zero2w
```

Expected install modules:

```text
Install ISI
Install FMS
Install Hotspot
Install Web Terminal
Install Sniffer / Bridge
```

Common menu actions:

```text
1-N) Install/select supported module
u)   Uninstall/remove supported module, when available
b)   Run baseline OS update
p)   Preseed offline package cache
v)   Verify offline package cache
c)   Run sanity checks
l)   Show install log path
s)   Show install state
q)   Quit
```

Use `c` before installing modules.

Expected Pi Zero sanity-check results include:

```text
Pi Zero 2W dashboard is blocked
Pi Zero 2W supports Web Terminal
All sanity checks passed.
```

When prompted by the installer, type:

```text
RUN
```

only when you are ready to execute the selected module.

---

## Recommended Module Install Order

For a full Pi Zero lab setup:

```text
1. Hotspot
2. Web Terminal
3. ISI
4. FMS, if required by the appliance role
5. Sniffer / Bridge, if packet capture is required
```

The hotspot should be installed before Web Terminal because the captive portal depends on hotspot DNS and DHCP ownership.

ISI should be installed before `br0` capture when you want the sniffer to capture ISI bridge traffic immediately, because ISI creates `br0` on Pi Zero after the COPILOT network gate passes.

---

## Logs and State

Installer log:

```text
/var/log/initbox/install.log
```

Legacy module log:

```text
/home/initbox/pi_logs/initbox-install.log
```

Install-state file:

```text
/etc/initbox/install-state.env
```

View diagnostics:

```bash
sudo ./scripts/initbox-status.sh
```

---

## Repository Update Model

This branch uses the GitHub repository as the source of truth.

Update script:

```text
scripts/update-repo.sh
```

Run it after changes are committed on GitHub:

```bash
cd /home/initbox/RaspberryPi
./scripts/update-repo.sh
```

The update script performs a deployment hard sync:

```text
git fetch origin pi-zero-W-2W
git reset --hard origin/pi-zero-W-2W
git clean -fd
```

Local edits on the Pi are intentionally discarded.

The deployment clone should ignore chmod-only Git noise:

```bash
git config core.fileMode false
```

The update script repairs local script permissions after sync.

If `git status --short` shows files with `M`, check whether they are only permission changes:

```bash
git diff --summary
```

A clean deployment tree should show no output:

```bash
git status --short
```

---

## Verification After Install

Run these checks before field deployment.

### General system check

```bash
hostname
uname -a
cat /etc/os-release
systemctl --failed
ip addr
ip route
ip link show
ss -tulpn
sudo ./scripts/initbox-status.sh
```

There should be no failed InitBox services.

### Package cache

```bash
sudo ./scripts/initbox-installer.sh pi-zero2w v
find /opt/initbox/packages -maxdepth 1 -type f -name '*.deb' | sort | head
```

The package cache should exist and verification should pass.

### Hotspot

```bash
sudo systemctl status hostapd dnsmasq --no-pager
sudo journalctl -u hostapd -n 100 --no-pager
sudo journalctl -u dnsmasq -n 100 --no-pager
sudo grep -nE '^(interface|bind|dhcp-range|dhcp-option|address=/#)' /etc/dnsmasq.conf
sudo dnsmasq --test
```

Expected DNS/DHCP behavior:

```text
interface=wlan0
dhcp-option=3,192.168.20.1
dhcp-option=6,192.168.20.1
address=/#/192.168.20.1
```

### Web Terminal and captive portal

```bash
sudo systemctl status ttyd initbox-captive-http.socket --no-pager
sudo journalctl -u ttyd -n 100 --no-pager
sudo journalctl -u initbox-captive-http.socket -n 100 --no-pager
sudo ss -tulpn | grep -E ':80|:7681'
curl -I http://127.0.0.1/
curl -I http://127.0.0.1:7681/
```

Expected redirect from port `80`:

```text
HTTP/1.1 302 Found
Location: http://initbox.wlan:7681/
```

Expected `ttyd` service details:

```bash
systemctl cat ttyd
```

```text
User=initbox
Group=initbox
ExecStart=/usr/local/bin/ttyd -W --interface 0.0.0.0 --port 7681 /bin/bash -l
```

### ISI safe gate when not connected to COPILOT

When the Pi is not connected to the COPILOT `10.x.x.x` network, starting ISI should not create `br0`.

```bash
sudo systemctl restart isirunall.service
sudo journalctl -u isirunall.service -n 100 --no-pager
ip link show br0 2>/dev/null || echo "br0 not present"
```

Expected safe log:

```text
COPILOT network gate not passed.
No wired Ethernet interface has both carrier and a 10.x.x.x IPv4 address.
Refusing to create br0; leaving Ethernet untouched.
```

### ISI when connected to COPILOT

When connected to the COPILOT network:

```bash
sudo systemctl restart isirunall.service
sudo systemctl status isirunall.service --no-pager
sudo journalctl -u isirunall.service -n 300 --no-pager
bridge link
sudo ip netns list
sudo ip netns exec ns1 ip -br addr
sudo ip netns exec ns2 ip -br addr
sudo ip netns exec ns3 ip -br addr
```

Expected final ISI state:

```text
COPILOT network gate passed
br0 exists
ns1 has a COPILOT-side DHCP IP
ns2 has a COPILOT-side DHCP IP
ns3 has a COPILOT-side DHCP IP
COPILOT target discovered from DHCP
DRACHE and NIX clients started
ZEITNEHMER loop started
```

Check ZEITNEHMER only:

```bash
sudo journalctl -u isirunall.service -n 500 --no-pager \
  | grep -E 'ZEITNEHMER|Time_ISO8601|DateTime|drift|clock|continuing'
```

Expected examples:

```text
ZEITNEHMER: Time_ISO8601=...
ZEITNEHMER: DateTime=...
ZEITNEHMER: drift ...
ZEITNEHMER: no Time_ISO8601 or DateTime in COPILOT response; continuing
```

### FMS

```bash
sudo systemctl status fms --no-pager
sudo journalctl -u fms -n 100 --no-pager
ip link show can0
```

### br0 capture

```bash
sudo systemctl status wireshark-autostart.service --no-pager
sudo journalctl -u wireshark-autostart.service -n 100 --no-pager
ls -lh /usr/tracefiles
```bash
sudo /usr/local/bin/log-prep.sh
ls -lh /usr/tracefiles
sudo systemctl status wireshark-autostart.service --no-pager
```

Expected behavior:

```text
If wireshark-autostart.service was active before log-prep, it should be restarted after ZIP creation.
If wireshark-autostart.service was inactive before log-prep, it should remain inactive.
```

If `br0` does not exist yet, connect to the COPILOT network and start ISI first:

```bash
sudo systemctl restart isirunall.service
ip link show br0
```

---

## Windows Captive Portal Verification

From a Windows laptop connected to the InitBox hotspot:

```cmd
ipconfig /flushdns
nslookup www.msftconnecttest.com 192.168.20.1
curl -I --noproxy "*" http://initbox.wlan/
curl -I --noproxy "*" http://initbox.wlan:7681/
```

Expected captive response:

```text
HTTP/1.1 302 Found
Location: http://initbox.wlan:7681/
```

Expected DNS result:

```text
Address: 192.168.20.1
```

If Windows does not show `Action needed` but the manual tests pass, check for another active network path, VPN, proxy, cached DNS, or secure DNS bypassing the InitBox hotspot.

---

## Reboot Test

Before field deployment:

```bash
sudo reboot
```

After reboot:

```bash
systemctl --failed
ip addr
ip link show
ss -tulpn
sudo ./scripts/initbox-status.sh
sudo systemctl status hostapd dnsmasq ttyd initbox-captive-http.socket --no-pager
sudo systemctl status isirunall.service --no-pager
```

Confirm:

* required services start automatically;
* required interfaces return;
* Web Terminal works;
* ISI does not create `br0` unless COPILOT gate passes;
* ISI namespaces are recreated when connected to COPILOT;
* ZEITNEHMER handles the COPILOT time field available on that device;
* optional `br0` capture starts if installed and `br0` exists;
* logs do not show repeated failures.

---

## Field Deployment Sign-Off

Before the device leaves the lab:

* [ ] Correct branch was used: `pi-zero-W-2W`.
* [ ] Correct profile was used: `pi-zero2w`.
* [ ] Installer sanity checks passed.
* [ ] Internet was available during lab setup.
* [ ] Baseline OS update completed.
* [ ] Offline package cache was preseeded.
* [ ] Offline package cache verification passed.
* [ ] Required modules were installed.
* [ ] Dashboard was not installed.
* [ ] Device was reboot-tested.
* [ ] Required services are active.
* [ ] Required interfaces are present.
* [ ] Web Terminal is reachable.
* [ ] Captive portal redirect works.
* [ ] ISI does not bridge Ethernet on normal lab Internet.
* [ ] ISI creates `br0` only after COPILOT `10.x.x.x` gate passes.
* [ ] ISI namespaces get DHCP leases when connected to COPILOT.
* [ ] ZEITNEHMER works with `Time_ISO8601` or `DateTime`.
* [ ] Optional `br0` capture was verified if installed.
* [ ] Installer log was reviewed.
* [ ] Install state was reviewed.
* [ ] Device is physically labelled.
* [ ] Field team knows which features are installed.

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
bash -n scripts/pi-zero2w/module-fms.sh
bash -n scripts/pi-zero2w/module-hotspot.sh
bash -n scripts/pi-zero2w/module-isi.sh
bash -n scripts/pi-zero2w/module-ttyd-portal.sh
bash -n scripts/pi-zero2w/module-ws-br0.sh
```

If ShellCheck is available:

```bash
shellcheck scripts/initbox-installer.sh scripts/initbox-status.sh scripts/update-repo.sh scripts/lib/*.sh scripts/pi-zero2w/*.sh
```

---

## Troubleshooting Principles

Start with local checks:

```bash
systemctl --failed
systemctl status SERVICE_NAME --no-pager
journalctl -u SERVICE_NAME -n 100 --no-pager
ip addr
ip route
ip link show
ss -tulpn
sudo ./scripts/initbox-status.sh
```

Do not assume Internet access is available in the field.

If a package is missing in the field, the device was not fully prepared in the lab and should be returned to the lab or repaired using a controlled maintenance process.

If Internet disappears after ISI work, check whether `br0` exists when it should not:

```bash
ip link show br0
bridge link
sudo journalctl -u isirunall.service -n 100 --no-pager
```

Expected behavior on normal lab Internet:

```text
No COPILOT 10.x.x.x gate
No br0 creation
Ethernet left untouched
```
