#!/usr/bin/env python3
"""
Stage-resolved report for ONE "BGP announce -> ASIC programming" run.

Answers the question the plain sairedis window cannot: *how long after the DUT
received a BGP announcement was that route in the ASIC*. The plain window
(measure_route_time.py) is first-SAI-create to last-SAI-create, so it starts
counting only once orchagent is already programming -- everything before that
(TCP receive, bgpd parse + bestpath, zebra, fpmsyncd, the APPL_DB/ZMQ hop and
orchagent's own queueing) is outside it. For an end-to-end latency question
that head segment is exactly what you want to see, so this tool anchors T0 on
the wire instead:

    A  = first BGP UPDATE from the peer          (tcpdump, kernel timestamp)
    A' = last  BGP UPDATE from the peer          (arrival burst width = A'-A)
    D  = first SAI route create/remove           (sairedis.rec)
    D' = last  SAI route create/remove           (sairedis.rec)

    T_e2e     = D' - A     the headline: announce received -> fully in ASIC
    T_head    = D  - A     receive -> orchagent's first SAI call
    T_program = D' - D     orchagent's SAI programming window (== the old T)

Both anchors are PASSIVE (a packet capture and a log orchagent writes anyway),
so unlike a count-polling measurement nothing this tool reads perturbs the run.

It also resolves latency PER PREFIX: sairedis bulk lines carry every route
entry's "dest", so each announced prefix gets its own create timestamp and the
run yields a p50/p90/p99 distribution, not just a single window. Resolution is
one bulk line (~hundreds of routes), which is the granularity orchagent
actually programs at.

Usage (normally invoked by run_bgp_latency.sh):

    ./bgp_latency_report.py --since "2026-07-16.09:00:00.000000" \
        --tcpdump /tmp/bgpperf/bgp.txt --base 10.0.0.0 --count 30000 \
        [--rec /var/log/swss/sairedis.rec] [--op create|remove] \
        [--samples /tmp/bgpperf/asic_count.csv] [--json /tmp/bgpperf/result.json]

Clock note: tcpdump -tt timestamps are epoch seconds from the host kernel;
sairedis.rec timestamps are local-time strings written inside the swss
container. Comparing them is only valid when the container and the host agree
on both the clock and the timezone -- run_bgp_latency.sh asserts that in
preflight, and this tool re-checks the ordering (A <= D) as a backstop.
"""
import argparse
import ipaddress
import json
import os
import re
import sys

# Same directory -- python puts the script's dir on sys.path. The whole
# scripts/ dir is meant to be copied to the DUT together (the orchestrators
# already enforce that), so this import doubles as a vintage check.
from measure_route_time import parse_ts, rec_segments, OP_ACTIONS

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2}\.\d+)\|")
# Every route entry in a rec line -- single ops carry one, bulk ops ('C'/'R',
# fields separated by '||') carry hundreds:
#   ts|C|SAI_OBJECT_TYPE_ROUTE_ENTRY||{"dest":"10.0.0.1/32",...}|attr=..||{...}|..
DEST_RE = re.compile(r'"dest":"([^"]+)"')
# tcpdump -tt -nn -q:  1721113201.938358 IP 10.0.0.1.179 > 10.0.0.2.55123: tcp 4096
# without -q the payload size is printed as 'length 4096' instead.
PKT_RE = re.compile(r"^(\d+\.\d+)\s+.*?\b(?:tcp|length)\s+(\d+)\b")


def percentile(sorted_vals, pct):
    """Nearest-rank percentile; no numpy on a stock SONiC DUT."""
    if not sorted_vals:
        return None
    k = int(round(pct / 100.0 * len(sorted_vals) + 0.5)) - 1
    return sorted_vals[min(max(k, 0), len(sorted_vals) - 1)]


def load_updates(path, min_len):
    """Peer -> DUT BGP packets carrying route data, as (epoch, payload_bytes).

    tcpdump was already told to capture only 'src host <peer> and tcp port
    179', so direction filtering is done. Here we drop the small packets: a
    KEEPALIVE is exactly 19 bytes and an OPEN is well under 60, so anything at
    or above --min-update-len is an UPDATE carrying NLRI. Without this the
    keepalive that happens to precede the burst would become T0.
    """
    pkts = []
    with open(path, "rt", errors="replace") as f:
        for line in f:
            m = PKT_RE.match(line)
            if not m:
                continue
            length = int(m.group(2))
            if length >= min_len:
                pkts.append((float(m.group(1)), length))
    pkts.sort()
    return pkts


