#!/usr/bin/env bash
#
# DUT-side orchestrator for the "BGP announce -> ASIC programming latency" test.
#
# Measures how long after the DUT RECEIVES a mass BGP announcement the routes
# are actually in the ASIC -- i.e. the whole pipeline
#
#   peer bgpd -> [wire] -> DUT bgpd -> zebra -> fpmsyncd -> (APPL_DB | ZMQ)
#              -> orchagent -> sairedis -> ASIC_DB
#
# and not just the orchagent-internal window that run_perf.sh / run_t2_bgp.sh
# report. The clock starts on the wire (tcpdump, kernel timestamp of the first
# BGP UPDATE from the peer) and stops at the last SAI route create for the
# announced set (sairedis.rec). Both anchors are passive, so the measurement
# does not depend on how fast this script polls anything.
#
# The peer must be armed first, ON THE PEER:
#     ./prep_bgp_burst.sh prepare --dut-ip <DUT session IP> --asn <PEER_AS> \
#                                 --count 30000 --base 10.0.0.0
# then, on the DUT:
#     ./run_bgp_latency.sh --peer admin@10.0.0.1 --peer-ip 10.0.0.1 \
#         --dut-ip 10.0.0.0 --peer-asn 65100 --count 30000 --out /tmp/bgpperf
#
# --no-trigger runs it manually (it prints what to run on the peer and waits).
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

REC="/var/log/swss/sairedis.rec"
PEER=""              # ssh target of the peer, e.g. admin@10.0.0.1
PEER_IP=""           # peer's BGP session address, as seen by the DUT
DUT_IP=""            # DUT's BGP session address, as seen by the peer
PEER_ASN=""
PEER_SCRIPTS="~/perf_verify/scripts"   # where prep_bgp_burst.sh lives on the peer
COUNT=30000
BASE="10.0.0.0"
IFACE="any"
NETNS=""             # multi-asic: asic0, asic1, ...
CONTAINER="swss"
VTYSH=""             # vtysh command; empty = auto-detect frr-vtysh / vtysh
OUT="/tmp/bgpperf"
POLL=2               # ASIC_DB poll interval (completion detection ONLY)
STABLE=10            # wall-clock seconds of no progress => finished/stalled
CEILING=1800         # wall-clock seconds before giving up
MAX_ROUTES=32000
STATS=""
NO_TRIGGER=0
MEASURE_WITHDRAW=0
MIN_UPDATE_LEN=60

while [ $# -gt 0 ]; do
    case "$1" in
        --peer) PEER="$2"; shift 2;;
        --peer-ip) PEER_IP="$2"; shift 2;;
        --dut-ip) DUT_IP="$2"; shift 2;;
        --peer-asn) PEER_ASN="$2"; shift 2;;
        --peer-scripts) PEER_SCRIPTS="$2"; shift 2;;
        --count) COUNT="$2"; shift 2;;
        --base) BASE="$2"; shift 2;;
        --iface) IFACE="$2"; shift 2;;
        --netns) NETNS="$2"; shift 2;;
        --container) CONTAINER="$2"; shift 2;;
        --vtysh) VTYSH="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        --poll) POLL="$2"; shift 2;;
        --stable) STABLE="$2"; shift 2;;
        --ceiling) CEILING="$2"; shift 2;;
        --max-routes) MAX_ROUTES="$2"; shift 2;;
        --recfile) REC="$2"; shift 2;;
        --stats) STATS="$2"; shift 2;;
        --min-update-len) MIN_UPDATE_LEN="$2"; shift 2;;
        --no-trigger) NO_TRIGGER=1; shift;;
        --measure-withdraw) MEASURE_WITHDRAW=1; shift;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done
[ -n "$PEER_IP" ] || { echo "ERROR: --peer-ip <peer's BGP session address> required" >&2; exit 1; }
if [ "$NO_TRIGGER" -eq 0 ]; then
    [ -n "$PEER" ] && [ -n "$DUT_IP" ] && [ -n "$PEER_ASN" ] || {
        echo "ERROR: --peer, --dut-ip and --peer-asn are required unless --no-trigger." >&2
        exit 1
    }
