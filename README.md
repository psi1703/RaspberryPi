# InitBox Raspberry Pi 3 / 4 / 5 Setup

This branch contains setup scripts and documentation for preparing Raspberry Pi 3, Raspberry Pi 4, and Raspberry Pi 5 devices as InitBox field appliances.

The Pi 3 / 4 / 5 build supports the full InitBox stack:

- Hotspot
- Dashboard
- Web Terminal
- ISI simulator
- FMS/CAN replay
- RTC sync
- Sniffer / bridge capture

The lightweight Raspberry Pi Zero W / Zero 2W build is maintained separately in the `pi-zero-W-2W` branch.

---

## Operating Model

The intended workflow is:

1. Prepare the Raspberry Pi in the lab.
2. Make sure the Pi has Internet access.
3. Clone or update this branch on the Pi.
4. Run the installer for the `pi-3-4-5` profile.
5. Run installer sanity checks.
6. Install required modules.
7. Reboot if required.
8. Verify all required services before field deployment.
9. Deploy the prepared device in the field.

All required packages must be installed during lab preparation.

Field deployment should not depend on Internet access for package installation.

---

## Supported Hardware Profile

This branch supports only:

```text
pi-3-4-5
