# shellcheck shell=bash
# Sourced by the multi-VM QEMU checks (dogfood-homelab-cluster.sh,
# dogfood-homelab-installer.sh): one L2 segment on the host for their guests.
#
#   lan_start <state dir> <port>  start the switch and the user-net router;
#                                 DOGFOOD_DNS=<ip> gives the router's DNS proxy
#                                 that resolver
#   lan_stop                      stop both (call it from the caller's EXIT trap)
#   nic <mac suffix>              QEMU arguments for a guest NIC on the segment
#                                 (52:54:00:b1:00:<suffix>)
#
# The segment is a small learning switch on the host speaking QEMU's stream
# netdev framing (4-byte length + Ethernet frame over TCP): unicast goes to
# the port that owns the destination MAC, the rest is flooded, and a frame
# for a guest that is not reading (still in firmware) is dropped rather than
# stalling the segment. user-net (DHCP, DNS, NAT, the host's HTTP servers at
# 10.0.2.2) is one more port, from a QEMU without a machine, so it only sees
# frames meant for it.

lan_start() {
    local state="$1"
    switch_port="$2"
    python3 - "${switch_port}" > "${state}/switch.log" 2>&1 <<'SWITCH' &
import asyncio, struct, sys
ports, macs = set(), {}
def send(writer, data):
    if writer.transport.get_write_buffer_size() < (1 << 20):
        writer.write(data)
async def port(reader, writer):
    ports.add(writer)
    try:
        while True:
            head = await reader.readexactly(4)
            frame = await reader.readexactly(struct.unpack(">I", head)[0])
            macs[frame[6:12]] = writer
            out = macs.get(frame[0:6]) if not frame[0] & 1 else None
            for other in [out] if out in ports else list(ports):
                if other is not writer:
                    send(other, head + frame)
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        ports.discard(writer)
        writer.close()
async def main():
    server = await asyncio.start_server(port, "127.0.0.1", int(sys.argv[1]))
    async with server:
        await server.serve_forever()
asyncio.run(main())
SWITCH
    switch_pid=$!
    # A stream netdev that finds nothing listening at start does not retry.
    for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/${switch_port}") 2>/dev/null && break; sleep 0.2; done
    read -r -a router_args <<<"$(seg sw)"
    # shellcheck disable=SC2054 # commas belong to the QEMU options
    router=(qemu-system-x86_64 -machine none -nodefaults -display none -monitor none
        -netdev user,id=u0 -netdev hubport,id=hu,hubid=0,netdev=u0
        "${router_args[@]}" -netdev hubport,id=hs,hubid=0,netdev=sw)
    if [ -n "${DOGFOOD_DNS:-}" ]; then
        # user-net's DNS proxy (10.0.2.3) forwards to the host's resolv.conf,
        # and statically linked guest programs (containerd) ask it first; give
        # it DOGFOOD_DNS in a private mount namespace.
        printf 'nameserver %s\n' "${DOGFOOD_DNS}" > "${state}/router-resolv.conf"
        # shellcheck disable=SC2016 # $0 and $@ belong to the inner sh
        router=(unshare -rm sh -c 'mount --bind "$0" /etc/resolv.conf && exec "$@"' "${state}/router-resolv.conf" "${router[@]}")
    fi
    "${router[@]}" > "${state}/router.log" 2>&1 &
    router_pid=$!
}

lan_stop() {
    kill "${router_pid:-}" "${switch_pid:-}" 2>/dev/null || true
}

seg() { printf -- '-netdev stream,id=%s,server=off,reconnect-ms=1000,addr.type=inet,addr.host=127.0.0.1,addr.port=%s' "$1" "${switch_port}"; }
nic() { printf -- '%s -device virtio-net-pci,netdev=sw,mac=52:54:00:b1:00:%s' "$(seg sw)" "$1"; }