def collect_route_ops(recfile, actions, since):
    """Scan sairedis.rec (+ rotated siblings) for route ops after `since`.

    Returns (first_epoch, last_epoch, n_lines, n_entries, {prefix: epoch}).
    A prefix keeps its EARLIEST timestamp: a prefix that is later updated
    (set) or re-created must be scored on when it first reached the ASIC.
    """
    first = last = None
    n_lines = n_entries = 0
    when = {}
    for path in rec_segments(recfile):
        try:
            opener = open
            if path.endswith(".gz"):
                import gzip
                opener = gzip.open
            with opener(path, "rt", errors="replace") as f:
                for line in f:
                    if "SAI_OBJECT_TYPE_ROUTE_ENTRY" not in line:
                        continue
                    fields = line.split("|", 2)
                    if len(fields) < 2 or fields[1] not in actions:
                        continue
                    m = TS_RE.match(line)
                    if not m:
                        continue
                    ts = parse_ts(m.group(1))
                    if since and ts < since:
                        continue
                    epoch = ts.timestamp()
                    n_lines += 1
                    if first is None or epoch < first:
                        first = epoch
                    if last is None or epoch > last:
                        last = epoch
                    for prefix in DEST_RE.findall(line):
                        n_entries += 1
                        if prefix not in when or epoch < when[prefix]:
                            when[prefix] = epoch
        except (OSError, EOFError) as e:
            # logrotate renamed/compressed/removed the segment mid-read; its
            # rows are either already counted from the sibling it moved to or
            # genuinely gone. Losing some is visible as a low match count.
            print("note: skipped rec segment %s (%s)" % (path, e.__class__.__name__),
                  file=sys.stderr)
    return first, last, n_lines, n_entries, when


def expected_prefixes(base, count):
    net = ipaddress.ip_address(base)
    return ["%s/32" % (net + i) for i in range(count)]


def load_samples(path):
    """Optional ASIC_DB progress curve: 'epoch,count' per line."""
    out = []
    if not path or not os.path.exists(path):
        return out
    with open(path, "rt", errors="replace") as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) >= 2:
                try:
                    out.append((float(parts[0]), int(parts[1])))
                except ValueError:
                    continue
    return out


