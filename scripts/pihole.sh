#!/usr/bin/env bash
set -euo pipefail

### ===== SETTINGS =====
CTID=122
HOSTNAME="pihole"
PASSWORD="changeme"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
DISK_SIZE="4"
MEMORY="512"
CORES="1"
BRIDGE="vmbr0"

WEB_PORT="8082"
TZ="Europe/London"
PIHOLE_PASSWORD="changeme"   # change this!
### ====================

echo "==> Updating templates"
pveam update

TEMPLATE="$(pveam available | awk '/system.*debian-12-standard/ {print $2}' | tail -n1)"

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
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
apt-get update
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker
'

echo "==> Creating Pi-hole dirs"
pct exec "$CTID" -- bash -lc "
mkdir -p /opt/pihole/etc-pihole
mkdir -p /opt/pihole/etc-dnsmasq.d
"

echo "==> Running Pi-hole"
pct exec "$CTID" -- bash -lc "
docker run -d \
  --name pihole \
  --restart unless-stopped \
  -e TZ='$TZ' \
  -e WEBPASSWORD='$PIHOLE_PASSWORD' \
  -p 53:53/tcp \
  -p 53:53/udp \
  -p ${WEB_PORT}:80 \
  -v /opt/pihole/etc-pihole:/etc/pihole \
  -v /opt/pihole/etc-dnsmasq.d:/etc/dnsmasq.d \
  --dns=127.0.0.1 \
  --dns=1.1.1.1 \
  pihole/pihole:latest
"

echo
echo "=============================================="
echo "Pi-hole deployed"
echo
echo "Get IP:"
echo "  pct exec $CTID -- hostname -I"
echo
echo "Web UI:"
echo "  http://<IP>:${WEB_PORT}/admin"
echo
echo "Password: $PIHOLE_PASSWORD"
echo "=============================================="
