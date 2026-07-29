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

# --- preflight: orchagent must carry symbols or the whole profile is
# unreadable -- the map->hash change is a symbol-level CPU shift, not a number
# perf can show against bare addresses. Check the exact binary perf resolves:
# the one inside the swss container, seen from the host via /proc/PID/root.
# Fail fast here instead of after a 60s perf record. PROFILE_FORCE=1 overrides
# (e.g. symbols served out-of-band by debuginfod).
BIN="/proc/$PID/root/usr/bin/orchagent"
[ -r "$BIN" ] || BIN="$(command -v orchagent 2>/dev/null || echo /usr/bin/orchagent)"
rc=0
python3 - "$BIN" <<'PY' || rc=$?
import sys, struct
try:
    d = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(0)   # cannot read -> do not block; the post-run check still runs
if d[:4] != b"\x7fELF" or d[4] != 2:
    sys.exit(0)
le = "<" if d[5] == 1 else ">"
shoff = struct.unpack_from(le + "Q", d, 0x28)[0]
entsz = struct.unpack_from(le + "H", d, 0x3a)[0]
num   = struct.unpack_from(le + "H", d, 0x3c)[0]
stnx  = struct.unpack_from(le + "H", d, 0x3e)[0]
base  = shoff + stnx * entsz
so = struct.unpack_from(le + "Q", d, base + 0x18)[0]
sz = struct.unpack_from(le + "Q", d, base + 0x20)[0]
strt = d[so:so + sz]
def nm(n):
    return strt[n:strt.find(b"\x00", n)].decode("latin1")
names = [nm(struct.unpack_from(le + "I", d, shoff + i * entsz)[0]) for i in range(num)]
sys.exit(0 if (".symtab" in names or any(s.startswith(".debug_") for s in names)) else 3)
PY
if [ "$rc" = 3 ]; then
    echo "!! orchagent ($BIN) is STRIPPED -- no .symtab / .debug_* sections." >&2
    echo "   perf would resolve most samples to bare addresses and the" >&2
    echo "   NextHopGroupTable map->hash shift (change #2) would be unreadable." >&2
    echo "   Install the matching swss-dbg / libsairedis-dbg debs, or use an" >&2
    echo "   image built with INSTALL_DEBUG_TOOLS=y. Re-run with PROFILE_FORCE=1" >&2
    echo "   to profile anyway." >&2
    [ "${PROFILE_FORCE:-0}" = 1 ] || exit 1
    echo "   (PROFILE_FORCE=1 set -- profiling despite missing symbols)" >&2
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
