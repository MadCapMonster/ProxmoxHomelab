#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
PASSWORD="changeme"
USER="ubuntu"

VM_IDS=(240 241 242)
VM_NAMES=("fleet" "mysql" "redis")

MEMORY=(4096 4096 2048)
CORES=(2 2 2)
DISK=("32G" "32G" "16G")

STORAGE="local-lvm"
CLOUDINIT="local-lvm"
SNIPPET_STORAGE="local"
BRIDGE="vmbr0"

IMG="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# ===== Ensure snippets enabled =====
echo "Enabling snippets on local storage..."
pvesm set local --content "$(pvesm status | awk '/local / {print $NF}' | tr -d ' '),snippets" || true

# ===== Download image =====
if [ ! -f "$IMG" ]; then
  echo "Downloading Ubuntu image..."
  wget -O "$IMG" "$IMG_URL"
fi

# ===== LOOP VMs =====
for i in ${!VM_IDS[@]}; do
  VMID=${VM_IDS[$i]}
  NAME=${VM_NAMES[$i]}
  RAM=${MEMORY[$i]}
  CPU=${CORES[$i]}
  SIZE=${DISK[$i]}

  echo "Creating VM $VMID ($NAME)..."

  SNIPPET_FILE="$SNIPPET_DIR/user-$VMID.yaml"

  cat > "$SNIPPET_FILE" <<EOF
#cloud-config
hostname: $NAME
manage_etc_hosts: true

users:
  - name: $USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: $PASSWORD

ssh_pwauth: true
disable_root: false

chpasswd:
  list: |
    $USER:$PASSWORD
  expire: false

runcmd:
  - sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh || systemctl restart sshd
  - systemctl enable qemu-guest-agent --now
EOF

  qm create $VMID \
    --name $NAME \
    --memory $RAM \
    --cores $CPU \
    --net0 virtio,bridge=$BRIDGE \
    --ostype l26 \
    --agent enabled=1 \
    --vga std

  qm importdisk $VMID $IMG $STORAGE

  DISK_REF=$(qm config $VMID | awk -F': ' '/unused/ {print $2}')

  qm set $VMID --scsi0 $DISK_REF
  qm set $VMID --boot order=scsi0
  qm set $VMID --ide2 $CLOUDINIT:cloudinit
  qm set $VMID --ciuser $USER
  qm set $VMID --cipassword $PASSWORD
  qm set $VMID --ipconfig0 ip=dhcp
  qm set $VMID --cicustom user=local:snippets/$(basename $SNIPPET_FILE)

  qm resize $VMID scsi0 $SIZE

  qm cloudinit update $VMID
  qm start $VMID

done

echo
echo "======================================="
echo "ALL VMs CREATED"
echo "Login:"
echo "  user: $USER"
echo "  pass: $PASSWORD"
echo "======================================="
