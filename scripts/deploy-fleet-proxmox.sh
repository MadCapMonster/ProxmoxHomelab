#!/usr/bin/env bash
set -euo pipefail

############################################
# Proxmox -> Ubuntu 24.04 VM -> FleetDM
# Uses:
#   VM disk:       local-lvm
#   cloud-init:    local-lvm
#   snippets:      local
############################################

### ===== EDIT THESE IF NEEDED =====
VMID=240
VM_NAME="fleetdm"
MEMORY=4096
CORES=2
DISK_SIZE="32G"

DISK_STORAGE="local-lvm"
CLOUDINIT_STORAGE="local-lvm"
SNIPPET_STORAGE="local"
SNIPPET_BASE_PATH="/var/lib/vz"
BRIDGE="vmbr0"

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_DIR="/var/lib/vz/template/iso"
IMG_FILE="${IMG_DIR}/noble-server-cloudimg-amd64.img"

CI_USER="ubuntu"
SSH_PUBKEY_FILE="/root/.ssh/id_rsa.pub"

USE_DHCP="true"
STATIC_IP_CIDR="192.168.68.240/24"
GATEWAY_IP="192.168.68.1"
DNS_SERVER="1.1.1.1"

FLEET_FQDN="fleet.local"
TIMEZONE="Europe/London"
ADMIN_EMAIL="admin@example.com"
### ================================

SNIPPET_DIR="${SNIPPET_BASE_PATH}/snippets"
USERDATA_FILE="${SNIPPET_DIR}/fleet-user-data-${VMID}.yaml"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

need_cmd qm
need_cmd pvesm
need_cmd awk
need_cmd grep
need_cmd sed
need_cmd wget

echo "==> Checking storage availability..."
pvesm status

if ! pvesm status | awk '{print $1}' | grep -qx "${DISK_STORAGE}"; then
  echo "Storage ${DISK_STORAGE} not found."
  exit 1
fi

if ! pvesm status | awk '{print $1}' | grep -qx "${CLOUDINIT_STORAGE}"; then
  echo "Storage ${CLOUDINIT_STORAGE} not found."
  exit 1
fi

if ! pvesm status | awk '{print $1}' | grep -qx "${SNIPPET_STORAGE}"; then
  echo "Storage ${SNIPPET_STORAGE} not found."
  exit 1
fi

echo "==> Ensuring '${SNIPPET_STORAGE}' supports snippets..."
CURRENT_LOCAL_CONTENT="$(awk '
  $1=="dir:" && $2=="local" {in_local=1; next}
  /^[A-Za-z0-9_-]+:/ && !($1=="dir:" && $2=="local") {in_local=0}
  in_local && $1=="content" {
    $1=""
    sub(/^ +/, "")
    print
    exit
  }
' /etc/pve/storage.cfg)"

if [[ -z "${CURRENT_LOCAL_CONTENT}" ]]; then
  echo "Could not determine content types for storage '${SNIPPET_STORAGE}'."
  exit 1
fi

NORMALIZED_CONTENT="$(echo "${CURRENT_LOCAL_CONTENT}" | tr -d ' ')"
if [[ ",${NORMALIZED_CONTENT}," != *",snippets,"* ]]; then
  NEW_CONTENT="${NORMALIZED_CONTENT},snippets"
  pvesm set "${SNIPPET_STORAGE}" --content "${NEW_CONTENT}"
  echo "Enabled snippets on ${SNIPPET_STORAGE}: ${NEW_CONTENT}"
else
  echo "Snippets already enabled on ${SNIPPET_STORAGE}"
fi

mkdir -p "${IMG_DIR}"
mkdir -p "${SNIPPET_DIR}"

if [[ ! -f "${IMG_FILE}" ]]; then
  echo "==> Downloading Ubuntu cloud image..."
  wget -O "${IMG_FILE}" "${UBUNTU_IMG_URL}"
else
  echo "==> Using existing Ubuntu image: ${IMG_FILE}"
fi

if qm status "${VMID}" >/dev/null 2>&1; then
  echo "VMID ${VMID} already exists. Remove it or change VMID."
  exit 1
fi

SSH_KEY_CONTENT=""
if [[ -f "${SSH_PUBKEY_FILE}" ]]; then
  SSH_KEY_CONTENT="$(cat "${SSH_PUBKEY_FILE}")"
else
  echo "No SSH public key found at ${SSH_PUBKEY_FILE}; continuing without injected key."
fi

if [[ "${USE_DHCP}" == "true" ]]; then
  IPCONFIG0="ip=dhcp"
  CERT_IP_SAN="127.0.0.1"
else
  IPCONFIG0="ip=${STATIC_IP_CIDR},gw=${GATEWAY_IP}"
  CERT_IP_SAN="${STATIC_IP_CIDR%/*}"
fi

echo "==> Writing cloud-init user-data to ${USERDATA_FILE} ..."
cat > "${USERDATA_FILE}" <<CLOUDCFG
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
timezone: ${TIMEZONE}
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - openssl
  - qemu-guest-agent

