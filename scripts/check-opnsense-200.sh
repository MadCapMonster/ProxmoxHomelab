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

say "Basic VM checks"
if ! qm status "$VMID" >/dev/null 2>&1; then
  bad "VM $VMID does not exist"
  exit 1
fi
qm status "$VMID"
STATUS="$(qm status "$VMID" | awk '{print $2}')"
if [[ "$STATUS" == "running" ]]; then
  ok "VM $VMID is running"
else
  bad "VM $VMID is not running"
fi

say "Read VM network config"
NET0_CFG="$(get_cfg_val net0 || true)"
NET1_CFG="$(get_cfg_val net1 || true)"

echo "net0: ${NET0_CFG:-<missing>}"
echo "net1: ${NET1_CFG:-<missing>}"

if [[ -z "${NET0_CFG}" ]]; then
  bad "net0 missing"
else
  NET0_BRIDGE="$(echo "$NET0_CFG" | extract_bridge)"
  NET0_MAC="$(echo "$NET0_CFG" | extract_mac)"
  [[ "$NET0_BRIDGE" == "$WAN_BRIDGE" ]] && ok "net0 bridge is $WAN_BRIDGE" || bad "net0 bridge is $NET0_BRIDGE, expected $WAN_BRIDGE"
  echo "net0 MAC: ${NET0_MAC:-unknown}"
fi

if [[ -z "${NET1_CFG}" ]]; then
  bad "net1 missing"
else
  NET1_BRIDGE="$(echo "$NET1_CFG" | extract_bridge)"
  NET1_MAC="$(echo "$NET1_CFG" | extract_mac)"
  [[ "$NET1_BRIDGE" == "$LAN_BRIDGE" ]] && ok "net1 bridge is $LAN_BRIDGE" || bad "net1 bridge is $NET1_BRIDGE, expected $LAN_BRIDGE"
  echo "net1 MAC: ${NET1_MAC:-unknown}"
fi

say "Check Proxmox bridge definitions"
for br in "$WAN_BRIDGE" "$LAN_BRIDGE"; do
  if ip link show "$br" >/dev/null 2>&1; then
    ok "$br exists"
    ip -br addr show "$br"
  else
    bad "$br does not exist"
  fi
done

say "Check /etc/network/interfaces bridge ports"
awk '
  $1=="iface" {cur=$2}
  cur ~ /^vmbr/ && $1=="bridge-ports" {print cur ": bridge-ports " $2}
' /etc/network/interfaces

WAN_PORT="$(awk -v br="$WAN_BRIDGE" '
  $1=="iface" {cur=$2}
  cur==br && $1=="bridge-ports" {print $2}
' /etc/network/interfaces || true)"

LAN_PORT="$(awk -v br="$LAN_BRIDGE" '
  $1=="iface" {cur=$2}
  cur==br && $1=="bridge-ports" {print $2}
' /etc/network/interfaces || true)"

if [[ -n "${WAN_PORT:-}" && "$WAN_PORT" != "none" ]]; then
  ok "$WAN_BRIDGE bridge-ports is $WAN_PORT"
  ip -br link show "$WAN_PORT" || true
else
  bad "$WAN_BRIDGE has no physical bridge-ports"
fi

if [[ "${LAN_PORT:-}" == "none" || -z "${LAN_PORT:-}" ]]; then
  ok "$LAN_BRIDGE is an internal-only bridge"
else
  inf "$LAN_BRIDGE is attached to $LAN_PORT"
fi

say "Check VM tap devices attached to bridges"
bridge link | egrep "fwpr|fwln|tap${VMID}i[01]" || true

for iface in "tap${VMID}i0" "tap${VMID}i1"; do
  if ip link show "$iface" >/dev/null 2>&1; then
    ok "$iface exists"
    bridge link show | grep -F "$iface" || true
  else
    inf "$iface not present directly (firewall bridge devices may be in use)"
  fi
done

say "Show bridge forwarding database entries for VM MACs"
if [[ -n "${NET0_MAC:-}" ]]; then
  bridge fdb show br "$WAN_BRIDGE" | grep -i "${NET0_MAC}" && ok "Found net0 MAC on $WAN_BRIDGE FDB" || bad "Did not find net0 MAC on $WAN_BRIDGE FDB"
fi
if [[ -n "${NET1_MAC:-}" ]]; then
  bridge fdb show br "$LAN_BRIDGE" | grep -i "${NET1_MAC}" && ok "Found net1 MAC on $LAN_BRIDGE FDB" || bad "Did not find net1 MAC on $LAN_BRIDGE FDB"
fi

say "Host routing checks"
ip route
echo
ip route get "$EXPECTED_WAN_IP" || true
echo
ip route get "$EXPECTED_LAN_IP" || true

say "L2/L3 reachability tests from Proxmox host"
ping -c 2 -W 2 "$EXPECTED_WAN_IP" && ok "Can ping OPNsense WAN IP $EXPECTED_WAN_IP" || bad "Cannot ping OPNsense WAN IP $EXPECTED_WAN_IP"
ping -c 2 -W 2 "$EXPECTED_LAN_IP" && ok "Can ping OPNsense LAN IP $EXPECTED_LAN_IP" || bad "Cannot ping OPNsense LAN IP $EXPECTED_LAN_IP"

say "ARP/neighbor table clues"
ip neigh show | egrep "(${EXPECTED_WAN_IP}|${EXPECTED_LAN_IP})" || true

say "Try to learn neighbor for WAN IP"
arping -c 3 -I "$WAN_BRIDGE" "$EXPECTED_WAN_IP" || true

say "Summary"
cat <<EOF
What to look for:

1. net0 must be on $WAN_BRIDGE and net1 must be on $LAN_BRIDGE.
2. $WAN_BRIDGE must have a real physical NIC in bridge-ports.
3. The VM WAN MAC should appear in the FDB for $WAN_BRIDGE.
4. Proxmox should be able to ping $EXPECTED_WAN_IP.
5. If #1-#3 are good but ping still fails, OPNsense likely does not currently have $EXPECTED_WAN_IP on WAN,
   or WAN/LAN are swapped inside OPNsense.

Most likely outcomes:
- If net0 is wrong: fix qm config / recreate NICs.
- If tap/FDB is missing: VM NIC is not attached correctly.
- If Proxmox cannot arping/ping $EXPECTED_WAN_IP: OPNsense WAN is not actually on that IP.
EOF
