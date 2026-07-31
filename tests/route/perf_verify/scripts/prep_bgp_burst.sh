#!/usr/bin/env bash
#
# PEER-side helper for the "BGP announce -> ASIC programming latency" test.
# Run this ON THE BGP PEER (the box that advertises to the DUT), not on the DUT.
#
# Why this exists: announcing a large route set by feeding N 'ip route' lines
# into vtysh does NOT produce a burst. vtysh parses line by line, zebra installs
# line by line, and on a SONiC peer fpmsyncd then programs each one into the
# peer's own ASIC -- a few hundred to a couple of thousand prefixes per second.
# bgpd redistributes them as they appear, so the DUT sees a slow trickle and any
# "time to program N routes" measured on the DUT is really the PEER's rate.
#
# So we separate the two costs:
#
#   prepare  -- slow, and deliberately OUTSIDE the measured window: install an
#               outbound deny for the test block, then preload the statics.
#               bgpd learns all N prefixes and holds them in the adj-rib-out,
#               advertising nothing.
#   release  -- the trigger, two vtysh commands: drop the outbound filter and
#               'clear ip bgp <dut> soft out'. bgpd re-runs outbound policy over
#               a table it already has and writes the whole set out back-to-back.
#               N prefixes leave in seconds, which is the burst the test needs.
#   withdraw -- re-apply the filter + soft out: all N prefixes are withdrawn in
#               one burst too, so the withdraw window is measurable the same way.
#   cleanup  -- remove the statics and all config this script added.
#
#   ./prep_bgp_burst.sh prepare  --dut-ip 10.0.0.0 --asn 65100 --count 30000
#   ./prep_bgp_burst.sh release  --dut-ip 10.0.0.0 --asn 65100
#   ./prep_bgp_burst.sh withdraw --dut-ip 10.0.0.0 --asn 65100
#   ./prep_bgp_burst.sh cleanup  --dut-ip 10.0.0.0 --asn 65100 --count 30000
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION=""
DUT_IP=""
ASN=""
COUNT=30000
BASE="10.0.0.0"
VTYSH=""               # empty = auto-detect frr-vtysh / vtysh (--vtysh to override)
CHUNK=5000             # statics per vtysh transaction during preload
SKIP_VERIFY=0
PL="PL_PERF_BURST"
RM="RM_PERF_BURST"
MARKER="/tmp/.perf_burst_added_redistribute"

[ $# -gt 0 ] || { echo "usage: $0 {prepare|release|withdraw|status|cleanup} [opts]" >&2; exit 1; }
ACTION="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --dut-ip) DUT_IP="$2"; shift 2;;
        --asn) ASN="$2"; shift 2;;
        --count) COUNT="$2"; shift 2;;
        --base) BASE="$2"; shift 2;;
        --vtysh) VTYSH="$2"; shift 2;;
        --chunk) CHUNK="$2"; shift 2;;
        --skip-verify) SKIP_VERIFY=1; shift;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done
case "$ACTION" in
    prepare|release|withdraw|status|cleanup) ;;
    *) echo "unknown action '$ACTION'" >&2; exit 1;;
esac
[ -n "$DUT_IP" ] || { echo "ERROR: --dut-ip <DUT's BGP session address> required" >&2; exit 1; }
[ -n "$ASN" ] || { echo "ERROR: --asn <this peer's local AS> required" >&2; exit 1; }

# A SONiC peer ships 'frr-vtysh' (execs into the bgp container), not 'vtysh';
# calling the wrong one silently does nothing here. Auto-detect unless overridden.
if [ -z "$VTYSH" ]; then
    if command -v frr-vtysh >/dev/null 2>&1; then
        VTYSH="frr-vtysh"
    else
        VTYSH="vtysh"
    fi
fi
echo "vtysh command: $VTYSH" >&2

vt() { $VTYSH "$@"; }
vtc() {  # vtc <cmd>... -- run config commands in one vtysh invocation
    local args=()
    for c in "$@"; do args+=(-c "$c"); done
    vt "${args[@]}" >/dev/null
}

