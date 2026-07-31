#!/usr/bin/env python3
"""
How many prefixes a BGP peer has advertised to us -- the "did bgpd actually
receive the whole set" cross-check.

Why it matters for a route-perf run: the orchestrators validate a batch by the
ASIC_DB delta, which cannot distinguish "orchagent was slow" from "the routes
never arrived". An inbound route-map, a prefix-list, a `maximum-prefix` limit or
a peer that never finished advertising all show up as a short ASIC delta, and
you would spend the afternoon profiling orchagent for a problem that is in bgpd.
Reading PfxRcd before and after tells the two apart in one line.

Prints a single integer:
    >= 0   session is Established; the value is PfxRcd (0 is a perfectly valid
           answer -- e.g. before the peer has been released)
    -1     no such peer, session not Established, or vtysh returned no JSON

Usage:
    ./bgp_peer_pfx.py --peer-ip 192.168.1.1
    ./bgp_peer_pfx.py --peer-ip fc00::2 --afi ipv6
    ./bgp_peer_pfx.py --peer-ip 192.168.1.1 --netns asic0
    ./bgp_peer_pfx.py --peer-ip 192.168.1.1 --vtysh 'vtysh -n 0'
"""
import argparse
import json
import shutil
import subprocess
import sys


def resolve_vtysh(explicit, netns):
    """The vtysh command to use.

    SONiC images differ: stock ships `vtysh` on the host, while this toolkit's
    target image ships `frr-vtysh`, a wrapper that execs into the bgp container.
    Calling the wrong one returns nothing, which a naive caller then reads as
    "no session" -- so detect rather than hardcode.
    """
    if explicit:
        return explicit.split()
    cmd = ["frr-vtysh"] if shutil.which("frr-vtysh") else ["vtysh"]
    if netns and cmd[0] == "vtysh":
        # plain vtysh takes the asic INDEX (-n 0), unlike sonic-db-cli which
        # takes the namespace NAME (-n asic0).
        cmd += ["-n", netns.replace("asic", "")]
    return cmd


def find_peer(obj, target):
    """Locate the peer's entry wherever this FRR version put it.

    The summary JSON has been shipped as {"peers": ...} at the top level, nested
    under {"ipv4Unicast": {...}}, and wrapped in {"vrfs": {"default": {...}}}
    depending on version and command form. Search for whichever "peers" dict
    actually contains the address instead of guessing the shape.
    """
    if isinstance(obj, dict):
        peers = obj.get("peers")
        if isinstance(peers, dict) and target in peers:
            return peers[target]
        for value in obj.values():
            found = find_peer(value, target)
            if found is not None:
                return found
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--peer-ip", required=True, help="the peer's BGP session address")
    ap.add_argument("--afi", choices=["ipv4", "ipv6"], default="ipv4")
    ap.add_argument("--netns", default=None, help="multi-asic namespace, e.g. asic0")
    ap.add_argument("--vtysh", default=None, help="override the vtysh command")
    args = ap.parse_args()

    cmd = resolve_vtysh(args.vtysh, args.netns)
    cmd += ["-c", "show bgp %s unicast summary json" % args.afi]
    try:
        out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=30).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        print(-1)
        return

    try:
        data = json.loads(out)
    except ValueError:
        # No JSON at all: wrong vtysh name, bgp container down, or an FRR too
        # old for 'json' on this command.
        print(-1)
        return

    peer = find_peer(data, args.peer_ip)
    if not isinstance(peer, dict):
        print(-1)
        return

    state = peer.get("state", "")
    pfx = peer.get("pfxRcd", peer.get("prefixReceivedCount"))
    # A non-Established session is not usable regardless of any stale counter.
    if (state and state != "Established") or pfx is None:
        print(-1)
    else:
        print(pfx)


if __name__ == "__main__":
    main()