fi

# vtysh command name varies by image: stock SONiC ships 'vtysh' on the host,
# but this QUANTA image (and the rest of this toolkit -- gen_frr_routes.py,
# run_t2_bgp.sh) uses 'frr-vtysh', a wrapper that execs into the bgp container.
# Calling the wrong one returns nothing, and pfx_rcd then reads an empty string
# as -1 and aborts with a bogus "no established session". Auto-detect it.
if [ -z "$VTYSH" ]; then
    if command -v frr-vtysh >/dev/null 2>&1; then
        VTYSH="frr-vtysh"
    else
        VTYSH="vtysh"
    fi
fi

# Namespace flags differ per tool: sonic-db-cli takes the namespace NAME
# (-n asic0), plain vtysh takes the asic INDEX (-n 0), and tcpdump has to be run
# inside the netns. Getting these mixed up silently reads the wrong ASIC.
NS_ARG=""; NS_EXEC=""; VTYSH_CMD="$VTYSH"
if [ -n "$NETNS" ]; then
    NS_ARG="-n $NETNS"
    NS_EXEC="ip netns exec $NETNS"   # no sudo: we already exec under sudo sh -c
    case "$VTYSH" in
        vtysh) VTYSH_CMD="vtysh -n ${NETNS#asic}";;
        *) echo "NOTE: multi-asic with '$VTYSH'; if PfxRcd reads wrong, pass the" >&2
           echo "      namespaced command explicitly: --vtysh 'vtysh -n ${NETNS#asic}'." >&2;;
    esac
fi
echo "vtysh command: $VTYSH_CMD"

mkdir -p "$OUT"

asic_route_count() {
    # Server-side EVAL, not 'keys | wc -l': KEYS already scans the whole ASIC_DB
    # keyspace inside single-threaded redis, and shipping ~30k key names to the
    # client on every poll adds megabytes of traffic to the very redis instance
    # orchagent is writing through. Same call sonic-mgmt's asic.count_routes uses.
    local c
    c="$(sonic-db-cli $NS_ARG ASIC_DB eval \
         "return #redis.call('keys', 'ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*')" 0 \
         2>/dev/null | tr -dc '0-9')"
    echo "${c:-0}"
}

# Prefixes this peer has advertised to us.
#   >= 0  : session Established -- the value is PfxRcd (0 is valid: nothing
#           advertised yet, which is exactly the pre-release state)
#   -1    : no such peer, session not Established, or vtysh gave no JSON
pfx_rcd() {
    local n
    n="$(python3 "$HERE/bgp_peer_pfx.py" --peer-ip "$PEER_IP" \
         ${NETNS:+--netns "$NETNS"} ${VTYSH:+--vtysh "$VTYSH"} 2>/dev/null)"
    case "$n" in
        ''|*[!0-9-]*) echo -1;;
        *) echo "$n";;
    esac
}

require_helper() {  # require_helper <script> <flag-it-must-support>
    local script="$1" flag="$2"
    [ -f "$HERE/$script" ] || {
        echo "ERROR: $HERE/$script is missing -- copy the WHOLE scripts/ dir to this DUT." >&2
        exit 1
    }
    python3 "$HERE/$script" --help 2>/dev/null | grep -q -- "$flag" || {
        echo "ERROR: $HERE/$script is older than this orchestrator (no '$flag')." >&2
        exit 1
    }
}

echo "=== preflight ==="
require_helper bgp_latency_report.py --tcpdump
require_helper measure_route_time.py --op
require_helper bgp_peer_pfx.py --peer-ip
[ -z "$STATS" ] || require_helper sample_proc_cpu.py --out
[ -x "$HERE/check_clock_skew.sh" ] || {
    echo "ERROR: $HERE/check_clock_skew.sh is missing or not executable --" >&2
    echo "copy the WHOLE scripts/ dir to this DUT." >&2
    exit 1
}

