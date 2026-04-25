#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================

# Your Zabbix server container
ZABBIX_SERVER_IP="192.168.68.158"   # change if CT 123 has a different IP
ZABBIX_SERVER_PORT="10051"

# LXCs to install agent on
LXC_TARGETS=(101 102 106 117 118 119 120 121 122)

# Optional VM targets over SSH
# Format: "ip user"
VM_TARGETS=(
  # "192.168.68.142 root"
)

ZABBIX_VERSION_MAJOR="7.4"

# =========================
# FUNCTIONS
# =========================

pct_running() {
  local ctid="$1"
  pct status "$ctid" 2>/dev/null | grep -q "status: running"
}

install_agent_lxc() {
  local ctid="$1"
  echo "==> [CT $ctid] Installing Zabbix Agent 2"

  pct exec "$ctid" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y wget ca-certificates

cd /tmp
wget -O zabbix-release.deb https://repo.zabbix.com/zabbix/${ZABBIX_VERSION_MAJOR}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian12_all.deb
dpkg -i zabbix-release.deb
apt-get update
apt-get install -y zabbix-agent2 zabbix-agent2-plugin-*

HOSTNAME_FQDN=\$(hostname -f 2>/dev/null || hostname)
HOSTNAME_SHORT=\$(hostname)

cp /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak.\$(date +%F-%H%M%S)

sed -i \"s/^Server=.*/Server=${ZABBIX_SERVER_IP}/\" /etc/zabbix/zabbix_agent2.conf
sed -i \"s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}:${ZABBIX_SERVER_PORT}/\" /etc/zabbix/zabbix_agent2.conf
sed -i \"s/^Hostname=.*/Hostname=\${HOSTNAME_SHORT}/\" /etc/zabbix/zabbix_agent2.conf

grep -q '^HostMetadata=' /etc/zabbix/zabbix_agent2.conf \
  && sed -i 's/^HostMetadata=.*/HostMetadata=proxmox-guest/' /etc/zabbix/zabbix_agent2.conf \
  || echo 'HostMetadata=proxmox-guest' >> /etc/zabbix/zabbix_agent2.conf

systemctl enable --now zabbix-agent2
systemctl restart zabbix-agent2
systemctl is-active zabbix-agent2
"
}

install_agent_vm_ssh() {
  local vm_ip="$1"
  local vm_user="$2"

  echo "==> [VM $vm_ip] Installing Zabbix Agent 2 over SSH"

  ssh -o StrictHostKeyChecking=accept-new "${vm_user}@${vm_ip}" bash <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y wget ca-certificates

cd /tmp
wget -O zabbix-release.deb https://repo.zabbix.com/zabbix/${ZABBIX_VERSION_MAJOR}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian12_all.deb
dpkg -i zabbix-release.deb
apt-get update
apt-get install -y zabbix-agent2 zabbix-agent2-plugin-*

HOSTNAME_SHORT=\$(hostname)

cp /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak.\$(date +%F-%H%M%S)

sed -i "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}:${ZABBIX_SERVER_PORT}/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^Hostname=.*/Hostname=\${HOSTNAME_SHORT}/" /etc/zabbix/zabbix_agent2.conf

grep -q '^HostMetadata=' /etc/zabbix/zabbix_agent2.conf \
  && sed -i 's/^HostMetadata=.*/HostMetadata=proxmox-vm/' /etc/zabbix/zabbix_agent2.conf \
  || echo 'HostMetadata=proxmox-vm' >> /etc/zabbix/zabbix_agent2.conf

systemctl enable --now zabbix-agent2
systemctl restart zabbix-agent2
systemctl is-active zabbix-agent2
EOF
}

# =========================
# MAIN
# =========================

echo "======================================"
echo "Deploying Zabbix Agent 2 to LXCs"
echo "======================================"

for ctid in "${LXC_TARGETS[@]}"; do
  if pct_running "$ctid"; then
    install_agent_lxc "$ctid"
  else
    echo "==> [CT $ctid] Not running, skipping"
  fi
done

echo
echo "======================================"
echo "Deploying Zabbix Agent 2 to VMs over SSH"
echo "======================================"

for vm in "${VM_TARGETS[@]}"; do
  vm_ip="$(awk '{print $1}' <<<"$vm")"
  vm_user="$(awk '{print $2}' <<<"$vm")"
  install_agent_vm_ssh "$vm_ip" "$vm_user"
done

echo
echo "======================================"
echo "Testing agent ports"
echo "======================================"

for ctid in "${LXC_TARGETS[@]}"; do
  if pct_running "$ctid"; then
    ip="$(pct exec "$ctid" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
    if [[ -n "${ip:-}" ]]; then
      echo "CT $ctid -> $ip:10050"
    fi
  fi
done

echo
echo "Done."
echo "Next in Zabbix:"
echo "  - Create hosts manually, or"
echo "  - Use auto-registration with HostMetadata=proxmox-guest / proxmox-vm"
