#!/usr/bin/env bash
#
# Hardware-side cross-check for the route-programming window (Broadcom).
#
# sairedis.rec timestamps and the ASIC_DB key count BOTH mark the orchagent
# egress boundary: the record and the ASIC_STATE keys are written by the
# sairedis client library inside orchagent, BEFORE syncd consumes the op and
# the SDK programs the chip. If syncd/SDK lags, T undercounts the real
# end-to-end time. This script watches the two boundaries side by side:
#
#   ASIC_DB : sonic-db-cli ASIC_DB keys 'ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*'
#   HW      : bcmcmd "l3 defip show" entry count (override with --count-cmd)
#
# and reports when each reached the expected delta plus the lag between them.
# A small lag (~= polling granularity) means syncd kept up and the sairedis.rec
# window is a fair proxy for hardware completion; a large lag means quote the
# HW time instead.
#
# START THIS BEFORE TRIGGERING THE INJECTION, in a second terminal:
#
#   ./hw_route_watch.sh --expect 100000 &
#   ./run_perf.sh --count 100000 --nexthop ... --iters 1
#
# Granularity: each sample costs one bcmcmd execution, which at 100k entries
# can itself take a few seconds -- so the reported lag is only meaningful to
# within (interval + bcmcmd time). This is a cross-check, not the headline
# number. Raise --interval at high scale to lighten the load.
#
set -euo pipefail

EXPECT=0
INTERVAL=2
CEILING=1800
COUNT_CMD='bcmcmd "l3 defip show"'    # may need sudo: --count-cmd 'sudo bcmcmd "l3 defip show"'
COUNT_REGEX='^ *[0-9]+'               # lines that are route entries in the cmd output

while [ $# -gt 0 ]; do
    case "$1" in
        --expect)      EXPECT="$2"; shift 2;;
        --interval)    INTERVAL="$2"; shift 2;;
        --ceiling)     CEILING="$2"; shift 2;;
        --count-cmd)   COUNT_CMD="$2"; shift 2;;
        --count-regex) COUNT_REGEX="$2"; shift 2;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done
[ "$EXPECT" -gt 0 ] || { echo "ERROR: --expect <route-delta> required" >&2; exit 1; }

asic_count() { sonic-db-cli ASIC_DB keys "ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*" 2>/dev/null | wc -l; }
hw_count()   { eval "$COUNT_CMD" 2>/dev/null | grep -Ec "$COUNT_REGEX" || true; }

# preflight: the HW command must work here (Broadcom only, may need sudo)
if ! eval "$COUNT_CMD" >/dev/null 2>&1; then
    echo "ERROR: '$COUNT_CMD' failed. Broadcom-only; try --count-cmd 'sudo bcmcmd \"l3 defip show\"'," >&2
    echo "or point --count-cmd/--count-regex at your platform's route-dump command." >&2
    exit 1
fi

ASIC_BASE=$(asic_count)
HW_BASE=$(hw_count)
T0=$(date +%s.%N)
echo "=== hw_route_watch: expect +$EXPECT  base ASIC_DB=$ASIC_BASE HW=$HW_BASE  interval=${INTERVAL}s ==="
echo "(reported lag is only meaningful to within interval + bcmcmd time)"

now() { date +%s.%N; }
rel() { awk -v a="$1" -v b="$T0" 'BEGIN { printf "%.1f", a - b }'; }

ASIC_START=""; ASIC_DONE=""; HW_START=""; HW_DONE=""
while :; do
    A=$(asic_count); TA=$(now)
    H=$(hw_count);   TH=$(now)
    AD=$((A - ASIC_BASE)); HD=$((H - HW_BASE))

    [ -z "$ASIC_START" ] && [ "$AD" -gt 0 ] && ASIC_START=$TA
    [ -z "$HW_START" ]   && [ "$HD" -gt 0 ] && HW_START=$TH
    [ -z "$ASIC_DONE" ]  && [ "$AD" -ge "$EXPECT" ] && ASIC_DONE=$TA
    [ -z "$HW_DONE" ]    && [ "$HD" -ge "$EXPECT" ] && HW_DONE=$TH

    printf "  t=%6ss  ASIC_DB +%-7s HW +%-7s\n" "$(rel "$TH")" "$AD" "$HD"
    if [ -n "$ASIC_DONE" ] && [ -n "$HW_DONE" ]; then break; fi
    if awk -v t="$(rel "$TH")" -v c="$CEILING" 'BEGIN { exit !(t >= c) }'; then
        echo "!! ceiling ${CEILING}s hit before both sides reached +$EXPECT (ASIC +$AD, HW +$HD)" >&2
        exit 1
    fi
    sleep "$INTERVAL"
done

echo
echo "=== result ==="
[ -n "$ASIC_START" ] && echo "ASIC_DB first movement : t=$(rel "$ASIC_START")s"
[ -n "$HW_START" ]   && echo "HW      first movement : t=$(rel "$HW_START")s"
echo "ASIC_DB reached +$EXPECT : t=$(rel "$ASIC_DONE")s"
echo "HW      reached +$EXPECT : t=$(rel "$HW_DONE")s"
awk -v h="$HW_DONE" -v a="$ASIC_DONE" -v i="$INTERVAL" 'BEGIN {
    lag = h - a
    printf "HW completion lag      : %.1f s  (granularity ~%.0fs + bcmcmd time)\n", lag, i
    if (lag > 3 * i)
        print ">> syncd/SDK lags orchagent here -- quote the HW time, not just sairedis.rec T"
    else
        print ">> syncd kept up -- the sairedis.rec window is a fair proxy for HW completion"
}'
