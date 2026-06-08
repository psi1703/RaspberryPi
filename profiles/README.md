# Hardware Profiles

This directory defines the supported Raspberry Pi hardware profiles.

Profiles are used to keep platform-specific decisions explicit. They should be treated as the source of truth for which features are allowed on each Raspberry Pi model.

## Supported profiles

| Profile   | Hardware               | Dashboard | Preferred management interface |
| --------- | ---------------------- | --------: | ------------------------------ |
| pi-zero2w | Raspberry Pi Zero 2W   |        No | Web Terminal                   |
| pi-3-4-5  | Raspberry Pi 3 / 4 / 5 |       Yes | Dashboard and Web Terminal     |

## Design rule

The Raspberry Pi Zero 2W must remain lightweight.

It must not include the dashboard stack.

The Raspberry Pi 3 / 4 / 5 profile may include dashboard components because these devices have more CPU and memory capacity.

## Lab setup model

All profiles assume that devices are configured in the lab while Internet access is available.

Field deployment assumes the device has already been prepared, verified, and reboot-tested.

## Profile file format

Each profile is a shell-compatible `.conf` file.

The installer can source the profile file later using:

```
. profiles/pi-zero2w.conf
```

or:

```
. profiles/pi-3-4-5.conf
```

Profile files should contain simple variable assignments only.

Avoid complex shell logic inside profile files.
