# InitBox Raspberry Pi Setup

This repository contains setup scripts and documentation for preparing Raspberry Pi devices used as InitBox field appliances.

The Raspberry Pi devices are expected to be configured in a lab environment where Internet access is available. After setup and verification, the devices are deployed in the field as preconfigured appliances.

## Operating model

1. Prepare the Raspberry Pi in the lab.
2. Ensure Internet access is available during setup.
3. Run the appropriate installer for the target Raspberry Pi model.
4. Install required packages and services.
5. Reboot if required.
6. Verify the device before field deployment.
7. Deploy the prepared device in the field.

Field deployment should not depend on Internet access for package installation.

## Supported hardware profiles

| Hardware | Intended use | Dashboard support | Recommended interface |
|---|---|---:|---|
| Raspberry Pi Zero 2W | Lightweight field device | No | Web Terminal |
| Raspberry Pi 3 / 4 / 5 | Full field device | Yes | Dashboard and Web Terminal |

## Raspberry Pi Zero 2W

The Raspberry Pi Zero 2W is resource-constrained. It should not run the full dashboard stack.

Recommended features:

- ISI
- FMS
- Hotspot
- Web Terminal

The Pi Zero 2W should use a lightweight terminal-based web interface instead of a dashboard.

Start here:

```text
docs/pi-zero2w/README.md
