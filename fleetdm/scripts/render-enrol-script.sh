#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

FLEET_URL="${FLEET_URL:-http://192.168.68.240:8080}"
ENROLL_SECRET="${ENROLL_SECRET:-CHANGE_ME}"
OUT="scripts/join-fleet-host.sh"

cat > "$OUT" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

FLEET_URL="${FLEET_URL}"
ENROLL_SECRET="${ENROLL_SECRET}"

if [[ "\$ENROLL_SECRET" == "CHANGE_ME" ]]; then
  echo "Edit ENROLL_SECRET first."
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y curl ca-certificates gnupg
else
  echo "This starter script currently supports Debian/Ubuntu apt-based VMs/LXCs."
  exit 1
fi

TMPDIR="\$(mktemp -d)"
cd "\$TMPDIR"

curl -fsSL "https://github.com/fleetdm/fleet/releases/latest/download/fleetctl_linux.tar.gz" -o fleetctl_linux.tar.gz
# If the asset name changes upstream, download fleetctl manually and place it in PATH.
tar -xzf fleetctl_linux.tar.gz || true
sudo install -m 0755 fleetctl /usr/local/bin/fleetctl || sudo install -m 0755 linux/fleetctl /usr/local/bin/fleetctl

fleetctl package \
  --type=deb \
  --fleet-url="\$FLEET_URL" \
  --enroll-secret="\$ENROLL_SECRET" \
  --fleet-desktop=false

PKG="\$(ls fleet-osquery*.deb fleetd*.deb 2>/dev/null | head -n1)"
sudo apt-get install -y "./\$PKG"

echo "Joined Fleet at \$FLEET_URL"
SCRIPT

chmod +x "$OUT"
echo "Generated $OUT"
