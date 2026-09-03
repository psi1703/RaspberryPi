#!/usr/bin/env bash
# InitBox Raspberry Pi hardware detection helper.
#
# Source this file; do not execute it directly.
# It reads /proc/device-tree/model and maps supported Raspberry Pi hardware to
# one of the two InitBox installation profiles.

set -euo pipefail

INITBOX_HARDWARE_DETECTED="no"
INITBOX_MODEL_RAW=""
INITBOX_HARDWARE_ID=""
INITBOX_HARDWARE_NAME=""
INITBOX_PROFILE_ID=""
INITBOX_HOTSPOT_SUBNET_PREFIX=""
INITBOX_HOTSPOT_GATEWAY=""
INITBOX_DASHBOARD_CAPABLE=""

initbox_read_hardware_model() {
  local model_file="/proc/device-tree/model"

  if [ ! -r "$model_file" ]; then
    echo "ERROR: cannot read Raspberry Pi model from $model_file." >&2
    return 1
  fi

  tr -d '\000' < "$model_file"
}

initbox_detect_hardware() {
  local model=""

  model="$(initbox_read_hardware_model)"

  if [ -z "$model" ]; then
    echo "ERROR: Raspberry Pi model string is empty." >&2
    return 1
  fi

  INITBOX_MODEL_RAW="$model"

  case "$model" in
    *"Raspberry Pi Zero 2 W"*)
      INITBOX_HARDWARE_ID="pi-zero-2w"
      INITBOX_HARDWARE_NAME="Raspberry Pi Zero 2 W"
      INITBOX_PROFILE_ID="pi-zero2w"
      INITBOX_HOTSPOT_SUBNET_PREFIX="192.168.20"
      INITBOX_DASHBOARD_CAPABLE="no"
      ;;
    *"Raspberry Pi Zero W"*)
      INITBOX_HARDWARE_ID="pi-zero-w"
      INITBOX_HARDWARE_NAME="Raspberry Pi Zero W"
      INITBOX_PROFILE_ID="pi-zero2w"
      INITBOX_HOTSPOT_SUBNET_PREFIX="192.168.20"
      INITBOX_DASHBOARD_CAPABLE="no"
      ;;
    *"Raspberry Pi Compute Module 5"*)
      INITBOX_HARDWARE_ID="cm5"
      INITBOX_HARDWARE_NAME="Raspberry Pi Compute Module 5"
      INITBOX_PROFILE_ID="pi-full"
      INITBOX_HOTSPOT_SUBNET_PREFIX="192.168.50"
      INITBOX_DASHBOARD_CAPABLE="yes"
      ;;
    *"Raspberry Pi Compute Module 4"*)
      INITBOX_HARDWARE_ID="cm4"
      INITBOX_HARDWARE_NAME="Raspberry Pi Compute Module 4"
      INITBOX_PROFILE_ID="pi-full"
      INITBOX_HOTSPOT_SUBNET_PREFIX="192.168.40"
      INITBOX_DASHBOARD_CAPABLE="yes"
      ;;
    *"Raspberry Pi 5 Model"*)
      INITBOX_HARDWARE_ID="pi5"
      INITBOX_HARDWARE_NAME="Raspberry Pi 5"
      INITBOX_PROFILE_ID="pi-full"
      INITBOX_HOTSPOT_SUBNET_PREFIX="192.168.50"
      INITBOX_DASHBOARD_CAPABLE="yes"
      ;;
    *"Raspberry Pi 4 Model"*)
      INITBOX_HARDWARE_ID="pi4"
      INITBOX_HARDWARE_NAME="Raspberry Pi 4"
      INITBOX_PROFILE_ID="pi-full"
      INITBOX_HOTSPOT_SUBNET_PREFIX="192.168.40"
      INITBOX_DASHBOARD_CAPABLE="yes"
      ;;
    *"Raspberry Pi 3 Model"*)
      INITBOX_HARDWARE_ID="pi3"
      INITBOX_HARDWARE_NAME="Raspberry Pi 3"
      INITBOX_PROFILE_ID="pi-full"
      INITBOX_HOTSPOT_SUBNET_PREFIX="192.168.30"
      INITBOX_DASHBOARD_CAPABLE="yes"
      ;;
    *)
      echo "ERROR: unsupported Raspberry Pi model: $model" >&2
      echo "Supported: Zero W, Zero 2 W, Pi 3, Pi 4, Pi 5, Compute Module 4, Compute Module 5." >&2
      return 1
      ;;
  esac

  INITBOX_HOTSPOT_GATEWAY="${INITBOX_HOTSPOT_SUBNET_PREFIX}.1"
  INITBOX_HARDWARE_DETECTED="yes"

  initbox_validate_hardware_detection
}

initbox_validate_hardware_detection() {
  local var_name=""

  if [ "$INITBOX_HARDWARE_DETECTED" != "yes" ]; then
    echo "ERROR: InitBox hardware detection has not completed." >&2
    return 1
  fi

  for var_name in \
    INITBOX_MODEL_RAW \
    INITBOX_HARDWARE_ID \
    INITBOX_HARDWARE_NAME \
    INITBOX_PROFILE_ID \
    INITBOX_HOTSPOT_SUBNET_PREFIX \
    INITBOX_HOTSPOT_GATEWAY \
    INITBOX_DASHBOARD_CAPABLE; do
    if [ -z "${!var_name:-}" ]; then
      echo "ERROR: hardware detection did not set $var_name." >&2
      return 1
    fi
  done

  case "$INITBOX_PROFILE_ID" in
    pi-zero2w|pi-full)
      ;;
    *)
      echo "ERROR: invalid detected profile: $INITBOX_PROFILE_ID" >&2
      return 1
      ;;
  esac

  case "$INITBOX_DASHBOARD_CAPABLE" in
    yes|no)
      ;;
    *)
      echo "ERROR: invalid dashboard capability: $INITBOX_DASHBOARD_CAPABLE" >&2
      return 1
      ;;
  esac

  if [ "$INITBOX_PROFILE_ID" = "pi-zero2w" ] && [ "$INITBOX_DASHBOARD_CAPABLE" != "no" ]; then
    echo "ERROR: Pi Zero hardware must not be dashboard-capable." >&2
    return 1
  fi

  if [ "$INITBOX_PROFILE_ID" = "pi-full" ] && [ "$INITBOX_DASHBOARD_CAPABLE" != "yes" ]; then
    echo "ERROR: pi-full hardware must be dashboard-capable." >&2
    return 1
  fi
}

initbox_print_hardware_summary() {
  if [ "$INITBOX_HARDWARE_DETECTED" != "yes" ]; then
    echo "ERROR: InitBox hardware has not been detected." >&2
    return 1
  fi

  cat <<EOF_SUMMARY
InitBox hardware detected
-------------------------
Model:             $INITBOX_MODEL_RAW
Hardware family:   $INITBOX_HARDWARE_NAME
Hardware ID:       $INITBOX_HARDWARE_ID
Selected profile:  $INITBOX_PROFILE_ID
Hotspot gateway:   $INITBOX_HOTSPOT_GATEWAY/24
Dashboard capable: $INITBOX_DASHBOARD_CAPABLE
EOF_SUMMARY
}
