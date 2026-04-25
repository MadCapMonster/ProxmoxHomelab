#!/usr/bin/env bash
set -euo pipefail

# ========= VM settings =========
VMID=200
NAME="opnsense"
MEMORY=4096
CORES=2
SOCKETS=1
DISK_SIZE="32"   # GiB

# ========= Storage =========
ISO_STORAGE="usb-storage"
ISO_FILE="OPNsense-26.1.2-dvd-amd64.iso"
DISK_STORAGE="local-lvm"

# ========= Network =========
WAN_BRIDGE="vmbr0"   # Home network / internet side
LAN_BRIDGE="vmbr1"   # Isolated lab / Proxmox resources side

# ========= Checks =========
if qm status "$VMID" >/dev/null 2>&1; then
  echo "Error: VMID $VMID already exists."
  exit 1
fi

if ! pvesm list "$ISO_STORAGE" | awk '{print $1}' | grep -Fxq "${ISO_STORAGE}:iso/${ISO_FILE}"; then
  echo "Error: ISO ${ISO_FILE} not found on storage ${ISO_STORAGE}."
  echo "Available ISOs:"
  pvesm list "$ISO_STORAGE" | awk '$2=="iso"{print $1}'
  exit 1
fi

# ========= Create VM =========
qm create "$VMID" \
  --name "$NAME" \
  --machine q35 \
  --bios ovmf \
  --ostype l26 \
  --cpu host \
  --sockets "$SOCKETS" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --balloon 0 \
  --scsihw virtio-scsi-pci \
  --net0 "virtio,bridge=${WAN_BRIDGE}" \
  --net1 "virtio,bridge=${LAN_BRIDGE}"

qm set "$VMID" --efidisk0 "${DISK_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
qm set "$VMID" --scsi0 "${DISK_STORAGE}:${DISK_SIZE},ssd=1"
qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${ISO_FILE},media=cdrom"
qm set "$VMID" --boot order='ide2;scsi0'
qm set "$VMID" --serial0 socket --vga serial0
qm set "$VMID" --agent enabled=1

echo
echo "VM $VMID ($NAME) created successfully."
echo
echo "Start it with:"
echo "  qm start $VMID"
echo
echo "Then in OPNsense installer / console use:"
echo "  WAN = vtnet0  (${WAN_BRIDGE})"
echo "  LAN = vtnet1  (${LAN_BRIDGE})"
echo
echo "Recommended LAN config after install:"
echo "  LAN IP: 192.168.50.1/24"
echo "  DHCP: enabled"
echo
echo "Your design will then be:"
echo "  WAN side: home network (192.168.68.0/24)"
echo "  LAN side: isolated lab network (192.168.50.0/24)"
echo
echo "After installation, remove the ISO with:"
echo "  qm set $VMID --ide2 none,media=cdrom"
echo "  qm set $VMID --boot order='scsi0'"
