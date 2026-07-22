#!/usr/bin/env python3
"""
Inject / withdraw a fixed batch of routes into APPL_DB ROUTE_TABLE. Run this
ON the DUT. Two transports:

  --via swssconfig (default)
      Generate a swssconfig JSON batch, docker-cp it into the swss container
      and run `swssconfig` there. swssconfig is C++ and writes through a
      buffered RedisPipeline (flushed on exit), so the produce side is fast
      enough not to become the bottleneck of the measurement. This is the same
      channel tests/route/test_route_perf.py uses.

  --via redis
      Python swsscommon ProducerStateTable, kept as a fallback when docker
      exec is not available. Uses a buffered RedisPipeline + flush() when the
      installed bindings expose it; otherwise falls back to per-op writes,
      which are slow (~10k ops/s) and can make the run producer-bound.

Either way the routes travel the classic Redis path (APPL_DB ROUTE_TABLE ->
orchagent ConsumerStateTable), so use this with route ZMQ DISABLED. With
orch_northbond_route_zmq_enabled=true orchagent's route consumer is a
ZmqConsumerStateTable and does NOT read this APPL_DB table -- use a real BGP
feed (run_t2_bgp.sh, see README) instead.

The printed produce-side wall time matters: run_perf.sh compares it against
the measured programming window T and discards iterations where the producer
was too slow to saturate orchagent (produce time > T/3).

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
import json
import os
import subprocess
import sys
import time


def gen_prefixes(base, count):
    net = ipaddress.ip_address(base)
    for i in range(count):
        # /32 host routes keep generation trivial and avoid overlap
        yield str(net + i) + "/32"


def parse_nexthop(nexthop_arg):
    nhs = nexthop_arg.split(",")
    ips = [nh.split("@")[0] for nh in nhs]
    ifaces = [nh.split("@")[1] if "@" in nh else "" for nh in nhs]
    return ",".join(ips), ",".join(ifaces)


def route_fields(nexthop_val, ifname_val):
    # Same field set as tests/route/test_route_perf.py so the workload matches
    # the framework test this DUT family already runs.
    return {"nexthop": nexthop_val, "ifname": ifname_val, "protocol": "kernel"}


def inject_via_swssconfig(args, nexthop_val, ifname_val):
    """Returns (count, produce_seconds). Staging (JSON gen + docker cp) is NOT
    counted; produce time is the swssconfig execution only."""
    entries = []
    for prefix in gen_prefixes(args.base, args.count):
        key = "%s:%s" % (args.table, prefix)
        if args.op == "add":
            # swssconfig requires exactly 2 keys per element: the hash + OP
            entries.append({key: route_fields(nexthop_val, ifname_val), "OP": "SET"})
        else:
            entries.append({key: {}, "OP": "DEL"})

    host_json = "/tmp/perf_routes_%s_%d.json" % (args.op, os.getpid())
    ctr_json = "/tmp/%s" % os.path.basename(host_json)
    with open(host_json, "w") as f:
        json.dump(entries, f, separators=(",", ":"))

    try:
        subprocess.run(["docker", "cp", host_json, "%s:%s" % (args.container, ctr_json)],
                       check=True)
        t0 = time.time()
        subprocess.run(["docker", "exec", "-i", args.container, "swssconfig", ctr_json],
                       check=True)
        dt = time.time() - t0
    finally:
        os.unlink(host_json)
        subprocess.run(["docker", "exec", args.container, "rm", "-f", ctr_json],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return len(entries), dt


def inject_via_redis(args, nexthop_val, ifname_val):
    """Returns (count, produce_seconds)."""
    from swsscommon import swsscommon

    appl_db = swsscommon.DBConnector("APPL_DB", 0)
    buffered = True
    try:
        pipeline = swsscommon.RedisPipeline(appl_db)
        pst = swsscommon.ProducerStateTable(pipeline, args.table, True)
    except AttributeError:
        buffered = False
        pst = swsscommon.ProducerStateTable(appl_db, args.table)
        print("WARNING: swsscommon has no RedisPipeline binding; unbuffered "
              "per-op writes -- the run may be producer-bound", file=sys.stderr)

    fields = route_fields(nexthop_val, ifname_val)
    t0 = time.time()
    n = 0
    for prefix in gen_prefixes(args.base, args.count):
        if args.op == "add":
            pst.set(prefix, list(fields.items()))
        else:
            pst.delete(prefix)
        n += 1
    if buffered:
        pst.flush()
    return n, time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("op", choices=["add", "del"])
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--base", default="10.0.0.0", help="first prefix address")
    ap.add_argument("--nexthop", default="",
                    help="comma-separated nexthops 'ip@ifname[,ip@ifname...]' "
                         "(required for add)")
    ap.add_argument("--table", default="ROUTE_TABLE")
    ap.add_argument("--via", choices=["swssconfig", "redis"], default="swssconfig")
    ap.add_argument("--container", default="swss",
                    help="swss container name (multi-asic: swss0, swss1, ...)")
    ap.add_argument("--quiet", action="store_true",
                    help="print only: <count> <produce_seconds>")
    args = ap.parse_args()

    if args.op == "add" and not args.nexthop:
        sys.exit("ERROR: --nexthop is required for 'add'")

    nexthop_val, ifname_val = ("", "")
    if args.nexthop:
        nexthop_val, ifname_val = parse_nexthop(args.nexthop)

    if args.via == "swssconfig":
        n, dt = inject_via_swssconfig(args, nexthop_val, ifname_val)
    else:
        n, dt = inject_via_redis(args, nexthop_val, ifname_val)

    if args.quiet:
        print("%d %.3f" % (n, dt))
    else:
        # This is only the produce-side time (how fast we pushed into APPL_DB);
        # the real number is the ASIC programming window from measure_route_time.py.
        print("%s %d routes into %s via %s in %.3f s (produce-side only)" %
              (args.op, n, args.table, args.via, dt))


if __name__ == "__main__":
    main()
