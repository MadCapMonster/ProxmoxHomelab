#!/usr/bin/env bash
set -euo pipefail

############################################
# Proxmox -> create 3 Ubuntu cloud VMs
# 240 = Fleet app
# 241 = MySQL
# 242 = Redis
#
# Stage 1 only:
# - creates all 3 VMs
# - enables snippets on local if needed
# - injects working console + SSH password auth
# - installs qemu-guest-agent everywhere
# - installs Docker on Fleet VM
############################################

### ===== EDIT THESE =====
FLEET_VMID=240
DB_VMID=241
REDIS_VMID=242

FLEET_NAME="fleet-app"
DB_NAME="fleet-db"
REDIS_NAME="fleet-redis"

DISK_STORAGE="local-lvm"
CLOUDINIT_STORAGE="local-lvm"
SNIPPET_STORAGE="local"
SNIPPET_BASE_PATH="/var/lib/vz"
BRIDGE="vmbr0"

FLEET_MEMORY=4096
FLEET_CORES=2
FLEET_DISK="32G"

DB_MEMORY=4096
DB_CORES=2
DB_DISK="32G"

REDIS_MEMORY=2048
REDIS_CORES=2
REDIS_DISK="16G"

USE_DHCP="true"

FLEET_STATIC_IP="192.168.68.240/24"
DB_STATIC_IP="192.168.68.241/24"
REDIS_STATIC_IP="192.168.68.242/24"
GATEWAY_IP="192.168.68.1"
DNS_SERVER="1.1.1.1"

CI_USER="ubuntu"
CI_PASSWORD="changeme"
TIMEZONE="Europe/London"

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_DIR="/var/lib/vz/template/iso"
IMG_FILE="${IMG_DIR}/noble-server-cloudimg-amd64.img"
### ======================

SNIPPET_DIR="${SNIPPET_BASE_PATH}/snippets"
FLEET_USERDATA="${SNIPPET_DIR}/fleet-user-data-${FLEET_VMID}.yaml"
DB_USERDATA="${SNIPPET_DIR}/fleet-user-data-${DB_VMID}.yaml"
REDIS_USERDATA="${SNIPPET_DIR}/fleet-user-data-${REDIS_VMID}.yaml"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    exit 1
  }
}

ensure_snippets_on_local() {
  local current normalized new_content

  current="$(awk '
    $1=="dir:" && $2=="local" {in_local=1; next}
    /^[A-Za-z0-9_-]+:/ && !($1=="dir:" && $2=="local") {in_local=0}
    in_local && $1=="content" {
      $1=""
      sub(/^ +/, "")
      print
      exit
    }
  ' /etc/pve/storage.cfg)"

  if [[ -z "${current}" ]]; then
    echo "Could not read content types for storage '${SNIPPET_STORAGE}'."
    exit 1
  fi

  normalized="$(echo "${current}" | tr -d ' ')"
  if [[ ",${normalized}," != *",snippets,"* ]]; then
    new_content="${normalized},snippets"
    pvesm set "${SNIPPET_STORAGE}" --content "${new_content}"
    echo "Enabled snippets on ${SNIPPET_STORAGE}: ${new_content}"
  else
    echo "Snippets already enabled on ${SNIPPET_STORAGE}"
  fi
}

create_vm() {
  local vmid="$1"
  local name="$2"
  local memory="$3"
  local cores="$4"
  local disk_size="$5"
  local ipconfig="$6"
  local userdata_file="$7"

  if qm status "${vmid}" >/dev/null 2>&1; then
    echo "VMID ${vmid} already exists. Delete it or change the script."
    exit 1
  fi

  echo "==> Creating VM ${vmid} (${name})..."
  qm create "${vmid}" \
    --name "${name}" \
    --memory "${memory}" \
    --cores "${cores}" \
    --cpu host \
    --ostype l26 \
    --net0 virtio,bridge="${BRIDGE}" \
    --agent enabled=1 \
    --vga std

  echo "==> Importing Ubuntu disk to ${DISK_STORAGE} for ${name}..."
  qm importdisk "${vmid}" "${IMG_FILE}" "${DISK_STORAGE}"

  local imported_disk
  imported_disk="$(qm config "${vmid}" | awk -F': ' '/^unused[0-9]+: / {print $2; exit}')"
  if [[ -z "${imported_disk}" ]]; then
    echo "Could not find imported disk for VM ${vmid}."
    exit 1
  fi

  qm set "${vmid}" --scsihw virtio-scsi-pci --scsi0 "${imported_disk}"
  qm set "${vmid}" --boot order=scsi0
  qm set "${vmid}" --ide2 "${CLOUDINIT_STORAGE}:cloudinit"
  qm set "${vmid}" --ciuser "${CI_USER}"
  qm set "${vmid}" --cipassword "${CI_PASSWORD}"
  qm set "${vmid}" --ipconfig0 "${ipconfig}"
  qm set "${vmid}" --nameserver "${DNS_SERVER}"
  qm set "${vmid}" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "${userdata_file}")"
  qm resize "${vmid}" scsi0 "${disk_size}"
  qm cloudinit update "${vmid}"
  qm start "${vmid}"
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

for cmd in qm pvesm wget awk grep sed; do
  need_cmd "$cmd"
done

echo "==> Validating Proxmox storages..."
pvesm status

for s in "$DISK_STORAGE" "$CLOUDINIT_STORAGE" "$SNIPPET_STORAGE"; do
  if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$s"; then
    echo "Storage '$s' not found."
    exit 1
  fi
done

ensure_snippets_on_local

