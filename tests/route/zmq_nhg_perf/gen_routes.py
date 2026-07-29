#!/usr/bin/env python3
"""
gen_routes.py -- 產生可控 ECMP 多樣性的路由批次檔。

重點:NextHopGroupTable(m_syncdNextHopGroups)只有在「nexthop >= 2」的
ECMP 路由才會被查表。單一 nexthop 的路由完全不碰它。所以要量 unordered_map
的效果,必須刻意製造「很多個不同的 next hop group」:
  --ecmp  K   每條路由幾個 nexthop(K>=2 才會建 NHG)
  --groups G  總共要有幾個「不同的」 nexthop 組合(= 表格的 n)

三種輸出模式:
  kernel     -> 給 `ip -batch <file>` 用。走 kernel -> zebra -> FPM -> fpmsyncd
                -> (ZMQ 或 Redis) -> orchagent。這是唯一能同時測到 ZMQ 與
                unordered_map 的注入法。
  swssconfig -> 給 `swssconfig` 用,直接寫 APPL_DB。只在 ZMQ 關閉時有效
                (ZMQ 開啟後 RouteOrch 只掛 ZmqConsumerStateTable,APPL_DB 的
                寫入不會被消費)。適合單獨量 unordered_map。
  frr        -> 給 `vtysh -f <file>` 用的 static route 設定。

範例:
  ./gen_routes.py --mode kernel --count 50000 --ecmp 8 --groups 1024 \
      --nh-count 64 --dev Ethernet0 --op add --out /tmp/routes_add.batch
  ./gen_routes.py --mode kernel --count 50000 --op del --out /tmp/routes_del.batch
"""

import argparse
import ipaddress
import json
import random
import sys


def nh_pool(count, base="30.0.0.0"):
    """與 setup_nexthops.sh 完全相同的位址配置公式,兩邊務必一致。"""
    base_int = int(ipaddress.IPv4Address(base))
    pool = []
    for i in range(count):
        octet3 = 1 + i // 250
        octet4 = 2 + i % 250
        pool.append(str(ipaddress.IPv4Address(base_int + (octet3 << 8) + octet4)))
    return pool


def build_groups(pool, ecmp, groups, seed):
    if ecmp > len(pool):
        sys.exit("--ecmp %d > nexthop pool size %d" % (ecmp, len(pool)))
    rng = random.Random(seed)
    seen = set()
    out = []
    attempts = 0
    while len(out) < groups:
        attempts += 1
        if attempts > groups * 200:
            sys.exit("cannot build %d distinct groups from pool=%d ecmp=%d"
                     % (groups, len(pool), ecmp))
        g = tuple(sorted(rng.sample(pool, ecmp)))
        if g in seen:
            continue
        seen.add(g)
        out.append(list(g))
    return out


def prefixes(count, base, plen):
    net = ipaddress.IPv4Network("%s/%d" % (base, plen), strict=False)
    step = 1 << (32 - plen)
    start = int(net.network_address)
    for i in range(count):
        yield "%s/%d" % (ipaddress.IPv4Address(start + i * step), plen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["kernel", "swssconfig", "frr"], default="kernel")
    ap.add_argument("--op", choices=["add", "del"], default="add")
    ap.add_argument("--count", type=int, default=10000, help="路由條數")
    ap.add_argument("--ecmp", type=int, default=1, help="每條路由的 nexthop 數 (K)")
    ap.add_argument("--groups", type=int, default=1, help="不同 nexthop 組合數 (G)")
    ap.add_argument("--nh-count", type=int, default=64, help="nexthop 位址池大小 (M)")
    ap.add_argument("--nh-base", default="30.0.0.0")
    ap.add_argument("--dev", default="Ethernet0", help="nexthop 所在的 L3 介面")
    ap.add_argument("--prefix-base", default="100.0.0.0")
    ap.add_argument("--prefix-len", type=int, default=24)
    ap.add_argument("--seed", type=int, default=20260729)
    ap.add_argument("--frr-wrap", action="store_true",
                    help="frr 模式:用 'configure terminal' / 'end' 包起來,方便 vtysh -f 載入")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    pool = nh_pool(args.nh_count, args.nh_base)
    grps = build_groups(pool, args.ecmp, args.groups, args.seed) if args.op == "add" else None

    lines = []
    swss_json = []

    for i, pfx in enumerate(prefixes(args.count, args.prefix_base, args.prefix_len)):
        if args.op == "del":
            if args.mode == "kernel":
                lines.append("route del %s" % pfx)
            elif args.mode == "frr":
                lines.append("no ip route %s" % pfx)
            else:
                swss_json.append({"ROUTE_TABLE:%s" % pfx: {}, "OP": "DEL"})
            continue

        nhs = grps[i % args.groups]
        if args.mode == "kernel":
            if len(nhs) == 1:
                lines.append("route add %s via %s dev %s" % (pfx, nhs[0], args.dev))
            else:
                hops = " ".join("nexthop via %s dev %s" % (nh, args.dev) for nh in nhs)
                lines.append("route add %s %s" % (pfx, hops))
        elif args.mode == "frr":
            for nh in nhs:
                lines.append("ip route %s %s" % (pfx, nh))
        else:
            swss_json.append({
                "ROUTE_TABLE:%s" % pfx: {
                    "ifname": ",".join([args.dev] * len(nhs)),
                    "nexthop": ",".join(nhs),
                    "protocol": "kernel",
                },
                "OP": "SET",
            })

    with open(args.out, "w") as f:
        if args.mode == "swssconfig":
            json.dump(swss_json, f, indent=2)
        elif args.mode == "frr" and args.frr_wrap:
            f.write("configure terminal\n" + "\n".join(lines) + "\nend\n")
        else:
            f.write("\n".join(lines) + "\n")

    if args.op == "add":
        print("[gen] %s: %d routes, ecmp=%d, distinct groups=%d, nh pool=%d"
              % (args.out, args.count, args.ecmp, args.groups, args.nh_count))
        if args.ecmp < 2:
            print("[gen] NOTE: ecmp<2 -> 不會建立 next hop group;測 unordered_map 要 ecmp>=2,"
                  "但單 nexthop 足以測 ZMQ(見 README §0-(5))", file=sys.stderr)
        if args.mode == "kernel":
            print("[gen] WARNING: kernel 模式(ip -batch)灌的路由到不了 fpmsyncd,"
                  "測不到 ZMQ/orchagent;測 ZMQ 請用 --mode frr,見 README §0-(4)",
                  file=sys.stderr)
    else:
        print("[gen] %s: %d delete entries" % (args.out, args.count))


if __name__ == "__main__":
    main()
