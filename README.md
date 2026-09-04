# InitBox Raspberry Pi Runtime

InitBox is a field-appliance runtime for supported Raspberry Pi hardware.

This repository is the source of truth. Installed devices run from `/usr/local/bin` and `/usr/local/share/initbox`; they do not run from a Git checkout.

## Supported hardware

| Hardware | Profile | Hotspot gateway | Dashboard |
|---|---:|---:|---:|
| Raspberry Pi Zero W | `pi-zero2w` | `192.168.20.1/24` | disabled |
| Raspberry Pi Zero 2 W | `pi-zero2w` | `192.168.20.1/24` | disabled |
| Raspberry Pi 3 | `pi-full` | `192.168.30.1/24` | optional |
| Raspberry Pi 4 / CM4 | `pi-full` | `192.168.40.1/24` | optional |
| Raspberry Pi 5 / CM5 | `pi-full` | `192.168.50.1/24` | optional |

Unknown hardware aborts. The installer does not guess.

## Fresh Pi first install, no clone

On a fresh Pi with Internet access, run this one bootstrap command:

```bash
curl -fsSL https://raw.githubusercontent.com/psi1703/RaspberryPi/main/scripts/bootstrap-initbox.sh | sudo bash
```

The bootstrap does **not** run `git clone`. It downloads a temporary GitHub source archive into `/tmp`, launches the menu installer from that temporary archive, then removes the temporary source tree when the installer exits.

Normal technicians should use the menu. They do not need to remember long commands with flags.

## Runtime layout

Executables:

```text
/usr/local/bin/
```

Shared runtime files:

```text
/usr/local/share/initbox/
```

Configuration, state, logs, and package cache:

```text
/etc/initbox/              persistent InitBox state/configuration
/run/initbox/              runtime state
/var/log/initbox/          all InitBox installer, module, and sync logs
/opt/initbox/packages/     offline APT package cache
```

Installed command surface:

```text
/usr/local/bin/initbox-installer.sh
/usr/local/bin/initbox-bootstrap.sh
/usr/local/bin/initbox-sync.sh
/usr/local/bin/initbox-module-runner.sh
/usr/local/bin/initbox-package-cache.sh
```

Pi-full Dashboard support files, when installed:

```text
/usr/local/bin/initbox-dashboard-api.py
/usr/local/bin/pi-stats.sh
/usr/local/bin/initbox-file-transfer.sh
/usr/local/share/initbox/dashboard/ui/
```

Real module bodies are not flattened into `/usr/local/bin`; they stay in the repo-compatible runtime tree:

```text
/usr/local/share/initbox/scripts/pi-zero2w/
/usr/local/share/initbox/scripts/pi-full/
```

This preserves proven module path behavior while keeping the operator-facing command surface small.

## Repository layout

```text
profiles/
  pi-zero2w.conf
  pi-full.conf

scripts/
  bootstrap-initbox.sh
  install-initbox.sh
  initbox-sync.sh
  manifest.json
  bin/
    initbox-module-runner.sh
    initbox-package-cache.sh
  lib/
    hardware.sh
    profile.sh
    modules.sh
    state.sh
    packages.sh
    module-runner.sh
  packages/
    pi-zero2w.txt
    pi-full.txt
  pi-zero2w/
    module-hotspot.sh
    module-ttyd-portal.sh
    module-isi.sh
    module-ws-br0.sh
    module-fms.sh
  pi-full/
    module-hotspot.sh
    module-runtime-control.sh
    module-ttyd-portal.sh
    module-dashboard.sh
    module-ws-br0.sh
    module-isi.sh
    module-fms.sh
    module-rtc.sh

backend/
  initbox_dashboard_api.py
  requirements.txt

frontend/
  dist/
  src/
  package.json
  package-lock.json
  vite.config.js
```

## Operating model

### Development

Code is edited in GitHub. GitHub is the source of truth.

Do not install GitHub Actions runners on the Pi. Do not make field devices depend on a live repository clone.

### Lab

Lab is where Internet access is expected. Use lab mode for:

- first install through the bootstrap command
- optional OS package update
- InitBox runtime sync from GitHub
- package cache refresh
- module installation/removal
- Dashboard installation on Pi-full hardware
- validation before field deployment

### Field

Field mode is offline appliance operation.

In the field:

- do not run GitHub sync
- do not run `apt-get update`
- do not run `apt-get upgrade`
- do not download packages
- use only cached packages if a module must be installed
- collect logs/traces and validate service state locally

If the sync tool has no Internet, it leaves the current installation unchanged.

## Menu installer

Normal use is menu-driven:

```bash
sudo initbox-installer.sh
```

From a temporary source archive or local repo checkout, this also opens the same menu:

```bash
sudo bash scripts/install-initbox.sh
```

Pi-full menu:

```text
1) Show install plan
2) Install baseline without Dashboard
3) Install baseline with Dashboard
4) Full lab install: prompt OS upgrade, prompt Dashboard, refresh cache
5) Refresh offline package cache only
6) Show installed state
q) Quit
```

Pi Zero menu:

```text
1) Show install plan
2) Install baseline without Dashboard
3) Full Zero install: prompt OS upgrade, no Dashboard, refresh cache
4) Refresh offline package cache only
5) Show installed state
q) Quit
```

The installer detects the hardware, loads the matching profile, installs the runtime tree under `/usr/local/share/initbox`, installs the command surface under `/usr/local/bin`, then calls the unified module runner for selected modules.

The installer does not duplicate the BOX number prompt. The hotspot module owns BOX number handling and writes `/etc/pi-boxno`.

Advanced flags still exist for automation and repeatable tests, but the menu is the normal path.

## System package policy

Package operations use `apt-get` only.

The package helper never runs:

```text
apt-get upgrade
apt-get dist-upgrade
apt-get full-upgrade
```

The top-level installer may optionally run this first-install lab operation only when selected:

```bash
apt-get update
apt-get upgrade
```

It must never run `dist-upgrade` or `full-upgrade`.

## Module installation

Use the unified module runner only when manual module work is needed:

```bash
sudo initbox-module-runner.sh install fms
sudo initbox-module-runner.sh uninstall fms
```

Supported module IDs:

| Module ID | Zero | Pi-full | Notes |
|---|---:|---:|---|
| `hotspot` | yes | yes | owns `wlan0`, hostapd, dnsmasq |
| `web-terminal` | yes | yes | owns ttyd and shared portal target helper |
| `runtime-control` | no | yes | owns role control and module flags |
| `dashboard` | no | yes | optional; Dashboard-only ownership |
| `sniffer-bridge` | yes | yes | maps to `module-ws-br0.sh` |
| `isi` | yes | yes | ISI simulator |
| `fms` | yes | yes | FMS/CAN processing |
| `rtc` | no | yes | RTC support |

Unsupported modules are blocked by the profile.

## Module ownership boundaries

Preserve these boundaries when editing modules.

### Hotspot

Owns `wlan0`, hostapd, dnsmasq, hotspot DHCP/DNS, and `/etc/pi-boxno`.

### Web Terminal / Portal

Owns ttyd, the port-80 captive responder/socket, `/usr/local/sbin/initbox-portal-target`, and terminal/dashboard portal target selection.

Dashboard must not recreate ttyd or the port-80 portal.

### Runtime Control

Pi-full only. Owns `/etc/pi_roles.conf`, `/etc/initbox/dashboard-modules.env`, `/usr/local/bin/pi-servsync.sh`, `/usr/local/bin/pi-rolectl.sh`, and `pi-servsync.service`.

Dashboard must not recreate this logic.

### Dashboard

Pi-full only and optional. Owns `/usr/local/bin/initbox-dashboard-api.py`, `/usr/local/share/initbox/dashboard/ui/`, `/etc/initbox/dashboard-auth.env`, `initbox-dashboard.service`, `/usr/local/bin/pi-stats.sh`, `/usr/local/bin/initbox-file-transfer.sh`, `DASHBOARD=1`, and switching the shared portal target to `dashboard`.

Dashboard does not own ttyd, the port-80 captive portal/socket, runtime-control, role files, ISI/FMS/sniffer/hotspot/RTC services, Node.js, npm, or React build tooling.

### Pi Zero field modules

The Pi Zero profile must remain lightweight: no Dashboard, no Runtime Control, no RTC, Web Terminal only for management, and low CPU/RAM behavior preserved.

## Sync from GitHub in the lab

Check for updates:

```bash
sudo initbox-sync.sh check
```

Apply updates:

