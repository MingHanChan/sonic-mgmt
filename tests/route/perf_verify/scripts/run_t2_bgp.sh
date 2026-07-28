#!/usr/bin/env bash
#
# BGP-feed orchestrator: measure the ASIC route-programming window T for the
# end-to-end path (BGP peer -> zebra -> fpmsyncd -> orchagent). Used for BOTH:
#
#   T1b  route ZMQ DISABLED  (same feed, classic Redis path)   --require-zmq false
#   T2   route ZMQ ENABLED   (fpmsyncd -> orchagent over ZMQ)  --require-zmq true
#
# Comparing T2 against T1b isolates change #3 with an identical workload and
# an identical pipeline length -- do NOT quote T2 against the swssconfig
# micro-benchmark (run_perf.sh), whose feed skips zebra/fpmsyncd entirely.
#
# Run this ON THE DUT. It marks a start time, waits for the peer to advertise
# the route set (either you trigger it, or --peer lets this script ssh the peer
# and run frr-vtysh for you), waits until the ASIC route count stops changing,
# then reads T from sairedis.rec scoped to the marker. With --del-file (auto)
# or --measure-del (manual) it then also measures the withdraw window.
#
# Completion is detected by an IDLE timer: as long as the count keeps moving we
# wait indefinitely (so a programming run longer than any fixed timeout is fine);
# we only stop once the count has been unchanged for --stable seconds. A large
# --ceiling only guards against a count that NEVER settles (e.g. oscillating) and
# aborts with an error rather than reporting a bogus T.
#
#   # manual trigger (you run frr-vtysh on the peer when prompted):
#   ./run_t2_bgp.sh --expect 30000 --require-zmq true --measure-del
#
#   # auto trigger (script ssh-es the peer and feeds it the route batches):
#   ./run_t2_bgp.sh --expect 30000 --require-zmq true \
#       --peer admin@192.168.1.1 --add-file /tmp/routes_add.conf \
#       --del-file /tmp/routes_del.conf --stats /tmp/perfstats_t2
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REC=/var/log/swss/sairedis.rec
STABLE=5            # seconds with no change => programming finished
CEILING=3600       # absolute guard (s): trips only if the count never settles
EXPECT=0           # expected route-count delta, for a sanity cross-check (0 = skip)
PEER=""            # ssh target for auto-trigger, e.g. admin@192.168.1.1
ADD_FILE=""        # path (on the peer) of the vtysh add-batch for auto-trigger
DEL_FILE=""        # path (on the peer) of the vtysh withdraw-batch
MEASURE_DEL=0      # manual-mode: also measure the withdraw window
REQUIRE_ZMQ=""     # true|false: abort unless the route-ZMQ flag matches
STATS=""           # dir: sample proc CPU during the run
MAX_ROUTES=32000   # ASIC route-table ceiling (this platform)

while [ $# -gt 0 ]; do
    case "$1" in
        --expect)  EXPECT="$2"; shift 2;;
        --stable)  STABLE="$2"; shift 2;;
        --ceiling) CEILING="$2"; shift 2;;
        --peer)    PEER="$2"; shift 2;;
        --add-file) ADD_FILE="$2"; shift 2;;
        --del-file) DEL_FILE="$2"; shift 2;;
        --measure-del) MEASURE_DEL=1; shift;;
        --require-zmq) REQUIRE_ZMQ="$2"; shift 2;;
        --stats)   STATS="$2"; shift 2;;
        --recfile) REC="$2"; shift 2;;
        --max-routes) MAX_ROUTES="$2"; shift 2;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done

route_count() { sonic-db-cli ASIC_DB keys "ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*" | wc -l; }

# --- label the run with the route-ZMQ flag so T1b and T2 results can't be mixed up
ZMQ_FLAG="$(sonic-db-cli CONFIG_DB hget "DEVICE_METADATA|localhost" \
            orch_northbond_route_zmq_enabled 2>/dev/null || true)"
[ "$ZMQ_FLAG" = "true" ] || ZMQ_FLAG="false"
echo "route ZMQ flag: $ZMQ_FLAG  ($([ "$ZMQ_FLAG" = "true" ] && echo "T2 row" || echo "T1b row"))"
if [ -n "$REQUIRE_ZMQ" ] && [ "$REQUIRE_ZMQ" != "$ZMQ_FLAG" ]; then
    echo "ERROR: this run requires route ZMQ '$REQUIRE_ZMQ' but the DUT has '$ZMQ_FLAG'." >&2
    echo "Fix the config (config route-zmq enable/disable + restart) or drop --require-zmq." >&2
    exit 1
fi

# --- optional CPU sampling for bottleneck attribution
SAMPLER_PID=""
cleanup() {
    if [ -n "$SAMPLER_PID" ]; then
        kill "$SAMPLER_PID" 2>/dev/null || true
        wait "$SAMPLER_PID" 2>/dev/null || true
        python3 "$HERE/sample_proc_cpu.py" summarize --out "$STATS" || true
    fi
}
trap cleanup EXIT
if [ -n "$STATS" ]; then
    mkdir -p "$STATS"
    python3 "$HERE/sample_proc_cpu.py" record --out "$STATS" &
    SAMPLER_PID=$!
    echo "CPU sampler running (pid $SAMPLER_PID) -> $STATS"
fi

