#!/usr/bin/env bash
set -euo pipefail

# =========================
# Project Nomad - Proxmox LXC setup
# =========================

CTID="${CTID:-130}"
CT_HOSTNAME="${CT_HOSTNAME:-project-nomad}"
CT_PASSWORD="changeme"
CT_CORES="${CT_CORES:-4}"
CT_MEMORY="${CT_MEMORY:-4096}"      # MB
CT_SWAP="${CT_SWAP:-1024}"          # MB
CT_ROOTFS_SIZE="${CT_ROOTFS_SIZE:-20}"   # GB
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IPCFG="${CT_IPCFG:-dhcp}"
CT_OSTYPE="${CT_OSTYPE:-debian}"

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
USB_MOUNT="${USB_MOUNT:-/mnt/usb-storage}"
USB_SUBDIR="${USB_SUBDIR:-project-nomad}"
CONTAINER_DATA_MOUNT="${CONTAINER_DATA_MOUNT:-/data}"

# Rootfs target: local or local-lvm
ROOT_STORAGE="${1:-local-lvm}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run this script as root on the Proxmox host."
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "pct not found. This must be run on a Proxmox VE host."
  exit 1
fi

if ! command -v pveam >/dev/null 2>&1; then
  echo "pveam not found. This must be run on a Proxmox VE host."
  exit 1
fi

if [[ "$ROOT_STORAGE" != "local" && "$ROOT_STORAGE" != "local-lvm" ]]; then
  echo "Invalid root storage: $ROOT_STORAGE"
  echo "Use: local or local-lvm"
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  echo "Container ID $CTID already exists."
  exit 1
fi

if ! pvesm status | awk '{print $1}' | grep -qx "$ROOT_STORAGE"; then
  echo "Root storage '$ROOT_STORAGE' not found in Proxmox."
  pvesm status
  exit 1
fi

if ! pvesm status | awk '{print $1}' | grep -qx "$TEMPLATE_STORAGE"; then
  echo "Template storage '$TEMPLATE_STORAGE' not found in Proxmox."
  pvesm status
  exit 1
fi

mkdir -p "$USB_MOUNT"
mkdir -p "$USB_MOUNT/$USB_SUBDIR"

if ! mountpoint -q "$USB_MOUNT"; then
  echo "WARNING: $USB_MOUNT is not currently a mounted filesystem."
  echo "The script will continue, but you should ensure your USB disk is mounted there."
fi

chmod 755 "$USB_MOUNT"
chmod 755 "$USB_MOUNT/$USB_SUBDIR"

echo "Checking Debian 12 LXC template..."
pveam update

TEMPLATE="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | tail -n1)"
if [[ -z "${TEMPLATE:-}" ]]; then
  echo "Could not find a Debian 12 standard template."
  exit 1
fi

TEMPLATE_FILE="/var/lib/vz/template/cache/$(basename "$TEMPLATE")"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Downloading template $TEMPLATE to storage '$TEMPLATE_STORAGE'..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
else
  echo "Template already present: $TEMPLATE_FILE"
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Template file was not found after download: $TEMPLATE_FILE"
  exit 1
fi

echo "Creating container $CTID ($CT_HOSTNAME)..."

pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$CT_HOSTNAME" \
  --ostype "$CT_OSTYPE" \
  --cores "$CT_CORES" \
  --memory "$CT_MEMORY" \
  --swap "$CT_SWAP" \
  --rootfs "${ROOT_STORAGE}:${CT_ROOTFS_SIZE}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IPCFG},type=veth" \
  --unprivileged 1 \
  --features nesting=1 \
  --password "$CT_PASSWORD" \
  --onboot 1 \
  --startup order=10 \
  --mp0 "${USB_MOUNT}/${USB_SUBDIR},mp=${CONTAINER_DATA_MOUNT}"

CONF_FILE="/etc/pve/lxc/${CTID}.conf"

if [[ -f "$CONF_FILE" ]]; then
  if ! grep -q "^lxc.apparmor.profile:" "$CONF_FILE"; then
    echo "lxc.apparmor.profile: unconfined" >> "$CONF_FILE"
  fi
fi

echo "Starting container..."
pct start "$CTID"

sleep 3

echo "Container created successfully."
echo
echo "Summary:"
echo "  CTID:              $CTID"
echo "  Hostname:          $CT_HOSTNAME"
echo "  Root storage:      $ROOT_STORAGE"
echo "  Rootfs size:       ${CT_ROOTFS_SIZE}G"
echo "  USB host path:     ${USB_MOUNT}/${USB_SUBDIR}"
echo "  Container mount:   ${CONTAINER_DATA_MOUNT}"
echo
echo "Login:"
echo "  pct enter $CTID"
