#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./shrink-lxc-rebuild.sh <SOURCE_CTID> <SPARE_CTID> [TEMP_CTID]
#
# Example:
#   ./shrink-lxc-rebuild.sh 120 9120 9121
#
# End result:
#   - Original CTID is backed up to usb-storage
#   - New smaller CT is restored from backup
#   - Old CT config is moved to SPARE_CTID and left stopped
#   - New CT takes over original CTID and is started

SOURCE_CTID="${1:?Usage: $0 <SOURCE_CTID> <SPARE_CTID> [TEMP_CTID]}"
SPARE_CTID="${2:?Usage: $0 <SOURCE_CTID> <SPARE_CTID> [TEMP_CTID]}"
TEMP_CTID="${3:-$((SOURCE_CTID + 9000))}"

BACKUP_STORAGE="usb-storage"
EXTRA_GB=4
COMPRESS="zstd"

echo "Source CTID : ${SOURCE_CTID}"
echo "Spare CTID  : ${SPARE_CTID}"
echo "Temp CTID   : ${TEMP_CTID}"
echo "Backup store: ${BACKUP_STORAGE}"
echo

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    exit 1
  }
}

require_cmd pct
require_cmd vzdump
require_cmd pvesm
require_cmd awk
require_cmd grep
require_cmd sed

if [[ ! -f "/etc/pve/lxc/${SOURCE_CTID}.conf" ]]; then
  echo "ERROR: Source container ${SOURCE_CTID} does not exist."
  exit 1
fi

if [[ -f "/etc/pve/lxc/${SPARE_CTID}.conf" ]]; then
  echo "ERROR: Spare CTID ${SPARE_CTID} already exists."
  exit 1
fi

if [[ -f "/etc/pve/lxc/${TEMP_CTID}.conf" ]]; then
  echo "ERROR: Temp CTID ${TEMP_CTID} already exists."
  exit 1
fi

echo "Checking backup storage exists..."
if ! pvesm status | awk '{print $1}' | grep -qx "${BACKUP_STORAGE}"; then
  echo "ERROR: Proxmox storage '${BACKUP_STORAGE}' not found."
  exit 1
fi

ROOTFS_LINE="$(pct config "${SOURCE_CTID}" | awk -F': ' '/^rootfs:/ {print $2}')"
if [[ -z "${ROOTFS_LINE}" ]]; then
  echo "ERROR: Could not find rootfs line for CT ${SOURCE_CTID}."
  exit 1
fi

ROOTFS_STORAGE="$(echo "${ROOTFS_LINE}" | cut -d: -f1)"
echo "Detected rootfs storage: ${ROOTFS_STORAGE}"

echo
echo "Calculating current root filesystem usage..."

WAS_RUNNING=0
if pct status "${SOURCE_CTID}" | grep -q "status: running"; then
  WAS_RUNNING=1
  USED_KB="$(pct exec "${SOURCE_CTID}" -- df -kP / | awk 'NR==2 {print $3}')"
else
  echo "Container is stopped; temporarily mounting rootfs..."
  MOUNT_POINT="$(pct mount "${SOURCE_CTID}" | awk '{print $NF}')"
  USED_KB="$(df -kP "${MOUNT_POINT}" | awk 'NR==2 {print $3}')"
  pct unmount "${SOURCE_CTID}" >/dev/null
fi

USED_GB="$(( (USED_KB + 1024*1024 - 1) / (1024*1024) ))"
NEW_SIZE_GB="$(( USED_GB + EXTRA_GB ))"

echo "Used space   : ${USED_GB}G"
echo "New disk size: ${NEW_SIZE_GB}G"
echo

echo "Backing up CT ${SOURCE_CTID} to ${BACKUP_STORAGE}..."
vzdump "${SOURCE_CTID}" \
  --storage "${BACKUP_STORAGE}" \
  --mode stop \
  --compress "${COMPRESS}"

echo
echo "Finding newest backup..."

BACKUP_DUMP_DIR="$(pvesm path "${BACKUP_STORAGE}:backup/vzdump-lxc-${SOURCE_CTID}-dummy.tar.zst" 2>/dev/null || true)"
BACKUP_DUMP_DIR="$(dirname "${BACKUP_DUMP_DIR}")"

if [[ ! -d "${BACKUP_DUMP_DIR}" ]]; then
  if [[ -d "/mnt/${BACKUP_STORAGE}/dump" ]]; then
    BACKUP_DUMP_DIR="/mnt/${BACKUP_STORAGE}/dump"
  elif [[ -d "/mnt/pve/${BACKUP_STORAGE}/dump" ]]; then
    BACKUP_DUMP_DIR="/mnt/pve/${BACKUP_STORAGE}/dump"
  else
    echo "ERROR: Could not locate dump directory for ${BACKUP_STORAGE}"
    exit 1
  fi
fi

BACKUP_PATH="$(find "${BACKUP_DUMP_DIR}" \
  -maxdepth 1 \
  -type f \
  \( -name "vzdump-lxc-${SOURCE_CTID}-*.tar.zst" -o -name "vzdump-lxc-${SOURCE_CTID}-*.tar.gz" -o -name "vzdump-lxc-${SOURCE_CTID}-*.tar.lzo" \) \
  -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"

if [[ -z "${BACKUP_PATH}" || ! -f "${BACKUP_PATH}" ]]; then
  echo "ERROR: Could not locate backup file in ${BACKUP_DUMP_DIR}"
  exit 1
fi

echo "Backup file: ${BACKUP_PATH}"


echo "Ensuring source container is stopped..."
pct stop "${SOURCE_CTID}" || true

echo "Restoring backup to temporary CT ${TEMP_CTID} with smaller rootfs..."
pct restore "${TEMP_CTID}" "${BACKUP_PATH}" \
  --storage "${ROOTFS_STORAGE}" \
  --rootfs "${ROOTFS_STORAGE}:${NEW_SIZE_GB}"

echo
echo "Stopping restored temporary CT, if running..."
pct stop "${TEMP_CTID}" || true

echo "Swapping CT IDs..."
mv "/etc/pve/lxc/${SOURCE_CTID}.conf" "/etc/pve/lxc/${SPARE_CTID}.conf"
mv "/etc/pve/lxc/${TEMP_CTID}.conf" "/etc/pve/lxc/${SOURCE_CTID}.conf"

echo
echo "Starting new container as original CTID ${SOURCE_CTID}..."
pct start "${SOURCE_CTID}"

echo
echo "Done."
echo
echo "New smaller container is running as CT ${SOURCE_CTID}."
echo "Old original container is now CT ${SPARE_CTID} and remains powered off."
echo "Backup is stored on ${BACKUP_STORAGE}:"
echo "  ${BACKUP_PATH}"