# The smallest prefix that covers base .. base+count-1, so the outbound filter
# matches exactly the test block and leaves the peer's real advertisements alone.
covering_block() {
    python3 - "$BASE" "$COUNT" <<'PY'
import ipaddress, sys
base = ipaddress.ip_address(sys.argv[1])
last = base + int(sys.argv[2]) - 1
net = [n for n in ipaddress.summarize_address_range(base, last)]
# summarize_address_range gives an exact cover as several nets; take the
# supernet that contains all of them so a single prefix-list entry suffices.
sup = net[0]
while not all(n.subnet_of(sup) for n in net):
    sup = sup.supernet()
print(sup.with_prefixlen)
PY
}

case "$ACTION" in

prepare)
    [ -f "$HERE/gen_frr_routes.py" ] || {
        echo "ERROR: $HERE/gen_frr_routes.py missing -- copy the WHOLE scripts/ dir here." >&2
        exit 1
    }
    BLOCK="$(covering_block)"
    echo "=== prepare: $COUNT statics from $BASE, filtered block $BLOCK, peer AS $ASN -> DUT $DUT_IP ==="

    # If this peer is itself a SONiC box, every static also lands in ITS ASIC via
    # fpmsyncd and eats ITS route-table budget. Overrunning it silently truncates
    # the set the DUT is supposed to receive, which looks like a DUT problem.
    if command -v crm >/dev/null 2>&1; then
        AVAIL="$(crm show resources 2>/dev/null | awk '/ipv4_route/ {print $NF}' | head -1)"
        case "$AVAIL" in (*[!0-9]*|"") AVAIL="";; esac
        if [ -n "$AVAIL" ]; then
            echo "peer's own ipv4_route headroom: $AVAIL"
            if [ "$AVAIL" -lt "$COUNT" ]; then
                echo "ERROR: this peer can only take $AVAIL more routes but the test needs" >&2
                echo "$COUNT. The statics are programmed into THIS box's ASIC too, so the" >&2
                echo "set would be truncated before it is ever advertised. Lower --count or" >&2
                echo "originate from a peer without a hardware FIB." >&2
                exit 1
            fi
        fi
    fi

    # 1) outbound deny for the test block only -- everything else this peer
    #    normally advertises keeps flowing, so the DUT's table is undisturbed.
    vtc "configure terminal" \
        "ip prefix-list $PL seq 10 permit $BLOCK le 32" \
        "route-map $RM deny 10" \
        "match ip address prefix-list $PL" \
        "exit" \
        "route-map $RM permit 20" \
        "exit" \
        "router bgp $ASN" \
        "address-family ipv4 unicast" \
        "neighbor $DUT_IP route-map $RM out" \
        "exit" \
        "exit" \
        "end"
    # advertisement-interval 0: MRAI would otherwise chop the release burst into
    # timer-spaced chunks and the arrival window would measure the timer.
    vtc "configure terminal" "router bgp $ASN" \
        "neighbor $DUT_IP advertisement-interval 0" "end"
    vt -c "clear ip bgp $DUT_IP soft out" >/dev/null
    echo ">> outbound filter armed ($RM: deny $BLOCK, permit the rest)"

    # 2) redistribute static, remembering whether we are the ones who added it
    if ! vt -c "show running-config" 2>/dev/null | grep -q "^ *redistribute static"; then
        vtc "configure terminal" "router bgp $ASN" "address-family ipv4 unicast" \
            "redistribute static" "end"
        : > "$MARKER"
        echo ">> enabled 'redistribute static' (will be removed by cleanup)"
    fi

    # 3) preload the statics. Slow on purpose -- it is outside the window.
    echo ">> preloading $COUNT statics in chunks of $CHUNK (this is the slow part)"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    python3 "$HERE/gen_frr_routes.py" add --count "$COUNT" --base "$BASE" \
        | grep -v -e '^configure terminal$' -e '^end$' > "$TMP/all"
    split -l "$CHUNK" -d "$TMP/all" "$TMP/chunk."
    T0=$(date +%s)
    n=0
    for f in "$TMP"/chunk.*; do
        { echo "configure terminal"; cat "$f"; echo "end"; } | vt >/dev/null
        n=$((n + $(wc -l < "$f")))
        printf "   %d/%d statics loaded (%ss)\n" "$n" "$COUNT" "$(( $(date +%s) - T0 ))"
    done
    echo ">> preload done in $(( $(date +%s) - T0 ))s"

    # 4) verify the peer really holds the whole set and is advertising none of it
    if [ "$SKIP_VERIFY" -eq 0 ]; then
        STATIC_N="$(vt -c "show ip route summary" 2>/dev/null | awk '/^static/ {print $2}' | head -1)"
        echo ">> peer RIB statics: ${STATIC_N:-unknown} (expected $COUNT)"
        ADV_N="$(vt -c "show ip bgp neighbor $DUT_IP advertised-routes" 2>/dev/null \
                 | awk '/^Total number of prefixes/ {print $NF}' | head -1)"
        echo ">> currently advertised to $DUT_IP: ${ADV_N:-unknown} prefixes"
        echo "   (the test block must NOT be in there yet -- check the DUT's PfxRcd)"
    fi
    echo "=== armed. Now run run_bgp_latency.sh on the DUT; it will call 'release'. ==="
    ;;

