#!/usr/bin/env bash
set -euo pipefail

SOURCE_VMID="${1:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> <TEMP_VMID> [ROOT_PARTITION]}"
SPARE_VMID="${2:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> <TEMP_VMID> [ROOT_PARTITION]}"
TEMP_VMID="${3:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> <TEMP_VMID> [ROOT_PARTITION]}"
ROOT_PARTITION="${4:-/dev/sda1}"

BACKUP_STORAGE="usb-storage"
CLONEZILLA_ISO="local:iso/clonezilla-live-3.3.1-35-amd64.iso"
EXTRA_GB=4
BRIDGE="vmbr0"

echo "Source VM : $SOURCE_VMID"
echo "Spare VM  : $SPARE_VMID"
echo "Temp VM   : $TEMP_VMID"
echo

if [[ ! -f "/etc/pve/qemu-server/${SOURCE_VMID}.conf" ]]; then
  echo "ERROR: Source VM does not exist."
  exit 1
fi

if [[ -f "/etc/pve/qemu-server/${SPARE_VMID}.conf" ]]; then
  echo "ERROR: Spare VMID already exists."
  exit 1
fi

if [[ -f "/etc/pve/qemu-server/${TEMP_VMID}.conf" ]]; then
  echo "ERROR: Temp VMID already exists."
  exit 1
fi

echo "Detecting boot disk..."

BOOTDISK="$(qm config "$SOURCE_VMID" | awk -F'order=' '/^boot:/ {print $2}' | cut -d';' -f1)"

if [[ -z "$BOOTDISK" ]]; then
  BOOTDISK="$(qm config "$SOURCE_VMID" | awk -F: '
    /^(scsi|virtio|sata)[0-9]+:/ &&
    $0 !~ /cloudinit/ &&
    $0 !~ /media=cdrom/ {
      print $1
      exit
    }
  ')"
fi
DISK_LINE="$(qm config "$SOURCE_VMID" | awk -F': ' -v d="$BOOTDISK" '$1 == d {print $2}')"
OLD_VOL="$(echo "$DISK_LINE" | cut -d',' -f1)"
OLD_STORAGE="$(echo "$OLD_VOL" | cut -d':' -f1)"

echo "Boot disk : $BOOTDISK"
echo "Old volume: $OLD_VOL"
echo "Storage   : $OLD_STORAGE"
echo

echo "Calculating used space from VM via guest agent..."
USED_GB="$(qm guest exec "$SOURCE_VMID" -- df -BG / | grep -o '"out-data"[^"]*"[^"]*"' | sed 's/\\n/\n/g' | awk '/\/$/ {gsub("G","",$3); print $3}')"

if [[ -z "$USED_GB" ]]; then
  echo "ERROR: Could not get disk usage via QEMU guest agent."
  echo "Inside the VM, run: df -h /"
  echo "Then manually set NEW_SIZE_GB in this script if needed."
  exit 1
fi

NEW_SIZE_GB="$((USED_GB + EXTRA_GB))"

echo "Used root space : ${USED_GB}G"
echo "New disk size   : ${NEW_SIZE_GB}G"
echo

echo "Backing up VM to ${BACKUP_STORAGE}..."
vzdump "$SOURCE_VMID" --storage "$BACKUP_STORAGE" --mode stop --compress zstd

echo "Stopping source VM..."
qm shutdown "$SOURCE_VMID" --timeout 120 || qm stop "$SOURCE_VMID"

echo "Creating Clonezilla helper VM..."
qm create "$TEMP_VMID" \
  --name "clonezilla-shrink-${SOURCE_VMID}" \
  --memory 4096 \
  --cores 2 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-single \
  --boot order=ide2 \
  --ide2 "$CLONEZILLA_ISO,media=cdrom" \
  --vga std

echo "Attaching old source disk as scsi0..."
qm set "$TEMP_VMID" --scsi0 "$OLD_VOL"

echo "Creating new smaller target disk as scsi1..."
qm set "$TEMP_VMID" --scsi1 "${OLD_STORAGE}:${NEW_SIZE_GB},discard=on,ssd=1"

echo
echo "Stage 1 complete."
echo
echo "Now start the helper VM:"
echo "  qm start $TEMP_VMID"
echo
echo "In Clonezilla choose:"
echo "  device-device"
echo "  Expert mode"
echo "  disk_to_local_disk"
echo "  source: old larger disk"
echo "  target: new smaller disk"
echo
echo "After Clonezilla finishes and shuts down, run:"
echo "  ./finalize-vm-shrink.sh $SOURCE_VMID $SPARE_VMID $TEMP_VMID $BOOTDISK"
