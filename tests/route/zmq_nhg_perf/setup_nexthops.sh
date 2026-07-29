#!/bin/bash
# setup_nexthops.sh -- 在 DUT 上建立一批靜態 nexthop(鄰居),供 ECMP 路由使用。
#
#   ./setup_nexthops.sh Ethernet0 64 add
#   ./setup_nexthops.sh Ethernet0 64 del
#
# 位址配置公式必須與 gen_routes.py 的 nh_pool() 一致:
#   第 i 個 nexthop = 30.0.<1 + i/250>.<2 + i%250>
#
# 這些 neighbor 是 PERMANENT 的靜態項,由 neighsyncd 同步到 APPL_DB NEIGH_TABLE,
# NeighOrch 會替每個建立 SAI next hop,RouteOrch 才能組出 next hop group。
# 對端不需要真的回應 ARP。

set -e

DEV=${1:?usage: $0 <interface> <count> [add|del]}
COUNT=${2:?usage: $0 <interface> <count> [add|del]}
ACTION=${3:-add}
LOCAL_IP=30.0.0.1/16
OUT=/tmp/nh_pool.txt

if [ "$ACTION" = "add" ]; then
    # 介面上加一個 /16 的次要位址,讓整段 30.0.0.0/16 成為 connected
    if ! ip addr show dev "$DEV" | grep -q "30\.0\.0\.1/16"; then
        config interface ip add "$DEV" "$LOCAL_IP"
        sleep 2
    fi
fi

: > "$OUT"
for ((i = 0; i < COUNT; i++)); do
    o3=$((1 + i / 250))
    o4=$((2 + i % 250))
    ip4="30.0.${o3}.${o4}"
    mac=$(printf "52:54:00:%02x:%02x:%02x" $(((i >> 16) & 0xff)) $(((i >> 8) & 0xff)) $((i & 0xff)))
    if [ "$ACTION" = "add" ]; then
        ip neigh replace "$ip4" lladdr "$mac" dev "$DEV"
    else
        ip neigh del "$ip4" dev "$DEV" 2>/dev/null || true
    fi
    echo "$ip4" >> "$OUT"
done

if [ "$ACTION" = "del" ]; then
    config interface ip remove "$DEV" "$LOCAL_IP" || true
    echo "[nh] removed $COUNT neighbors from $DEV"
    exit 0
fi

echo "[nh] added $COUNT neighbors on $DEV, pool written to $OUT"
echo "[nh] 等待 NeighOrch 建立 SAI nexthop,確認數量:"
echo "     sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_nexthop_used"
