#!/usr/bin/env bash
set -euo pipefail

### ===== CHECK THESE BEFORE RUNNING =====
VMID=240
VM_NAME="fleetdm"
MEMORY=4096
CORES=2
DISK_SIZE="32G"

DISK_STORAGE="SET_ME"
CLOUDINIT_STORAGE="SET_ME"
SNIPPET_STORAGE="SET_ME"
SNIPPET_BASE_PATH="/var/lib/vz"
BRIDGE="vmbr0"

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_DIR="/var/lib/vz/template/iso"
IMG_FILE="${IMG_DIR}/noble-server-cloudimg-amd64.img"

CI_USER="ubuntu"
SSH_PUBKEY_FILE="/root/.ssh/id_rsa.pub"

USE_DHCP="true"
STATIC_IP_CIDR="192.168.1.240/24"
GATEWAY_IP="192.168.1.1"
DNS_SERVER="1.1.1.1"

FLEET_FQDN="fleet.local"
TIMEZONE="Europe/London"
ADMIN_EMAIL="admin@example.com"
### ====================================

if [[ "${DISK_STORAGE}" == "SET_ME" || "${CLOUDINIT_STORAGE}" == "SET_ME" || "${SNIPPET_STORAGE}" == "SET_ME" ]]; then
  echo "Edit this script first and set DISK_STORAGE, CLOUDINIT_STORAGE, and SNIPPET_STORAGE."
  exit 1
fi

SNIPPET_DIR="${SNIPPET_BASE_PATH}/snippets"
USERDATA_FILE="${SNIPPET_DIR}/fleet-user-data-${VMID}.yaml"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

if qm status "${VMID}" >/dev/null 2>&1; then
  echo "VMID ${VMID} already exists."
  exit 1
fi

mkdir -p "${IMG_DIR}" "${SNIPPET_DIR}"

if [[ ! -f "${IMG_FILE}" ]]; then
  apt-get update
  apt-get install -y wget
  wget -O "${IMG_FILE}" "${UBUNTU_IMG_URL}"
fi

SSH_KEY_CONTENT=""
if [[ -f "${SSH_PUBKEY_FILE}" ]]; then
  SSH_KEY_CONTENT="$(cat "${SSH_PUBKEY_FILE}")"
fi

if [[ "${USE_DHCP}" == "true" ]]; then
  IPCONFIG0="ip=dhcp"
  CERT_IP_SAN="127.0.0.1"
else
  IPCONFIG0="ip=${STATIC_IP_CIDR},gw=${GATEWAY_IP}"
  CERT_IP_SAN="${STATIC_IP_CIDR%/*}"
fi

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
      ARCH="$(dpkg --print-architecture)"
      cat >/etc/apt/sources.list.d/docker.list <<DOCKERREPO
      deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
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
      FLEET_SERVER_PRIVATE_KEY="$(openssl rand -base64 32 | tr -d '\n')"

      sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}|" .env
      sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=${MYSQL_PASSWORD}|" .env
      sed -i "s|^FLEET_SERVER_PRIVATE_KEY=.*|FLEET_SERVER_PRIVATE_KEY=${FLEET_SERVER_PRIVATE_KEY}|" .env

      if grep -q '^FLEET_SERVER_TLS=' .env; then
        sed -i 's/^FLEET_SERVER_TLS=.*/FLEET_SERVER_TLS=true/' .env
      else
        echo 'FLEET_SERVER_TLS=true' >> .env
      fi

      mkdir -p certs
      openssl req -x509 -nodes -days 365 -newkey rsa:2048         -keyout certs/fleet.key         -out certs/fleet.crt         -subj "/CN=${FLEET_FQDN}"         -addext "subjectAltName=DNS:localhost,DNS:${FLEET_FQDN},IP:127.0.0.1,IP:${CERT_IP_SAN}"

      chown 100:101 certs/fleet.crt certs/fleet.key || true
      chmod 640 certs/fleet.crt certs/fleet.key || true
      chmod 600 .env

      docker compose pull
      docker compose up -d

      cat >/root/FLEET-INFO.txt <<INFO
Fleet install directory: /opt/fleet-deployment
Fleet URL: https://${FLEET_FQDN}:1337
Admin email hint: ${ADMIN_EMAIL}
INFO

runcmd:
  - [ bash, /root/install-fleet.sh ]
CLOUDCFG

qm create "${VMID}"   --name "${VM_NAME}"   --memory "${MEMORY}"   --cores "${CORES}"   --cpu host   --net0 virtio,bridge="${BRIDGE}"   --ostype l26   --agent enabled=1   --serial0 socket   --vga serial0

qm importdisk "${VMID}" "${IMG_FILE}" "${DISK_STORAGE}"

IMPORTED_DISK="$(qm config "${VMID}" | awk -F': ' '/^unused[0-9]+: / {print $2; exit}')"
[[ -n "${IMPORTED_DISK}" ]] || { echo "Imported disk not found"; exit 1; }

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
qm start "${VMID}"

echo "VM created and started: ${VMID}"
echo "Check progress with: qm terminal ${VMID}"
