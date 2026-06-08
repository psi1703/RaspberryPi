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
5. Install required packages and services.
6. Reboot if required.
7. Verify the device before field deployment.
8. Deploy the prepared device in the field.

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
  check-profile.sh
  initbox-installer.sh
  initbox-status.sh
  show-state.sh
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

* Pi Zero 2W uses `module-ttyd-portal.sh` for Web Terminal.
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

## Validate Profiles

For Pi Zero 2W:

```bash
./scripts/check-profile.sh pi-zero2w
```

Expected:

```text
Dashboard:       no
Web Terminal:    yes
```

For Pi 3 / 4 / 5:

```bash
./scripts/check-profile.sh pi-3-4-5
```

Expected:

```text
Dashboard:       yes
Web Terminal:    yes
```

Do not continue if the selected profile does not match the hardware.

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
* Require explicit `RUN` confirmation before executing a module script.
* Log installation activity to `/var/log/initbox/install.log`.

For Pi Zero 2W, the dashboard module must not appear in the menu.

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

### Pi 3 / 4 / 5

Install only what is needed:

* [ ] ISI
* [ ] FMS
* [ ] Hotspot
* [ ] Dashboard
* [ ] Web Terminal, if bundled with dashboard or separately available
* [ ] RTC
* [ ] Sniffer / Bridge

---

## Review Install Logs

Installer log path:

```text
/var/log/initbox/install.log
```

Check recent installer activity:

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

Show install state:

```bash
./scripts/show-state.sh
```

If state tracking is not yet wired into the installer, this command may report that no install state exists. In that case, rely on the installer log and service checks.

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

```bash
systemctl status ttyd --no-pager
journalctl -u ttyd -n 100 --no-pager
ss -tulpn
```

Default access, if using the standard ttyd port:

```text
http://PI_IP_ADDRESS:7681
```

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

| Feature             | Typical Port |
| ------------------- | -----------: |
| Dashboard / Portal  |           80 |
| Node-RED            |         1880 |
| Web Terminal / ttyd |         7681 |

Only verify ports for installed features.

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

---

## Final Field Deployment Sign-Off

Before the device leaves the lab:

* [ ] Correct hardware profile was used.
* [ ] Internet was available during setup.
* [ ] Required modules were installed.
* [ ] Unsupported modules were not installed.
* [ ] Pi Zero 2W does not have dashboard installed.
* [ ] Device was reboot-tested.
* [ ] Required services are active.
* [ ] Required interfaces are present.
* [ ] Required UI is reachable.
* [ ] Installer log was reviewed.
* [ ] Field diagnostics command was run.
* [ ] Device is physically labelled.
* [ ] Access details are recorded securely.
* [ ] Field team knows which profile/features are installed.

---

## Troubleshooting Principles

When troubleshooting in the field, start with local checks:

```bash
systemctl --failed
systemctl status <service-name> --no-pager
journalctl -u <service-name> -n 100 --no-pager
ip addr
ip route
ip link show
ss -tulpn
sudo ./scripts/initbox-status.sh
```

Do not assume Internet access is available in the field.

If a package is missing in the field, the device was not fully prepared in the lab and should be returned to the lab or repaired using a controlled maintenance process.

---

## Development Checks

Run syntax checks before testing on hardware:

```bash
bash -n scripts/check-profile.sh
bash -n scripts/initbox-installer.sh
bash -n scripts/initbox-status.sh
bash -n scripts/show-state.sh
bash -n scripts/lib/profile.sh
bash -n scripts/lib/modules.sh
bash -n scripts/lib/state.sh
```

If ShellCheck is available:

```bash
shellcheck scripts/*.sh scripts/lib/*.sh
```

---

## Design Rules

* Lab setup requires Internet access.
* Field deployment assumes the Pi is already configured.
* Pi Zero 2W must remain lightweight.
* Pi Zero 2W must not include dashboard components.
* Pi 3 / 4 / 5 may include dashboard components.
* Installer behavior should be repeatable.
* Verification must be completed before field deployment.
* Logs should be kept for support.
* Unnecessary changes to working installer code should be avoided.
* Hardware-specific behavior should be documented clearly.
