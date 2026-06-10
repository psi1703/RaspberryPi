# InitBox Raspberry Pi Setup

This repository contains setup scripts and documentation for preparing Raspberry Pi devices used as InitBox field appliances.

Raspberry Pi devices are configured in a lab environment where Internet access is available. After setup and verification, the devices are deployed in the field as preconfigured appliances.

Field deployment should not depend on Internet access for package installation.

---

## Operating Model

The intended workflow is:

1. Prepare the Raspberry Pi in the lab.
2. Make sure the Pi has Internet access.
3. Select the correct hardware profile.
4. Run the installer for the selected profile.
5. Run installer sanity checks.
6. Install required packages and services.
7. Reboot if required.
8. Verify the device before field deployment.
9. Deploy the prepared device in the field.

All required packages should be installed during lab preparation.

---

## Supported Hardware Profiles

| Profile     | Hardware               | Dashboard Support | Recommended Interface      |
| ----------- | ---------------------- | ----------------: | -------------------------- |
| `pi-zero2w` | Raspberry Pi Zero 2W   |                No | Web Terminal               |
| `pi-3-4-5`  | Raspberry Pi 3 / 4 / 5 |               Yes | Dashboard and Web Terminal |

Profile definitions are stored in:

```text
profiles/
  pi-zero2w.conf
  pi-3-4-5.conf
```

---

## Pi Zero 2W Policy

The Raspberry Pi Zero 2W is resource-constrained and must remain lightweight.

Recommended Pi Zero 2W modules:

* ISI
* FMS
* Hotspot
* Web Terminal

The Pi Zero 2W must not install dashboard components.

Use Web Terminal instead.

---

## Pi Zero 2W Captive Portal and Web Terminal Model

The Raspberry Pi Zero 2W uses a lightweight captive portal design.

It does not install dashboard components, Node-RED, nginx, lighttpd, Python captive portal services, BusyBox HTTP server, or other full web server packages for the portal path.

The Pi Zero 2W portal model is:

```text
Wi-Fi client
  -> hotspot DNS wildcard
  -> Raspberry Pi hotspot IP
  -> port 80 systemd socket responder
  -> HTTP 302 redirect to http://initbox.wlan:7681/
  -> ttyd Web Terminal
```

Service ownership is split intentionally:

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

The hotspot module must provide wildcard DNS similar to:

```text
address=/#/192.168.20.1
```

The Web Terminal module must not replace or duplicate hotspot DNS, DHCP, hostapd, or wlan0 ownership.

The port 80 captive responder is intentionally implemented using systemd socket activation. It is not a persistent web server. It starts only when a client connects to port 80 and returns a simple HTTP redirect to the ttyd Web Terminal.

Expected Pi Zero 2W URLs:

```text
Captive portal URL: http://initbox.wlan/
Web Terminal URL:   http://initbox.wlan:7681/
```

Expected Windows behavior:

* Windows may show `Action needed` after joining the InitBox hotspot.
* The automatic captive portal page should open to the InitBox portal URL.
* The portal redirects to the ttyd Web Terminal on port `7681`.

Important design rule:

```text
Do not run ttyd directly on port 80 for Pi Zero 2W.
```

Windows captive portal detection expects a normal HTTP response on port 80. The working Pi Zero 2W design uses a lightweight HTTP 302 responder on port 80 and keeps ttyd on port 7681.

---

## Pi 3 / 4 / 5 Policy

Raspberry Pi 3, Raspberry Pi 4, and Raspberry Pi 5 devices can support heavier services.

Possible Pi 3 / 4 / 5 modules:

* ISI
* FMS
* Hotspot
* Dashboard
* Web Terminal
* RTC
* Sniffer / Bridge

For Pi 3 / 4 / 5, Web Terminal may be bundled with the dashboard module depending on the current module implementation.

---

## Repository Layout

```text
README.md

profiles/
  README.md
  pi-zero2w.conf
  pi-3-4-5.conf

scripts/
  initbox-installer.sh
  initbox-status.sh
  lib/
    profile.sh
    modules.sh
    state.sh
  pi-zero2w/
    module-isi.sh
    module-fms.sh
    module-hotspot.sh
    module-ttyd-portal.sh
  pi-3-4-5/
    module-isi.sh
    module-fms.sh
    module-hotspot.sh
    module-dashboard.sh
    module-rtc.sh
    module-ws-br0.sh
```

