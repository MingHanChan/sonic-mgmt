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

Rotation-aware: a batch of tens of thousands of routes writes several MB to
sairedis.rec, which blows past the logrotate 'size' threshold (1M on
small-disk images, 16M otherwise; see files/image_config/logrotate/rsyslog.j2)
so the file ROTATES one or more times mid-run. logrotate keeps the segments
('rotate 5000') and SIGHUPs orchagent to reopen, so the run's data ends up
split across sairedis.rec, sairedis.rec.1 and sairedis.rec.2.gz ... -- reading
only the current file would see just the tail (e.g. 40 of 30000 creates) and
report a meaningless T. When --since is given we therefore scan the current
file AND its rotated siblings (numeric suffix, optionally .gz) and take the
global min/max timestamp; --since filters each line so only this run counts.

Usage:
    # measure the whole current file (single file, no rotation stitching)
    ./measure_route_time.py /var/log/swss/sairedis.rec

    # only routes created after a marker time (e.g. start of this run);
    # rotated siblings are stitched in automatically
    ./measure_route_time.py /var/log/swss/sairedis.rec --since "2026-07-16.09:00:00"

    # the withdraw window of a batch removed after the marker
    ./measure_route_time.py /var/log/swss/sairedis.rec --since "..." --op remove

    # machine-readable one-liner for run_perf.sh to capture
    ./measure_route_time.py /var/log/swss/sairedis.rec --quiet
"""
import argparse
import datetime
import glob
import gzip
import os
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


# A rotated sibling of <recfile>: a numeric suffix, optionally .gz-compressed
# (delaycompress leaves .1 plain and gzips .2 onward). NOT date-suffixed --
# the SONiC logrotate config uses numeric suffixes.
_SIBLING_SUFFIX_RE = re.compile(r"\.\d+(\.gz)?$")


def rec_segments(recfile):
    """The current rec file plus its rotated siblings, so a run whose output
    rotated mid-measurement is read whole. Order is irrelevant -- the caller
    takes the global min/max timestamp across every segment."""
    segments = []
    if os.path.exists(recfile):
        segments.append(recfile)
    for path in glob.glob(glob.escape(recfile) + ".*"):
        if _SIBLING_SUFFIX_RE.fullmatch(path[len(recfile):]):
            segments.append(path)
    return segments


def scan_segment(path, actions, since, first, last, count):
    """Fold one rec segment into the running (first, last, count). Uses global
    min/max rather than first-seen/last-seen because, once segments are
    stitched, chronological order is not guaranteed across files.

    Tolerant of a segment that logrotate mutates underneath us: between the
    glob that discovered it and this open, or mid-read, logrotate (the SONiC
    cron fires it every 10 min) can rename it (.1 -> .2), compress it
    (.1 -> .1.gz) or delete it. A vanished or half-written/half-compressed
    segment must not abort the whole measurement -- skip it and note it on
    stderr. Its rows are either already counted from the sibling it moved to,
    or genuinely gone (in which case run_perf.sh's ASIC_DB delta is the
    authoritative route count, not this line tally)."""
    opener = gzip.open if path.endswith(".gz") else open
    try:
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
                if first is None or ts < first:
                    first = ts
                if last is None or ts > last:
                    last = ts
                count += 1
    except (OSError, EOFError) as e:
        # FileNotFoundError/BadGzipFile are OSError subclasses; a truncated gz
        # raises EOFError. All mean "logrotate is touching this segment".
        print("note: skipped rec segment %s (%s)" % (path, e.__class__.__name__),
              file=sys.stderr)
    return first, last, count


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

    # With --since we stitch in rotated siblings (the run may have rotated the
    # file mid-measurement). Without it, keep the historical single-file
    # behaviour -- summing every rotated segment with no lower time bound would
    # fold in all prior history, which is not what a bare invocation means.
    if since is not None:
        segments = rec_segments(args.recfile)
    else:
        segments = [args.recfile] if os.path.exists(args.recfile) else []

    if not segments:
        sys.exit("ERROR: %s not found" % args.recfile)

    first = last = None
    count = 0
    for path in segments:
        first, last, count = scan_segment(path, actions, since, first, last, count)

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
        if since is not None and len(segments) > 1:
            print("segments read  : %d (rotated mid-run: %s)"
                  % (len(segments), ", ".join(os.path.basename(s) for s in segments)))


if __name__ == "__main__":
    main()
