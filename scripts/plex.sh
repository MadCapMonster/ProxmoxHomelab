#!/usr/bin/env bash
set -euo pipefail

### ===== SETTINGS =====
CTID=124
HOSTNAME="plex"
PASSWORD="changeme"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
DISK_SIZE="12"
MEMORY="4096"
CORES="4"
BRIDGE="vmbr0"
TZ="Europe/London"

# Proxmox host path for your media storage
MEDIA_PATH="/mnt/pve/volume1-Video"

# Optional Plex claim token
# Leave blank if you want to claim it through the web UI
PLEX_CLAIM=""

# linuxserver container user/group
PUID="1000"
PGID="1000"
### ====================

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root on the Proxmox host."
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists. Change CTID or remove the old container first."
  exit 1
fi

if [[ ! -d "$MEDIA_PATH" ]]; then
  echo "Media path does not exist: $MEDIA_PATH"
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

echo "==> Creating Plex container $CTID"
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
  --ostype debian \
  --mp0 "${MEDIA_PATH},mp=/media"

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

echo "==> Preparing Plex directories"
pct exec "$CTID" -- bash -lc '
mkdir -p /opt/plex/config
mkdir -p /opt/plex/transcode
mkdir -p /media
'

echo "==> Starting Plex"
pct exec "$CTID" -- bash -lc "
docker rm -f plex >/dev/null 2>&1 || true

docker run -d \
  --name plex \
  --network host \
  -e TZ='${TZ}' \
  -e PUID='${PUID}' \
  -e PGID='${PGID}' \
  -e VERSION='docker' \
  -e PLEX_CLAIM='${PLEX_CLAIM}' \
  -v /opt/plex/config:/config \
  -v /opt/plex/transcode:/transcode \
  -v /media:/data \
  --restart unless-stopped \
  linuxserver/plex:latest
"

echo
echo "=============================================="
echo "Plex deployed."
echo
echo "Get IP with:"
echo "  pct exec $CTID -- hostname -I"
echo
echo "Then open:"
echo "  http://<container-ip>:32400/web"
echo
echo "Inside Plex, add libraries from:"
echo "  /data"
echo "=============================================="
