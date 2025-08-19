#!/usr/bin/env bash
set -euo pipefail

# 1) Bridge and controller
ovs-vsctl --may-exist add-br br-n6
ovs-vsctl set-fail-mode br-n6 secure
ovs-vsctl set-controller br-n6 tcp:${ONOS_CTRL:-127.0.0.1:6653}

# 2) Replace existing N6 links with OVS-backed ports
#    We down/flush the old Docker NICs to avoid duplicate IPs,
#    then add OVS ports inside the same containers with the SAME IPs.
docker exec ${UPF_CONT} ip addr flush dev ${UPF_N6_IF} || true
docker exec ${UPF_CONT} ip link set  ${UPF_N6_IF} down || true
docker exec ${EDN_CONT} ip addr flush dev ${EDN_IF}    || true
docker exec ${EDN_CONT} ip link set  ${EDN_IF} down    || true

# Use the ovs-docker helper shipped in this image
OVSDOCKER=/usr/share/openvswitch/scripts/ovs-docker

# UPF N6 → br-n6 (keep IP 192.168.72.134/26)
${OVSDOCKER} del-port br-n6 n6-upf ${UPF_CONT} || true
${OVSDOCKER} add-port br-n6 n6-upf ${UPF_CONT} --ipaddress=192.168.72.134/26

# Ext-DN → br-n6 (keep IP 192.168.72.135/26)
${OVSDOCKER} del-port br-n6 n6-edn ${EDN_CONT} || true
${OVSDOCKER} add-port br-n6 n6-edn ${EDN_CONT} --ipaddress=192.168.72.135/26

echo "OVS br-n6 up, UPF_N6 <-> Ext-DN connected, controller ${ONOS_CTRL}"
