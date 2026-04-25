#!/usr/bin/env bash
set -euo pipefail

VMID="${VMID:-190}"
VMNAME="${VMNAME:-clonezilla}"
ISO_DIR="${ISO_DIR:-local}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"

CLONEZILLA_VERSION="3.3.1-35"
ISO_NAME="clonezilla-live-${CLONEZILLA_VERSION}-amd64.iso"
ISO_URL="https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable/${CLONEZILLA_VERSION}/${ISO_NAME}/download"
ISO_PATH="${ISO_DIR}/${ISO_NAME}"

echo "Installing required tools..."
apt update
apt install -y wget curl ca-certificates

echo "Preparing ISO directory: ${ISO_DIR}"
mkdir -p "${ISO_DIR}"

if [[ ! -f "${ISO_PATH}" ]]; then
  echo "Downloading Clonezilla ${CLONEZILLA_VERSION}..."
  wget -O "${ISO_PATH}" "${ISO_URL}"
else
  echo "Clonezilla ISO already exists: ${ISO_PATH}"
fi

echo "Checking VMID ${VMID}..."
if qm status "${VMID}" &>/dev/null; then
  echo "VM ${VMID} already exists. Skipping VM creation."
else
  echo "Creating Clonezilla utility VM..."

  qm create "${VMID}" \
    --name "${VMNAME}" \
    --memory "${MEMORY}" \
    --cores "${CORES}" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --ostype l26 \
    --agent 0 \
    --scsihw virtio-scsi-single \
    --boot order=ide2 \
    --ide2 "${STORAGE}:iso/${ISO_NAME},media=cdrom" \
    --serial0 socket \
    --vga std

  echo "VM created."
fi

echo
echo "Done."
echo "Start it with:"
echo "  qm start ${VMID}"
echo
echo "Open console in Proxmox:"
echo "  VM ${VMID} > Console"
echo
echo "To attach a VM disk later, shut down the source VM first, then use:"
echo "  qm set ${VMID} --scsi1 <storage>:vm-<source-vmid>-disk-0"
echo
echo "Clonezilla ISO source: ${ISO_URL}"
