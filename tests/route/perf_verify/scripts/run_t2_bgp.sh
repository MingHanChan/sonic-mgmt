#!/usr/bin/env bash
#
# T2 orchestrator: measure the ASIC route-programming window T for the
# end-to-end BGP path (fpmsyncd -> orchagent), i.e. with route ZMQ ENABLED.
#
# Unlike run_perf.sh (Redis-path micro-benchmark that injects into APPL_DB), the
# routes here must arrive over real BGP, because with
# orch_northbond_route_zmq_enabled=true orchagent's route consumer is a
# ZmqConsumerStateTable and no longer reads APPL_DB ROUTE_TABLE.
#
# Run this ON THE DUT. It marks a start time, waits for the peer to advertise
# the route set (either you trigger it, or --peer lets this script ssh the peer
# and run frr-vtysh for you), waits until the ASIC route count stops changing,
# then reads T from sairedis.rec scoped to the marker.
#
# Completion is detected by an IDLE timer: as long as the count keeps moving we
# wait indefinitely (so a programming run longer than any fixed timeout is fine);
# we only stop once the count has been unchanged for --stable seconds. A large
# --ceiling only guards against a count that NEVER settles (e.g. oscillating) and
# aborts with an error rather than reporting a bogus T.
#
#   # manual trigger (you run frr-vtysh on the peer when prompted):
#   ./run_t2_bgp.sh --expect 100000
#
#   # auto trigger (script ssh-es the peer and feeds it the route batch):
#   ./run_t2_bgp.sh --expect 100000 \
#       --peer admin@192.168.1.1 --add-file /tmp/routes_add.conf
#
set -euo pipefail

REC=/var/log/swss/sairedis.rec
STABLE=5            # seconds with no change => programming finished
CEILING=3600       # absolute guard (s): trips only if the count never settles
EXPECT=0           # expected route-count delta, for a sanity cross-check (0 = skip)
PEER=""            # ssh target for auto-trigger, e.g. admin@192.168.1.1
ADD_FILE=""        # path (on the peer) of the vtysh add-batch for auto-trigger

while [ $# -gt 0 ]; do
    case "$1" in
        --expect)  EXPECT="$2"; shift 2;;
        --stable)  STABLE="$2"; shift 2;;
        --ceiling) CEILING="$2"; shift 2;;
        --peer)    PEER="$2"; shift 2;;
        --add-file) ADD_FILE="$2"; shift 2;;
        --recfile) REC="$2"; shift 2;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done

route_count() { sonic-db-cli ASIC_DB keys "ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*" | wc -l; }

BASE=$(route_count)
MARK=$(date +"%Y-%m-%d.%H:%M:%S")
sleep 1

echo "=== T2 BGP run: base_count=$BASE marker=$MARK ==="
if [ -n "$PEER" ] && [ -n "$ADD_FILE" ]; then
    echo ">> Triggering announcement on $PEER (frr-vtysh < $ADD_FILE)"
    ssh "$PEER" "frr-vtysh < $ADD_FILE" >/dev/null
else
    echo ">> Now advertise the route set from the peer, e.g.:"
    echo "     frr-vtysh < /tmp/routes_add.conf"
    read -p "   Press Enter once the peer has finished sending..." _
fi

echo ">> Waiting until ASIC route count stops changing (idle >= ${STABLE}s = done)"
last=-1
idle=0
elapsed=0
while [ "$idle" -lt "$STABLE" ]; do
    cur=$(route_count)
    if [ "$cur" -eq "$last" ]; then
        idle=$((idle + 1))          # count did not move this second
    else
        idle=0                       # progress -> reset idle timer, no cap while advancing
    fi
    printf "  count=%s (delta=%s) idle=%ss elapsed=%ss\n" "$cur" "$((cur - BASE))" "$idle" "$elapsed"
    last=$cur
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$CEILING" ]; then
        echo "!! Count never settled after ${CEILING}s -- something is stuck. Aborting (T unreliable)." >&2
        exit 1
    fi
done

FINAL=$(route_count)
echo ">> Stabilized: base=$BASE final=$FINAL delta=$((FINAL - BASE))"
if [ "$EXPECT" -gt 0 ] && [ "$((FINAL - BASE))" -lt "$EXPECT" ]; then
    echo "!! WARNING: delta $((FINAL - BASE)) < expected $EXPECT -- batch may be incomplete; T is unreliable." >&2
fi

echo ">> Measuring T"
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/measure_route_time.py" "$REC" --since "$MARK"
