# InitBox Raspberry Pi Setup

This repository contains setup scripts and documentation for preparing Raspberry Pi devices used as InitBox field appliances.

The Raspberry Pi devices are configured in a lab environment where Internet access is available. After setup and verification, the devices are deployed in the field as preconfigured appliances.

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

This project is not designed around downloading packages in the field. All required packages should be installed during lab preparation.

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

The profile files define which modules are allowed for each Raspberry Pi model.

---

## Raspberry Pi Zero 2W

The Raspberry Pi Zero 2W is resource-constrained and must remain lightweight.

It should not run the full dashboard stack.

Recommended Pi Zero 2W features:

* ISI
* FMS
* Hotspot
* Web Terminal

The Web Terminal is the preferred management interface for the Pi Zero 2W.

Dashboard components must not be installed on the Pi Zero 2W because they are too heavy for the device and may make it slow or unreliable in the field.

---

## Raspberry Pi 3 / 4 / 5

Raspberry Pi 3, Raspberry Pi 4, and Raspberry Pi 5 devices can support heavier services than the Pi Zero 2W.

Recommended Pi 3 / 4 / 5 features may include:

* ISI
* FMS
* Hotspot
* Dashboard
* Web Terminal
* RTC
* Sniffer / Bridge, where required

For Pi 3 / 4 / 5, dashboard and web terminal functionality may be provided by the same dashboard module, depending on the current module implementation.

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

Before running the installer, confirm the following:

* The Raspberry Pi is in the lab.
* Internet access is available.
* Raspberry Pi OS has been installed.
* SSH or local console access is available.
* The correct hardware profile is known.
* The correct installer/profile is being used.
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

Before running the installer, validate the selected profile.

For Pi Zero 2W:

```bash
./scripts/check-profile.sh pi-zero2w
```

For Pi 3 / 4 / 5:

```bash
./scripts/check-profile.sh pi-3-4-5
```

Expected Pi Zero 2W behavior:

```text
Dashboard:       no
Web Terminal:    yes
```

Expected Pi 3 / 4 / 5 behavior:

```text
Dashboard:       yes
Web Terminal:    yes
```

---

## Run the Installer

Run the installer with the correct profile.

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

For Pi Zero 2W, the dashboard module should not appear in the menu.

---

## Install State

The project records install-state information under:

```text
/etc/initbox/install-state.env
```

Show install state with:

```bash
./scripts/show-state.sh
```

If no modules have been recorded yet, this command may report that no install state exists. That is expected before installation or before state tracking has been wired into the module flow.

---

## Field Diagnostics

After lab setup, or during field support, run:

```bash
./scripts/initbox-status.sh
```

or with elevated permissions:

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

Before a Raspberry Pi leaves the lab, run basic verification checks.

### Confirm system information

```bash
hostname
uname -a
cat /etc/os-release
```

### Confirm network state

```bash
ip addr
ip route
ip link show
```

### Confirm failed services

```bash
systemctl --failed
```

There should be no failed services related to the installed InitBox features.

---

## Pi Zero 2W Verification

For Pi Zero 2W devices, verify only the lightweight feature set.

### Web Terminal

```bash
systemctl status ttyd --no-pager
journalctl -u ttyd -n 100 --no-pager
ss -tulpn
```

If the default ttyd port is used, check access from a browser:

```text
http://<pi-ip-address>:7681
```

### Hotspot

If hotspot is installed:

```bash
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager
journalctl -u hostapd -n 100 --no-pager
journalctl -u dnsmasq -n 100 --no-pager
```

### ISI

If ISI is installed:

```bash
systemctl status isirunall --no-pager
journalctl -u isirunall -n 100 --no-pager
```

If the service name differs, search for it:

```bash
systemctl list-units --type=service | grep -i isi
```

### FMS

If FMS is installed:

```bash
systemctl status fms --no-pager
journalctl -u fms -n 100 --no-pager
ip link show can0
```

### Pi Zero 2W final checklist

* [ ] Pi booted successfully after setup.
* [ ] Pi rebooted successfully after setup.
* [ ] Internet was available during lab setup.
* [ ] Required packages installed successfully.
* [ ] Dashboard was not installed.
* [ ] Web Terminal is active.
* [ ] Hotspot works if required.
* [ ] ISI works if required.
* [ ] FMS works if required.
* [ ] Required interfaces are present.
* [ ] Logs show no repeated failures.
* [ ] Device is labelled.
* [ ] Access details are recorded securely.

