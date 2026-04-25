#!/usr/bin/env bash
set -euo pipefail

PASSWORD="changeme"
CIUSER="ubuntu"

BRIDGE="vmbr0"
DISK_STORAGE="local-lvm"
CLOUDINIT_STORAGE="local-lvm"
SNIPPET_STORAGE="local"
SNIPPET_DIR="/var/lib/vz/snippets"

GATEWAY="192.168.68.1"
DNS_SERVER="1.1.1.1"

IMG_DIR="/var/lib/vz/template/iso"
IMG_FILE="${IMG_DIR}/noble-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

SSH_PUBKEY_FILE="/root/.ssh/id_rsa.pub"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    exit 1
  }
}

destroy_if_exists() {
  local vmid="$1"
  if qm status "$vmid" >/dev/null 2>&1; then
    qm stop "$vmid" || true
    qm destroy "$vmid" --destroy-unreferenced-disks 1 --purge 1
  fi
}

write_userdata() {
  local name="$1"
  local ipcidr="$2"
  local outfile="$3"
  local sshkey_block=""

  if [[ -f "$SSH_PUBKEY_FILE" ]]; then
    local key
    key="$(cat "$SSH_PUBKEY_FILE")"
    sshkey_block=$(cat <<EOF
ssh_authorized_keys:
  - ${key}
EOF
)
  fi

  cat > "$outfile" <<EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: true
timezone: Europe/London

password: ${PASSWORD}
chpasswd:
  expire: false
ssh_pwauth: true
disable_root: true

${sshkey_block}

packages:
  - qemu-guest-agent

write_files:
  - path: /etc/ssh/sshd_config.d/99-password-auth.conf
    permissions: '0644'
    owner: root:root
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      ChallengeResponseAuthentication yes
      UsePAM yes

runcmd:
  - [ systemctl, enable, qemu-guest-agent, --now ]
  - [ systemctl, restart, ssh ]
  - [ bash, -lc, "id ${CIUSER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${CIUSER}" ]
  - [ bash, -lc, "echo '${CIUSER}:${PASSWORD}' | chpasswd" ]
  - [ bash, -lc, "usermod -aG sudo ${CIUSER} || true" ]
  - [ bash, -lc, "mkdir -p /home/${CIUSER}/.ssh && chown -R ${CIUSER}:${CIUSER} /home/${CIUSER}/.ssh" ]
  - [ bash, -lc, "echo '${name} ${ipcidr}' > /root/VM-INFO.txt" ]

final_message: "VM bootstrap finished."
EOF
}

create_vm() {
  local vmid="$1"
  local name="$2"
  local memory="$3"
  local cores="$4"
  local disksize="$5"
  local ipcidr="$6"

  local snippet_file="${SNIPPET_DIR}/user-${vmid}.yaml"

  write_userdata "$name" "$ipcidr" "$snippet_file"

  qm create "$vmid" \
    --name "$name" \
    --memory "$memory" \
    --cores "$cores" \
    --cpu host \
    --net0 virtio,bridge="$BRIDGE" \
    --ostype l26 \
    --agent enabled=1 \
    --vga std

  qm importdisk "$vmid" "$IMG_FILE" "$DISK_STORAGE"

  local disk_ref
  disk_ref="$(qm config "$vmid" | awk -F': ' '/^unused[0-9]+: / {print $2; exit}')"
  [[ -n "$disk_ref" ]] || { echo "Imported disk not found for VM $vmid"; exit 1; }

  qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$disk_ref"
  qm set "$vmid" --boot order=scsi0
  qm set "$vmid" --ide2 "${CLOUDINIT_STORAGE}:cloudinit"
  qm set "$vmid" --ciuser "$CIUSER"
  qm set "$vmid" --cipassword "$PASSWORD"
  qm set "$vmid" --ipconfig0 "ip=${ipcidr},gw=${GATEWAY}"
  qm set "$vmid" --nameserver "$DNS_SERVER"
  qm set "$vmid" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$snippet_file")"

  if [[ -f "$SSH_PUBKEY_FILE" ]]; then
    qm set "$vmid" --sshkey "$SSH_PUBKEY_FILE"
  fi

  qm resize "$vmid" scsi0 "$disksize"
  qm cloudinit update "$vmid"
  qm start "$vmid"
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

for cmd in qm pvesm wget awk; do
  need_cmd "$cmd"
done

mkdir -p "$SNIPPET_DIR" "$IMG_DIR"

# ensure local supports snippets
CURRENT_CONTENT="$(awk '
  $1=="dir:" && $2=="local" {in_local=1; next}
  /^[A-Za-z0-9_-]+:/ && !($1=="dir:" && $2=="local") {in_local=0}
  in_local && $1=="content" {
    $1=""
    sub(/^ +/, "")
    print
    exit
  }
' /etc/pve/storage.cfg)"

NORMALIZED_CONTENT="$(echo "$CURRENT_CONTENT" | tr -d ' ')"
if [[ ",${NORMALIZED_CONTENT}," != *",snippets,"* ]]; then
  pvesm set local --content "${NORMALIZED_CONTENT},snippets"
fi

if [[ ! -f "$IMG_FILE" ]]; then
  wget -O "$IMG_FILE" "$IMG_URL"
fi

destroy_if_exists 240
destroy_if_exists 241
destroy_if_exists 242

create_vm 240 fleet-app   4096 2 32G 192.168.68.240/24
create_vm 241 fleet-db    4096 2 32G 192.168.68.241/24
create_vm 242 fleet-redis 2048 2 16G 192.168.68.242/24

cat <<EOF

Created:
  240 -> 192.168.68.240
  241 -> 192.168.68.241
  242 -> 192.168.68.242

Login:
  user: ubuntu
  pass: 12341234

SSH:
  ssh ubuntu@192.168.68.240
  ssh ubuntu@192.168.68.241
  ssh ubuntu@192.168.68.242

If your SSH client keeps trying keys first, force password auth:
  ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password ubuntu@192.168.68.240
EOF