# 1) clocks. tcpdump timestamps come from the host kernel; sairedis.rec
# timestamps are local-time strings written inside the swss container. If the
# two disagree on the clock OR the timezone every stage number is nonsense --
# and the failure is silent (a big constant offset just looks like a slow DUT).
# Here the stakes are higher than for the other orchestrators: T0 comes from
# tcpdump (host kernel) and T1 from sairedis.rec (written in the container), so
# a skew does not just mis-scope the window, it offsets the headline latency.
"$HERE/check_clock_skew.sh" "$CONTAINER"

# 2) route-ZMQ flag: not a gate here (this test works on both paths), but the
# result must be labelled with it or the two pipelines get compared by accident.
ZMQ_FLAG="$(sonic-db-cli $NS_ARG CONFIG_DB hget "DEVICE_METADATA|localhost" \
            orch_northbond_route_zmq_enabled 2>/dev/null || true)"
[ "$ZMQ_FLAG" = "true" ] || ZMQ_FLAG="false"
echo "route ZMQ flag: $ZMQ_FLAG"

# 3) BGP session and how many prefixes we already have from this peer
PFX_BASE="$(pfx_rcd)"
echo "PfxRcd from $PEER_IP before the run: $PFX_BASE"
if [ "$PFX_BASE" -lt 0 ]; then
    echo "ERROR: no established ipv4 session with $PEER_IP (show bgp ipv4 unicast summary)." >&2
    exit 1
fi

# 4) ASIC route-table headroom. Overshooting is silent: the count just stops
# advancing and every latency number computed off the truncated batch is void.
#
# Ask CRM first -- it is the hardware's own accounting of the ipv4_route table,
# so it knows the real ceiling. --max-routes is only a static guess and is used
# as a fallback when CRM is unreadable. Note the ASIC_DB ROUTE_ENTRY count
# (below) spans v4 AND v6 plus system routes, so it is NOT comparable to the
# ipv4_route budget -- it is recorded as the run's baseline, not as the gate.
ASIC_BASE="$(asic_route_count)"
CRM_LINE="$(crm show resources 2>/dev/null | awk '/ipv4_route/ {print; exit}')"
CRM_USED="$(echo "$CRM_LINE" | awk '{print $2}')"
CRM_AVAIL="$(echo "$CRM_LINE" | awk '{print $NF}')"
case "$CRM_USED"  in (*[!0-9]*|"") CRM_USED="";;  esac
case "$CRM_AVAIL" in (*[!0-9]*|"") CRM_AVAIL="";; esac

echo "ASIC_DB route entries (v4+v6+system): $ASIC_BASE"
if [ -n "$CRM_AVAIL" ] && [ -n "$CRM_USED" ]; then
    echo "CRM ipv4_route: used $CRM_USED, available $CRM_AVAIL (hardware ceiling $((CRM_USED + CRM_AVAIL)))"
    if [ "$COUNT" -gt "$CRM_AVAIL" ]; then
        echo "ERROR: announcing $COUNT ipv4 routes but only $CRM_AVAIL fit in the ASIC." >&2
        echo "The table would fill mid-run and every latency number would be measured" >&2
        echo "over a truncated batch. Either:" >&2
        echo "  * lower the scale on BOTH sides: --count $CRM_AVAIL or less (and the same" >&2
        echo "    --count on the peer's 'prep_bgp_burst.sh prepare')" >&2
        echo "  * or clear leftover test routes first, then re-run" >&2
        echo "(CRM polls every 'crm config polling interval' seconds -- if you just" >&2
        echo "cleared routes, this number may be stale by up to that long.)" >&2
        exit 1
    fi
else
    echo "CRM ipv4_route unreadable -- falling back to the --max-routes guess ($MAX_ROUTES)"
    if [ "$((ASIC_BASE + COUNT))" -gt "$MAX_ROUTES" ]; then
        echo "ERROR: $ASIC_BASE existing + $COUNT announced = $((ASIC_BASE + COUNT)), over the" >&2
        echo "assumed ceiling of $MAX_ROUTES. Check the real limit with" >&2
        echo "'crm show resources | grep ipv4_route', then lower --count (to at most" >&2
        echo "$((MAX_ROUTES - ASIC_BASE)) here), clear leftovers, or raise --max-routes." >&2
        exit 1
    fi
fi

