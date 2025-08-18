cat > ovs-init.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

UPF_CONT="${UPF_CONT:-rfsim5g-oai-upf}"
EDN_CONT="${EDN_CONT:-rfsim5g-oai-ext-dn}"
UPF_N6_IF="${UPF_N6_IF:-eth1}"
EDN_IF="${EDN_IF:-eth0}"
ONOS_CTRL="${ONOS_CTRL:-127.0.0.1:6653}"

BR="br-n6"
UPF_HOST_PORT="veth-upf-br"
EDN_HOST_PORT="veth-edn-br"
UPF_CNT_IF="n6s0"
EDN_CNT_IF="edns0"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openvswitch-switch iproute2 docker.io >/dev/null

# Wait until target containers exist
for c in "$UPF_CONT" "$EDN_CONT"; do
  for i in {1..60}; do docker inspect "$c" >/dev/null 2>&1 && break; sleep 1; done
done

UPF_PID=$(docker inspect -f '{{.State.Pid}}' "$UPF_CONT")
EDN_PID=$(docker inspect -f '{{.State.Pid}}' "$EDN_CONT")

# Create bridge and point it at ONOS
ovs-vsctl --may-exist add-br "$BR"
ovs-vsctl set-controller "$BR" "tcp:$ONOS_CTRL"
ovs-vsctl set-fail-mode "$BR" secure

# Create veth pairs and move one end into each container
ip link del "$UPF_HOST_PORT" 2>/dev/null || true
ip link del "$EDN_HOST_PORT" 2>/dev/null || true
ip link add veth-upf type veth peer name "$UPF_HOST_PORT"
ip link add veth-edn type veth peer name "$EDN_HOST_PORT"

ip link set veth-upf netns "$UPF_PID"
ip link set veth-edn netns "$EDN_PID"
nsenter -t "$UPF_PID" -n ip link set veth-upf name "$UPF_CNT_IF"
nsenter -t "$EDN_PID" -n ip link set veth-edn name "$EDN_CNT_IF"
nsenter -t "$UPF_PID" -n ip link set "$UPF_CNT_IF" up
nsenter -t "$EDN_PID" -n ip link set "$EDN_CNT_IF" up

# Attach the host ends to the bridge
ip link set "$UPF_HOST_PORT" up
ip link set "$EDN_HOST_PORT" up
ovs-vsctl --may-exist add-port "$BR" "$UPF_HOST_PORT"
ovs-vsctl --may-exist add-port "$BR" "$EDN_HOST_PORT"

# Move the N6 IPs from the old NICs onto the new ones
UPF_OLD_IP=$(nsenter -t "$UPF_PID" -n bash -lc "ip -o -4 addr show $UPF_N6_IF | awk '{print \$4}' || true")
EDN_OLD_IP=$(nsenter -t "$EDN_PID" -n bash -lc "ip -o -4 addr show $EDN_IF    | awk '{print \$4}' || true")
if [ -n "$UPF_OLD_IP" ]; then
  nsenter -t "$UPF_PID" -n bash -lc "ip addr del $UPF_OLD_IP dev $UPF_N6_IF || true; ip addr add $UPF_OLD_IP dev $UPF_CNT_IF"
fi
if [ -n "$EDN_OLD_IP" ]; then
  nsenter -t "$EDN_PID" -n bash -lc "ip addr del $EDN_OLD_IP dev $EDN_IF || true; ip addr add $EDN_OLD_IP dev $EDN_CNT_IF"
fi

# (Optional) down the old links
nsenter -t "$UPF_PID" -n ip link set "$UPF_N6_IF" down || true
nsenter -t "$EDN_PID" -n ip link set "$EDN_IF" down || true

echo "[ovs-init] Bridge and wiring completed. Controller: $ONOS_CTRL"
ovs-vsctl show
tail -f /dev/null
SH
chmod +x ovs-init.sh