Notes:

* Pi Zero 2W uses `module-ttyd-portal.sh` for Web Terminal and captive portal redirection.
* Pi Zero 2W does not support dashboard.
* Pi 3 / 4 / 5 uses `module-dashboard.sh` for dashboard functionality.
* If Web Terminal is bundled into the Pi 3 / 4 / 5 dashboard module, both `dashboard` and `web-terminal` can map to `module-dashboard.sh`.

---

## Lab Setup Requirements

Before running the installer, confirm:

* The Raspberry Pi is in the lab.
* Internet access is available.
* Raspberry Pi OS has been installed.
* SSH or local console access is available.
* The correct hardware profile is known.
* The correct repository files are present on the Pi.
* The Pi has stable power.

During setup, the installer may:

* Run `apt-get update`
* Install Debian packages
* Download required dependencies
* Configure system users
* Configure networking
* Configure systemd services
* Modify boot or hardware settings
* Require a reboot

---

## Run the Installer

For Pi Zero 2W:

```bash
sudo ./scripts/initbox-installer.sh pi-zero2w
```

For Pi 3 / 4 / 5:

```bash
sudo ./scripts/initbox-installer.sh pi-3-4-5
```

The installer will:

* Load the selected hardware profile.
* Show only modules supported by that profile.
* Block unsupported modules.
* Provide built-in sanity checks.
* Require explicit `RUN` confirmation before executing a module script.
* Log installation activity to `/var/log/initbox/install.log`.
* Record install state to `/etc/initbox/install-state.env`.

For Pi Zero 2W, the dashboard module must not appear in the menu.

---

## Installer Menu Options

The installer menu includes:

```text
1-N) Install/select supported module
c) Run sanity checks
l) Show install log path
s) Show install state
q) Quit
```

Use `c` before installing any module.

The sanity check verifies:

* Required repository files exist.
* The selected profile is valid.
* Supported modules have script mappings.
* Supported module scripts exist.
* Unsupported modules are blocked.

For Pi Zero 2W, the sanity check must confirm that dashboard is blocked and Web Terminal is supported.

Expected Pi Zero 2W sanity check result includes:

```text
Pi Zero 2W dashboard is blocked
Pi Zero 2W supports Web Terminal
All sanity checks passed.
```

---

## Install Modules

Install only the modules required for the device role.

### Pi Zero 2W

Recommended:

* [ ] ISI
* [ ] FMS
* [ ] Hotspot
* [ ] Web Terminal

Do not install:

* [ ] Dashboard

For Pi Zero 2W, install the hotspot module before the Web Terminal module. The Web Terminal captive portal depends on the hotspot module for wlan0, DHCP, DNS, and wildcard captive DNS ownership.

Recommended Pi Zero 2W order:

```text
1. Hotspot
2. Web Terminal
3. ISI and FMS as required by the appliance role
```

### Pi 3 / 4 / 5

Install only what is needed:

* [ ] ISI
* [ ] FMS
* [ ] Hotspot
* [ ] Dashboard
* [ ] Web Terminal, if bundled with dashboard or separately available
* [ ] RTC
* [ ] Sniffer / Bridge

When prompted by the installer, type:

```text
RUN
```

only when you are ready to execute the selected module.

---

## Install Logs

Installer log path:

```text
/var/log/initbox/install.log
```

To view the log from the installer menu, press:

```text
l
```

Or check recent installer activity directly:

```bash
sudo tail -n 100 /var/log/initbox/install.log
```

Look for:

* Failed package installs
* Missing files
* Permission errors
* Service enable failures
* Reboot-required messages

Do not deploy a device with unresolved installer errors.

---

## Install State

Install-state path:

```text
/etc/initbox/install-state.env
```

To view install state from the installer menu, press:

```text
s
```

The installer records profile information and module success/failure status when run with `sudo`.

The state file is intended to help with field diagnostics and lab handover.

---

## Field Diagnostics

Run:

```bash
sudo ./scripts/initbox-status.sh
```

The status command prints local diagnostics, including:

* System information
* Install state
* Network interfaces
* Failed services
* Listening ports
* Known InitBox-related service status

This command is designed to work without Internet access.

---

## Verification Before Field Deployment

Before a Raspberry Pi leaves the lab, run these checks.

