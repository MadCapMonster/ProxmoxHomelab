#!/usr/bin/env bash
set -euo pipefail

# Containers to move
CTIDS=(101 102 103 104 105 106 117 118 119 120 121 122 123 124)

# Target network
TARGET_BRIDGE="vmbr1"

# Mode:
#   dhcp   = containers get IPs from OPNsense DHCP
#   static = assign static IPs from the map below
MODE="dhcp"

# OPNsense LAN gateway
LAN_GW="192.168.50.1"

# Only used if MODE="static"
declare -A STATIC_IPS=(
  [101]="192.168.50.101"
  [102]="192.168.50.102"
  [103]="192.168.50.103"
  [104]="192.168.50.104"
  [105]="192.168.50.105"
  [106]="192.168.50.106"
  [117]="192.168.50.117"
  [118]="192.168.50.118"
  [119]="192.168.50.119"
  [120]="192.168.50.120"
  [121]="192.168.50.121"
  [122]="192.168.50.122"
  [123]="192.168.50.123"
  [124]="192.168.50.124"
)

BACKUP_DIR="/root/lxc-net-backups-$(date +%F-%H%M%S)"
mkdir -p "$BACKUP_DIR"

build_net0_spec() {
  local ctid="$1"
  local current="$2"

  declare -A kv=()

  IFS=',' read -ra parts <<< "$current"
  for part in "${parts[@]}"; do
    local key="${part%%=*}"
    local val="${part#*=}"
    kv["$key"]="$val"
  done

  # Move to vmbr1
  kv["bridge"]="$TARGET_BRIDGE"

  if [[ "$MODE" == "dhcp" ]]; then
    kv["ip"]="dhcp"
    unset kv["gw"]
  elif [[ "$MODE" == "static" ]]; then
    if [[ -z "${STATIC_IPS[$ctid]:-}" ]]; then
      echo "No static IP defined for CT $ctid" >&2
      exit 1
    fi
    kv["ip"]="${STATIC_IPS[$ctid]}/24"
    kv["gw"]="$LAN_GW"
  else
    echo "Invalid MODE: $MODE" >&2
    exit 1
  fi

  # Rebuild in a sensible order
  local ordered_keys=(
    name bridge hwaddr ip gw ip6 gw6 firewall tag mtu rate type link_down
  )

  local out=()
  for key in "${ordered_keys[@]}"; do
    if [[ -n "${kv[$key]:-}" ]]; then
      out+=("${key}=${kv[$key]}")
      unset kv["$key"]
    fi
  done

  # Append any other keys we didn't explicitly order
  for key in "${!kv[@]}"; do
    out+=("${key}=${kv[$key]}")
  done

  local spec=""
  local first=1
  for item in "${out[@]}"; do
    if [[ $first -eq 1 ]]; then
      spec="$item"
      first=0
    else
      spec="${spec},${item}"
    fi
  done

  echo "$spec"
}

for ctid in "${CTIDS[@]}"; do
  echo "=== Processing CT $ctid ==="

  if [[ ! -f "/etc/pve/lxc/${ctid}.conf" ]]; then
    echo "Skipping CT $ctid: config not found"
    continue
  fi

  cp "/etc/pve/lxc/${ctid}.conf" "${BACKUP_DIR}/${ctid}.conf.bak"

  current_net0="$(pct config "$ctid" | awk -F': ' '$1=="net0"{print $2}')"
  if [[ -z "$current_net0" ]]; then
    echo "Skipping CT $ctid: no net0 found"
    continue
  fi

  new_net0="$(build_net0_spec "$ctid" "$current_net0")"

  status="$(pct status "$ctid" | awk '{print $2}')"

  echo "Current net0: $current_net0"
  echo "New net0:     $new_net0"

  if [[ "$status" == "running" ]]; then
    echo "Stopping CT $ctid..."
    pct shutdown "$ctid" --timeout 60 || pct stop "$ctid"
  fi

  echo "Applying new network config to CT $ctid..."
  pct set "$ctid" -net0 "$new_net0"

  echo "Starting CT $ctid..."
  pct start "$ctid"

  echo "Done with CT $ctid"
  echo
done

echo "All done."
echo "Backups saved in: $BACKUP_DIR"