def fmt(v, unit="s"):
    return "n/a" if v is None else "%.3f %s" % (v, unit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rec", default="/var/log/swss/sairedis.rec")
    ap.add_argument("--since", required=True,
                    help="scope marker, YYYY-MM-DD.HH:MM:SS[.us] (run start)")
    ap.add_argument("--op", choices=sorted(OP_ACTIONS), default="create",
                    help="create = announce run, remove = withdraw run")
    ap.add_argument("--tcpdump", required=True,
                    help="text tcpdump output of peer->DUT port 179")
    ap.add_argument("--min-update-len", type=int, default=60,
                    help="TCP payload bytes below which a packet is not an "
                         "UPDATE with NLRI (default 60; keepalive is 19)")
    ap.add_argument("--base", default="10.0.0.0")
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--samples", default=None,
                    help="optional 'epoch,asic_count' CSV for the progress curve")
    ap.add_argument("--burst-ratio", type=float, default=0.25,
                    help="max arrival-burst width as a fraction of T_e2e before "
                         "the run is declared feed-bound (default 0.25)")
    ap.add_argument("--json", default=None, help="write the full result as JSON")
    args = ap.parse_args()

    since = parse_ts(args.since)
    pkts = load_updates(args.tcpdump, args.min_update_len)
    first_op, last_op, n_lines, n_entries, when = collect_route_ops(
        args.rec, OP_ACTIONS[args.op], since)

    verb = "create" if args.op == "create" else "remove"
    print("=== BGP announce -> ASIC %s latency ===" % verb)

    if not pkts:
        sys.exit("ERROR: no BGP UPDATE packets >= %d bytes in %s -- was the capture "
                 "running, was the filter right, did the peer actually send?"
                 % (args.min_update_len, args.tcpdump))
    if first_op is None:
        sys.exit("ERROR: no route %s ops in %s since %s -- wrong marker, wrong "
                 "--op, or the routes never reached orchagent."
                 % (args.op, args.rec, args.since))

    a_first, a_last = pkts[0][0], pkts[-1][0]
    update_bytes = sum(p[1] for p in pkts)
    arrival_span = a_last - a_first

    expected = expected_prefixes(args.base, args.count)
    exp_set = set(expected)
    matched = {p: t for p, t in when.items() if p in exp_set}
    lat = sorted(t - a_first for t in matched.values())

    # D / D' come from the ANNOUNCED prefixes only, not from every route op in
    # the window. A DUT in a lab still has background churn (a neighbour
    # resolving, a default route bouncing); folding those in would stretch the
    # window by whatever else happened to be programmed at the time.
    d_first = min(matched.values()) if matched else first_op
    d_last = max(matched.values()) if matched else last_op
    t_e2e = d_last - a_first
    t_head = d_first - a_first
    t_prog = d_last - d_first

    print("route set        : %s .. %s  (%d prefixes)"
          % (expected[0], expected[-1], args.count))
    print("BGP UPDATEs      : %d packets, %.1f KiB payload from the peer"
          % (len(pkts), update_bytes / 1024.0))
    print("SAI route ops    : %d rec lines covering %d route entries "
          "(all routes in the window, incl. background churn)"
          % (n_lines, n_entries))
    print()
    print("stage timeline (t=0 at the first BGP UPDATE)")
    print("  %-28s t+%8.3f s" % ("A  first UPDATE received", 0.0))
    print("  %-28s t+%8.3f s   (arrival burst %.3f s)"
          % ("A' last  UPDATE received", arrival_span, arrival_span))
    print("  %-28s t+%8.3f s" % ("D  first SAI %s" % verb, t_head))
    print("  %-28s t+%8.3f s" % ("D' last  SAI %s" % verb, t_e2e))
    print()
    print("headline")
    print("  T_e2e     (A  -> D') : %-10s  announce received -> all routes in ASIC"
          % fmt(t_e2e))
    print("  T_head    (A  -> D)  : %-10s  bgpd + zebra + fpmsyncd + queueing"
          % fmt(t_head))
    print("  T_program (D  -> D') : %-10s  orchagent SAI programming window"
          % fmt(t_prog))
    if t_e2e > 0:
        print("  effective rate       : %.0f routes/s over T_e2e" % (args.count / t_e2e))

    if lat:
        print()
        print("per-prefix latency (UPDATE received -> that prefix's SAI %s,"
              " bulk-line resolution)" % verb)
        print("  matched %d/%d announced prefixes" % (len(lat), args.count))
        print("  p50 %.3f s   p90 %.3f s   p99 %.3f s   max %.3f s"
              % (percentile(lat, 50), percentile(lat, 90),
                 percentile(lat, 99), lat[-1]))

    samples = load_samples(args.samples)
    if samples:
        base_cnt = samples[0][1]
        t0 = samples[0][0]
        print()
        print("ASIC_DB progress (poll-based, completion detection only -- not the metric)")
        for pct in (25, 50, 75, 100):
            target = base_cnt + args.count * pct // 100
            hit = next((t for t, c in samples if c >= target), None)
            print("  %3d%% (+%6d routes) : %s"
                  % (pct, args.count * pct // 100,
                     "not reached" if hit is None else "t+%.1f s" % (hit - t0)))

    # ---- validity gates. A number that passes none of these is not a DUT
    # measurement, and the point of printing them is that you find out here
    # rather than in the write-up.
    print()
    print("validity")
    ok = True

    if len(lat) == args.count:
        print("  [OK]   all %d announced prefixes found in sairedis.rec" % args.count)
    else:
        ok = False
        missing = [p for p in expected if p not in matched][:5]
        print("  [FAIL] only %d/%d announced prefixes have a SAI %s -- the batch was "
              "truncated (ASIC table full? peer filtered? rec segment lost?). "
              "First missing: %s" % (len(lat), args.count, verb, ", ".join(missing)))

    if t_e2e <= 0:
        # Nothing to compare the burst against; the clock check below says why.
        print("  [SKIP] arrival burst ratio is meaningless with T_e2e <= 0")
    elif arrival_span / t_e2e <= args.burst_ratio:
        print("  [OK]   arrival burst %.3f s = %.1f%% of T_e2e (<= %.0f%%): the DUT, "
              "not the peer, is what T_e2e measures"
              % (arrival_span, 100 * arrival_span / t_e2e, 100 * args.burst_ratio))
    else:
        ok = False
        print("  [FAIL] arrival burst %.3f s = %.1f%% of T_e2e (> %.0f%%): the peer fed "
              "the routes as a TRICKLE, so T_e2e is mostly the peer's advertisement "
              "rate. Re-arm with prep_bgp_burst.sh (preload behind an outbound deny, "
              "release with one soft-out) instead of announcing route-by-route."
              % (arrival_span, 100 * arrival_span / t_e2e if t_e2e else 0,
                 100 * args.burst_ratio))

    if t_head >= 0:
        print("  [OK]   first SAI %s is after the first UPDATE (clocks aligned)" % verb)
    else:
        ok = False
        print("  [FAIL] first SAI %s precedes the first UPDATE by %.3f s -- the swss "
              "container clock/timezone disagrees with the host, or --since is stale "
              "and the run picked up an earlier batch." % (verb, -t_head))

    print()
    print("VERDICT: %s" % ("VALID" if ok else "INVALID -- do not quote these numbers"))

    if args.json:
        with open(args.json, "w") as f:
            json.dump({
                "op": args.op,
                "count": args.count,
                "base": args.base,
                "valid": ok,
                "update_packets": len(pkts),
                "update_bytes": update_bytes,
                "sai_rec_lines": n_lines,
                "sai_route_entries": n_entries,
                "matched_prefixes": len(lat),
                "a_first_epoch": a_first,
                "a_last_epoch": a_last,
                "d_first_epoch": d_first,
                "d_last_epoch": d_last,
                "all_ops_first_epoch": first_op,
                "all_ops_last_epoch": last_op,
                "arrival_span_s": arrival_span,
                "t_e2e_s": t_e2e,
                "t_head_s": t_head,
                "t_program_s": t_prog,
                "latency_p50_s": percentile(lat, 50),
                "latency_p90_s": percentile(lat, 90),
                "latency_p99_s": percentile(lat, 99),
                "latency_max_s": lat[-1] if lat else None,
            }, f, indent=2)
        print("JSON written to %s" % args.json)

    sys.exit(0 if ok else 2)


if __name__ == "__main__":
    main()
