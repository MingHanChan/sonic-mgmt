#!/usr/bin/env bash
# Orchestrate one route-programming benchmark run on the DUT (Redis-path
# micro-benchmark, i.e. route ZMQ disabled) and report mean +/- stddev of the
# ASIC programming window T over several iterations.
#
# For each iteration it: marks a start time, injects COUNT routes into APPL_DB,
# waits until they all land in ASIC_DB, then reads T from sairedis.rec scoped to
# the marker. The first iteration is discarded (cold cache).
#
#   ./run_perf.sh --count 100000 --nexthop 192.168.1.1@Ethernet0 --iters 6
#   ./run_perf.sh --count 50000  --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4 --iters 6
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

while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT="$2"; shift 2;;
        --base) BASE="$2"; shift 2;;
        --nexthop) NEXTHOP="$2"; shift 2;;
        --iters) ITERS="$2"; shift 2;;
        --timeout) TIMEOUT="$2"; shift 2;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done
[ -n "$NEXTHOP" ] || { echo "ERROR: --nexthop required" >&2; exit 1; }

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

RESULTS=()
echo "=== route-perf: COUNT=$COUNT ITERS=$ITERS NEXTHOP=$NEXTHOP ==="
for i in $(seq 1 "$ITERS"); do
    base_cnt="$(asic_route_count)"
    marker="$(date +"%Y-%m-%d.%H:%M:%S")"
    sleep 1  # ensure marker strictly precedes the first create timestamp

    python3 "$HERE/inject_routes.py" add --count "$COUNT" --base "$BASE" --nexthop "$NEXTHOP" >/dev/null
    wait_for "$((base_cnt + COUNT))" ge || { echo "iter $i FAILED"; continue; }

    read -r got ms < <(python3 "$HERE/measure_route_time.py" "$REC" --since "$marker" --quiet)
    printf "iter %d: programmed %s routes, T = %s ms\n" "$i" "$got" "$ms"
    RESULTS+=("$ms")

    # clean up for the next iteration
    python3 "$HERE/inject_routes.py" del --count "$COUNT" --base "$BASE" --nexthop "$NEXTHOP" >/dev/null
    wait_for "$base_cnt" le || true
done

echo
echo "=== summary (first iteration discarded as warm-up) ==="
printf '%s\n' "${RESULTS[@]}" | python3 -c "
import sys
vals = [float(x) for x in sys.stdin.read().split()]
vals = vals[1:] if len(vals) > 1 else vals   # drop warm-up
if not vals:
    print('no results'); sys.exit(0)
n = len(vals)
mean = sum(vals)/n
var = sum((v-mean)**2 for v in vals)/n
std = var ** 0.5
print('runs counted : %d' % n)
print('T mean       : %.1f ms' % mean)
print('T stddev     : %.1f ms (%.1f%%)' % (std, 100*std/mean if mean else 0))
print('T min / max  : %.1f / %.1f ms' % (min(vals), max(vals)))
print()
print('>> record this T mean for baseline vs treatment, then:')
print('   improvement%% = (T_base - T_treatment) / T_base * 100')
"
