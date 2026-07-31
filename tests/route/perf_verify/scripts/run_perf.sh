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
#   ./run_perf.sh --count 30000 --nexthop 192.168.1.1@Ethernet0 --iters 6
#   ./run_perf.sh --count 30000 --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4 --iters 6
#   ./run_perf.sh --count 30000 --nexthop 192.168.1.1@Ethernet0 --stats /tmp/perfstats
#
# COUNT must fit the ASIC route table (see --max-routes): overshooting it does
# not raise an error anywhere in the stack -- the ASIC_DB count simply stops
# advancing partway, and every T read from that truncated batch is garbage.
#
# Run the SAME command on the baseline image and on the treatment image, then:
#   improvement% = (T_baseline - T_treatment) / T_baseline * 100
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REC="/var/log/swss/sairedis.rec"
COUNT=30000
BASE="10.0.0.0"
NEXTHOP=""
ITERS=6
TIMEOUT=300
VIA="swssconfig"
CONTAINER="swss"
STATS=""
FORCE=0
MAX_ROUTES=32000    # ASIC route-table ceiling (this platform); see the check below

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
        --max-routes) MAX_ROUTES="$2"; shift 2;;  # ASIC route-table ceiling
        --force) FORCE=1; shift;;                 # skip the route-ZMQ preflight abort
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done
[ -n "$NEXTHOP" ] || { echo "ERROR: --nexthop required" >&2; exit 1; }

# --- preflight: the helper scripts must be the same vintage as this
# orchestrator. Copying only some files onto a DUT leaves e.g. an older
# inject_routes.py that does not understand --via/--quiet, and the run dies
# with an argparse error after the first inject.
require_helper() {  # require_helper <script> <flag-it-must-support>
    local script="$1" flag="$2"
    [ -f "$HERE/$script" ] || {
        echo "ERROR: $HERE/$script is missing -- copy the WHOLE scripts/ dir to this DUT." >&2
        exit 1
    }
    python3 "$HERE/$script" --help 2>/dev/null | grep -q -- "$flag" || {
        echo "ERROR: $HERE/$script is older than this orchestrator (no '$flag')." >&2
        echo "Re-copy the WHOLE scripts/ directory to this DUT -- mixing vintages" >&2
        echo "fails mid-run or, worse, silently measures the wrong thing." >&2
        exit 1
    }
}
require_helper inject_routes.py --via
require_helper measure_route_time.py --op
[ -z "$STATS" ] || require_helper sample_proc_cpu.py --out
[ -x "$HERE/check_clock_skew.sh" ] || {
    echo "ERROR: $HERE/check_clock_skew.sh is missing or not executable --" >&2
    echo "copy the WHOLE scripts/ dir to this DUT." >&2
    exit 1
}

asic_route_count() {
    # Server-side EVAL, not 'keys | wc -l'. Either way redis scans the whole
    # ASIC_DB keyspace, but piping ~30k key names back to the client once a
    # second adds megabytes of traffic to the single-threaded instance that
    # orchagent is writing routes through -- so the poller inflates the very T
    # it is measuring, and contaminates the redis-server CPU signature the
    # --stats summary asks you to read. Same call sonic-mgmt's
    # asic.count_routes() uses (tests/common/devices/sonic_asic.py).
    local c
    c="$(sonic-db-cli ASIC_DB eval \
         "return #redis.call('keys', 'ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*')" 0 \
         2>/dev/null | tr -dc '0-9')"
    echo "${c:-0}"
}

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
# --- preflight: T is read from sairedis.rec, whose timestamps are written
# inside the swss container, but the --since marker below comes from the host's
# `date`. A clock or timezone mismatch either drops every record (no timing) or
# silently folds in earlier runs (a plausible but wrong T).
"$HERE/check_clock_skew.sh" "$CONTAINER"

if counterpoll show 2>/dev/null | grep -qi enable; then
    echo "NOTE: some flex counters are enabled (counterpoll show) -- they add"
    echo "      orchagent/syncd CPU noise; consider disabling them for the run."
fi

# --- preflight: the ASIC route table has a hard ceiling, and overshooting it is
# SILENT: swssconfig, orchagent and syncd all report success while the ASIC_DB
# count simply stops advancing partway. Every T read from such a truncated batch
# is meaningless, so refuse the run instead of producing a plausible-looking
# number. Leftover routes from an earlier run eat into the same budget.
PRE_ROUTES="$(asic_route_count)"
echo "existing ASIC routes: $PRE_ROUTES (ceiling $MAX_ROUTES)"
if [ "$((PRE_ROUTES + COUNT))" -gt "$MAX_ROUTES" ]; then
    echo "ERROR: $PRE_ROUTES existing + $COUNT injected = $((PRE_ROUTES + COUNT))," >&2
    echo "over the ASIC route-table ceiling of $MAX_ROUTES." >&2
    echo "Clear leftover test routes first (inject_routes.py del ... on the DUT," >&2
    echo "withdraw on the peer), lower --count, or raise --max-routes if the" >&2
    echo "platform allows (check 'crm show resources' for the real limit)." >&2
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

