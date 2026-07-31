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
CONTAINER="swss"   # swss container, for the clock-skew preflight (multi-asic: swss0..)
PEER_IP=""         # peer's BGP SESSION address (not the ssh/mgmt one), for the
                   # PfxRcd cross-check; defaults to the host part of --peer
POLL=1             # seconds between ASIC_DB polls

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
        --container) CONTAINER="$2"; shift 2;;
        --peer-ip) PEER_IP="$2"; shift 2;;
        --poll) POLL="$2"; shift 2;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done

# --- preflight: helper scripts must be the same vintage as this orchestrator.
# A partial copy onto a DUT (old measure_route_time.py, no --op) otherwise fails
# only after the route batch has already been sent -- wasting the whole run.
require_helper() {  # require_helper <script> <flag-it-must-support>
    local script="$1" flag="$2"
    [ -f "$HERE/$script" ] || {
        echo "ERROR: $HERE/$script is missing -- copy the WHOLE scripts/ dir to this DUT." >&2
        exit 1
    }
    python3 "$HERE/$script" --help 2>/dev/null | grep -q -- "$flag" || {
        echo "ERROR: $HERE/$script is older than this orchestrator (no '$flag')." >&2
        echo "Re-copy the WHOLE scripts/ directory to this DUT." >&2
        exit 1
    }
}
require_helper measure_route_time.py --op
require_helper bgp_peer_pfx.py --peer-ip
[ -z "$STATS" ] || require_helper sample_proc_cpu.py --out
[ -x "$HERE/check_clock_skew.sh" ] || {
    echo "ERROR: $HERE/check_clock_skew.sh is missing or not executable --" >&2
    echo "copy the WHOLE scripts/ dir to this DUT." >&2
    exit 1
}

# T is read from sairedis.rec, whose timestamps are written inside the swss
# container, but the markers below come from the host's `date`. A clock or
# timezone mismatch either drops every record (no timing at all) or silently
# folds in earlier runs (a plausible but wrong T).
"$HERE/check_clock_skew.sh" "$CONTAINER"

# The PfxRcd cross-check needs the peer's BGP session address. --peer is an ssh
# target, whose host part is usually the same address in a two-box lab but need
# not be -- so derive it as a default and let --peer-ip override.
if [ -z "$PEER_IP" ] && [ -n "$PEER" ]; then
    PEER_IP="${PEER##*@}"
    PEER_IP="${PEER_IP%%:*}"
fi

route_count() {
    # Server-side EVAL, not 'keys | wc -l'. Either way redis scans the whole
    # ASIC_DB keyspace, but piping ~30k key names back to the client once a
    # second adds megabytes of traffic to the single-threaded instance that
    # orchagent is writing routes through -- so the poller inflates the very T
    # it is measuring, and contaminates the redis-server CPU signature the
    # --stats summary asks you to read (which is exactly the signal the T1b/T2
    # comparison hangs on). Same call sonic-mgmt's asic.count_routes() uses.
    local c
    c="$(sonic-db-cli ASIC_DB eval \
         "return #redis.call('keys', 'ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*')" 0 \
         2>/dev/null | tr -dc '0-9')"
    echo "${c:-0}"
}

# Prefixes this peer has advertised to us; -1 when there is no usable session.
peer_pfx() { python3 "$HERE/bgp_peer_pfx.py" --peer-ip "$PEER_IP" 2>/dev/null || echo -1; }

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

# wait_idle <base>: poll until the count is unchanged for STABLE WALL-CLOCK
# seconds. Both timers used to count loop iterations, not seconds: each
# iteration also paid for a route count, which at 30k routes cost 0.5-2s
# (python startup + full keyspace scan + shipping the key names back). So
# "--stable 5" was really 10-15s of quiet and "--ceiling 3600" was 1.5-3 hours,
# and the idle=/elapsed= numbers printed below understated reality 2-3x.
# EVAL-based counting (see route_count) makes a poll cheap; measuring the timers
# against date(1) makes them mean what they say regardless.
wait_idle() {
    local base="$1" last=-1 cur now idle start idle_start=0
    start=$(date +%s)
    while :; do
        cur=$(route_count)
        now=$(date +%s)
        if [ "$cur" -eq "$last" ]; then
            if [ "$idle_start" -eq 0 ]; then idle_start=$now; fi
        else
            idle_start=0                 # progress -> reset, no cap while advancing
        fi
        if [ "$idle_start" -eq 0 ]; then idle=0; else idle=$((now - idle_start)); fi
        printf "  count=%s (delta=%s) idle=%ss elapsed=%ss\n" \
            "$cur" "$((cur - base))" "$idle" "$((now - start))"
        if [ "$idle" -ge "$STABLE" ]; then return 0; fi
        last=$cur
        sleep "$POLL"
        if [ "$(( $(date +%s) - start ))" -ge "$CEILING" ]; then
            echo "!! Count never settled after ${CEILING}s -- something is stuck. Aborting (T unreliable)." >&2
            exit 1
        fi
    done
}

# ---------------- add window ----------------
BASE=$(route_count)
# Baseline for the PfxRcd cross-check: a short ASIC delta cannot, on its own,
# tell "orchagent was slow" from "bgpd never got the routes" (inbound
# route-map/prefix-list, maximum-prefix, or a peer that stalled mid-advertise).
PFX_BASE=-1
if [ -n "$PEER_IP" ]; then
    PFX_BASE=$(peer_pfx)
    echo "PfxRcd from $PEER_IP before the run: $PFX_BASE"
    if [ "$PFX_BASE" -lt 0 ]; then
        echo "NOTE: no established ipv4 session with '$PEER_IP' -- skipping the PfxRcd" >&2
        echo "      cross-check. Pass the peer's BGP SESSION address with --peer-ip if" >&2
        echo "      it differs from the ssh target." >&2
    fi
else
    echo "NOTE: --peer-ip not set and not derivable from --peer; the PfxRcd"
    echo "      cross-check is disabled (ASIC delta alone cannot tell a slow"
    echo "      orchagent from routes that never arrived)."
fi
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

# PfxRcd cross-check FIRST: it separates "the DUT never received them" from
# "the DUT received them but did not program them", which the ASIC delta alone
# cannot. Without it a filtered/limited session looks exactly like slow
# programming, and you profile orchagent for a bug that is in bgpd.
if [ "$PFX_BASE" -ge 0 ]; then
    PFX_FINAL=$(peer_pfx)
    echo ">> PfxRcd from $PEER_IP: $PFX_BASE -> $PFX_FINAL (delta $((PFX_FINAL - PFX_BASE)))"
    if [ "$PFX_FINAL" -lt 0 ]; then
        echo "!! The session to $PEER_IP is no longer Established -- it flapped during the" >&2
        echo "   run (maximum-prefix teardown?). T is void." >&2
    elif [ "$EXPECT" -gt 0 ] && [ "$((PFX_FINAL - PFX_BASE))" -lt "$EXPECT" ]; then
        echo "!! bgpd only received $((PFX_FINAL - PFX_BASE)) of $EXPECT prefixes, so the ASIC" >&2
        echo "   count was ALWAYS going to fall short -- this is not an orchagent result." >&2
        echo "   Look at the DUT's inbound policy (route-map/prefix-list on this neighbor)," >&2
        echo "   'maximum-prefix', and whether the peer finished advertising." >&2
    fi
fi

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
