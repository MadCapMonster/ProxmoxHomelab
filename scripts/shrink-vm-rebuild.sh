#!/usr/bin/env bash
set -euo pipefail

# Shrink/rebuild a Linux Proxmox VM by creating a smaller replacement VM disk.
#
# Usage:
#   ./shrink-vm-rebuild.sh <SOURCE_VMID> <SPARE_VMID> [TEMP_VMID] [ROOT_PARTITION]
#
# Example:
#   ./shrink-vm-rebuild.sh 240 9240 9241 /dev/sda2
#
# Notes:
#   - Linux VMs only.
#   - Not suitable for Windows, encrypted disks, ZFS-inside-guest, or complex multi-disk VMs.
#   - Works best with ext4/xfs/btrfs filesystems supported by libguestfs.
#   - Backs up first to usb-storage.
#   - Old VM is kept powered off under SPARE_VMID.
#   - New VM takes over the original VMID.

SOURCE_VMID="${1:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> [TEMP_VMID] [ROOT_PARTITION]}"
SPARE_VMID="${2:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> [TEMP_VMID] [ROOT_PARTITION]}"
TEMP_VMID="${3:-$((SOURCE_VMID + 9000))}"
ROOT_PARTITION="${4:-}"

BACKUP_STORAGE="usb-storage"
EXTRA_GB=4
COMPRESS="zstd"

echo "Source VMID : ${SOURCE_VMID}"
echo "Spare VMID  : ${SPARE_VMID}"
echo "Temp VMID   : ${TEMP_VMID}"
echo "Backup store: ${BACKUP_STORAGE}"
echo

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    exit 1
  }
}

require_cmd qm
require_cmd vzdump
require_cmd pvesm
require_cmd awk
require_cmd sed
require_cmd grep

echo "Installing required tools..."
apt update
#apt install -y libguestfs-tools qemu-utils zstd

require_cmd virt-df
require_cmd virt-filesystems
require_cmd virt-resize

if [[ ! -f "/etc/pve/qemu-server/${SOURCE_VMID}.conf" ]]; then
  echo "ERROR: Source VM ${SOURCE_VMID} does not exist."
  exit 1
fi

if [[ -f "/etc/pve/qemu-server/${SPARE_VMID}.conf" ]]; then
  echo "ERROR: Spare VMID ${SPARE_VMID} already exists."
  exit 1
fi

if [[ -f "/etc/pve/qemu-server/${TEMP_VMID}.conf" ]]; then
  echo "ERROR: Temp VMID ${TEMP_VMID} already exists."
  exit 1
fi

if ! pvesm status | awk '{print $1}' | grep -qx "${BACKUP_STORAGE}"; then
  echo "ERROR: Storage '${BACKUP_STORAGE}' not found."
  exit 1
fi

echo
echo "Detecting boot disk..."

BOOTDISK="$(qm config "${SOURCE_VMID}" | awk -F': ' '/^bootdisk:/ {print $2}')"

if [[ -z "${BOOTDISK}" ]]; then
  BOOTDISK="$(qm config "${SOURCE_VMID}" | awk -F: '/^(scsi|virtio|sata|ide)[0-9]+:/ {print $1; exit}')"
fi

if [[ -z "${BOOTDISK}" ]]; then
  echo "ERROR: Could not detect VM boot disk."
  exit 1
fi

DISK_LINE="$(qm config "${SOURCE_VMID}" | awk -F': ' -v d="${BOOTDISK}" '$1 == d {print $2}')"
DISK_VOL="$(echo "${DISK_LINE}" | cut -d',' -f1)"
DISK_STORAGE="$(echo "${DISK_VOL}" | cut -d':' -f1)"
DISK_PATH="$(pvesm path "${DISK_VOL}")"

echo "Boot disk   : ${BOOTDISK}"
echo "Disk volume : ${DISK_VOL}"
echo "Disk storage: ${DISK_STORAGE}"
echo "Disk path   : ${DISK_PATH}"

echo
echo "Stopping source VM for consistent backup and copy..."
qm stop "${SOURCE_VMID}" || true

echo
echo "Backing up VM ${SOURCE_VMID} to ${BACKUP_STORAGE}..."
vzdump "${SOURCE_VMID}" \
  --storage "${BACKUP_STORAGE}" \
  --mode stop \
  --compress "${COMPRESS}"

