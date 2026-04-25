#!/usr/bin/env bash
set -euo pipefail

############################################
# Proxmox -> Ubuntu VM -> FleetDM bootstrap
############################################

### ===== EDIT THESE =====
VMID=240
VM_NAME="fleetdm"
MEMORY=4096
CORES=2
DISK_SIZE="32G"

# Proxmox storage/network
STORAGE="local-lvm"      # VM disk storage, e.g. local-lvm or local2
CI_STORAGE="local"    # storage that supports snippets/cloud-init, usually "local"
BRIDGE="vmbr0"

# Ubuntu cloud image
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_DIR="/var/lib/vz/template/iso"
IMG_FILE="${IMG_DIR}/noble-server-cloudimg-amd64.img"

# VM access
CI_USER="ubuntu"
SSH_PUBKEY_FILE="/root/.ssh/id_rsa.pub"   # change if needed; leave as-is if file exists
USE_DHCP="true"                           # true or false
STATIC_IP_CIDR="192.168.1.240/24"
GATEWAY_IP="192.168.1.1"
DNS_SERVER="1.1.1.1"

# Fleet settings
FLEET_FQDN="fleet.local"
TIMEZONE="Europe/London"
ADMIN_EMAIL="admin@example.com"
############################################

SNIPPET_DIR="/var/lib/vz/snippets"
USERDATA_FILE="${SNIPPET_DIR}/fleet-user-data-${VMID}.yaml"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

command -v qm >/dev/null 2>&1 || {
  echo "This must be run on a Proxmox host with qm available."
  exit 1
}

if qm status "${VMID}" >/dev/null 2>&1; then
  echo "VMID ${VMID} already exists. Pick another VMID."
  exit 1
fi

mkdir -p "${IMG_DIR}"
mkdir -p "${SNIPPET_DIR}"

if [[ ! -f "${IMG_FILE}" ]]; then
  echo "Downloading Ubuntu cloud image..."
  wget -O "${IMG_FILE}" "${UBUNTU_IMG_URL}"
else
  echo "Using existing image: ${IMG_FILE}"
fi

if [[ -f "${SSH_PUBKEY_FILE}" ]]; then
  SSH_KEY_CONTENT="$(cat "${SSH_PUBKEY_FILE}")"
else
  echo "SSH public key not found at ${SSH_PUBKEY_FILE}"
  echo "Continuing without ssh_authorized_keys. Console login may be required."
  SSH_KEY_CONTENT=""
fi

if [[ "${USE_DHCP}" == "true" ]]; then
  IPCONFIG0="ip=dhcp"
else
  IPCONFIG0="ip=${STATIC_IP_CIDR},gw=${GATEWAY_IP}"
fi

cat > "${USERDATA_FILE}" <<EOF
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
  - apt-transport-https

users:
  - name: ${CI_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, docker
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
      if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
      fi

      . /etc/os-release
      ARCH="\$(dpkg --print-architecture)"
      cat >/etc/apt/sources.list.d/docker.list <<DOCKERREPO
      deb [arch=\${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \${VERSION_CODENAME} stable
      DOCKERREPO

      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable docker
      systemctl start docker
      systemctl enable qemu-guest-agent
      systemctl start qemu-guest-agent

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
        -subj "/CN=${FLEET_FQDN}"

      chmod 600 .env certs/fleet.key certs/fleet.crt

      docker compose pull
      docker compose up -d

      cat >/root/FLEET-INFO.txt <<INFO
      Fleet install directory: /opt/fleet-deployment
      Fleet URL: https://${FLEET_FQDN}:1337
      Admin email hint: ${ADMIN_EMAIL}

      IMPORTANT:
      - Browser warning is expected because TLS is self-signed.
      - Save /opt/fleet-deployment/.env securely.
      - Keep FLEET_SERVER_PRIVATE_KEY for restore/migration.

      Generated secrets:
      MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
      MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      FLEET_SERVER_PRIVATE_KEY=\${FLEET_SERVER_PRIVATE_KEY}
      INFO

runcmd:
  - [ systemctl, enable, qemu-guest-agent ]
  - [ systemctl, start, qemu-guest-agent ]
  - [ bash, /root/install-fleet.sh ]
  - [ bash, -lc, "echo 'Bootstrap finished at \$(date -Is)' >> /root/FLEET-INFO.txt" ]

final_message: "Cloud-init finished. Fleet bootstrap should now be running."
EOF

echo "Creating VM ${VMID}..."
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

echo "Importing Ubuntu disk to ${STORAGE}..."
qm importdisk "${VMID}" "${IMG_FILE}" "${STORAGE}"

echo "Attaching imported disk..."
IMPORTED_DISK="$(qm config "${VMID}" | awk -F': ' '/^unused[0-9]+: / {print $2; exit}')"
if [[ -z "${IMPORTED_DISK}" ]]; then
  echo "Could not find imported disk."
  exit 1
fi

qm set "${VMID}" --scsihw virtio-scsi-pci --scsi0 "${IMPORTED_DISK}"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ide2 "${CI_STORAGE}:cloudinit"
qm set "${VMID}" --ciuser "${CI_USER}"
qm set "${VMID}" --ipconfig0 "${IPCONFIG0}"
qm set "${VMID}" --nameserver "${DNS_SERVER}"

if [[ -f "${SSH_PUBKEY_FILE}" ]]; then
  qm set "${VMID}" --sshkey "${SSH_PUBKEY_FILE}"
fi

qm set "${VMID}" --cicustom "user=${CI_STORAGE}:snippets/$(basename "${USERDATA_FILE}")"
qm resize "${VMID}" scsi0 "${DISK_SIZE}"

echo "Starting VM..."
qm start "${VMID}"

echo
echo "Done."
echo "VMID: ${VMID}"
echo "Name: ${VM_NAME}"
echo "Cloud-init snippet: ${USERDATA_FILE}"
echo
echo "Next steps:"
echo "1. Wait 3-10 minutes for first boot and package installs."
echo "2. Check VM console in Proxmox, or:"
echo "   qm guest exec ${VMID} -- cat /root/FLEET-INFO.txt"
echo "3. Open Fleet on:"
if [[ "${USE_DHCP}" == "true" ]]; then
  echo "   https://${FLEET_FQDN}:1337  (after your DNS/hosts entry points at the VM IP)"
else
  echo "   https://${STATIC_IP_CIDR%/*}:1337"
fi
echo
echo "If you used self-signed TLS, your browser will warn until you trust the cert."
