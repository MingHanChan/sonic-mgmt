#!/usr/bin/env bash
# Orchestrate one route-programming benchmark run on the DUT (Redis-path
# micro-benchmark, i.e. route ZMQ disabled) and report mean +/- stddev of the
# ASIC programming window T over several iterations -- for BOTH the add window
# and the withdraw (remove) window.
#
# For each iteration it: marks a start time, injects COUNT routes into APPL_DB
# (via swssconfig by default -- C++ buffered pipeline, so the producer does not
# bottleneck the measurement), waits until they all land in ASIC_DB, reads the
# add window T from sairedis.rec scoped to the marker, then does the same for
# the withdraw. The first iteration is discarded (cold cache), and any
# iteration whose produce-side time exceeds T/3 is discarded as
# producer-bound (T would be measuring the injector, not orchagent).
#
#   ./run_perf.sh --count 100000 --nexthop 192.168.1.1@Ethernet0 --iters 6
#   ./run_perf.sh --count 50000  --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4 --iters 6
#   ./run_perf.sh --count 100000 --nexthop 192.168.1.1@Ethernet0 --stats /tmp/perfstats
#
# Run the SAME command on the baseline image and on the treatment image, then:
#   improvement% = (T_baseline - T_treatment) / T_baseline * 100
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REC="/var/log/swss/sairedis.rec"
COUNT=100000
BASE="10.0.0.0"
NEXTHOP=""
ITERS=6
TIMEOUT=300
VIA="swssconfig"
CONTAINER="swss"
STATS=""
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT="$2"; shift 2;;
        --base) BASE="$2"; shift 2;;
        --nexthop) NEXTHOP="$2"; shift 2;;
        --iters) ITERS="$2"; shift 2;;
        --timeout) TIMEOUT="$2"; shift 2;;
        --via) VIA="$2"; shift 2;;                # swssconfig (default) | redis
        --container) CONTAINER="$2"; shift 2;;    # swss container (multi-asic: swss0..)
        --stats) STATS="$2"; shift 2;;            # dir: sample proc CPU during the run
        --recfile) REC="$2"; shift 2;;            # multi-asic: /var/log/swss/sairedis.asic0.rec
        --force) FORCE=1; shift;;                 # skip the route-ZMQ preflight abort
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done
[ -n "$NEXTHOP" ] || { echo "ERROR: --nexthop required" >&2; exit 1; }

# --- preflight: this benchmark feeds APPL_DB, which orchagent does NOT read
# when the route-ZMQ path is enabled. Refuse to measure a config that can't work.
ZMQ_FLAG="$(sonic-db-cli CONFIG_DB hget "DEVICE_METADATA|localhost" \
            orch_northbond_route_zmq_enabled 2>/dev/null || true)"
echo "route ZMQ flag: '${ZMQ_FLAG:-<unset>}'"
if [ "$ZMQ_FLAG" = "true" ] && [ "$FORCE" -ne 1 ]; then
    echo "ERROR: orch_northbond_route_zmq_enabled=true -- orchagent is not" >&2
    echo "consuming APPL_DB ROUTE_TABLE, so this injection would never program." >&2
    echo "Use run_t2_bgp.sh for the ZMQ path, or --force to override." >&2
    exit 1
fi
if counterpoll show 2>/dev/null | grep -qi enable; then
    echo "NOTE: some flex counters are enabled (counterpoll show) -- they add"
    echo "      orchagent/syncd CPU noise; consider disabling them for the run."
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

asic_route_count() {
    sonic-db-cli ASIC_DB keys "ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*" 2>/dev/null | wc -l
}

wait_for() {  # wait_for <target-count> <cmp: ge|le>
    local target="$1" cmp="$2" waited=0
    while :; do
        local c; c="$(asic_route_count)"
        if [ "$cmp" = "ge" ] && [ "$c" -ge "$target" ]; then return 0; fi
        if [ "$cmp" = "le" ] && [ "$c" -le "$target" ]; then return 0; fi
        sleep 1; waited=$((waited+1))
        if [ "$waited" -ge "$TIMEOUT" ]; then
            echo "  TIMEOUT waiting for ASIC route count $cmp $target (now $c)" >&2
            return 1
        fi
    done
}

