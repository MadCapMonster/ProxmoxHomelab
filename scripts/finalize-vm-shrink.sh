#!/usr/bin/env bash
set -euo pipefail

SOURCE_VMID="${1:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> <TEMP_VMID> <BOOTDISK>}"
SPARE_VMID="${2:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> <TEMP_VMID> <BOOTDISK>}"
TEMP_VMID="${3:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> <TEMP_VMID> <BOOTDISK>}"
BOOTDISK="${4:?Usage: $0 <SOURCE_VMID> <SPARE_VMID> <TEMP_VMID> <BOOTDISK>}"

echo "Stopping helper VM..."
qm stop "$TEMP_VMID" || true

NEW_DISK_LINE="$(qm config "$TEMP_VMID" | awk -F': ' '/^scsi1:/ {print $2}')"
NEW_VOL="$(echo "$NEW_DISK_LINE" | cut -d',' -f1)"

if [[ -z "$NEW_VOL" ]]; then
  echo "ERROR: Could not find new disk on scsi1."
  exit 1
fi

echo "New disk volume: $NEW_VOL"

echo "Copying original VM config to spare ID..."
mv "/etc/pve/qemu-server/${SOURCE_VMID}.conf" "/etc/pve/qemu-server/${SPARE_VMID}.conf"

echo "Creating new VM config using original config..."
cp "/etc/pve/qemu-server/${SPARE_VMID}.conf" "/etc/pve/qemu-server/${SOURCE_VMID}.conf"

echo "Replacing old boot disk with new smaller disk..."
sed -i "/^${BOOTDISK}:/d" "/etc/pve/qemu-server/${SOURCE_VMID}.conf"
sed -i "/^bootdisk:/d" "/etc/pve/qemu-server/${SOURCE_VMID}.conf"

cat >> "/etc/pve/qemu-server/${SOURCE_VMID}.conf" <<EOF
${BOOTDISK}: ${NEW_VOL},discard=on,ssd=1
bootdisk: ${BOOTDISK}
EOF

echo "Removing helper VM config only..."
rm -f "/etc/pve/qemu-server/${TEMP_VMID}.conf"

echo "Starting new smaller VM as original VMID..."
qm start "$SOURCE_VMID"

echo
echo "Done."
echo "New smaller VM is running as VM $SOURCE_VMID."
echo "Old original VM is now VM $SPARE_VMID and is powered off."
