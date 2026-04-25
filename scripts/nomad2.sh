#!/usr/bin/env bash
set -euo pipefail

# =========================
# Proxmox -> create Nomad node and join existing cluster
# =========================

### ---- USER SETTINGS ----

CTID="${CTID:-131}"
CT_HOSTNAME="${CT_HOSTNAME:-project-nomad-2}"
CT_PASSWORD="changeme"
CT_CORES="${CT_CORES:-4}"
CT_MEMORY="${CT_MEMORY:-4096}"
CT_SWAP="${CT_SWAP:-1024}"
CT_ROOTFS_SIZE="${CT_ROOTFS_SIZE:-20}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IPCFG="${CT_IPCFG:-dhcp}"
CT_OSTYPE="${CT_OSTYPE:-debian}"

ROOT_STORAGE="${1:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

USB_MOUNT="${USB_MOUNT:-/mnt/usb-storage}"
USB_SUBDIR="${USB_SUBDIR:-project-nomad-2}"
CONTAINER_DATA_MOUNT="${CONTAINER_DATA_MOUNT:-/data}"

# Existing Nomad server to join
NOMAD_JOIN_ADDR="${NOMAD_JOIN_ADDR:-192.168.68.159:4648}"

# Nomad config
NOMAD_DATADIR="${NOMAD_DATADIR:-/data/nomad}"
NOMAD_DC="${NOMAD_DC:-dc1}"
NOMAD_REGION="${NOMAD_REGION:-global}"
CNI_PLUGIN_VERSION="${CNI_PLUGIN_VERSION:-v1.6.2}"

### ---- CHECKS ----

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root on the Proxmox host."
  exit 1
fi

for cmd in pct pveam pvesm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done

if [[ "$ROOT_STORAGE" != "local" && "$ROOT_STORAGE" != "local-lvm" ]]; then
  echo "Invalid root storage: $ROOT_STORAGE"
  echo "Use: local or local-lvm"
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  echo "Container ID $CTID already exists."
  exit 1
fi

if ! pvesm status | awk '{print $1}' | grep -qx "$ROOT_STORAGE"; then
  echo "Root storage '$ROOT_STORAGE' not found."
  pvesm status
  exit 1
fi

if ! pvesm status | awk '{print $1}' | grep -qx "$TEMPLATE_STORAGE"; then
  echo "Template storage '$TEMPLATE_STORAGE' not found."
  pvesm status
  exit 1
fi

### ---- PREP HOST USB STORAGE ----

mkdir -p "$USB_MOUNT"
mkdir -p "$USB_MOUNT/$USB_SUBDIR"

if ! mountpoint -q "$USB_MOUNT"; then
  echo "WARNING: $USB_MOUNT is not currently mounted."
  echo "Continuing anyway, but you should mount the USB disk there."
fi

# Unprivileged LXC root maps to host uid/gid 100000
chown -R 100000:100000 "$USB_MOUNT/$USB_SUBDIR"
chmod 755 "$USB_MOUNT"
chmod 755 "$USB_MOUNT/$USB_SUBDIR"

### ---- TEMPLATE ----

echo "Checking Debian 12 template..."
pveam update

TEMPLATE="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | tail -n1)"
if [[ -z "${TEMPLATE:-}" ]]; then
  echo "Could not find Debian 12 standard template."
  exit 1
fi

TEMPLATE_FILE="/var/lib/vz/template/cache/$(basename "$TEMPLATE")"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Downloading template..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Template file missing: $TEMPLATE_FILE"
  exit 1
fi

### ---- CREATE CONTAINER ----

echo "Creating container $CTID ($CT_HOSTNAME)..."

pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$CT_HOSTNAME" \
  --ostype "$CT_OSTYPE" \
  --cores "$CT_CORES" \
  --memory "$CT_MEMORY" \
  --swap "$CT_SWAP" \
  --rootfs "${ROOT_STORAGE}:${CT_ROOTFS_SIZE}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IPCFG},type=veth" \
  --unprivileged 1 \
  --features nesting=1 \
  --password "$CT_PASSWORD" \
  --onboot 1 \
  --startup order=20 \
  --mp0 "${USB_MOUNT}/${USB_SUBDIR},mp=${CONTAINER_DATA_MOUNT}"

CONF_FILE="/etc/pve/lxc/${CTID}.conf"
if [[ -f "$CONF_FILE" ]]; then
  grep -q "^lxc.apparmor.profile:" "$CONF_FILE" || echo "lxc.apparmor.profile: unconfined" >> "$CONF_FILE"
fi

echo "Starting container..."
pct start "$CTID"
sleep 5

### ---- INSTALL NOMAD INSIDE CONTAINER ----

echo "Installing Nomad inside CT $CTID..."

pct exec "$CTID" -- bash -c "
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl wget gpg lsb-release ca-certificates unzip jq

install -d -m 0755 /usr/share/keyrings
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

CODENAME=\$(. /etc/os-release && echo \${VERSION_CODENAME:-})
if [[ -z \"\$CODENAME\" ]]; then
  CODENAME=\$(lsb_release -cs)
fi

echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \${CODENAME} main\" \
  > /etc/apt/sources.list.d/hashicorp.list

apt-get update
apt-get install -y nomad

ARCH=\$(dpkg --print-architecture)
case \"\$ARCH\" in
  amd64) CNI_ARCH='amd64' ;;
  arm64) CNI_ARCH='arm64' ;;
  *)
    echo 'Unsupported architecture for CNI auto-install'
    exit 1
    ;;
esac

mkdir -p /opt/cni/bin
TMPDIR=\$(mktemp -d)
trap 'rm -rf \"\$TMPDIR\"' EXIT

wget -qO \"\$TMPDIR/cni.tgz\" \
  \"https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-\${CNI_ARCH}-${CNI_PLUGIN_VERSION}.tgz\"

tar -C /opt/cni/bin -xzf \"\$TMPDIR/cni.tgz\"
chmod -R 0755 /opt/cni/bin

mkdir -p /etc/nomad.d
mkdir -p '${NOMAD_DATADIR}'
mkdir -p /opt/nomad/plugins
chmod 700 /etc/nomad.d
chmod 700 '${NOMAD_DATADIR}'

cat >/etc/nomad.d/nomad.hcl <<EOF
data_dir   = \"${NOMAD_DATADIR}\"
bind_addr  = \"0.0.0.0\"
region     = \"${NOMAD_REGION}\"
datacenter = \"${NOMAD_DC}\"

client {
  enabled = true

  server_join {
    retry_join = [\"${NOMAD_JOIN_ADDR}\"]
  }

  options = {
    \"driver.raw_exec.enable\" = \"1\"
  }

  host_volume \"nomad_data\" {
    path      = \"/data\"
    read_only = false
  }
}

plugin_dir = \"/opt/nomad/plugins\"

ports {
  http = 4646
  rpc  = 4647
  serf = 4648
}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
EOF

nomad config validate /etc/nomad.d
systemctl enable nomad
systemctl restart nomad
"

sleep 5

echo
echo "=== New node created ==="
echo "CTID:        $CTID"
echo "Hostname:    $CT_HOSTNAME"
echo "Rootfs:      $ROOT_STORAGE"
echo "USB path:    $USB_MOUNT/$USB_SUBDIR"
echo "CT mount:    $CONTAINER_DATA_MOUNT"
echo
echo "Container IP(s):"
pct exec "$CTID" -- hostname -I || true
echo
echo "Nomad version:"
pct exec "$CTID" -- nomad version || true
echo
echo "Nomad node status on new node:"
pct exec "$CTID" -- nomad node status || true
echo
echo "Done."
echo "Now check the existing UI:"
echo "  http://192.168.68.159:4646/ui/clients"
