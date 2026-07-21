#!/usr/bin/env python3
"""
Generate an FRR/vtysh config batch that adds (or removes) a fixed set of static
routes, to be redistributed into BGP toward the DUT for the T2 end-to-end path.

Run this on the BGP peer (which, in a SONiC-to-SONiC lab, is itself a SONiC/FRR
box). The peer must already have, once:

    router bgp <PEER_AS>
     address-family ipv4 unicast
      redistribute static

The generated batch is fed to vtysh as a single transaction:

    ./gen_frr_routes.py add --count 100000 --base 10.0.0.0 > /tmp/routes_add.conf
    frr-vtysh < /tmp/routes_add.conf            # NOT 'vtysh -f <hostpath>' (container FS)

    ./gen_frr_routes.py del --count 100000 --base 10.0.0.0 > /tmp/routes_del.conf
    frr-vtysh < /tmp/routes_del.conf            # withdraw between iterations

Uses the same --count/--base convention as inject_routes.py so the T2 (BGP) and
T1 (Redis) runs cover the exact same route set and T is comparable.

next-hop: static routes point at Null0 -- forwarding correctness is irrelevant
here; we only need FRR to originate them so bgpd advertises them to the DUT.
eBGP rewrites the next-hop to the peer's session address, which the DUT has
already resolved, so the routes program to hardware on the DUT side.
"""
import argparse
import ipaddress
import sys


def gen_prefixes(base, count):
    net = ipaddress.ip_address(base)
    for i in range(count):
        yield "%s/32" % (net + i)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("op", choices=["add", "del"])
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--base", default="10.0.0.0", help="first prefix address")
    args = ap.parse_args()

    out = sys.stdout
    out.write("configure terminal\n")
    for prefix in gen_prefixes(args.base, args.count):
        if args.op == "add":
            out.write("ip route %s Null0\n" % prefix)
        else:
            out.write("no ip route %s Null0\n" % prefix)
    out.write("end\n")


if __name__ == "__main__":
    main()
