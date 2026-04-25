#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# update-monitoring-ips.sh
#
# Run on the Proxmox host.
# Updates old IPs to new IPs inside selected LXCs.
# =========================================================

# 1 = preview only, 0 = make changes
DRY_RUN=0

# Container IDs
PROMETHEUS_CTID=103
GRAFANA_CTID=104
LOKI_CTID=105
ZABBIX_CTID=123

TIMESTAMP="$(date +%F-%H%M%S)"

# ---------------------------------------------------------
# OLD -> NEW IP mapping
# Fill these in for your migration
# Example:
#   ["192.168.68.101"]="192.168.50.101"
# ---------------------------------------------------------
declare -A IP_MAP=(
  ["192.168.68.158"]="192.168.50.79"
  ["192.168.68.139"]="192.168.50.120"
  ["192.168.68.141"]="192.168.50.227"
  ["192.168.68.148"]="192.168.50.181"
  ["192.168.68.149"]="192.168.50.240"
  ["192.168.68.150"]="192.168.50.44"
  ["192.168.68.151"]="192.168.50.167"
  ["192.168.68.152"]="192.168.50.235"
  ["192.168.68.153"]="192.168.50.106"
  ["192.168.68.158"]="192.168.50.197"
  ["192.168.68.148"]="192.168.50.195"
  ["192.168.68.149"]="192.168.50.119"
  ["192.168.68.152"]="192.168.50.114"
  ["192.168.68.153"]="192.168.50.100"
)

# ---------------------------------------------------------
# Common config paths to check
# Add more if your setup uses different locations
# ---------------------------------------------------------
PROMETHEUS_PATHS=(
  /etc/prometheus
  /opt/prometheus
  /srv/prometheus
  /var/lib/prometheus
)

LOKI_PATHS=(
  /etc/loki
  /opt/loki
  /srv/loki
  /usr/local/etc/loki
)

GRAFANA_PATHS=(
  /etc/grafana
  /var/lib/grafana
  /etc/default/grafana-server
)

ZABBIX_PATHS=(
  /etc/zabbix
  /usr/share/zabbix
  /etc/apache2
  /etc/nginx
)

# ---------------------------------------------------------
# Helper functions
# ---------------------------------------------------------
log() {
  echo "[$(date +%H:%M:%S)] $*"
}

check_ct_exists() {
  local ctid="$1"
  if [[ ! -f "/etc/pve/lxc/${ctid}.conf" ]]; then
    echo "Container $ctid not found." >&2
    exit 1
  fi
}

pct_sh() {
  local ctid="$1"
  shift
  pct exec "$ctid" -- bash -lc "$*"
}

build_find_expr() {
  local paths=("$@")
  local out=""
  for p in "${paths[@]}"; do
    out+=" \"$p\""
  done
  echo "$out"
}

preview_matches() {
  local ctid="$1"
  local label="$2"
  shift 2
  local paths=("$@")

  log "Previewing matches in $label (CT $ctid)..."

  for old_ip in "${!IP_MAP[@]}"; do
    log "  Searching for $old_ip"
    pct_sh "$ctid" "
      for base in ${paths[*]}; do
        if [ -e \"\$base\" ]; then
          grep -RIl --binary-files=without-match --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp' --exclude='*.woff' --exclude='*.woff2' --exclude='*.ttf' --exclude='*.zip' --exclude='*.gz' --exclude='*.tgz' --exclude='*.tar' --exclude='*.7z' --exclude='*.jar' --exclude='*.pyc' --exclude='*.so' '$old_ip' \"\$base\" 2>/dev/null || true
        fi
      done | sort -u
    "
  done
}

apply_replacements() {
  local ctid="$1"
  local label="$2"
  shift 2
  local paths=("$@")

  log "Updating $label (CT $ctid)..."

  pct_sh "$ctid" "
    mkdir -p /root/ip-migration-backups/$TIMESTAMP
  "

  for old_ip in "${!IP_MAP[@]}"; do
    local new_ip="${IP_MAP[$old_ip]}"
    log "  Replacing $old_ip -> $new_ip"

    pct_sh "$ctid" "
      mapfile -t files < <(
        for base in ${paths[*]}; do
          if [ -e \"\$base\" ]; then
            grep -RIl --binary-files=without-match --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp' --exclude='*.woff' --exclude='*.woff2' --exclude='*.ttf' --exclude='*.zip' --exclude='*.gz' --exclude='*.tgz' --exclude='*.tar' --exclude='*.7z' --exclude='*.jar' --exclude='*.pyc' --exclude='*.so' '$old_ip' \"\$base\" 2>/dev/null || true
          fi
        done | sort -u
      )

      for f in \"\${files[@]}\"; do
        [ -f \"\$f\" ] || continue
        backup=\"/root/ip-migration-backups/$TIMESTAMP/\$(echo \"\$f\" | sed 's#/#__#g')\"
        cp -a \"\$f\" \"\$backup\"
        sed -i 's/$old_ip/$new_ip/g' \"\$f\"
        echo \"Changed: \$f\"
      done
    "
  done
}

restart_service_if_present() {
  local ctid="$1"
  shift
  local services=("$@")

  for svc in "${services[@]}"; do
    if pct_sh "$ctid" "systemctl list-unit-files | grep -q '^${svc}\.service'"; then
      log "Restarting $svc in CT $ctid"
      pct_sh "$ctid" "systemctl restart '$svc'"
    fi
  done
}

show_remaining_old_ips() {
  local ctid="$1"
  local label="$2"
  shift 2
  local paths=("$@")

  log "Checking for leftover old IPs in $label (CT $ctid)..."

  for old_ip in "${!IP_MAP[@]}"; do
    pct_sh "$ctid" "
      found=0
      for base in ${paths[*]}; do
        if [ -e \"\$base\" ] && grep -RIl --binary-files=without-match '$old_ip' \"\$base\" >/dev/null 2>&1; then
          echo \"Still found $old_ip under \$base\"
          found=1
        fi
      done
      exit 0
    "
  done
}

process_app() {
  local ctid="$1"
  local label="$2"
  local restart_services_csv="$3"
  shift 3
  local paths=("$@")

  check_ct_exists "$ctid"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    preview_matches "$ctid" "$label" "${paths[@]}"
    return
  fi

  apply_replacements "$ctid" "$label" "${paths[@]}"

  IFS=',' read -r -a restart_services <<< "$restart_services_csv"
  restart_service_if_present "$ctid" "${restart_services[@]}"

  show_remaining_old_ips "$ctid" "$label" "${paths[@]}"
}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------
log "Starting IP update script"
log "DRY_RUN=$DRY_RUN"

process_app "$PROMETHEUS_CTID" "Prometheus" "prometheus" "${PROMETHEUS_PATHS[@]}"
process_app "$LOKI_CTID"       "Loki"       "loki,promtail" "${LOKI_PATHS[@]}"
process_app "$GRAFANA_CTID"    "Grafana"    "grafana-server" "${GRAFANA_PATHS[@]}"
process_app "$ZABBIX_CTID"     "Zabbix"     "zabbix-server,zabbix-agent2,apache2,nginx,php8.2-fpm,php8.1-fpm,php-fpm" "${ZABBIX_PATHS[@]}"

log "Done"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "This was a dry run. Set DRY_RUN=0 to apply changes."
fi
