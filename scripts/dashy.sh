#!/usr/bin/env bash
set -euo pipefail

### ===== SETTINGS =====
CTID=121
HOSTNAME="dashy"
PASSWORD="changeme"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
DISK_SIZE="8"
MEMORY="2048"
CORES="2"
BRIDGE="vmbr0"

APP_PORT="8080"
TZ="Europe/London"
IMAGE="lissy93/dashy:latest"
DATA_DIR="/opt/dashy/user-data"
### ====================

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root on the Proxmox host."
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists."
  exit 1
fi

echo "==> Updating templates"
pveam update

TEMPLATE="$(pveam available | awk '/system.*debian-12-standard/ {print $2}' | tail -n1)"
if [[ -z "${TEMPLATE:-}" ]]; then
  echo "Could not find a Debian 12 template."
  exit 1
fi

echo "==> Using template: $TEMPLATE"

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  echo "==> Downloading template"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

echo "==> Creating container $CTID"
pct create "$CTID" "$TEMPLATE_PATH" \
  --hostname "$HOSTNAME" \
  --password "$PASSWORD" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --net0 name=eth0,bridge=${BRIDGE},ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 0 \
  --onboot 1 \
  --ostype debian

echo "==> Starting container"
pct start "$CTID"
sleep 8

echo "==> Installing Docker"
pct exec "$CTID" -- bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker
'

echo "==> Creating Dashy data directory"
pct exec "$CTID" -- bash -lc "
mkdir -p '$DATA_DIR'
cat > '$DATA_DIR/conf.yml' <<'EOF'
pageInfo:
  title: Dashy
  description: My dashboard
  navLinks:
    - title: GitHub
      path: https://github.com/Lissy93/dashy

appConfig:
  theme: colorful
  layout: auto
  iconSize: medium
  language: en

sections:
  - name: Infrastructure
    icon: fas fa-server
    items:
      - title: Proxmox
        description: Hypervisor
        url: https://proxmox.local
      - title: Router
        description: Gateway
        url: http://192.168.1.1

  - name: Apps
    icon: fas fa-th-large
    items:
      - title: Dashy
        description: This dashboard
        url: http://localhost:8080
EOF
"

echo "==> Pulling Dashy image"
pct exec "$CTID" -- bash -lc "
docker pull '$IMAGE'
"

echo "==> Starting Dashy container"
pct exec "$CTID" -- bash -lc "
docker run -d \
  --name dashy \
  --restart unless-stopped \
  -e TZ='$TZ' \
  -p ${APP_PORT}:8080 \
  -v '$DATA_DIR':/app/user-data \
  '$IMAGE'
"

echo
echo "=============================================="
echo "Dashy deployed."
echo "Container ID : $CTID"
echo "Hostname     : $HOSTNAME"
echo "External port: $APP_PORT"
echo
echo "Get IP with:"
echo "  pct exec $CTID -- hostname -I"
echo
echo "Then open:"
echo "  http://<container-ip>:$APP_PORT"
echo
echo "Edit config here:"
echo "  pct exec $CTID -- nano $DATA_DIR/conf.yml"
echo
echo "Restart container after config changes:"
echo "  pct exec $CTID -- docker restart dashy"
echo "=============================================="