### System information

```bash
hostname
uname -a
cat /etc/os-release
```

### Network state

```bash
ip addr
ip route
ip link show
```

### Failed services

```bash
systemctl --failed
```

There should be no failed services related to installed InitBox features.

---

## Service Checks

Check only the services relevant to installed modules.

### Web Terminal

Pi Zero 2W and Pi 3 / 4 / 5 Web Terminal behavior may differ.

#### Pi Zero 2W

For Pi Zero 2W, Web Terminal is provided by:

```text
ttyd.service
initbox-captive-http.socket
initbox-captive-http@.service
```

Check service status:

```bash
systemctl status ttyd --no-pager
systemctl status initbox-captive-http.socket --no-pager
journalctl -u ttyd -n 100 --no-pager
journalctl -u initbox-captive-http.socket -n 100 --no-pager
```

Check listening ports:

```bash
ss -tulpn | grep -E ':80|:7681'
```

Expected Pi Zero 2W ports:

```text
0.0.0.0:80    systemd captive HTTP socket
0.0.0.0:7681  ttyd Web Terminal
```

Test the captive responder locally:

```bash
curl -I http://127.0.0.1/
```

Expected result:

```text
HTTP/1.1 302 Found
Location: http://initbox.wlan:7681/
```

Test ttyd locally:

```bash
curl -I http://127.0.0.1:7681/
```

From a Wi-Fi client connected to the InitBox hotspot, open:

```text
http://initbox.wlan/
```

The expected behavior is:

```text
http://initbox.wlan/
  -> HTTP 302 redirect
  -> http://initbox.wlan:7681/
  -> ttyd Web Terminal
```

The ttyd service must run as the `initbox` user and must enable keyboard input with `-W`.

To verify the generated ttyd service:

```bash
systemctl cat ttyd
```

Expected service details include:

```text
User=initbox
Group=initbox
ExecStart=/usr/local/bin/ttyd -W --interface 0.0.0.0 --port 7681 /bin/bash -l
```

To verify the captive portal socket:

```bash
systemctl cat initbox-captive-http.socket
systemctl cat 'initbox-captive-http@.service'
```

Expected socket behavior:

```text
ListenStream=0.0.0.0:80
Accept=yes
```

Expected responder behavior:

```text
StandardInput=socket
StandardOutput=socket
Environment=INITBOX_TERMINAL_URL=http://initbox.wlan:7681/
```

#### Pi 3 / 4 / 5

For Pi 3 / 4 / 5, Web Terminal may be bundled with the dashboard module depending on the current module implementation.

Check dashboard and portal services as documented in the Dashboard / Portal section.

### Dashboard / Portal

Dashboard verification applies to Pi 3 / 4 / 5 only.

```bash
systemctl status nodered --no-pager
systemctl status pi-nodered --no-pager
systemctl status portal --no-pager
```

If service names differ:

```bash
systemctl list-units --type=service | grep -i node
systemctl list-units --type=service | grep -i red
systemctl list-units --type=service | grep -i portal
```

Common dashboard URLs:

```text
http://PI_IP_ADDRESS/
http://PI_IP_ADDRESS:1880
```

### Hotspot

```bash
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager
journalctl -u hostapd -n 100 --no-pager
journalctl -u dnsmasq -n 100 --no-pager
```

For Pi Zero 2W captive portal behavior, confirm that dnsmasq provides the Pi as DNS server and resolves captive-check domains to the hotspot IP.

Check dnsmasq configuration:

```bash
sudo grep -nE '^(interface|bind|dhcp-range|dhcp-option|address=/#)' /etc/dnsmasq.conf
sudo dnsmasq --test
```

Expected Pi Zero 2W hotspot DNS lines include:

```text
interface=wlan0
dhcp-option=3,192.168.20.1
dhcp-option=6,192.168.20.1
address=/#/192.168.20.1
```

From a Windows Wi-Fi client, direct DNS testing can be done with:

```cmd
nslookup www.msftconnecttest.com 192.168.20.1
```

Expected result:

```text
Address: 192.168.20.1
```

The exact displayed name may include a local DNS suffix, but the returned address should be the Pi hotspot IP.

### ISI

```bash
systemctl status isirunall --no-pager
journalctl -u isirunall -n 100 --no-pager
```

If the service name differs:

```bash
systemctl list-units --type=service | grep -i isi
```

