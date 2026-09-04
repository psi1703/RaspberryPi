# InitBox Raspberry Pi Runtime

InitBox is a field appliance runtime for supported Raspberry Pi hardware. This repository now contains one unified codebase for:

- Raspberry Pi Zero W / Zero 2 W field units
- Raspberry Pi 3 / 4 / 5 and Compute Module 4 / 5 full units
- optional React Dashboard on Pi-full hardware only
- Web Terminal management on all supported profiles
- offline package-cache based field operation

The repository is the source of truth. Installed devices run from `/usr/local/bin` and `/usr/local/share/initbox`; they do not run from a Git checkout.

---

## Supported hardware

| Hardware | Profile | Hotspot gateway | Dashboard |
|---|---:|---:|---:|
| Raspberry Pi Zero W | `pi-zero2w` | `192.168.20.1/24` | disabled |
| Raspberry Pi Zero 2 W | `pi-zero2w` | `192.168.20.1/24` | disabled |
| Raspberry Pi 3 | `pi-full` | `192.168.30.1/24` | optional |
| Raspberry Pi 4 / CM4 | `pi-full` | `192.168.40.1/24` | optional |
| Raspberry Pi 5 / CM5 | `pi-full` | `192.168.50.1/24` | optional |

Unknown hardware aborts. The installer does not guess.

---

## Runtime layout

Executable commands live under:

```text
/usr/local/bin/
```

Shared InitBox runtime files live under:

```text
/usr/local/share/initbox/
```

Mutable system state, configuration, logs and package cache live outside `/usr/local`:

```text
/etc/initbox/              persistent InitBox state/configuration
/run/initbox/              runtime state
/var/log/initbox/          installer/sync logs
/opt/initbox/packages/     offline APT package cache
/home/initbox/pi_logs/     legacy module log compatibility
```

Installed command surface:

```text
/usr/local/bin/initbox-installer.sh
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

---

## Repository layout

```text
profiles/
  pi-zero2w.conf
  pi-full.conf

scripts/
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

---

## Operating model

### Development

Code is edited in GitHub. GitHub is the source of truth.

Do not install GitHub Actions runners on the Pi. Do not make field devices depend on a live repository clone.

### Lab

Lab is where Internet access is expected. Use lab mode for:

- first install
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

---

## First install

From the repository root on the Pi:

```bash
sudo bash scripts/install-initbox.sh plan
```

Then install without optional OS upgrade, Dashboard, or cache refresh:

```bash
sudo bash scripts/install-initbox.sh install \
  --system-upgrade no \
  --dashboard no \
  --refresh-cache no
```

For Pi-full with Dashboard:

```bash
sudo bash scripts/install-initbox.sh install \
  --system-upgrade no \
  --dashboard yes \
  --refresh-cache no
```

For a lab install that also refreshes the offline package cache:

```bash
sudo bash scripts/install-initbox.sh install \
  --system-upgrade no \
  --dashboard yes \
  --refresh-cache yes
```

The installer detects the hardware, loads the matching profile, installs the runtime tree under `/usr/local/share/initbox`, installs the command surface under `/usr/local/bin`, then calls the unified module runner for selected modules.

The installer does not duplicate the BOX number prompt. The hotspot module owns BOX number handling and writes `/etc/pi-boxno`.

---

## System package policy

Package operations use `apt-get` only.

The package helper never runs:

```text
apt-get upgrade
apt-get dist-upgrade
apt-get full-upgrade
```

The top-level installer may optionally run this first-install lab operation only when explicitly selected:

```bash
apt-get update
apt-get upgrade
```

It must never run `dist-upgrade` or `full-upgrade`.

---

## Module installation

Use the unified module runner:

```bash
sudo initbox-module-runner.sh install hotspot
sudo initbox-module-runner.sh install web-terminal
sudo initbox-module-runner.sh install isi
sudo initbox-module-runner.sh install sniffer-bridge
sudo initbox-module-runner.sh install fms
sudo initbox-module-runner.sh install rtc
sudo initbox-module-runner.sh install dashboard
```

Uninstall example:

