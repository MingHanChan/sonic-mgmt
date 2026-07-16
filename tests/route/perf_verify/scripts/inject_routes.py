#!/usr/bin/env python3
"""
Inject / withdraw a fixed batch of routes into APPL_DB ROUTE_TABLE using the
swsscommon ProducerStateTable protocol -- the same channel orchagent consumes
on the classic Redis path. Run this ON the DUT (swsscommon is installed there).

This is the reproducible micro-benchmark workload for the orchagent-internal
changes (NextHopGroupTable map->unordered_map, swss.rec on/off). It exercises
the Redis path, so use it with route ZMQ DISABLED.

For the ZMQ path (orch_northbond_route_zmq_enabled=true) orchagent's route
consumer is a ZmqConsumerStateTable and does NOT read this APPL_DB table -- use
a real BGP feed (exabgp/gobgp, see README) for the end-to-end ZMQ test instead.

Examples:
    # 100k /32 single-nexthop routes starting at 10.0.0.0
    ./inject_routes.py add --count 100000 --base 10.0.0.0 --nexthop 192.168.1.1@Ethernet0

    # 50k routes, 4-way ECMP (stresses NextHopGroupTable the most)
    ./inject_routes.py add --count 50000 --base 20.0.0.0 \
        --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4,192.168.1.3@Ethernet8,192.168.1.4@Ethernet12

    # remove the same batch afterwards
    ./inject_routes.py del --count 100000 --base 10.0.0.0
"""
import argparse
import ipaddress
import sys
import time

from swsscommon import swsscommon


def gen_prefixes(base, count):
    net = ipaddress.ip_address(base)
    for i in range(count):
        # /32 host routes keep generation trivial and avoid overlap
        yield str(net + i) + "/32"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("op", choices=["add", "del"])
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--base", default="10.0.0.0", help="first prefix address")
    ap.add_argument("--nexthop", default="",
                    help="comma-separated nexthops 'ip@ifname[,ip@ifname...]' "
                         "(required for add)")
    ap.add_argument("--table", default="ROUTE_TABLE")
    args = ap.parse_args()

    if args.op == "add" and not args.nexthop:
        sys.exit("ERROR: --nexthop is required for 'add'")

    appl_db = swsscommon.DBConnector("APPL_DB", 0)
    pst = swsscommon.ProducerStateTable(appl_db, args.table)

    nhs = args.nexthop.split(",")
    ifaces = [nh.split("@")[1] if "@" in nh else "" for nh in nhs]
    ips = [nh.split("@")[0] for nh in nhs]
    nexthop_val = ",".join(ips)
    ifname_val = ",".join(ifaces)

    t0 = time.time()
    n = 0
    for prefix in gen_prefixes(args.base, args.count):
        if args.op == "add":
            fvs = [("nexthop", nexthop_val), ("ifname", ifname_val)]
            pst.set(prefix, fvs)
        else:
            pst.delete(prefix)
        n += 1
    dt = time.time() - t0
    # This is only the produce-side time (how fast we pushed into APPL_DB); the
    # real number is the ASIC programming window from measure_route_time.py.
    print("%s %d routes into %s in %.3f s (produce-side only)" %
          (args.op, n, args.table, dt))


if __name__ == "__main__":
    main()
