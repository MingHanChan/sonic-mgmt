#!/usr/bin/env python3
"""
Measure the ASIC route-programming window from /var/log/swss/sairedis.rec.

sairedis.rec is still enabled by default (record_type=1) after the swss.rec
change, so it is the most reliable, always-present timing source. Each line is:

    <timestamp>|<action>|SAI_OBJECT_TYPE_ROUTE_ENTRY:{...}|<attrs...>

where <action> is 'c' (create), 'C' (bulk create), 's'/'S' (set), 'r'/'R'
(remove). <timestamp> is 'YYYY-MM-DD.HH:MM:SS.microseconds'.

T = (timestamp of the LAST matching op) - (timestamp of the FIRST matching op)

With --op create (default) that window is the headline number: how long
orchagent+syncd took to push the whole batch of routes into the ASIC. With
--op remove it is the withdraw window -- route removal speed matters just as
much during failure convergence, so measure both.

Usage:
    # measure the whole file
    ./measure_route_time.py /var/log/swss/sairedis.rec

    # only routes created after a marker time (e.g. start of this run)
    ./measure_route_time.py /var/log/swss/sairedis.rec --since "2026-07-16.09:00:00"

    # the withdraw window of a batch removed after the marker
    ./measure_route_time.py /var/log/swss/sairedis.rec --since "..." --op remove

    # machine-readable one-liner for run_perf.sh to capture
    ./measure_route_time.py /var/log/swss/sairedis.rec --quiet
"""
import argparse
import datetime
import re
import sys

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2}\.\d+)\|")
OP_ACTIONS = {
    "create": {"c", "C"},   # single + bulk create
    "remove": {"r", "R"},   # single + bulk remove
}


def parse_ts(s):
    # 2026-07-16.09:00:01.938358 -> datetime
    date_part, time_part = s.split(".", 1)
    # time_part may itself contain the fractional seconds after the last ':'
    hms, frac = time_part.rsplit(".", 1) if time_part.count(".") else (time_part, "0")
    dt = datetime.datetime.strptime(date_part + " " + hms, "%Y-%m-%d %H:%M:%S")
    return dt + datetime.timedelta(microseconds=int(frac.ljust(6, "0")[:6]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recfile", nargs="?", default="/var/log/swss/sairedis.rec")
    ap.add_argument("--since", default=None,
                    help="only count route ops at/after this timestamp "
                         "(YYYY-MM-DD.HH:MM:SS[.us])")
    ap.add_argument("--op", choices=sorted(OP_ACTIONS), default="create",
                    help="which window to measure (default: create)")
    ap.add_argument("--quiet", action="store_true",
                    help="print only: <count> <milliseconds>")
    args = ap.parse_args()

    # parse_ts already handles a timestamp with or without the .microseconds part
    since = parse_ts(args.since) if args.since else None
    actions = OP_ACTIONS[args.op]

    first = last = None
    count = 0
    try:
        with open(args.recfile, "r", errors="replace") as f:
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
                if first is None:
                    first = ts
                last = ts
                count += 1
    except FileNotFoundError:
        sys.exit("ERROR: %s not found" % args.recfile)

    verb = {"create": "created", "remove": "removed"}[args.op]
    if count == 0 or first is None:
        if args.quiet:
            print("0 0")
        else:
            print("No route %s ops found (check --since / --op / recfile)." % args.op)
        return

    ms = (last - first).total_seconds() * 1000.0
    if args.quiet:
        print("%d %.3f" % (count, ms))
    else:
        print("routes %s : %d" % (verb, count))
        print("first %-9s: %s" % (args.op, first))
        print("last %-10s: %s" % (args.op, last))
        print("window T       : %.3f ms  (%.3f s)" % (ms, ms / 1000.0))
        if ms > 0:
            print("rate           : %.1f routes/s" % (count / (ms / 1000.0)))


if __name__ == "__main__":
    main()