```bash
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

---

## Module ownership boundaries

Preserve these boundaries when editing modules.

### Hotspot

Owns:

- `wlan0` hotspot addressing
- hostapd
- dnsmasq
- hotspot DHCP/DNS
- `/etc/pi-boxno`

Does not own Dashboard, ttyd, ISI, FMS, sniffer, or RTC behavior.

### Web Terminal / Portal

Owns:

- ttyd service
- port-80 captive responder/socket
- `/usr/local/sbin/initbox-portal-target`
- terminal/dashboard portal target selection

Dashboard must not recreate ttyd or the port-80 portal.

### Runtime Control

Pi-full only.

Owns:

- `/etc/pi_roles.conf`
- `/etc/initbox/dashboard-modules.env`
- `/usr/local/bin/pi-servsync.sh`
- `/usr/local/bin/pi-rolectl.sh`
- `pi-servsync.service`

Dashboard must not recreate this logic.

### Dashboard

Pi-full only and optional.

Owns:

- `/usr/local/bin/initbox-dashboard-api.py`
- `/usr/local/share/initbox/dashboard/ui/`
- `/etc/initbox/dashboard-auth.env`
- `initbox-dashboard.service`
- `/usr/local/bin/pi-stats.sh`
- `/usr/local/bin/initbox-file-transfer.sh`
- `DASHBOARD=1` in `/etc/initbox/dashboard-modules.env`
- switching the shared portal target to `dashboard`

Does not own:

- ttyd
- port-80 captive portal/socket
- runtime-control
- role files
- ISI/FMS/sniffer/hotspot/RTC services
- Node.js, npm, or React build tooling

### Pi Zero field modules

The Pi Zero profile must remain lightweight:

- no Dashboard
- no Runtime Control
- no RTC
- Web Terminal only for management
- low CPU/RAM behavior preserved

---

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

The sync tool:

- does not use git
- does not provide rollback
- downloads and installs only changed runtime artifacts
- verifies downloaded files by SHA-256
- replaces files atomically
- restarts only affected services listed in `scripts/manifest.json`
- refuses to change the system if GitHub is unreachable

---

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

Show cache status:

```bash
sudo initbox-package-cache.sh status pi-zero2w
sudo initbox-package-cache.sh status pi-full
```

Field installs should use the existing cache and fail cleanly if the cache is incomplete.

---

## Validation after install or sync

Run these checks after every first install and after every lab update:

```bash
systemctl --failed --no-pager
cat /etc/initbox/install-state.env
ls -la /usr/local/bin/initbox-*
ls -la /usr/local/share/initbox
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

---

## Dashboard access

Dashboard is optional and Pi-full only.

When installed, the Dashboard API runs on port 8080 and the shared portal target points users to Dashboard:

```text
http://initbox.wlan/
http://<hotspot-gateway>/
```

The Web Terminal remains available through the shared portal/terminal path and ttyd backend. Dashboard installation must not remove Web Terminal.

---

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

---

## Safe edit rules

The existing module behavior is treated as proven. Do not rewrite module internals unless there is a confirmed defect.

Allowed changes:

- path integration
- installer wiring
- manifest updates
- logging improvements
- confirmed bug fixes
- documentation

Avoid:

- changing network ownership
- changing DHCP behavior without evidence
- rewriting bridge/namespace logic casually
- changing FMS SocketCAN/CAN.trc behavior casually
- moving ttyd/portal ownership into Dashboard
- adding Node/npm runtime requirements to the Pi
- adding GitHub Actions runners to field devices

---

## Quick command summary

First install plan:

```bash
sudo bash scripts/install-initbox.sh plan
```

First install without optional Dashboard/cache refresh:

```bash
sudo bash scripts/install-initbox.sh install \
  --system-upgrade no \
  --dashboard no \
  --refresh-cache no
```

First install with Dashboard on Pi-full:

```bash
sudo bash scripts/install-initbox.sh install \
  --system-upgrade no \
  --dashboard yes \
  --refresh-cache no
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

State and service check:

```bash
cat /etc/initbox/install-state.env
systemctl --failed --no-pager
```
