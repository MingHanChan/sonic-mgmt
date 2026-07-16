#!/usr/bin/env bash
# Profile orchagent CPU while routes are being programmed, to validate the
# NextHopGroupTable std::map -> std::unordered_map change.
#
# Before the change, upstream perf showed ~30% of orchagent CPU in the next-hop
# lookup (std::_Rb_tree comparisons walking the whole NextHopGroupKey). After
# the change that share should shrink markedly; grep the report for the tree /
# hash symbols to see it.
#
# Run this ON the DUT (needs 'perf' -- linux-perf / linux-tools). Kick it just
# before you start injecting routes.
#
# Usage: ./profile_orchagent.sh [seconds] [output.txt]
set -euo pipefail

DUR="${1:-60}"
OUT="${2:-/tmp/orchagent_perf.txt}"
PID="$(pidof orchagent | awk '{print $1}')"

if [ -z "${PID:-}" ]; then
    echo "ERROR: orchagent not running" >&2
    exit 1
fi

echo "profiling orchagent (pid $PID) for ${DUR}s ..."
perf record -o /tmp/orchagent.perf.data -p "$PID" -g -- sleep "$DUR"

echo "== top symbols ==" | tee "$OUT"
perf report -i /tmp/orchagent.perf.data --stdio --percent-limit 0.5 2>/dev/null \
    | sed -n '1,60p' | tee -a "$OUT"

echo | tee -a "$OUT"
echo "== next-hop lookup related (map/tree/hash/RouteOrch/NextHopGroup) ==" | tee -a "$OUT"
perf report -i /tmp/orchagent.perf.data --stdio 2>/dev/null \
    | grep -iE "_Rb_tree|_Hashtable|unordered|NextHopGroup|RouteOrch|hash<" \
    | head -30 | tee -a "$OUT" || echo "(no matching symbols above threshold)" | tee -a "$OUT"

echo
echo "saved: $OUT  (raw: /tmp/orchagent.perf.data)"