release)
    # THE TRIGGER. Two commands, both O(1) in the route count: bgpd already has
    # the prefixes, it only has to re-run outbound policy and write them out.
    vtc "configure terminal" "router bgp $ASN" "address-family ipv4 unicast" \
        "no neighbor $DUT_IP route-map $RM out" "end"
    echo "RELEASE_EPOCH=$(date +%s.%N)"
    vt -c "clear ip bgp $DUT_IP soft out" >/dev/null
    echo "released: $DUT_IP now receives the full table in one burst"
    ;;

withdraw)
    # Re-arming the filter withdraws the whole block in one burst -- the mirror
    # image of release, and far closer to a real convergence event than
    # 'no ip route' x N.
    vtc "configure terminal" "router bgp $ASN" "address-family ipv4 unicast" \
        "neighbor $DUT_IP route-map $RM out" "end"
    echo "WITHDRAW_EPOCH=$(date +%s.%N)"
    vt -c "clear ip bgp $DUT_IP soft out" >/dev/null
    echo "withdrawn: the test block is filtered out again"
    ;;

status)
    echo "--- route-map/prefix-list ---"
    vt -c "show running-config" 2>/dev/null | grep -E "$RM|$PL|redistribute static" || echo "(none)"
    echo "--- RIB ---"
    vt -c "show ip route summary" 2>/dev/null | sed -n '1,12p'
    echo "--- advertised to $DUT_IP ---"
    vt -c "show ip bgp neighbor $DUT_IP advertised-routes" 2>/dev/null | tail -3
    ;;

cleanup)
    echo "=== cleanup: removing $COUNT statics and the burst config ==="
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    python3 "$HERE/gen_frr_routes.py" del --count "$COUNT" --base "$BASE" \
        | grep -v -e '^configure terminal$' -e '^end$' > "$TMP/all"
    split -l "$CHUNK" -d "$TMP/all" "$TMP/chunk."
    for f in "$TMP"/chunk.*; do
        { echo "configure terminal"; cat "$f"; echo "end"; } | vt >/dev/null
    done
    vtc "configure terminal" "router bgp $ASN" "address-family ipv4 unicast" \
        "no neighbor $DUT_IP route-map $RM out" "end" || true
    if [ -f "$MARKER" ]; then
        vtc "configure terminal" "router bgp $ASN" "address-family ipv4 unicast" \
            "no redistribute static" "end" || true
        rm -f "$MARKER"
    fi
    vtc "configure terminal" "no route-map $RM" "no ip prefix-list $PL" "end" || true
    vt -c "clear ip bgp $DUT_IP soft out" >/dev/null || true
    echo ">> cleaned. Confirm with: $0 status --dut-ip $DUT_IP --asn $ASN"
    ;;
esac