```bash
sudo initbox-sync.sh update
```

Apply updates and refresh the offline package cache:

```bash
sudo initbox-sync.sh update --refresh-cache
```

Refresh cache only:

```bash
sudo initbox-sync.sh refresh-cache
```

Show local sync state:

```bash
sudo initbox-sync.sh status
```

The sync tool does not use git, does not provide rollback, downloads and installs only changed runtime artifacts, verifies downloads by SHA-256, replaces files atomically, restarts only affected services listed in `scripts/manifest.json`, and refuses to change the system if GitHub is unreachable.

## Offline package cache

Package lists are profile-specific:

```text
scripts/packages/pi-zero2w.txt
scripts/packages/pi-full.txt
```

Refresh package cache in the lab:

```bash
sudo initbox-package-cache.sh preseed pi-zero2w
sudo initbox-package-cache.sh preseed pi-full
```

Verify cache:

```bash
sudo initbox-package-cache.sh verify pi-zero2w
sudo initbox-package-cache.sh verify pi-full
```

Field installs should use the existing cache and fail cleanly if the cache is incomplete.

## Logs

All InitBox logs are under:

```text
/var/log/initbox/
```

Important files:

```text
/var/log/initbox/install.log
/var/log/initbox/sync.log
/var/log/initbox/module-hotspot.log
/var/log/initbox/module-web-terminal.log
/var/log/initbox/module-runtime-control.log
/var/log/initbox/module-dashboard.log
/var/log/initbox/module-isi.log
/var/log/initbox/module-sniffer-bridge.log
/var/log/initbox/module-fms.log
/var/log/initbox/module-rtc.log
```

The module runner exports the log path before launching each module, so proven modules can keep their existing internals while still writing to the central log directory.

## Validation after install or sync

Run these checks after every first install and after every lab update:

```bash
systemctl --failed --no-pager
cat /etc/initbox/install-state.env
ls -la /usr/local/bin/initbox-*
ls -la /usr/local/share/initbox
ls -la /var/log/initbox
```

For Pi-full with Dashboard:

```bash
systemctl status initbox-dashboard.service --no-pager
curl -fsS http://127.0.0.1:8080/api/health
```

For Web Terminal / portal:

```bash
systemctl status ttyd.service --no-pager
systemctl status initbox-portal.socket --no-pager || true
```

For hotspot:

```bash
systemctl status hostapd.service --no-pager
systemctl status dnsmasq.service --no-pager
ip -br addr
```

Expected Zero network shape after field install:

```text
wlan0       192.168.20.1/24
eth0        no inet
eth1        no inet, if present
br0         no inet, if present
veth*_host  no inet, if present
can0        no inet, if present
```

Only `wlan0` should have the management IP on Pi Zero.

## React frontend policy

The Pi does not build React.

Development files remain in GitHub:

```text
frontend/src/
frontend/package.json
frontend/package-lock.json
frontend/vite.config.js
```

Deployable UI files live in:

```text
frontend/dist/
```

The manifest syncs only deployable static assets from `frontend/dist` into:

```text
/usr/local/share/initbox/dashboard/ui/
```

If the frontend is rebuilt and asset filenames change, update `scripts/manifest.json` to match the new `frontend/dist/assets/*` names.

## Safe edit rules

The existing module behavior is treated as proven. Do not rewrite module internals unless there is a confirmed defect.

Allowed changes: path integration, installer wiring, manifest updates, logging improvements, confirmed bug fixes, and documentation.

Avoid changing network ownership, DHCP behavior, bridge/namespace logic, FMS SocketCAN/CAN.trc behavior, ttyd/portal ownership, Dashboard ownership boundaries, or adding Node/npm runtime requirements to the Pi.

## Quick commands

Fresh Pi bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/psi1703/RaspberryPi/main/scripts/bootstrap-initbox.sh | sudo bash
```

Installed menu:

```bash
sudo initbox-installer.sh
```

Lab sync:

```bash
sudo initbox-sync.sh check
sudo initbox-sync.sh update
```

Module install:

```bash
sudo initbox-module-runner.sh install fms
```

Package cache refresh:

```bash
sudo initbox-package-cache.sh preseed pi-full
```

State, service, and logs:

```bash
cat /etc/initbox/install-state.env
systemctl --failed --no-pager
ls -la /var/log/initbox
```