# 5) sairedis.rec rotation. The analyzer stitches rotated siblings, but a
# segment deleted under disk pressure loses prefixes and shows up as a low
# match count -- warn now rather than after the run.
REC_SZ=$(stat -c %s "$REC" 2>/dev/null || echo 0)
echo "sairedis.rec size: $((REC_SZ / 1024)) KiB (logrotate fires every 10 min at 1M/16M)"

# --- collectors -------------------------------------------------------------
TCPDUMP_PID_FILE="$OUT/tcpdump.pid"
SAMPLER_PID=""
CAPTURE_STARTED=0

stop_capture() {
    [ "$CAPTURE_STARTED" -eq 1 ] || return 0
    CAPTURE_STARTED=0
    if [ -s "$TCPDUMP_PID_FILE" ]; then
        sudo kill -INT "$(cat "$TCPDUMP_PID_FILE")" 2>/dev/null || true
        sleep 1
    fi
}
cleanup() {
    stop_capture
    if [ -n "$SAMPLER_PID" ]; then
        kill "$SAMPLER_PID" 2>/dev/null || true
        wait "$SAMPLER_PID" 2>/dev/null || true
        python3 "$HERE/sample_proc_cpu.py" summarize --out "$STATS" || true
    fi
}
trap cleanup EXIT

start_capture() {  # start_capture <outfile>
    local txt="$1"
    : > "$txt"
    # -s 96: we only need timestamps and payload sizes, so do not copy full
    # UPDATE packets through the ring buffer.
    # Filter on the peer as SOURCE so only peer->DUT traffic is timestamped,
    # whichever side of the session owns port 179.
    sudo sh -c "echo \$\$ > $TCPDUMP_PID_FILE; exec $NS_EXEC tcpdump -i $IFACE -nn -q -tt -l \
        -s 96 'src host $PEER_IP and tcp port 179' > $txt 2> $OUT/tcpdump.err" &
    CAPTURE_STARTED=1
    local waited=0
    until grep -q "listening on" "$OUT/tcpdump.err" 2>/dev/null; do
        sleep 1; waited=$((waited + 1))
        if [ "$waited" -ge 15 ]; then
            echo "ERROR: tcpdump did not start:" >&2; cat "$OUT/tcpdump.err" >&2; exit 1
        fi
    done
    sleep 1   # let the BPF filter settle before the peer is told to go
}

# wait_done <target-count> <cmp ge|le> <csv>
# Wall-clock idle detection. The poll only decides WHEN TO STOP; the reported
# latency comes from the capture and sairedis.rec, so a slow poll cannot inflate
# it (and a fast poll cannot perturb it, since we go through EVAL not KEYS).
wait_done() {
    local target="$1" cmp="$2" csv="$3"
    local last=-1 idle_start=0 cur now start
    start=$(date +%s)
    while :; do
        cur="$(asic_route_count)"
        printf "%s,%s\n" "$(date +%s.%N)" "$cur" >> "$csv"
        now=$(date +%s)
        printf "  count=%s target%s%s  elapsed=%ss\n" "$cur" "$cmp" "$target" "$((now - start))"
        if [ "$cmp" = "ge" ] && [ "$cur" -ge "$target" ]; then return 0; fi
        if [ "$cmp" = "le" ] && [ "$cur" -le "$target" ]; then return 0; fi
        if [ "$cur" -eq "$last" ]; then
            [ "$idle_start" -eq 0 ] && idle_start=$now
            if [ "$((now - idle_start))" -ge "$STABLE" ]; then
                echo "  !! no progress for ${STABLE}s at $cur -- stopping (batch incomplete)" >&2
                return 1
            fi
        else
            idle_start=0
        fi
        last=$cur
        if [ "$((now - start))" -ge "$CEILING" ]; then
            echo "  !! ceiling ${CEILING}s reached at $cur -- stopping" >&2
            return 1
        fi
        sleep "$POLL"
    done
}

if [ -n "$STATS" ]; then
    mkdir -p "$STATS"
    python3 "$HERE/sample_proc_cpu.py" record --out "$STATS" &
    SAMPLER_PID=$!
    echo "CPU sampler running (pid $SAMPLER_PID) -> $STATS"
fi

