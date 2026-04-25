#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-./fleetdm-discovery-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/discovery.log"
JSON="$OUT_DIR/inventory.json"

run() {
  local name="$1"; shift
  echo "### $name" | tee -a "$LOG"
  { "$@"; } >>"$LOG" 2>&1 || true
  echo | tee -a "$LOG" >/dev/null
}

need() { command -v "$1" >/dev/null 2>&1; }

HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
OS_PRETTY=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
ROLE="unknown"

if systemctl list-unit-files 2>/dev/null | grep -qi '^fleet'; then ROLE="fleet-app"; fi
if systemctl list-unit-files 2>/dev/null | grep -qi '^mysql'; then ROLE="fleet-db"; fi
if systemctl list-unit-files 2>/dev/null | grep -qi '^redis'; then ROLE="fleet-redis"; fi
if [[ "$HOSTNAME_FQDN" =~ fleet-app ]]; then ROLE="fleet-app"; fi
if [[ "$HOSTNAME_FQDN" =~ fleet-db ]]; then ROLE="fleet-db"; fi
if [[ "$HOSTNAME_FQDN" =~ fleet-redis ]]; then ROLE="fleet-redis"; fi

run "system" uname -a
run "os-release" cat /etc/os-release
run "network-addresses" ip -br addr
run "routes" ip route
run "listening-ports" ss -tulpen
run "services-fleet-mysql-redis" bash -lc "systemctl status fleet fleet.service mysql mysqld redis redis-server --no-pager"
run "enabled-services" bash -lc "systemctl list-unit-files | egrep -i 'fleet|mysql|redis|nginx|caddy|apache|traefik'"
run "fleet-binary" bash -lc "command -v fleet && fleet version || true; command -v fleetctl && fleetctl version || true"
run "fleet-config-files" bash -lc "ls -la /etc/fleet* /opt/fleet* /var/lib/fleet* 2>/dev/null; grep -R --line-number --exclude='*.key' --exclude='*.pem' -E 'mysql|redis|server|tls|address|database' /etc/fleet* /opt/fleet* 2>/dev/null"
run "fleet-unit" bash -lc "systemctl cat fleet fleet.service 2>/dev/null"
run "mysql-version" bash -lc "mysql --version || mysqld --version || true"
run "mysql-bind" bash -lc "grep -R --line-number -E 'bind-address|port|max_connections|innodb' /etc/mysql /etc/my.cnf* 2>/dev/null"
run "mysql-databases" bash -lc "mysql -NBe 'show databases;' 2>/dev/null || true"
run "redis-version" bash -lc "redis-server --version || redis-cli INFO server | head || true"
run "redis-config" bash -lc "grep -R --line-number -E '^(bind|port|requirepass|protected-mode|maxmemory|appendonly|save)' /etc/redis /etc/redis.conf 2>/dev/null"
run "firewall" bash -lc "ufw status verbose 2>/dev/null || true; nft list ruleset 2>/dev/null || true; iptables-save 2>/dev/null || true"
run "certificates" bash -lc "find /etc/letsencrypt /etc/ssl /opt/fleet -maxdepth 3 -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.key' \) -printf '%p %m %u:%g\n' 2>/dev/null"
run "cron" bash -lc "crontab -l 2>/dev/null || true; ls -la /etc/cron* 2>/dev/null"
run "proxmox-guest" bash -lc "dmidecode -s system-product-name 2>/dev/null || true; cloud-init status --long 2>/dev/null || true"

cat > "$JSON" <<JSON
{
  "hostname": "$HOSTNAME_FQDN",
  "primary_ip": "$PRIMARY_IP",
  "os": "$OS_PRETTY",
  "detected_role": "$ROLE",
  "generated_at": "$(date -Is)",
  "notes": "Run this script on fleet-app, fleet-db and fleet-redis, then commit the three output folders under discovery/ for review. Secrets are not intentionally printed, but review before sharing."
}
JSON

echo "Discovery written to: $OUT_DIR"
echo "Review $LOG for secrets before sharing."
