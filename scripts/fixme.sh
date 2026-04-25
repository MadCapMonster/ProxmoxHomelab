#!/usr/bin/env bash
set -euo pipefail

PASSWORD="changeme"
USER_NAME="ubuntu"

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

create_vm() {
  local VMID="$1"
  local NAME="$2"
  local MEMORY="$3"
  local CORES="$4"
  local DISK_SIZE="$5"
  local IP_CIDR="$6"

  local SNIPPET_FILE="${SNIPPET_DIR}/user-${VMID}.yaml"

  cat > "${SNIPPET_FILE}" <<EOF
#cloud-config
hostname: ${NAME}
manage_etc_hosts: true
timezone: Europe/London
package_update: true
package_upgrade: true

users:
  - name: ${USER_NAME}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${PASSWORD}

ssh_pwauth: true
disable_root: true

chpasswd:
  list: |
    ${USER_NAME}:${PASSWORD}
  expire: false

packages:
  - qemu-guest-agent

write_files:
  - path: /root/firstboot.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
      sed -i 's/^#\\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config || true
      systemctl restart ssh || systemctl restart sshd || true
      systemctl enable qemu-guest-agent --now

      cat >/root/LOGIN-INFO.txt <<INFO
Login:
  user: ${USER_NAME}
  password: ${PASSWORD}
IP:
  ${IP_CIDR}
INFO

runcmd:
  - [ bash, /root/firstboot.sh ]

final_message: "VM bootstrap finished."
EOF

  qm create "${VMID}" \
    --name "${NAME}" \
    --memory "${MEMORY}" \
    --cores "${CORES}" \
    --cpu host \
    --net0 virtio,bridge="${BRIDGE}" \
    --ostype l26 \
    --agent enabled=1 \
    --vga std

  qm importdisk "${VMID}" "${IMG_FILE}" "${DISK_STORAGE}"

  local DISK_REF
  DISK_REF="$(qm config "${VMID}" | awk -F': ' '/^unused[0-9]+: / {print $2; exit}')"

  qm set "${VMID}" --scsihw virtio-scsi-pci --scsi0 "${DISK_REF}"
  qm set "${VMID}" --boot order=scsi0
  qm set "${VMID}" --ide2 "${CLOUDINIT_STORAGE}:cloudinit"
  qm set "${VMID}" --ciuser "${USER_NAME}"
  qm set "${VMID}" --cipassword "${PASSWORD}"
  qm set "${VMID}" --ipconfig0 "ip=${IP_CIDR},gw=${GATEWAY}"
  qm set "${VMID}" --nameserver "${DNS_SERVER}"
  qm set "${VMID}" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "${SNIPPET_FILE}")"
  qm resize "${VMID}" scsi0 "${DISK_SIZE}"
  qm cloudinit update "${VMID}"
  qm start "${VMID}"
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

for cmd in qm pvesm wget awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd"; exit 1; }
done

mkdir -p "${SNIPPET_DIR}" "${IMG_DIR}"

# Enable snippets on local if missing
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

NORMALIZED_CONTENT="$(echo "${CURRENT_CONTENT}" | tr -d ' ')"
if [[ ",${NORMALIZED_CONTENT}," != *",snippets,"* ]]; then
  pvesm set local --content "${NORMALIZED_CONTENT},snippets"
fi

if [[ ! -f "${IMG_FILE}" ]]; then
  wget -O "${IMG_FILE}" "${IMG_URL}"
fi

# Clean up any existing VMs with these IDs
for VMID in 240 241 242; do
  if qm status "${VMID}" >/dev/null 2>&1; then
    qm stop "${VMID}" || true
    qm destroy "${VMID}" --destroy-unreferenced-disks 1 --purge 1
  fi
done

create_vm 240 fleet-app 4096 2 32G 192.168.68.240/24
create_vm 241 fleet-db 4096 2 32G 192.168.68.241/24
create_vm 242 fleet-redis 2048 2 16G 192.168.68.242/24

echo
echo "Done."
echo "240 -> 192.168.68.240"
echo "241 -> 192.168.68.241"
echo "242 -> 192.168.68.242"
echo "Login: ubuntu / 12341234"
