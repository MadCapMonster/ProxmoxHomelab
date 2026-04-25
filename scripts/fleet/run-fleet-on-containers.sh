#!/usr/bin/env bash
set -euo pipefail

# Path on Proxmox host
LOCAL_SCRIPT="/root/scripts/fleet/fleet.sh"

# Path inside container
REMOTE_SCRIPT="/root/fleet.sh"

expand_targets() {
  for arg in "$@"; do
    if [[ "$arg" == "all" ]]; then
      pct list | awk 'NR>1 {print $1}'
    elif [[ "$arg" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${arg%-*}"
      end="${arg#*-}"
      seq "$start" "$end"
    else
      echo "$arg"
    fi
  done
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <CTID... | range | all>"
  exit 1
fi

if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "ERROR: Local script not found at $LOCAL_SCRIPT"
  exit 1
fi

for CTID in $(expand_targets "$@"); do
  echo "=================================================="
  echo "Container: $CTID"
  echo "=================================================="

  if ! pct status "$CTID" >/dev/null 2>&1; then
    echo "SKIP: CT $CTID does not exist"
    continue
  fi

  STATUS="$(pct status "$CTID" | awk '{print $2}')"

  if [[ "$STATUS" != "running" ]]; then
    echo "Starting CT $CTID..."
    pct start "$CTID"
    sleep 5
  fi

  echo "Copying script to container..."
  pct push "$CTID" "$LOCAL_SCRIPT" "$REMOTE_SCRIPT"

  echo "Making script executable..."
  pct exec "$CTID" -- chmod +x "$REMOTE_SCRIPT"

  echo "Running Fleet installer..."
  if pct exec "$CTID" -- bash "$REMOTE_SCRIPT"; then
    echo "SUCCESS: CT $CTID"
  else
    echo "FAILED: CT $CTID"
  fi

  echo
done