---

## Pi 3 / 4 / 5 Verification

For Pi 3 / 4 / 5 devices, verify the installed feature set.

### Web Terminal / Dashboard

If dashboard or web terminal support is installed through the dashboard module, check the dashboard-related services.

Common examples:

```bash
systemctl status nodered --no-pager
systemctl status pi-nodered --no-pager
systemctl status portal --no-pager
```

If the exact service names differ, search for them:

```bash
systemctl list-units --type=service | grep -i node
systemctl list-units --type=service | grep -i red
systemctl list-units --type=service | grep -i portal
```

Check recent logs:

```bash
journalctl -u nodered -n 100 --no-pager
journalctl -u pi-nodered -n 100 --no-pager
journalctl -u portal -n 100 --no-pager
```

Common dashboard URLs may include:

```text
http://<pi-ip-address>/
http://<pi-ip-address>:1880
```

### Hotspot

If hotspot is installed:

```bash
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager
journalctl -u hostapd -n 100 --no-pager
journalctl -u dnsmasq -n 100 --no-pager
```

### ISI

If ISI is installed:

```bash
systemctl status isirunall --no-pager
journalctl -u isirunall -n 100 --no-pager
```

If the service name differs:

```bash
systemctl list-units --type=service | grep -i isi
```

### FMS

If FMS is installed:

```bash
systemctl status fms --no-pager
journalctl -u fms -n 100 --no-pager
ip link show can0
```

### RTC

If RTC is installed:

```bash
timedatectl
systemctl list-units --type=service --all | grep -i rtc
systemctl list-timers --all | grep -i rtc
```

### Sniffer / Bridge

If Sniffer / Bridge is installed:

```bash
ip link show br0
systemctl status bridge-check --no-pager
systemctl status wireshark-autostart --no-pager
```

If the exact service names differ:

```bash
systemctl list-units --type=service | grep -i bridge
systemctl list-units --type=service | grep -i wireshark
```

### Pi 3 / 4 / 5 final checklist

* [ ] Pi booted successfully after setup.
* [ ] Pi rebooted successfully after setup.
* [ ] Internet was available during lab setup.
* [ ] Required packages installed successfully.
* [ ] Required services are active.
* [ ] Dashboard works if installed.
* [ ] Web Terminal works if installed.
* [ ] Hotspot works if required.
* [ ] ISI works if required.
* [ ] FMS works if required.
* [ ] RTC works if required.
* [ ] Bridge/sniffer works if required.
* [ ] Required interfaces are present.
* [ ] Logs show no repeated failures.
* [ ] Device is labelled.
* [ ] Access details are recorded securely.

---

## Reboot Test

Before any device leaves the lab, reboot it at least once:

```bash
sudo reboot
```

After reboot, run:

```bash
ip addr
ip link show
ss -tulpn
systemctl --failed
```

Then check all services required for the installed features.

Expected result:

* Required services start automatically.
* Required interfaces return.
* Required ports are listening.
* Web Terminal is reachable if installed.
* Dashboard is reachable if installed.
* No manual restart is required.

---

## Troubleshooting Principles

When troubleshooting in the field, start with local checks.

Useful commands:

```bash
systemctl --failed
systemctl status <service-name> --no-pager
journalctl -u <service-name> -n 100 --no-pager
ip addr
ip route
ip link show
ss -tulpn
```

Do not assume Internet access is available in the field.

If a package is missing in the field, the device was not fully prepared in the lab and should be returned to the lab or repaired using a controlled maintenance process.

---

## Design Rules

The project should follow these rules:

* Lab setup requires Internet access.
* Field deployment assumes the Pi is already configured.
* Pi Zero 2W must remain lightweight.
* Pi Zero 2W must not include the dashboard stack.
* Pi 3 / 4 / 5 may include dashboard components.
* Installer behavior should be repeatable.
* Verification must be completed before field deployment.
* Logs should be kept for support.
* Unnecessary changes to working installer code should be avoided.
* Hardware-specific behavior should be documented clearly.

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

## Suggested Commit Message

```text
docs: update root readme for profile-aware installer
```
