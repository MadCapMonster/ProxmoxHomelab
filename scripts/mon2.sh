#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================
PIHOLE_CTID=122
PROM_CTID=103

PIHOLE_IP="192.168.68.156"          # change if your Pi-hole IP is different
PIHOLE_WEB_PORT="8082"              # your Pi-hole web UI port
PIHOLE_PASSWORD="changeme"          # change this to your actual Pi-hole password

EXPORTER_NAME="pihole-exporter"
EXPORTER_IMAGE="ekofr/pihole-exporter:latest"
EXPORTER_PORT="9617"

PROM_CONFIG="/opt/prometheus/prometheus.yml"
JOB_NAME="pihole-exporter"

# =========================
# CHECKS
# =========================
echo "==> Checking CTs"
pct status "$PIHOLE_CTID" >/dev/null
pct status "$PROM_CTID" >/dev/null

echo "==> Checking Pi-hole container exists"
pct exec "$PIHOLE_CTID" -- docker ps --format '{{.Names}}' | grep -q '^pihole$'

# =========================
# DEPLOY EXPORTER
# =========================
echo "==> Deploying pihole-exporter in CT $PIHOLE_CTID"
pct exec "$PIHOLE_CTID" -- bash -lc "
set -euo pipefail

docker rm -f '$EXPORTER_NAME' >/dev/null 2>&1 || true

docker run -d \
  --name '$EXPORTER_NAME' \
  --restart unless-stopped \
  -e PIHOLE_HOSTNAME='127.0.0.1' \
  -e PIHOLE_PORT='$PIHOLE_WEB_PORT' \
  -e PIHOLE_PROTOCOL='http' \
  -e PIHOLE_PASSWORD='$PIHOLE_PASSWORD' \
  -e PORT='$EXPORTER_PORT' \
  -p ${EXPORTER_PORT}:${EXPORTER_PORT} \
  '$EXPORTER_IMAGE'
"

echo "==> Testing exporter locally"
pct exec "$PIHOLE_CTID" -- bash -lc "curl -fsS http://127.0.0.1:${EXPORTER_PORT}/metrics | head -n 5"

# =========================
# ADD PROMETHEUS SCRAPE JOB
# =========================
echo "==> Backing up Prometheus config"
pct exec "$PROM_CTID" -- cp "$PROM_CONFIG" "${PROM_CONFIG}.bak.$(date +%F-%H%M%S)"

echo "==> Adding Prometheus scrape job if missing"
pct exec "$PROM_CTID" -- bash -lc "
set -euo pipefail

if grep -q \"job_name: '$JOB_NAME'\" '$PROM_CONFIG'; then
  echo 'Prometheus job already exists, skipping append.'
else
cat >> '$PROM_CONFIG' <<'EOF'

  - job_name: '$JOB_NAME'
    static_configs:
      - targets:
          - '$PIHOLE_IP:$EXPORTER_PORT'
EOF
fi
"

echo "==> Restarting Prometheus"
pct exec "$PROM_CTID" -- systemctl restart prometheus

echo "==> Checking Prometheus service"
pct exec "$PROM_CTID" -- systemctl is-active prometheus

echo
echo "=============================================="
echo "Pi-hole monitoring added."
echo
echo "Exporter target:"
echo "  $PIHOLE_IP:$EXPORTER_PORT"
echo
echo "Prometheus target page:"
echo "  http://192.168.68.144:9090/targets"
echo
echo "Metrics test from Pi-hole CT:"
echo "  pct exec $PIHOLE_CTID -- curl http://127.0.0.1:${EXPORTER_PORT}/metrics"
echo "=============================================="
