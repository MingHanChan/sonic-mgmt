#!/bin/bash
# l3_peer.sh -- 在 Peer(SONiC/FRR)上,為 L3 ZMQ 量測製造「一次送出」的 BGP burst。
#
# 概念:在 Peer 上預載 N 條 static route(指向 Null0,一定可安裝),redistribute 進 BGP,
# 但對「朝向 DUT 的 neighbor」套一個 outbound route-map BURST,一開始 deny 測試網段,
# 所以什麼都不廣播。量測時把 BURST 由 deny 改 permit 並 soft-out,DUT 就一次收到全部 N 條。
# 撤回時改回 deny 再 soft-out。
#
# 這樣「Peer 產生/安裝路由」的時間不會混進量測區間 —— 計時區間內 Peer 只是把已備好的
# 路由一次推出去,確保瓶頸不在 Peer(見 README §5)。
#
# 用法(都在 Peer 上執行):
#   ./l3_peer.sh setup    <DUT_BGP_IP> <PEER_ASN> <count>   # 一次性
#   ./l3_peer.sh announce <DUT_BGP_IP>                      # 放行 burst(當 run_case 的 inject)
#   ./l3_peer.sh withdraw <DUT_BGP_IP>                      # 撤回
#   ./l3_peer.sh cleanup  <DUT_BGP_IP> <count>              # 清掉 static route 與 route-map
#
# 測試網段固定為 100.0.0.0/24 起、每條 /24(與 gen_routes.py 一致)。

set -u
CMD=${1:?usage: setup|announce|withdraw|cleanup ...}
VTYSH="docker exec -i bgp vtysh"

gen_prefixes() {   # $1 = count ; 印出 100.0.x.0/24 ...(與 gen_routes.py 同公式)
    python3 - "$1" <<'PY'
import ipaddress, sys
start = int(ipaddress.IPv4Address("100.0.0.0"))
for i in range(int(sys.argv[1])):
    print("%s/24" % ipaddress.IPv4Address(start + i * 256))
PY
}

case "$CMD" in
setup)
    DUT_IP=${2:?}; ASN=${3:?}; COUNT=${4:?}
    echo "[peer] 預載 $COUNT 條 static route (Null0) 並 redistribute 進 BGP,先用 deny route-map 擋住"
    {
        echo "configure terminal"
        # route-map:先 deny 測試網段(seq 10),其餘照送(seq 20),不影響既有 session
        echo "ip prefix-list BURSTPFX seq 5 permit 100.0.0.0/8 le 32"
        echo "route-map BURST deny 10"
        echo " match ip address prefix-list BURSTPFX"
        echo "route-map BURST permit 20"
        # 對 DUT neighbor 套 outbound route-map
        echo "router bgp $ASN"
        echo " address-family ipv4 unicast"
        echo "  neighbor $DUT_IP route-map BURST out"
        echo "  redistribute static"
        echo " exit-address-family"
        # 預載 static routes(此時被 route-map 擋住,不會廣播)
        gen_prefixes "$COUNT" | sed 's/^/ip route /; s|$| Null0|'
        echo "end"
    } | $VTYSH
    echo "[peer] setup 完成。確認 DUT 目前應該還沒收到 100.0.0.0/24:"
    echo "       (在 DUT 上) show ip route 100.0.0.0/24"
    ;;

announce)
    DUT_IP=${2:?}
    # 把 seq 10 由 deny 改 permit -> 測試網段開始廣播;soft-out 立即重送
    $VTYSH -c "configure terminal" \
           -c "route-map BURST permit 10" \
           -c "match ip address prefix-list BURSTPFX" \
           -c "end"
    $VTYSH -c "clear bgp ipv4 unicast $DUT_IP soft out"
    ;;

withdraw)
    DUT_IP=${2:?}
    $VTYSH -c "configure terminal" \
           -c "route-map BURST deny 10" \
           -c "match ip address prefix-list BURSTPFX" \
           -c "end"
    $VTYSH -c "clear bgp ipv4 unicast $DUT_IP soft out"
    ;;

cleanup)
    DUT_IP=${2:?}; COUNT=${3:?}
    {
        echo "configure terminal"
        gen_prefixes "$COUNT" | sed 's/^/no ip route /; s|$| Null0|'
        echo "no route-map BURST permit 20"
        echo "no route-map BURST permit 10"
        echo "no route-map BURST deny 10"
        echo "no ip prefix-list BURSTPFX seq 5 permit 100.0.0.0/8 le 32"
        echo "end"
    } | $VTYSH
    echo "[peer] cleanup 完成"
    ;;

*)
    echo "unknown command: $CMD" >&2; exit 2 ;;
esac