users:
  - name: ${CI_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
$( [[ -n "${SSH_KEY_CONTENT}" ]] && printf '    ssh_authorized_keys:\n      - %s\n' "${SSH_KEY_CONTENT}" )

write_files:
  - path: /root/install-fleet.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive

      apt-get update
      apt-get install -y ca-certificates curl gnupg openssl

      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      . /etc/os-release
      ARCH="\$(dpkg --print-architecture)"
      cat >/etc/apt/sources.list.d/docker.list <<DOCKERREPO
      deb [arch=\${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \${VERSION_CODENAME} stable
      DOCKERREPO

      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable docker --now
      systemctl enable qemu-guest-agent --now

      mkdir -p /opt/fleet-deployment
      cd /opt/fleet-deployment

      curl -fsSL -o docker-compose.yml https://raw.githubusercontent.com/fleetdm/fleet/refs/heads/main/docs/solutions/docker-compose/docker-compose.yml
      curl -fsSL -o env.example https://raw.githubusercontent.com/fleetdm/fleet/refs/heads/main/docs/solutions/docker-compose/env.example
      cp -f env.example .env

      MYSQL_ROOT_PASSWORD="changeme"
      MYSQL_PASSWORD="changeme"
      FLEET_SERVER_PRIVATE_KEY="\$(openssl rand -base64 32 | tr -d '\n')"

      sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}|" .env
      sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=\${MYSQL_PASSWORD}|" .env
      sed -i "s|^FLEET_SERVER_PRIVATE_KEY=.*|FLEET_SERVER_PRIVATE_KEY=\${FLEET_SERVER_PRIVATE_KEY}|" .env

      if grep -q '^FLEET_SERVER_TLS=' .env; then
        sed -i 's/^FLEET_SERVER_TLS=.*/FLEET_SERVER_TLS=true/' .env
      else
        echo 'FLEET_SERVER_TLS=true' >> .env
      fi

      mkdir -p certs
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout certs/fleet.key \
        -out certs/fleet.crt \
        -subj "/CN=${FLEET_FQDN}" \
        -addext "subjectAltName=DNS:localhost,DNS:${FLEET_FQDN},IP:127.0.0.1,IP:${CERT_IP_SAN}"

      chmod 600 .env
      chmod 600 certs/fleet.key certs/fleet.crt

      docker compose pull
      docker compose up -d

      cat >/root/FLEET-INFO.txt <<INFO
Fleet install directory: /opt/fleet-deployment
Fleet URL: https://${FLEET_FQDN}:1337
Admin email hint: ${ADMIN_EMAIL}

Generated secrets:
MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=\${MYSQL_PASSWORD}
FLEET_SERVER_PRIVATE_KEY=\${FLEET_SERVER_PRIVATE_KEY}
INFO

runcmd:
  - [ bash, /root/install-fleet.sh ]

final_message: "Cloud-init finished. Fleet bootstrap should now be running."
CLOUDCFG

echo "==> Creating VM ${VMID}..."
qm create "${VMID}" \
  --name "${VM_NAME}" \
  --memory "${MEMORY}" \
  --cores "${CORES}" \
  --cpu host \
  --net0 virtio,bridge="${BRIDGE}" \
  --ostype l26 \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

echo "==> Importing disk to ${DISK_STORAGE}..."
qm importdisk "${VMID}" "${IMG_FILE}" "${DISK_STORAGE}"

IMPORTED_DISK="$(qm config "${VMID}" | awk -F': ' '/^unused[0-9]+: / {print $2; exit}')"
if [[ -z "${IMPORTED_DISK}" ]]; then
  echo "Could not find imported disk."
  exit 1
fi

echo "==> Configuring VM..."
qm set "${VMID}" --scsihw virtio-scsi-pci --scsi0 "${IMPORTED_DISK}"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ide2 "${CLOUDINIT_STORAGE}:cloudinit"
qm set "${VMID}" --ciuser "${CI_USER}"
qm set "${VMID}" --ipconfig0 "${IPCONFIG0}"
qm set "${VMID}" --nameserver "${DNS_SERVER}"

if [[ -f "${SSH_PUBKEY_FILE}" ]]; then
  qm set "${VMID}" --sshkey "${SSH_PUBKEY_FILE}"
fi

qm set "${VMID}" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "${USERDATA_FILE}")"
qm resize "${VMID}" scsi0 "${DISK_SIZE}"

echo "==> Starting VM..."
qm start "${VMID}"

echo
echo "Done."
echo "VMID: ${VMID}"
echo "Check status with:"
echo "  qm config ${VMID}"
echo "  qm terminal ${VMID}"
echo
echo "Once cloud-init finishes, Fleet should be on:"
if [[ "${USE_DHCP}" == "true" ]]; then
  echo "  https://${FLEET_FQDN}:1337"
else
  echo "  https://${STATIC_IP_CIDR%/*}:1337"
fi
