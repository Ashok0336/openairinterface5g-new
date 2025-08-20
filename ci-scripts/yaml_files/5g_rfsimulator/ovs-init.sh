#!/usr/bin/env bash
set -euo pipefail

# --- Config from environment (provided in docker-compose) ---
: "${UPF_CONT:?set UPF_CONT}"
: "${EDN_CONT:?set EDN_CONT}"
: "${UPF_N6_IF:?set UPF_N6_IF}"   # e.g., eth1
: "${EDN_IF:?set EDN_IF}"         # e.g., dn0  (avoid eth0 to not clash)
: "${ONOS_CTRL:?set ONOS_CTRL}"   # e.g., 127.0.0.1:6653

BR=br-n6
V_UPF_HOST=v-upf-host
V_UPF_CONT=v-upf
V_EDN_HOST=v-edn-host
V_EDN_CONT=v-edn

# --- Helpers ---
cid_pid() { docker inspect -f '{{.State.Pid}}' "$1"; }
in_ns() { nsenter -t "$1" -n -- bash -lc "$2"; }

exists_link() { ip -o link show "$1" &>/dev/null; }

# --- Get container PIDs ---
UPF_PID="$(cid_pid "$UPF_CONT")"
EDN_PID="$(cid_pid "$EDN_CONT")"

echo "[ovs-init] UPF pid=$UPF_PID  EDN pid=$EDN_PID"

# --- Create OVS bridge and point to ONOS ---
if ! ovs-vsctl br-exists "$BR"; then
  ovs-vsctl add-br "$BR"
fi
ovs-vsctl set-fail-mode "$BR" secure || true
ovs-vsctl set-controller "$BR" "tcp:${ONOS_CTRL}"

# --- Create veth pairs if missing ---
if ! exists_link "$V_UPF_HOST"; then
  ip link add "$V_UPF_HOST" type veth peer name "$V_UPF_CONT"
fi
if ! exists_link "$V_EDN_HOST"; then
  ip link add "$V_EDN_HOST" type veth peer name "$V_EDN_CONT"
fi

# --- Move one end of each pair into the target container netns ---
ip link set "$V_UPF_CONT" netns "$UPF_PID"
ip link set "$V_EDN_CONT" netns "$EDN_PID"

# --- Inside containers: rename and bring up interfaces ---
in_ns "$UPF_PID" "
  set -e
  ip link set '$V_UPF_CONT' name '$UPF_N6_IF'
  ip link set '$UPF_N6_IF' up
"

in_ns "$EDN_PID" "
  set -e
  ip link set '$V_EDN_CONT' name '$EDN_IF'
  ip link set '$EDN_IF' up
"

# --- On the host: add host ends to OVS bridge ---
# Remove from OVS if they exist, then re-add (idempotent)
ovs-vsctl --if-exists del-port "$BR" "$V_UPF_HOST"
ovs-vsctl --if-exists del-port "$BR" "$V_EDN_HOST"
ip link set "$V_UPF_HOST" up
ip link set "$V_EDN_HOST" up
ovs-vsctl add-port "$BR" "$V_UPF_HOST"
ovs-vsctl add-port "$BR" "$V_EDN_HOST"

# --- Move the existing IPs from Docker NICs onto the new veths ---
# We detect current 192.168.72.x/26 addresses & migrate them.

# For UPF: find current N6 IP (on its Docker NIC), move it to $UPF_N6_IF
UPF_CUR_IF=$(in_ns "$UPF_PID" "ip -o -4 addr show | awk '/192\\.168\\.72\\./{print \$2; exit}'")
UPF_CUR_IP=$(in_ns "$UPF_PID" "ip -o -4 addr show dev \"$UPF_CUR_IF\" | awk '{print \$4}' || true")
if [[ -n "$UPF_CUR_IP" && "$UPF_CUR_IF" != "$UPF_N6_IF" ]]; then
  in_ns "$UPF_PID" "
    ip addr del '$UPF_CUR_IP' dev '$UPF_CUR_IF' || true
    ip addr add '$UPF_CUR_IP' dev '$UPF_N6_IF'
  "
fi

# For Ext-DN: same for its 192.168.72.x address -> $EDN_IF
EDN_CUR_IF=$(in_ns "$EDN_PID" "ip -o -4 addr show | awk '/192\\.168\\.72\\./{print \$2; exit}'")
EDN_CUR_IP=$(in_ns "$EDN_PID" "ip -o -4 addr show dev \"$EDN_CUR_IF\" | awk '{print \$4}' || true")
if [[ -n "$EDN_CUR_IP" && "$EDN_CUR_IF" != "$EDN_IF" ]]; then
  in_ns "$EDN_PID" "
    ip addr del '$EDN_CUR_IP' dev '$EDN_CUR_IF' || true
    ip addr add '$EDN_CUR_IP' dev '$EDN_IF'
  "
fi

# --- Ensure return route on Ext-DN for UE subnet (12.1.1.0/24) via UPF ---
# Detect UPF's 192.168.72.x address (now on $UPF_N6_IF) and program route.
UPF_72_IP=$(in_ns "$UPF_PID" "ip -o -4 addr show dev '$UPF_N6_IF' | awk '{print \$4}' | cut -d/ -f1")
if [[ -n "$UPF_72_IP" ]]; then
  in_ns "$EDN_PID" "
    sysctl -w net.ipv4.ip_forward=1
    ip route replace 12.1.1.0/24 via '$UPF_72_IP' dev '$EDN_IF'
  "
fi

# --- Optional: tag ports so ONOS can identify them (helpful but not required) ---
ovs-vsctl set interface "$V_UPF_HOST" external-ids:role=n6
ovs-vsctl set interface "$V_EDN_HOST" external-ids:role=dn

echo "[ovs-init] Done. Bridge: $BR"
ovs-vsctl show