# producer_bound <produce_seconds> <window_ms> -> 0 if produce > window/3
producer_bound() {
    awk -v p="$1" -v t="$2" 'BEGIN { exit !(t > 0 && p * 1000 > t / 3) }'
}

INJECT=(python3 "$HERE/inject_routes.py")
INJ_ARGS=(--count "$COUNT" --base "$BASE" --via "$VIA" --container "$CONTAINER" --quiet)

ADD_RESULTS=()
DEL_RESULTS=()
echo "=== route-perf: COUNT=$COUNT ITERS=$ITERS NEXTHOP=$NEXTHOP VIA=$VIA ==="
for i in $(seq 1 "$ITERS"); do
    base_cnt="$(asic_route_count)"
    marker="$(date +"%Y-%m-%d.%H:%M:%S.%6N")"
    sleep 1  # ensure marker strictly precedes the first create timestamp

    read -r _ add_prod < <("${INJECT[@]}" add "${INJ_ARGS[@]}" --nexthop "$NEXTHOP")
    if ! wait_for "$((base_cnt + COUNT))" ge; then
        echo "iter $i FAILED (add did not complete); withdrawing before next iter"
        "${INJECT[@]}" del "${INJ_ARGS[@]}" >/dev/null || true
        wait_for "$base_cnt" le || true
        continue
    fi
    read -r add_got add_ms < <(python3 "$HERE/measure_route_time.py" "$REC" \
                               --since "$marker" --op create --quiet)

    del_marker="$(date +"%Y-%m-%d.%H:%M:%S.%6N")"
    sleep 1
    del_ok=1
    read -r _ del_prod < <("${INJECT[@]}" del "${INJ_ARGS[@]}")
    wait_for "$base_cnt" le || { echo "iter $i: withdraw did not complete" >&2; del_ok=0; }
    read -r del_got del_ms < <(python3 "$HERE/measure_route_time.py" "$REC" \
                               --since "$del_marker" --op remove --quiet)

    tag=""
    if [ "$i" -eq 1 ]; then
        tag=" [warm-up: not counted]"
    elif [ "$add_got" -eq 0 ]; then
        tag=" [no creates found in $REC since marker: not counted -- was the rec rotated?]"
    elif producer_bound "$add_prod" "$add_ms"; then
        tag=" [PRODUCER-BOUND: not counted -- produce ${add_prod}s vs T ${add_ms}ms]"
    else
        ADD_RESULTS+=("$add_ms")
        if [ "$del_ok" -ne 1 ] || [ "$del_got" -eq 0 ]; then
            echo "  iter $i del window incomplete -- del not counted"
        elif producer_bound "$del_prod" "$del_ms"; then
            echo "  iter $i del window producer-bound (${del_prod}s) -- del not counted"
        else
            DEL_RESULTS+=("$del_ms")
        fi
    fi
    printf "iter %d: add %s routes T=%s ms (produce %ss) | del %s routes T=%s ms (produce %ss)%s\n" \
        "$i" "$add_got" "$add_ms" "$add_prod" "$del_got" "$del_ms" "$del_prod" "$tag"
done

summarize() {  # summarize <label> <values...>
    local label="$1"; shift
    printf '%s\n' "$@" | python3 -c "
import sys
label = '''$label'''
vals = [float(x) for x in sys.stdin.read().split()]
if not vals:
    print('%s: no counted iterations (all warm-up/producer-bound/failed)' % label)
    sys.exit(0)
n = len(vals)
mean = sum(vals)/n
var = sum((v-mean)**2 for v in vals)/n
std = var ** 0.5
rel = 100*std/mean if mean else 0
print('%s: n=%d  T mean %.1f ms  stddev %.1f ms (%.1f%%)  min/max %.1f/%.1f ms'
      % (label, n, mean, std, rel, min(vals), max(vals)))
if rel > 5:
    print('   NOTE: stddev > 5% of mean -- find the noise source before A/B comparing')
"
}

echo
echo "=== summary (iteration 1 discarded as warm-up; producer-bound iterations discarded) ==="
summarize "ADD window" "${ADD_RESULTS[@]:-}"
summarize "DEL window" "${DEL_RESULTS[@]:-}"
echo
echo ">> record these T means for baseline vs treatment, then:"
echo "   improvement% = (T_base - T_treatment) / T_base * 100"
