[README.md](https://github.com/user-attachments/files/28867997/README.md)
# Raspberry Pi Zero W / Zero 2W Profile

This branch contains the lightweight InitBox profile for Raspberry Pi Zero W and Raspberry Pi Zero 2W class devices.

The active profile ID is:

```text
pi-zero2w
```

The profile file is:

```text
profiles/pi-zero2w.conf
```

---

## Profile Purpose

The Zero profile keeps the device small and predictable:

* no dashboard stack;
* no Node-RED;
* no heavyweight web server for the captive portal path;
* Web Terminal through `ttyd`;
* hotspot-based field access;
* ISI and FMS support;
* optional br0 capture through the Pi Zero capture module.

---

## Profile Variables

The profile file is a shell-compatible `.conf` file. It should contain simple variable assignments only.

Important variables:

```bash
PROFILE_ID="pi-zero2w"
PROFILE_NAME="Raspberry Pi Zero 2W"
REQUIRES_LAB_INTERNET="yes"
FIELD_INSTALL_ALLOWED="no"
SUPPORTS_DASHBOARD="no"
SUPPORTS_WEB_TERMINAL="yes"
PRIMARY_MANAGEMENT_INTERFACE="web-terminal"
```

Module flags are controlled with variables such as:

```bash
MODULE_ISI="yes"
MODULE_FMS="yes"
MODULE_HOTSPOT="yes"
MODULE_WEB_TERMINAL="yes"
MODULE_DASHBOARD="no"
MODULE_RTC="no"
MODULE_SNIFFER_BRIDGE="no"
```

When a module should appear in the installer menu, it must be both:

1. enabled in `profiles/pi-zero2w.conf`; and
2. mapped in `scripts/lib/modules.sh`.

---

## Zero Branch Rules

This branch is not the Pi 3 / 4 / 5 dashboard branch.

Rules for this branch:

* Dashboard must remain blocked.
* Web Terminal is the management interface.
* `ttyd` must stay on port `7681`.
* Port `80` must remain the captive HTTP redirect socket.
* `isirunall.service` owns `br0` on Pi Zero.
* The br0 capture module may capture `br0`, but must not compete with ISI for bridge ownership.
* Field deployment assumes setup was completed in the lab with Internet access.

---

## Clean Install Command

After flashing the Pi and cloning this branch:

```bash
sudo ./scripts/initbox-installer.sh pi-zero2w
```

Run sanity checks from the installer menu before installing modules.