### FMS

```bash
systemctl status fms --no-pager
journalctl -u fms -n 100 --no-pager
ip link show can0
```

### RTC

```bash
timedatectl
systemctl list-units --type=service --all | grep -i rtc
systemctl list-timers --all | grep -i rtc
```

### Sniffer / Bridge

```bash
ip link show br0
systemctl status bridge-check --no-pager
systemctl status wireshark-autostart --no-pager
```

If service names differ:

```bash
systemctl list-units --type=service | grep -i bridge
systemctl list-units --type=service | grep -i wireshark
```

---

## Listening Ports

Check ports:

```bash
ss -tulpn
```

Common expected ports:

| Profile     | Feature                         | Typical Port |
| ----------- | ------------------------------- | -----------: |
| `pi-zero2w` | Captive HTTP socket responder   |           80 |
| `pi-zero2w` | Web Terminal / ttyd             |         7681 |
| `pi-3-4-5`  | Dashboard / Portal              |           80 |
| `pi-3-4-5`  | Node-RED                        |         1880 |
| `pi-3-4-5`  | Web Terminal / ttyd, if enabled |         7681 |

Only verify ports for installed features.

For Pi Zero 2W, port `80` should be owned by systemd socket activation, not by ttyd directly and not by an additional web server package.

Expected Pi Zero 2W check:

```bash
systemctl status initbox-captive-http.socket --no-pager
systemctl status ttyd --no-pager
ss -tulpn | grep -E ':80|:7681'
```

Expected Pi Zero 2W behavior:

```text
port 80    captive portal HTTP 302 responder
port 7681  ttyd Web Terminal
```

Do not change the Pi Zero 2W Web Terminal module to run ttyd directly on port `80`. That removes the normal captive HTTP response required for the Windows `Action needed` captive portal flow.

---

## Captive Portal Client Verification

For Pi Zero 2W, test the captive portal from a Wi-Fi client before field deployment.

### Windows client check

Connect the Windows laptop to the InitBox hotspot.

Windows may display:

```text
Action needed
```

Open the captive portal prompt if shown. It should open the InitBox portal and redirect to the Web Terminal.

Manual browser check:

```text
http://initbox.wlan/
```

Expected redirect:

```text
http://initbox.wlan/
  -> http://initbox.wlan:7681/
```

Command-line check from Windows:

```cmd
ipconfig /flushdns
nslookup www.msftconnecttest.com 192.168.20.1
curl -I --noproxy "*" http://initbox.wlan/
curl -I --noproxy "*" http://initbox.wlan:7681/
```

Expected captive response from port 80:

```text
HTTP/1.1 302 Found
Location: http://initbox.wlan:7681/
```

Expected ttyd response from port 7681:

```text
HTTP/1.1 200 OK
```

If `curl http://www.msftconnecttest.com/connecttest.txt` returns the real text below, the client is still reaching Microsoft rather than the InitBox captive path:

```text
Microsoft Connect Test
```

That normally indicates DNS routing, proxy, cache, or another active network path is bypassing the Pi hotspot.

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
ip link show
ss -tulpn
sudo ./scripts/initbox-status.sh
```

Confirm:

* Required services start automatically.
* Required interfaces return.
* Required ports are listening.
* Web Terminal works if installed.
* Dashboard works if installed.
* Logs do not show repeated failures.

For Pi Zero 2W with Web Terminal installed, also confirm:

```bash
systemctl status hostapd dnsmasq ttyd initbox-captive-http.socket --no-pager
curl -I http://127.0.0.1/
curl -I http://127.0.0.1:7681/
```

Expected port 80 response:

```text
HTTP/1.1 302 Found
Location: http://initbox.wlan:7681/
```

---

## Final Field Deployment Sign-Off

Before the device leaves the lab:

* [ ] Correct hardware profile was used.
* [ ] Installer sanity checks passed.
* [ ] Internet was available during setup.
* [ ] Required modules were installed.
* [ ] Unsupported modules were not installed.
* [ ] Pi Zero 2W does not have dashboard installed.
* [ ] Device was reboot-tested.
* [ ] Required services are active.
* [ ] Required interfaces are present.
* [ ] Required UI is reachable.
* [ ] Installer log was reviewed.
* [ ] Install state was reviewed.
* [ ] Field diagnostics command was run.
* [ ] Device is physically labelled.
* [ ] Access details are recorded securely.
* [ ] Field team knows which profile/features are installed.

Pi Zero 2W Web Terminal and captive portal checks, if installed:

* [ ] `hostapd` is active.
* [ ] `dnsmasq` is active.
* [ ] `ttyd` is active.
* [ ] `initbox-captive-http.socket` is active.
* [ ] Pi Zero 2W ttyd is listening on port `7681`, not port `80`.
* [ ] Pi Zero 2W port `80` returns HTTP `302` to `http://initbox.wlan:7681/`.
* [ ] Pi Zero 2W hotspot DNS wildcard returns the hotspot IP.
* [ ] Windows `Action needed` captive portal behavior was tested from a Wi-Fi client.
* [ ] Manual browser access to `http://initbox.wlan/` redirects to the Web Terminal.