wait_for() {  # wait_for <target-count> <cmp: ge|le>
    # --timeout is WALL-CLOCK seconds. It used to count loop iterations, which
    # at 30k routes was 2-3x longer than it looked: every iteration also paid
    # for a route count (python startup + a full keyspace scan + shipping the
    # key names back), so "--timeout 300" was really 10+ minutes.
    local target="$1" cmp="$2" start c now
    start=$(date +%s)
    while :; do
        c="$(asic_route_count)"
        if [ "$cmp" = "ge" ] && [ "$c" -ge "$target" ]; then return 0; fi
        if [ "$cmp" = "le" ] && [ "$c" -le "$target" ]; then return 0; fi
        sleep 1
        now=$(date +%s)
        if [ "$((now - start))" -ge "$TIMEOUT" ]; then
            echo "  TIMEOUT after $((now - start))s waiting for ASIC route count $cmp $target (now $c)" >&2
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
PRODUCER_BOUND_HITS=0
add_prod=""      # last add produce time, for the producer-rate hint at the end
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
    # ASIC_DB delta is the authoritative count of routes programmed this iter.
    # The sairedis line count is NOT: orchagent records routes in BULK ('C'),
    # one line covering ~hundreds of routes (30000 routes -> ~50 lines), so
    # gating on the line count wrongly discarded valid runs. Gate validity on
    # the delta; use the sairedis timestamps only for the T window.
    add_asic="$(asic_route_count)"
    add_delta="$((add_asic - base_cnt))"
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
    elif [ "$add_delta" -lt "$COUNT" ]; then
        # wait_for already blocked until base_cnt+COUNT, so this only trips on a
        # genuine partial program (ASIC table ceiling, leftover prefixes taking
        # the no-SAI update path) -- a real reason to distrust T.
        tag=" [ONLY $add_delta/$COUNT routes reached ASIC_DB: not counted]"
    elif [ "$add_got" -eq 0 ]; then
        tag=" [no create records in $REC since marker: no timing -- rec deleted by logrotate?]"
    elif producer_bound "$add_prod" "$add_ms"; then
        PRODUCER_BOUND_HITS=$((PRODUCER_BOUND_HITS + 1))
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
    printf "iter %d: add %s routes / %s SAI ops T=%s ms (produce %ss) | del %s SAI ops T=%s ms (produce %ss)%s\n" \
        "$i" "$add_delta" "$add_got" "$add_ms" "$add_prod" "$del_got" "$del_ms" "$del_prod" "$tag"
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

# If nothing survived and the reason was producer-bound, the Redis micro-benchmark
# simply cannot isolate orchagent on this DUT -- say so and point at the tools
# that do not depend on the producer's speed, rather than leaving an empty result.
if [ "${#ADD_RESULTS[@]}" -eq 0 ] && [ "$PRODUCER_BOUND_HITS" -gt 0 ]; then
    python3 - "$COUNT" "${add_prod:-0}" <<'PY'
import sys
count = float(sys.argv[1]); prod = float(sys.argv[2] or 0)
rate = count / prod if prod > 0 else 0
print()
print("!! Every counted add iteration was PRODUCER-BOUND on this DUT.")
if rate:
    print("   swssconfig feeds ~%.0f routes/s here, comparable to orchagent's" % rate)
    print("   programming rate, so produce took a large fraction of the window T")
else:
    print("   produce took a large fraction of the window T,")
print("   -- T is dominated by the FEED, not by orchagent. The Redis micro-")
print("   benchmark therefore cannot isolate the orchagent changes (#1 swss.rec,")
print("   #2 NextHopGroupTable) on this unit. Use the feed-independent tools:")
print("     #2  ./profile_orchagent.sh 60 /tmp/oa.txt &   (then an ECMP run below)")
print("         reads the map->hash CPU share straight from perf, any feed speed")
print("     #3  ./run_t2_bgp.sh ...   BGP feed, no swssconfig producer at all")
print("   See README 'Validating change #2' and 'Rows T1b / T2'.")
PY
else
    echo
    echo ">> record these T means for baseline vs treatment, then:"
    echo "   improvement% = (T_base - T_treatment) / T_base * 100"
fi
