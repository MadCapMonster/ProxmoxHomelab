#!/usr/bin/env bash
set -euo pipefail

VMID=200
WAN_BRIDGE="vmbr0"
LAN_BRIDGE="vmbr1"
EXPECTED_WAN_IP="192.168.68.160"
EXPECTED_LAN_IP="192.168.50.1"

say() { echo -e "\n== $* =="; }
ok()  { echo "[OK]  $*"; }
bad() { echo "[ERR] $*"; }
inf() { echo "[INF] $*"; }

get_cfg_val() {
  local key="$1"
  qm config "$VMID" | awk -F': ' -v k="$key" '$1==k {print $2}'
}

extract_bridge() {
  sed -n 's/.*bridge=\([^,]*\).*/\1/p'
}

extract_mac() {
  sed -n 's/^[^=]*=\([^,]*\).*/\1/p'
}

say "VM status"
qm status "$VMID" || { bad "VM $VMID missing"; exit 1; }

say "VM network config"
NET0_CFG="$(get_cfg_val net0 || true)"
NET1_CFG="$(get_cfg_val net1 || true)"
echo "net0: ${NET0_CFG:-<missing>}"
echo "net1: ${NET1_CFG:-<missing>}"

NET0_BRIDGE="$(echo "${NET0_CFG:-}" | extract_bridge)"
NET1_BRIDGE="$(echo "${NET1_CFG:-}" | extract_bridge)"
NET0_MAC="$(echo "${NET0_CFG:-}" | extract_mac)"
NET1_MAC="$(echo "${NET1_CFG:-}" | extract_mac)"

[[ "$NET0_BRIDGE" == "$WAN_BRIDGE" ]] && ok "net0 -> $WAN_BRIDGE" || bad "net0 is $NET0_BRIDGE"
[[ "$NET1_BRIDGE" == "$LAN_BRIDGE" ]] && ok "net1 -> $LAN_BRIDGE" || bad "net1 is $NET1_BRIDGE"
echo "net0 MAC: ${NET0_MAC:-unknown}"
echo "net1 MAC: ${NET1_MAC:-unknown}"

say "Bridge/IP summary"
ip -br addr show "$WAN_BRIDGE" "$LAN_BRIDGE" || true

say "Bridge ports from /etc/network/interfaces"
awk '
  $1=="iface" {cur=$2}
  cur ~ /^vmbr/ && ($1=="bridge-ports" || $1=="bridge_ports") {print cur ": " $1 " " $2}
' /etc/network/interfaces

WAN_PORT="$(awk -v br="$WAN_BRIDGE" '
  $1=="iface" {cur=$2}
  cur==br && ($1=="bridge-ports" || $1=="bridge_ports") {print $2}
' /etc/network/interfaces || true)"
LAN_PORT="$(awk -v br="$LAN_BRIDGE" '
  $1=="iface" {cur=$2}
  cur==br && ($1=="bridge-ports" || $1=="bridge_ports") {print $2}
' /etc/network/interfaces || true)"

[[ -n "${WAN_PORT:-}" && "$WAN_PORT" != "none" ]] && ok "$WAN_BRIDGE uses physical port $WAN_PORT" || bad "$WAN_BRIDGE missing physical uplink"
[[ "${LAN_PORT:-}" == "none" || -z "${LAN_PORT:-}" ]] && ok "$LAN_BRIDGE is internal-only" || inf "$LAN_BRIDGE attached to $LAN_PORT"

say "VM tap devices"
bridge link | egrep "tap${VMID}i[01]|fwpr${VMID}|fwln${VMID}|fwbr${VMID}" || true

say "FDB entries"
if [[ -n "${NET0_MAC:-}" ]]; then
  bridge fdb show br "$WAN_BRIDGE" | grep -i "${NET0_MAC}" || inf "No direct FDB hit for WAN MAC (can be normal if firewall bridge devices are in use)"
fi
if [[ -n "${NET1_MAC:-}" ]]; then
  bridge fdb show br "$LAN_BRIDGE" | grep -i "${NET1_MAC}" || inf "No direct FDB hit for LAN MAC"
fi

say "Host routing"
ip route

say "Route lookup"
echo "-- route to WAN IP --"
ip route get "$EXPECTED_WAN_IP" || true
echo "-- route to LAN IP --"
ip route get "$EXPECTED_LAN_IP" || true

say "Ping tests from Proxmox"
ping -c 2 -W 2 "$EXPECTED_WAN_IP" && ok "WAN IP responds" || bad "WAN IP does not respond"
ping -c 2 -W 2 "$EXPECTED_LAN_IP" && ok "LAN IP responds" || bad "LAN IP does not respond"

say "Neighbor table"
ip neigh show | egrep "(${EXPECTED_WAN_IP}|${EXPECTED_LAN_IP})" || true

say "Interpretation"
cat <<'EOF'
1. If net0->vmbr0 and net1->vmbr1 are correct, Proxmox bridge wiring is likely fine.
2. If WAN IP still does not answer, OPNsense probably does not currently have that IP on WAN,
   or WAN/LAN are swapped inside OPNsense.
3. If LAN IP does not answer, remember: if vmbr1 is NOT in 192.168.50.0/24 on the host,
   Proxmox itself will not be able to reach 192.168.50.1 directly without a route.
4. Your current host vmbr1 address being 10.10.1.1/24 is inconsistent with OPNsense LAN 192.168.50.1/24.
EOF

say "Next commands to run INSIDE OPNsense console, not on Proxmox"
cat <<'EOF'
ifconfig vtnet0
ifconfig vtnet1
route -n get default
netstat -rn
EOF