---

## Troubleshooting Principles

When troubleshooting in the field, start with local checks:

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

---

## Pi Zero 2W Captive Portal Troubleshooting

Use this section only for Pi Zero 2W devices with the Web Terminal module installed.

### Check core services

```bash
sudo systemctl status hostapd dnsmasq ttyd initbox-captive-http.socket --no-pager
```

All four should be active.

### Check port ownership

```bash
sudo ss -tulpn | grep -E ':80|:7681'
```

Expected:

```text
:80    systemd
:7681  ttyd
```

Port `80` should not be owned directly by ttyd.

### Check captive HTTP redirect

```bash
curl -I http://127.0.0.1/
```

Expected:

```text
HTTP/1.1 302 Found
Location: http://initbox.wlan:7681/
```

### Check ttyd

```bash
curl -I http://127.0.0.1:7681/
systemctl cat ttyd
```

Expected service configuration includes:

```text
User=initbox
Group=initbox
ExecStart=/usr/local/bin/ttyd -W --interface 0.0.0.0 --port 7681 /bin/bash -l
```

If the Web Terminal opens but keyboard input does not work, confirm that the ttyd command includes `-W`.

### Check hotspot DNS

```bash
sudo grep -nE '^(interface|bind|dhcp-range|dhcp-option|address=/#)' /etc/dnsmasq.conf
sudo dnsmasq --test
```

Expected DNS behavior:

```text
dhcp-option=6,192.168.20.1
address=/#/192.168.20.1
```

### Check Windows client path

From Windows:

```cmd
ipconfig /flushdns
nslookup www.msftconnecttest.com 192.168.20.1
curl -I --noproxy "*" http://initbox.wlan/
```

Expected:

```text
Address: 192.168.20.1
HTTP/1.1 302 Found
Location: http://initbox.wlan:7681/
```

If Windows does not show `Action needed`, but the manual tests above pass, verify that the laptop is not using another active network path, VPN, proxy, cached DNS, or secure DNS mechanism that bypasses the InitBox hotspot.

---

## Development Checks

Run syntax checks before testing on hardware:

```bash
bash -n scripts/initbox-installer.sh
bash -n scripts/initbox-status.sh
bash -n scripts/lib/profile.sh
bash -n scripts/lib/modules.sh
bash -n scripts/lib/state.sh
bash -n scripts/pi-zero2w/module-ttyd-portal.sh
```

If ShellCheck is available:

```bash
shellcheck scripts/initbox-installer.sh scripts/initbox-status.sh scripts/lib/*.sh scripts/pi-zero2w/*.sh scripts/pi-3-4-5/*.sh
```

---

## Design Rules

* Lab setup requires Internet access.
* Field deployment assumes the Pi is already configured.
* Pi Zero 2W must remain lightweight.
* Pi Zero 2W must not include dashboard components.
* Pi Zero 2W Web Terminal uses ttyd on port `7681`.
* Pi Zero 2W captive portal uses systemd socket activation on port `80`.
* Pi Zero 2W must not run ttyd directly on port `80`.
* Pi Zero 2W must not install a dashboard, Node-RED, nginx, lighttpd, or Python captive portal service for the portal path.
* Pi 3 / 4 / 5 may include dashboard components.
* Installer behavior should be repeatable.
* Verification must be completed before field deployment.
* Logs should be kept for support.
* Install state should be recorded for support.
* Unnecessary changes to working module code should be avoided.
* Hardware-specific behavior should be documented clearly.
