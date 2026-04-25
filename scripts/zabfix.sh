#!/usr/bin/env bash
set -euo pipefail

ZABBIX_SERVER_IP="192.168.68.158"
ZABBIX_SERVER_PORT="10051"
ZABBIX_VERSION_MAJOR="7.4"

LXC_TARGETS=(101 102 106 117 118 119 120 121 122)

install_agent_lxc() {
  local ctid="$1"
  echo "==> [CT $ctid] Cleaning broken Zabbix install and reinstalling"

  pct exec "$ctid" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Block service auto-start BEFORE any package action
cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

# Clean any broken package state first
dpkg --remove --force-remove-reinstreq zabbix-agent2 2>/dev/null || true
dpkg --purge --force-all zabbix-agent2 zabbix-agent2-plugin-* zabbix-release 2>/dev/null || true
apt-get -f install -y || true
dpkg --configure -a || true
apt-get clean
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock

# Base tools
apt-get update
apt-get install -y wget ca-certificates

# Zabbix repo
cd /tmp
rm -f zabbix-release.deb
wget -q -O zabbix-release.deb https://repo.zabbix.com/zabbix/${ZABBIX_VERSION_MAJOR}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian12_all.deb
dpkg -i zabbix-release.deb
apt-get update

# Install agent only
apt-get install -y zabbix-agent2

# Replace config completely with minimal working config
mkdir -p /run/zabbix /var/log/zabbix /etc/zabbix/zabbix_agent2.d
cat >/etc/zabbix/zabbix_agent2.conf <<CFG
PidFile=/run/zabbix/zabbix_agent2.pid
LogType=file
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
Server=${ZABBIX_SERVER_IP}
ServerActive=${ZABBIX_SERVER_IP}:${ZABBIX_SERVER_PORT}
HostnameItem=system.hostname
HostMetadata=proxmox-guest
Include=/etc/zabbix/zabbix_agent2.d/*.conf
ControlSocket=/tmp/agent.sock
CFG

chown -R zabbix:zabbix /run/zabbix /var/log/zabbix 2>/dev/null || true

# Validate config before service start
/usr/sbin/zabbix_agent2 -T -c /etc/zabbix/zabbix_agent2.conf

# Re-enable service management
rm -f /usr/sbin/policy-rc.d

# Finish package state
dpkg --configure -a
apt-get -f install -y

# Start service
systemctl daemon-reload
systemctl enable --now zabbix-agent2
systemctl restart zabbix-agent2
systemctl is-active zabbix-agent2

# Show listener
ss -tulpn | grep 10050 || true
"
}

for ctid in "${LXC_TARGETS[@]}"; do
  if pct status "$ctid" 2>/dev/null | grep -q 'status: running'; then
    install_agent_lxc "$ctid"
  else
    echo "==> [CT $ctid] Not running, skipping"
  fi
done

echo "Done."
