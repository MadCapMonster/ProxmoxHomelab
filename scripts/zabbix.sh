#!/usr/bin/env bash
set -euo pipefail

### ===== SETTINGS =====
CTID=123
HOSTNAME="zabbix"
PASSWORD="changeme"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
DISK_SIZE="12"
MEMORY="4096"
CORES="2"
BRIDGE="vmbr0"

WEB_PORT="8084"
ZABBIX_PORT="10051"
TZ="Europe/London"

DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASS="changeme"
POSTGRES_SUPERPASS="changeme"
ZABBIX_SERVER_NAME="Zabbix"
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

echo "==> Writing Zabbix compose files"
pct exec "$CTID" -- bash -lc "
mkdir -p /opt/zabbix
cat > /opt/zabbix/docker-compose.yml <<'EOF'
services:
  postgres-server:
    image: postgres:16
    container_name: postgres-server
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      POSTGRES_HOST_AUTH_METHOD: trust
    volumes:
      - ./postgres:/var/lib/postgresql/data

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:alpine-7.4-latest
    container_name: zabbix-server
    restart: unless-stopped
    depends_on:
      - postgres-server
    environment:
      DB_SERVER_HOST: postgres-server
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      ZBX_STARTPOLLERS: 10
      ZBX_STARTPINGERS: 5
    ports:
      - '${ZABBIX_PORT}:10051'
    volumes:
      - ./zabbix/alertscripts:/usr/lib/zabbix/alertscripts
      - ./zabbix/externalscripts:/usr/lib/zabbix/externalscripts
      - ./zabbix/modules:/var/lib/zabbix/modules
      - ./zabbix/enc:/var/lib/zabbix/enc
      - ./zabbix/ssh_keys:/var/lib/zabbix/ssh_keys
      - ./zabbix/ssl/certs:/var/lib/zabbix/ssl/certs
      - ./zabbix/ssl/keys:/var/lib/zabbix/ssl/keys
      - ./zabbix/ssl/ssl_ca:/var/lib/zabbix/ssl/ssl_ca

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:alpine-7.4-latest
    container_name: zabbix-web
    restart: unless-stopped
    depends_on:
      - postgres-server
      - zabbix-server
    environment:
      DB_SERVER_HOST: postgres-server
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      PHP_TZ: ${TZ}
      ZBX_SERVER_HOST: zabbix-server
      ZBX_SERVER_PORT: 10051
      ZBX_SERVER_NAME: ${ZABBIX_SERVER_NAME}
    ports:
      - '${WEB_PORT}:8080'

volumes: {}
EOF
"

echo "==> Starting Zabbix stack"
pct exec "$CTID" -- bash -lc "
cd /opt/zabbix
docker compose up -d
docker compose ps
"

echo
echo "=============================================="
echo "Zabbix deployed."
echo "Container ID : $CTID"
echo "Hostname     : $HOSTNAME"
echo
echo "Get IP with:"
echo "  pct exec $CTID -- hostname -I"
echo
echo "Then open:"
echo "  http://<container-ip>:${WEB_PORT}"
echo
echo "Default login:"
echo "  Username: Admin"
echo "  Password: zabbix"
echo
echo "Change the Admin password immediately after login."
echo "=============================================="