# wait_idle <base>: poll until the count is unchanged for STABLE seconds
wait_idle() {
    local base="$1" last=-1 idle=0 elapsed=0 cur
    while [ "$idle" -lt "$STABLE" ]; do
        cur=$(route_count)
        if [ "$cur" -eq "$last" ]; then
            idle=$((idle + 1))          # count did not move this second
        else
            idle=0                       # progress -> reset idle timer, no cap while advancing
        fi
        printf "  count=%s (delta=%s) idle=%ss elapsed=%ss\n" "$cur" "$((cur - base))" "$idle" "$elapsed"
        last=$cur
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$CEILING" ]; then
            echo "!! Count never settled after ${CEILING}s -- something is stuck. Aborting (T unreliable)." >&2
            exit 1
        fi
    done
}

# ---------------- add window ----------------
BASE=$(route_count)
MARK=$(date +"%Y-%m-%d.%H:%M:%S.%6N")
sleep 1

echo "=== BGP-feed run (zmq=$ZMQ_FLAG): base_count=$BASE marker=$MARK ==="
if [ "$EXPECT" -gt 0 ] && [ "$((BASE + EXPECT))" -gt "$MAX_ROUTES" ]; then
    echo "ERROR: $BASE existing + $EXPECT advertised = $((BASE + EXPECT)), over the" >&2
    echo "ASIC route-table ceiling of $MAX_ROUTES. The table would fill mid-run and" >&2
    echo "T would be measured over a truncated batch. Clear leftovers or lower the" >&2
    echo "peer's route set (--max-routes to override)." >&2
    exit 1
fi
if [ -n "$PEER" ] && [ -n "$ADD_FILE" ]; then
    echo ">> Triggering announcement on $PEER (frr-vtysh < $ADD_FILE)"
    ssh "$PEER" "frr-vtysh < $ADD_FILE" >/dev/null
else
    echo ">> Now advertise the route set from the peer, e.g.:"
    echo "     frr-vtysh < /tmp/routes_add.conf"
    read -p "   Press Enter once the peer has finished sending..." _
fi

echo ">> Waiting until ASIC route count stops changing (idle >= ${STABLE}s = done)"
wait_idle "$BASE"

FINAL=$(route_count)
echo ">> Stabilized: base=$BASE final=$FINAL delta=$((FINAL - BASE))"
if [ "$EXPECT" -gt 0 ] && [ "$((FINAL - BASE))" -lt "$EXPECT" ]; then
    # The count going idle short of the target has two very different causes:
    # the table filled up (hard ceiling -- the run is void, waiting never helps)
    # or the feed stalled and the idle timer fired early. Ask CRM for the real
    # remaining capacity: the configured --max-routes is a guess that may sit
    # ABOVE the hardware's actual limit, which is exactly when this misfires.
    echo "!! WARNING: delta $((FINAL - BASE)) < expected $EXPECT -- T is unreliable." >&2
    AVAIL="$(crm show resources 2>/dev/null | awk '/ipv4_route/ {print $NF}' | head -1)"
    case "$AVAIL" in (*[!0-9]*|"") AVAIL="";; esac
    if [ -n "$AVAIL" ] && [ "$AVAIL" -lt 100 ]; then
        echo "   ASIC ROUTE TABLE FULL (crm ipv4_route available=$AVAIL): the batch was" >&2
        echo "   truncated by capacity, not by orchagent. Clear leftovers and/or shrink" >&2
        echo "   the peer's route set, then re-run." >&2
    elif [ "$FINAL" -ge "$((MAX_ROUTES - MAX_ROUTES / 100))" ]; then
        echo "   Settled at the configured ceiling ($MAX_ROUTES) -- capacity truncation." >&2
    else
        echo "   Table is NOT full (crm ipv4_route available=${AVAIL:-unknown}), so the" >&2
        echo "   feed likely stalled (vtysh still parsing? session flapped?) and the idle" >&2
        echo "   timer fired early. Raise --stable, or use a session-flap trigger so the" >&2
        echo "   whole set arrives as one burst." >&2
    fi
fi

echo ">> ADD window (zmq=$ZMQ_FLAG)"
python3 "$HERE/measure_route_time.py" "$REC" --since "$MARK" --op create

# ---------------- withdraw window (optional) ----------------
if [ -n "$DEL_FILE" ] || [ "$MEASURE_DEL" -eq 1 ]; then
    DEL_MARK=$(date +"%Y-%m-%d.%H:%M:%S.%6N")
    sleep 1
    if [ -n "$PEER" ] && [ -n "$DEL_FILE" ]; then
        echo ">> Triggering withdraw on $PEER (frr-vtysh < $DEL_FILE)"
        ssh "$PEER" "frr-vtysh < $DEL_FILE" >/dev/null
    else
        echo ">> Now withdraw the route set from the peer, e.g.:"
        echo "     frr-vtysh < /tmp/routes_del.conf"
        read -p "   Press Enter once the peer has finished withdrawing..." _
    fi

    echo ">> Waiting until ASIC route count stops changing"
    wait_idle "$BASE"

    DFINAL=$(route_count)
    echo ">> Stabilized: final=$DFINAL (started from $FINAL, base was $BASE)"
    if [ "$DFINAL" -gt "$BASE" ]; then
        echo "!! WARNING: count did not return to base ($DFINAL > $BASE) -- withdraw incomplete; T unreliable." >&2
    fi

    echo ">> DEL window (zmq=$ZMQ_FLAG)"
    python3 "$HERE/measure_route_time.py" "$REC" --since "$DEL_MARK" --op remove
fi
