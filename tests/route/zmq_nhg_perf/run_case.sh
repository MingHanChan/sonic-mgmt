#!/bin/bash
# run_case.sh -- 在 DUT 上跑一輪 route burst 並收集量測資料。
#
#   ./run_case.sh <label> <add_batch_file> <del_batch_file> <expected_routes>
#
# 例:
#   ./run_case.sh zmqon_run1 /tmp/routes_add.batch /tmp/routes_del.batch 50000
#
# 產出:
#   /tmp/perf/<label>.add.csv   加路由那一輪
#   /tmp/perf/<label>.del.csv   刪路由那一輪
#   /tmp/perf/<label>.meta.txt  當時的環境快照(image / flag / orchagent 參數)

set -u

LABEL=${1:?usage: $0 <label> <add_batch> <del_batch> <expected_routes>}
ADD_BATCH=${2:?}
DEL_BATCH=${3:?}
EXPECT=${4:?}

OUTDIR=/tmp/perf
PROBE=$(dirname "$0")/route_perf_probe.py
mkdir -p "$OUTDIR"

crm_routes() {
    local v4 v6
    v4=$(sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_route_used)
    v6=$(sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv6_route_used)
    echo $(( ${v4:-0} + ${v6:-0} ))
}

wait_stable() {   # 等路由數連續 5 秒不變
    local last=-1 same=0 cur
    for _ in $(seq 1 600); do
        cur=$(crm_routes)
        if [ "$cur" = "$last" ]; then
            same=$((same + 1))
            [ $same -ge 5 ] && return 0
        else
            same=0
            last=$cur
        fi
        sleep 1
    done
    echo "[run] WARNING: route count never stabilised" >&2
}

echo "=== $LABEL: 環境快照 ==="
{
    date -Is
    echo "--- image ---"
    sonic-installer list 2>/dev/null | head -5
    echo "--- route-zmq flag ---"
    sonic-db-cli CONFIG_DB hget "DEVICE_METADATA|localhost" orch_northbond_route_zmq_enabled
    echo "--- orchagent cmdline (要看到 -q 才代表 ZMQ server 有起來) ---"
    pgrep -a orchagent
    echo "--- ZMQ listener ---"
    docker exec swss sh -c 'ss -lntp 2>/dev/null | grep 8100' || echo "no listener on 8100"
    echo "--- swss log level (跑量測時務必是 NOTICE) ---"
    sonic-db-cli LOGLEVEL_DB hget "orchagent:orchagent" LOGLEVEL
    echo "--- 起始資源 ---"
    sonic-db-cli COUNTERS_DB hgetall CRM:STATS | paste - - | grep -E "route_used|nexthop|neighbor"
} | tee "$OUTDIR/$LABEL.meta.txt"

BEFORE=$(crm_routes)
echo "[run] baseline route count = $BEFORE"

# ---------- ADD ----------
echo "[run] starting probe (add)"
python3 "$PROBE" --out "$OUTDIR/$LABEL.add.csv" --duration 600 --interval 0.2 --stop-when-idle 8 &
PROBE_PID=$!
sleep 3

echo "[run] injecting $ADD_BATCH"
T0=$(date +%s.%N)
ip -force -batch "$ADD_BATCH"
T1=$(date +%s.%N)
echo "[run] injector wall time: $(echo "$T1 - $T0" | bc) s   <-- 這個必須遠小於收斂時間,"
echo "[run] 否則瓶頸在注入端而不是 orchagent,量測無效"

wait_stable
kill $PROBE_PID 2>/dev/null
wait $PROBE_PID 2>/dev/null

AFTER=$(crm_routes)
echo "[run] route count $BEFORE -> $AFTER (delta $((AFTER - BEFORE)), expected $EXPECT)"
if [ $((AFTER - BEFORE)) -ne "$EXPECT" ]; then
    echo "[run] !! 路由數不符,這輪資料不可信(可能有掉封包或資源不足)" >&2
fi

echo "[run] APPL_DB vs ASIC_DB 一致性檢查:"
route_check.py 2>&1 | tail -20

# ---------- DEL ----------
echo "[run] starting probe (del)"
python3 "$PROBE" --out "$OUTDIR/$LABEL.del.csv" --duration 600 --interval 0.2 --stop-when-idle 8 &
PROBE_PID=$!
sleep 3
ip -force -batch "$DEL_BATCH"
wait_stable
kill $PROBE_PID 2>/dev/null
wait $PROBE_PID 2>/dev/null

echo "[run] done. 分析:"
echo "   ./analyze_runs.py $OUTDIR/$LABEL.add.csv"
