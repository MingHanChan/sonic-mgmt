#!/bin/bash
# run_case.sh -- 在 DUT 上跑一輪量測:環境快照 -> 啟動取樣 -> 執行 inject 指令
#                -> 等收斂 -> 校驗路由數 -> 一致性檢查。
#
# 用法:
#   ./run_case.sh <label> <expected_delta> -- <inject 指令...>
#
# <inject 指令> 是「造成這一輪 route burst」的動作,由本腳本在啟動取樣後才執行,
# 且會繼承本腳本的 stdin(所以 swssconfig 讀 /dev/stdin 時,把 json 重導進本腳本即可)。
#
# 三層對應的 inject 寫法:
#   L1 (swssconfig / unordered_map):
#     ./run_case.sh A_map_r1 50000 -- 'docker exec -i swss swssconfig /dev/stdin' < routes_add.json
#   L2 (single-DUT static route / ZMQ):        # 先預載 inactive static route,見 README §4
#     ./run_case.sh L2_zmqON_r1 50000 -- './setup_nexthops.sh Ethernet0 1 add'
#   L3 (two-DUT BGP / ZMQ):
#     ./run_case.sh L3_zmqON_r1 50000 -- 'ssh admin@<PEER> ./l3_peer.sh announce <DUT_BGP_IP>'
#
# 產出:
#   /tmp/perf/<label>.add.csv    這一輪的取樣資料(交給 analyze_runs.py)
#   /tmp/perf/<label>.meta.txt   環境快照

set -u

LABEL=${1:?usage: $0 <label> <expected_delta> -- <inject cmd...>}
EXPECT=${2:?usage: $0 <label> <expected_delta> -- <inject cmd...>}
shift 2
[ "${1:-}" = "--" ] && shift
INJECT="$*"
[ -n "$INJECT" ] || { echo "no inject command given after --" >&2; exit 2; }

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
    echo "--- route-zmq flag ---"
    sonic-db-cli CONFIG_DB hget "DEVICE_METADATA|localhost" orch_northbond_route_zmq_enabled
    echo "--- orchagent cmdline (ZMQ 開啟時要看到 -q) ---"
    pgrep -a orchagent
    echo "--- ZMQ listener ---"
    docker exec swss sh -c 'ss -lntp 2>/dev/null | grep 8100' || echo "no listener on 8100"
    echo "--- swss log level (量測時務必 NOTICE) ---"
    sonic-db-cli LOGLEVEL_DB hget "orchagent:orchagent" LOGLEVEL 2>/dev/null
    echo "--- orchagent binary md5 (確認換對 binary) ---"
    docker exec swss md5sum /usr/bin/orchagent 2>/dev/null
    echo "--- 起始資源 ---"
    sonic-db-cli COUNTERS_DB hgetall CRM:STATS | paste - - | grep -E "route_used|nexthop|neighbor"
} | tee "$OUTDIR/$LABEL.meta.txt"

BEFORE=$(crm_routes)
echo "[run] baseline route count = $BEFORE"

echo "[run] starting probe -> $OUTDIR/$LABEL.add.csv"
python3 "$PROBE" --out "$OUTDIR/$LABEL.add.csv" --duration 600 --interval 0.2 \
        --stop-when-idle 8 < /dev/null &
PROBE_PID=$!
sleep 3

echo "[run] inject: $INJECT"
T0=$(date +%s.%N)
bash -c "$INJECT"
RC=$?
T1=$(date +%s.%N)
echo "[run] inject rc=$RC, wall=$(echo "$T1 - $T0" | bc) s"
echo "[run] ^ 這個 inject 牆鐘時間必須遠小於收斂時間,否則瓶頸在注入端,量測無效"

wait_stable
kill $PROBE_PID 2>/dev/null
wait $PROBE_PID 2>/dev/null

AFTER=$(crm_routes)
DELTA=$((AFTER - BEFORE))
echo "[run] route count $BEFORE -> $AFTER (delta $DELTA, expected $EXPECT)"
if [ "$DELTA" -ne "$EXPECT" ]; then
    echo "[run] !! 路由數不符,這輪資料不可信(可能掉封包或資源不足) -- 建議作廢" >&2
fi

echo "[run] APPL_DB vs ASIC_DB 一致性檢查:"
docker exec swss route_check.py 2>&1 | tail -20 || \
    route_check.py 2>&1 | tail -20 || echo "[run] route_check.py 路徑需依環境調整"

echo "[run] done -> ./analyze_runs.py $OUTDIR/$LABEL.add.csv"
