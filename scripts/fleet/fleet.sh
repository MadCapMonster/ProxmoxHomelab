#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
FLEET_URL="https://192.168.68.240:1337"
ENROLL_SECRET="Rqt5B8N8LZGx8D3r/zbJoNAJPfbznm4/"
INSECURE_TLS="true"
WORKDIR="/tmp/fleetd-install"
# ====================

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0"
  exit 1
fi

if [[ -z "$ENROLL_SECRET" || "$ENROLL_SECRET" == "PASTE_YOUR_SECRET_HERE" ]]; then
  echo "ERROR: Set ENROLL_SECRET at the top of this script."
  exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[1/6] Installing dependencies..."
apt-get update
apt-get install -y curl ca-certificates

echo "[2/6] Installing fleetctl (official method)..."
if ! command -v fleetctl >/dev/null 2>&1; then
  curl -sSL https://fleetdm.com/resources/install-fleetctl.sh | bash
  export PATH="$PATH:/root/.fleetctl:/root/.fleet/bin"
fi

fleetctl version || true

echo "[3/6] Generating Fleet agent package..."
rm -f ./*.deb

PKG_CMD=(
  fleetctl package
  --type=deb
  --fleet-url="$FLEET_URL"
  --enroll-secret="$ENROLL_SECRET"
)

if [[ "$INSECURE_TLS" == "true" ]]; then
  PKG_CMD+=(--insecure)
fi

"${PKG_CMD[@]}"

DEB_FILE="$(ls -1 ./*.deb | head -n 1)"

if [[ ! -f "$DEB_FILE" ]]; then
  echo "ERROR: No .deb package was generated."
  exit 1
fi

echo "[4/6] Installing Fleet agent..."
dpkg -i "$DEB_FILE" || apt-get install -f -y

echo "[5/6] Enabling and starting Orbit..."
systemctl daemon-reload
systemctl enable orbit
systemctl restart orbit

echo "[6/6] Status..."
systemctl --no-pager --full status orbit || true

echo
echo "✅ Done!"
echo "📡 Check Fleet UI → Hosts"
echo "📜 Logs: sudo journalctl -u orbit -f"
