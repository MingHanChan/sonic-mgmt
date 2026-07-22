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

# --- symbol-quality check: a production image ships a stripped orchagent, so
# perf resolves most samples to bare addresses and the map->hash shift is
# unreadable. Detect that and say what to install.
SYM_LINES=$(perf report -i /tmp/orchagent.perf.data --stdio --percent-limit 0.5 2>/dev/null \
    | grep -cE '^ *[0-9]+\.[0-9]+%' || true)
UNRESOLVED=$(perf report -i /tmp/orchagent.perf.data --stdio --percent-limit 0.5 2>/dev/null \
    | grep -E '^ *[0-9]+\.[0-9]+%' | grep -cE '\[unknown\]|0x[0-9a-f]{6,}' || true)
SYM_LINES=${SYM_LINES:-0}
UNRESOLVED=${UNRESOLVED:-0}
if [ "$SYM_LINES" -gt 0 ] && [ $((100 * UNRESOLVED / SYM_LINES)) -ge 40 ]; then
    echo | tee -a "$OUT"
    echo "!! ${UNRESOLVED}/${SYM_LINES} top entries are unresolved addresses -- orchagent has no debug symbols," | tee -a "$OUT"
    echo "   so the _Rb_tree vs _Hashtable comparison cannot be read from this report." | tee -a "$OUT"
    echo "   Use an image built with INSTALL_DEBUG_TOOLS=y (ships the -dbg dockers), or install" | tee -a "$OUT"
    echo "   the swss-dbg / libsairedis-dbg debs matching this build. Also make sure the perf" | tee -a "$OUT"
    echo "   binary matches the running kernel version." | tee -a "$OUT"
fi

echo
echo "saved: $OUT  (raw: /tmp/orchagent.perf.data)"