mkdir -p "${IMG_DIR}" "${SNIPPET_DIR}"

if [[ ! -f "${IMG_FILE}" ]]; then
  echo "==> Downloading Ubuntu 24.04 cloud image..."
  wget -O "${IMG_FILE}" "${UBUNTU_IMG_URL}"
else
  echo "==> Using existing image: ${IMG_FILE}"
fi

if [[ "${USE_DHCP}" == "true" ]]; then
  FLEET_IPCONFIG="ip=dhcp"
  DB_IPCONFIG="ip=dhcp"
  REDIS_IPCONFIG="ip=dhcp"
else
  FLEET_IPCONFIG="ip=${FLEET_STATIC_IP},gw=${GATEWAY_IP}"
  DB_IPCONFIG="ip=${DB_STATIC_IP},gw=${GATEWAY_IP}"
  REDIS_IPCONFIG="ip=${REDIS_STATIC_IP},gw=${GATEWAY_IP}"
fi

cat > "${FLEET_USERDATA}" <<EOF
#cloud-config
hostname: ${FLEET_NAME}
manage_etc_hosts: true
timezone: ${TIMEZONE}
package_update: true
package_upgrade: true

users:
  - name: ${CI_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${CI_PASSWORD}

ssh_pwauth: true
disable_root: true

packages:
  - ca-certificates
  - curl
  - gnupg
  - qemu-guest-agent

write_files:
  - path: /root/bootstrap-fleet-base.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive

      apt-get update
      apt-get install -y ca-certificates curl gnupg

      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc

      . /etc/os-release
      ARCH="\$(dpkg --print-architecture)"
      echo "deb [arch=\${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

      systemctl enable qemu-guest-agent --now
      systemctl enable docker --now

      usermod -aG docker ${CI_USER} || true

      sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
      systemctl restart ssh || systemctl restart sshd || true

      cat >/root/BASE-SETUP-INFO.txt <<INFO
Fleet app VM ready.

Login:
  user: ${CI_USER}
  password: ${CI_PASSWORD}

Installed:
  - Docker Engine
  - Docker Compose plugin
  - qemu-guest-agent
INFO

runcmd:
  - [ bash, /root/bootstrap-fleet-base.sh ]

final_message: "Fleet app VM bootstrap finished."
EOF

cat > "${DB_USERDATA}" <<EOF
#cloud-config
hostname: ${DB_NAME}
manage_etc_hosts: true
timezone: ${TIMEZONE}
package_update: true
package_upgrade: true

users:
  - name: ${CI_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${CI_PASSWORD}

ssh_pwauth: true
disable_root: true

packages:
  - qemu-guest-agent

write_files:
  - path: /root/bootstrap-db-base.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      systemctl enable qemu-guest-agent --now
      sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
      systemctl restart ssh || systemctl restart sshd || true

      cat >/root/BASE-SETUP-INFO.txt <<INFO
Database VM ready.

Login:
  user: ${CI_USER}
  password: ${CI_PASSWORD}

Installed:
  - qemu-guest-agent
INFO

runcmd:
  - [ bash, /root/bootstrap-db-base.sh ]

final_message: "Database VM bootstrap finished."
EOF

cat > "${REDIS_USERDATA}" <<EOF
#cloud-config
hostname: ${REDIS_NAME}
manage_etc_hosts: true
timezone: ${TIMEZONE}
package_update: true
package_upgrade: true

users:
  - name: ${CI_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${CI_PASSWORD}

ssh_pwauth: true
disable_root: true

packages:
  - qemu-guest-agent

write_files:
  - path: /root/bootstrap-redis-base.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive

      apt-get update
      apt-get install -y redis-server

      systemctl enable qemu-guest-agent --now
      systemctl enable redis-server --now

      sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
      systemctl restart ssh || systemctl restart sshd || true

      cat >/root/BASE-SETUP-INFO.txt <<INFO
Redis VM ready.

Login:
  user: ${CI_USER}
  password: ${CI_PASSWORD}

Installed:
  - Redis server
  - qemu-guest-agent
INFO

runcmd:
  - [ bash, /root/bootstrap-redis-base.sh ]

final_message: "Redis VM bootstrap finished."
EOF

create_vm "${FLEET_VMID}" "${FLEET_NAME}" "${FLEET_MEMORY}" "${FLEET_CORES}" "${FLEET_DISK}" "${FLEET_IPCONFIG}" "${FLEET_USERDATA}"
create_vm "${DB_VMID}" "${DB_NAME}" "${DB_MEMORY}" "${DB_CORES}" "${DB_DISK}" "${DB_IPCONFIG}" "${DB_USERDATA}"
create_vm "${REDIS_VMID}" "${REDIS_NAME}" "${REDIS_MEMORY}" "${REDIS_CORES}" "${REDIS_DISK}" "${REDIS_IPCONFIG}" "${REDIS_USERDATA}"

cat <<INFO

Done.

Created VMs:
  ${FLEET_VMID} -> ${FLEET_NAME}
  ${DB_VMID} -> ${DB_NAME}
  ${REDIS_VMID} -> ${REDIS_NAME}

Console / SSH login for all three:
  user: ${CI_USER}
  password: ${CI_PASSWORD}

Next checks:
  qm status ${FLEET_VMID}
  qm status ${DB_VMID}
  qm status ${REDIS_VMID}
  ip neigh
  arp -an

After they boot:
  ssh ${CI_USER}@<fleet-ip>
  ssh ${CI_USER}@<db-ip>
  ssh ${CI_USER}@<redis-ip>

INFO
