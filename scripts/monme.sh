#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================

# Containers to monitor with node_exporter
CTS_NODE_EXPORTER=(100 101 102 106 117 118 119 120 121)

# Containers that run Docker apps and should also get cAdvisor
CTS_CADVISOR=(106 117 119 120 121)

NODE_EXPORTER_VERSION="1.8.2"
CADVISOR_IMAGE="gcr.io/cadvisor/cadvisor:latest"

# =========================
# FUNCTIONS
# =========================

pct_running() {
  local ctid="$1"
  pct status "$ctid" 2>/dev/null | grep -q "status: running"
}

get_ct_ip() {
  local ctid="$1"
  pct exec "$ctid" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true
}

install_node_exporter() {
  local ctid="$1"

  echo "==> [$ctid] Installing node_exporter"

  pct exec "$ctid" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl tar

id -u node_exporter >/dev/null 2>&1 || useradd --no-create-home --shell /usr/sbin/nologin node_exporter

cd /tmp
curl -fsSLO https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
tar -xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
install -m 0755 node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/node_exporter

cat >/etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter
systemctl is-active node_exporter
"
}

install_cadvisor() {
  local ctid="$1"

  echo "==> [$ctid] Installing cAdvisor"

  pct exec "$ctid" -- bash -lc "
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo 'Docker not found, skipping cAdvisor'
  exit 0
fi

docker rm -f cadvisor >/dev/null 2>&1 || true

docker run -d \
  --name=cadvisor \
  --restart unless-stopped \
  -p 8081:8080 \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker:/var/lib/docker:ro \
  ${CADVISOR_IMAGE}

docker ps --format '{{.Names}}' | grep -q '^cadvisor$'
"
}

# =========================
# MAIN
# =========================

echo "======================================"
echo "Installing node_exporter"
echo "======================================"

for ctid in "${CTS_NODE_EXPORTER[@]}"; do
  if pct_running "$ctid"; then
    install_node_exporter "$ctid"
  else
    echo "==> [$ctid] Container is not running, skipping"
  fi
done

echo
echo "======================================"
echo "Installing cAdvisor on Docker containers"
echo "======================================"

for ctid in "${CTS_CADVISOR[@]}"; do
  if pct_running "$ctid"; then
    install_cadvisor "$ctid"
  else
    echo "==> [$ctid] Container is not running, skipping"
  fi
done

echo
echo "======================================"
echo "Detected targets"
echo "======================================"

echo
echo "# node_exporter targets"
for ctid in "${CTS_NODE_EXPORTER[@]}"; do
  ip="$(get_ct_ip "$ctid")"
  if [[ -n \"$ip\" ]]; then
    echo "- ${ip}:9100    # CT ${ctid}"
  fi
done

echo
echo "# cAdvisor targets"
for ctid in "${CTS_CADVISOR[@]}"; do
  ip="$(get_ct_ip "$ctid")"
  if [[ -n \"$ip\" ]]; then
    echo "- ${ip}:8081    # CT ${ctid}"
  fi
done

echo
echo "Done."