# --- announce run -----------------------------------------------------------
echo
echo "=== announce run (zmq=$ZMQ_FLAG, $COUNT prefixes from $BASE) ==="
CSV="$OUT/asic_count_add.csv"
: > "$CSV"
start_capture "$OUT/bgp_add.txt"
printf "%s,%s\n" "$(date +%s.%N)" "$ASIC_BASE" >> "$CSV"

MARK="$(date +"%Y-%m-%d.%H:%M:%S.%6N")"
if [ "$NO_TRIGGER" -eq 1 ]; then
    echo ">> On the peer, run:"
    echo "     ./prep_bgp_burst.sh release --dut-ip <DUT_IP> --asn <PEER_AS>"
    read -p "   Press Enter once you have released..." _
else
    echo ">> Releasing the burst on $PEER"
    ssh "$PEER" "$PEER_SCRIPTS/prep_bgp_burst.sh release --dut-ip $DUT_IP --asn $PEER_ASN" \
        | tee "$OUT/release.log"
fi

wait_done "$((ASIC_BASE + COUNT))" ge "$CSV" || true
stop_capture

PFX_AFTER="$(pfx_rcd)"
ASIC_AFTER="$(asic_route_count)"
echo ">> PfxRcd $PFX_BASE -> $PFX_AFTER (delta $((PFX_AFTER - PFX_BASE)), expected $COUNT)"
echo ">> ASIC   $ASIC_BASE -> $ASIC_AFTER (delta $((ASIC_AFTER - ASIC_BASE)), expected $COUNT)"
if [ "$((PFX_AFTER - PFX_BASE))" -lt "$COUNT" ]; then
    echo "!! The DUT's bgpd never received the whole set: an inbound route-map/prefix" >&2
    echo "   filter, maximum-prefix, or a peer that did not finish preloading." >&2
    echo "   Fix that first -- the ASIC numbers below cannot be better than this." >&2
fi

echo
python3 "$HERE/bgp_latency_report.py" --rec "$REC" --since "$MARK" --op create \
    --tcpdump "$OUT/bgp_add.txt" --min-update-len "$MIN_UPDATE_LEN" \
    --base "$BASE" --count "$COUNT" --samples "$CSV" \
    --json "$OUT/result_add.json" || ADD_RC=$?
echo "(artifacts in $OUT)"

# --- withdraw run -----------------------------------------------------------
if [ "$MEASURE_WITHDRAW" -eq 1 ]; then
    echo
    echo "=== withdraw run (zmq=$ZMQ_FLAG) ==="
    CSV="$OUT/asic_count_del.csv"
    : > "$CSV"
    start_capture "$OUT/bgp_del.txt"
    printf "%s,%s\n" "$(date +%s.%N)" "$(asic_route_count)" >> "$CSV"

    DEL_MARK="$(date +"%Y-%m-%d.%H:%M:%S.%6N")"
    if [ "$NO_TRIGGER" -eq 1 ]; then
        echo ">> On the peer, run:"
        echo "     ./prep_bgp_burst.sh withdraw --dut-ip <DUT_IP> --asn <PEER_AS>"
        read -p "   Press Enter once you have withdrawn..." _
    else
        echo ">> Withdrawing on $PEER"
        ssh "$PEER" "$PEER_SCRIPTS/prep_bgp_burst.sh withdraw --dut-ip $DUT_IP --asn $PEER_ASN" \
            | tee "$OUT/withdraw.log"
    fi

    wait_done "$ASIC_BASE" le "$CSV" || true
    stop_capture

    echo ">> ASIC back to $(asic_route_count) (base was $ASIC_BASE)"
    echo
    python3 "$HERE/bgp_latency_report.py" --rec "$REC" --since "$DEL_MARK" --op remove \
        --tcpdump "$OUT/bgp_del.txt" --min-update-len "$MIN_UPDATE_LEN" \
        --base "$BASE" --count "$COUNT" --samples "$CSV" \
        --json "$OUT/result_del.json" || true
fi

echo
echo "=== done. Repeat >= 3 times and discard the first (cold) run before quoting. ==="
exit "${ADD_RC:-0}"