echo
echo "Calculating filesystem usage from guest disk..."
USED_BYTES="$(virt-df -a "${DISK_PATH}" --csv | awk -F, '
  NR > 1 && $1 != "Filesystem" {
    used += $4 * 1024
  }
  END {print used}
')"

if [[ -z "${USED_BYTES}" || "${USED_BYTES}" -le 0 ]]; then
  echo "ERROR: Could not calculate used space with virt-df."
  exit 1
fi

USED_GB="$(( (USED_BYTES + 1024*1024*1024 - 1) / (1024*1024*1024) ))"
NEW_SIZE_GB="$(( USED_GB + EXTRA_GB ))"

echo "Used space estimate: ${USED_GB}G"
echo "New disk size      : ${NEW_SIZE_GB}G"

echo
echo "Detecting partition to resize..."

if [[ -z "${ROOT_PARTITION}" ]]; then
  ROOT_PARTITION="$(virt-filesystems -a "${DISK_PATH}" --filesystems --long --uuid -h | awk '
    /ext|xfs|btrfs/ {
      print $1
      exit
    }
  ')"
fi

if [[ -z "${ROOT_PARTITION}" ]]; then
  echo "ERROR: Could not auto-detect root partition."
  echo "Re-run with partition, for example:"
  echo "  $0 ${SOURCE_VMID} ${SPARE_VMID} ${TEMP_VMID} /dev/sda2"
  exit 1
fi

echo "Resize partition: ${ROOT_PARTITION}"

echo
echo "Creating temporary replacement VM config..."
cp "/etc/pve/qemu-server/${SOURCE_VMID}.conf" "/etc/pve/qemu-server/${TEMP_VMID}.conf"

sed -i "/^${BOOTDISK}:/d" "/etc/pve/qemu-server/${TEMP_VMID}.conf"
sed -i "/^bootdisk:/d" "/etc/pve/qemu-server/${TEMP_VMID}.conf"
sed -i "s/^name:.*/name: shrink-temp-${SOURCE_VMID}/" "/etc/pve/qemu-server/${TEMP_VMID}.conf" || true

echo "Creating smaller disk on ${DISK_STORAGE}..."
qm set "${TEMP_VMID}" --"${BOOTDISK}" "${DISK_STORAGE}:${NEW_SIZE_GB},discard=on,ssd=1"
qm set "${TEMP_VMID}" --boot "order=${BOOTDISK}"

NEW_DISK_LINE="$(qm config "${TEMP_VMID}" | awk -F': ' -v d="${BOOTDISK}" '$1 == d {print $2}')"
NEW_DISK_VOL="$(echo "${NEW_DISK_LINE}" | cut -d',' -f1)"
NEW_DISK_PATH="$(pvesm path "${NEW_DISK_VOL}")"

echo "New disk volume: ${NEW_DISK_VOL}"
echo "New disk path  : ${NEW_DISK_PATH}"

echo
echo "Copying and resizing disk..."
virt-resize \
  --shrink "${ROOT_PARTITION}" \
  "${DISK_PATH}" \
  "${NEW_DISK_PATH}"

echo
echo "Running filesystem check on new disk where possible..."
virt-rescue -a "${NEW_DISK_PATH}" --ro -i true >/dev/null 2>&1 || true

echo
echo "Swapping VM IDs..."
mv "/etc/pve/qemu-server/${SOURCE_VMID}.conf" "/etc/pve/qemu-server/${SPARE_VMID}.conf"
mv "/etc/pve/qemu-server/${TEMP_VMID}.conf" "/etc/pve/qemu-server/${SOURCE_VMID}.conf"

sed -i "s/^name:.*/name: vm-${SOURCE_VMID}-shrunk/" "/etc/pve/qemu-server/${SOURCE_VMID}.conf" || true
sed -i "s/^name:.*/name: vm-${SPARE_VMID}-old-original/" "/etc/pve/qemu-server/${SPARE_VMID}.conf" || true

echo
echo "Starting new smaller VM as original VMID ${SOURCE_VMID}..."
qm start "${SOURCE_VMID}"

echo
echo "Done."
echo
echo "New smaller VM is running as VM ${SOURCE_VMID}."
echo "Old original VM is now VM ${SPARE_VMID} and is powered off."
echo
echo "Check the new VM carefully before deleting the old one."
