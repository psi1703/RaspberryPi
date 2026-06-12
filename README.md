[README.md](https://github.com/user-attachments/files/28867979/README.md)
# InitBox Raspberry Pi Zero W / Zero 2W Setup

This branch is dedicated to the lightweight InitBox build for Raspberry Pi Zero W and Raspberry Pi Zero 2W class devices.

The goal of this branch is clear separation from the heavier Raspberry Pi 3 / 4 / 5 design. The Zero profile uses Web Terminal, hotspot, ISI, FMS, and optional br0 packet capture only. It must not install dashboard components.

Field deployment should not depend on Internet access. All package installation and verification must be completed in the lab before the device leaves for the field.

---

## Supported Hardware

| Profile | Hardware | Dashboard | Management interface |
| --- | --- | ---: | --- |
| `pi-zero2w` | Raspberry Pi Zero W / Zero 2W | No | Web Terminal |

The profile file is:

```text
profiles/pi-zero2w.conf
```

This branch intentionally does not document or support the Pi 3 / 4 / 5 dashboard profile.

---

## Operating Model

The intended workflow is:

1. Flash Raspberry Pi OS.
2. Boot the Pi in the lab with Internet access.
3. Clone this branch.
4. Run the installer with the `pi-zero2w` profile.
5. Run sanity checks.
6. Install the required modules.
7. Reboot.
8. Verify hotspot, Web Terminal, ISI, FMS, and optional packet capture.
9. Deploy the prepared device in the field.

All package downloads and operating-system updates must happen in the lab.

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
* run baseline `apt-get update` and `apt-get upgrade -y` for normal menu installs;
* load the `pi-zero2w` profile;
* show only supported modules;
* run sanity checks;
* require explicit `RUN` confirmation before installing a module;
* record install state in `/etc/initbox/install-state.env`.

Passwordless sudo is installed before the baseline package update so later module scripts can run consistently without repeated password prompts.

---

## Branch Policy

This branch is for Pi Zero W / Zero 2W only.

Required rules:

* Use Web Terminal, not dashboard.
* Do not install Node-RED dashboard components.
* Do not install nginx, lighttpd, or a Python web portal for the Zero captive portal path.
* Keep `ttyd` on port `7681`.
* Keep port `80` owned by the lightweight captive HTTP redirect socket.
* Let `isirunall.service` own `br0` for ISI.
* Let the Wireshark module capture `br0`; do not run a competing dynamic bridge manager on Pi Zero.
* Keep scripts ShellCheck-friendly and repeatable from a clean reflash.

---

## Repository Layout

```text
README.md
LICENSE

profiles/
  README.md
  pi-zero2w.conf

scripts/
  initbox-installer.sh
  initbox-status.sh
  update-repo.sh
  lib/
    profile.sh
    modules.sh
    state.sh
  pi-zero2w/
    module-fms.sh
    module-hotspot.sh
    module-isi.sh
    module-ttyd-portal.sh
    module-ws-br0.sh
```

Important module ownership:

| Module | Script | Ownership |
| --- | --- | --- |
| Hotspot | `scripts/pi-zero2w/module-hotspot.sh` | `hostapd`, `dnsmasq`, wlan0 hotspot IP, DHCP/DNS, wildcard captive DNS |
| Web Terminal | `scripts/pi-zero2w/module-ttyd-portal.sh` | `ttyd`, port `7681`, port `80` captive redirect socket |
| ISI | `scripts/pi-zero2w/module-isi.sh` | `br0`, namespaces, veth pairs, DHCP inside namespaces, XML clients |
| FMS | `scripts/pi-zero2w/module-fms.sh` | FMS/CAN support |
| Sniffer / br0 capture | `scripts/pi-zero2w/module-ws-br0.sh` | `tshark`, `/usr/tracefiles`, `log-prep.sh`, capture on `br0` |

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

---

## ISI Model on Pi Zero W / Zero 2W

`module-isi.sh` installs `isirunall.service` and writes `/usr/local/bin/isirunall.sh`.

The ISI runner:

* creates or reuses `br0`;
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

| Namespace | App name | Payload file |
| --- | --- | --- |
| `ns1` | DRACHE | `/usr/local/bin/isi1.txt` |
| `ns2` | NIX | `/usr/local/bin/isi2.txt` |
| `ns3` | ZEITNEHMER | `/usr/local/bin/isi3.txt` |

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

DRACHE and NIX responses may be suppressed in the journal to avoid burying ZEITNEHMER logs. Use `tcpdump` when you need to prove XML is flowing.

---

## Pi Zero br0 Packet Capture

`module-ws-br0.sh` installs a lightweight packet-capture service for `br0`.

On Pi Zero W / Zero 2W:

* ISI owns and creates `br0`.
* The capture service waits for `br0` to exist.
* The capture service records traffic from `br0`.
* No dynamic `bridge-check.service` should manage `br0` on this branch.

Capture files are stored in:

```text
/usr/tracefiles
```

The helper script:

```text
/usr/local/bin/log-prep.sh
```

can stop the sniffer, zip capture files, remove originals, and restart capture when configured to do so.

---

## Installer Menu

Run:

```bash
sudo ./scripts/initbox-installer.sh pi-zero2w
```

Common menu actions:

```text
1-N) Install/select supported module
u)   Uninstall/remove supported module, when available
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
5. Sniffer / br0 capture, if enabled for this branch/profile
```

The hotspot should be installed before Web Terminal because the captive portal depends on hotspot DNS and DHCP ownership.

ISI should be installed before br0 capture when you want the sniffer to capture ISI bridge traffic immediately, because ISI creates `br0` on Pi Zero.

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

### ISI

```bash
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

To verify XML traffic on the bridge:

```bash
sudo tcpdump -A -s 0 -i br0 'tcp port 51001'
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
```

If `br0` does not exist yet, start or repair ISI first:

```bash
sudo systemctl status isirunall.service --no-pager
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
* ISI namespaces are recreated;
* ZEITNEHMER handles the COPILOT time field available on that device;
* optional br0 capture starts if installed;
* logs do not show repeated failures.

---

## Field Deployment Sign-Off

Before the device leaves the lab:

* [ ] Correct branch was used: `pi-zero-W-2W`.
* [ ] Correct profile was used: `pi-zero2w`.
* [ ] Installer sanity checks passed.
* [ ] Internet was available during setup.
* [ ] Baseline `apt-get update` and `apt-get upgrade` completed.
* [ ] Required modules were installed.
* [ ] Dashboard was not installed.
* [ ] Device was reboot-tested.
* [ ] Required services are active.
* [ ] Required interfaces are present.
* [ ] Web Terminal is reachable.
* [ ] Captive portal redirect works.
* [ ] ISI namespaces get DHCP leases when connected to COPILOT.
* [ ] ZEITNEHMER works with `Time_ISO8601` or `DateTime`.
* [ ] Optional br0 capture was verified if installed.
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
bash -n scripts/lib/profile.sh
bash -n scripts/lib/modules.sh
bash -n scripts/lib/state.sh
bash -n scripts/pi-zero2w/module-fms.sh
bash -n scripts/pi-zero2w/module-hotspot.sh
bash -n scripts/pi-zero2w/module-isi.sh
bash -n scripts/pi-zero2w/module-ttyd-portal.sh
bash -n scripts/pi-zero2w/module-ws-br0.sh
```

If ShellCheck is available:

```bash
shellcheck scripts/initbox-installer.sh scripts/initbox-status.sh scripts/lib/*.sh scripts/pi-zero2w/*.sh
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
