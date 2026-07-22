#!/usr/bin/env python3
"""
Per-process and per-core CPU sampler for route-programming runs. Run ON the
DUT. No dependencies beyond python3 + /proc (sysstat/pidstat is not installed
on every SONiC image).

The point of sampling during a run is bottleneck attribution: orchagent's main
loop is single-threaded, so the process that pins one core near 100% during
the burst IS the bottleneck stage. The expected signatures:

  - orchagent  ~100% of a core          -> orchagent-bound (changes #1/#2 apply)
  - redis-server high on B/T1, low on T2 -> the ZMQ path removed the Redis hop
  - zebra/fpmsyncd pinned, orchagent idle-ish -> the FEED is the bottleneck and
    T no longer isolates the DUT changes (fix the feed before comparing)

Usage:
    # start sampling (runs until SIGTERM/SIGINT, or --duration)
    ./sample_proc_cpu.py record --out /tmp/perfstats [--interval 1] [--procs a,b,c]

    # stop it, then summarize
    ./sample_proc_cpu.py summarize --out /tmp/perfstats

record also snapshots the noise-relevant environment (route-ZMQ flag,
counterpoll, CRM polling interval, orchagent args, image version) into
<out>/env.txt so every result archive is self-describing.

run_perf.sh / run_t2_bgp.sh integrate this via their --stats <dir> flag.
"""
import argparse
import csv
import os
import signal
import subprocess
import sys
import time

DEFAULT_PROCS = "orchagent,syncd,redis-server,fpmsyncd,zebra,bgpd"
CSV_NAME = "proc_cpu.csv"
ENV_NAME = "env.txt"

ENV_CMDS = [
    ("date", "date"),
    ("image version", "show version 2>/dev/null | head -12"),
    ("route ZMQ flag",
     "sonic-db-cli CONFIG_DB hget 'DEVICE_METADATA|localhost' "
     "orch_northbond_route_zmq_enabled"),
    ("orchagent args", "ps -o pid=,args= -C orchagent"),
    ("counterpoll", "counterpoll show 2>/dev/null"),
    ("crm summary (polling interval)", "crm show summary 2>/dev/null"),
]


def snapshot_env(out_dir):
    path = os.path.join(out_dir, ENV_NAME)
    with open(path, "w") as f:
        for title, cmd in ENV_CMDS:
            f.write("### %s\n$ %s\n" % (title, cmd))
            try:
                r = subprocess.run(cmd, shell=True, capture_output=True,
                                   text=True, timeout=30)
                f.write(r.stdout)
                if r.stderr.strip():
                    f.write("[stderr] " + r.stderr)
            except Exception as e:  # snapshot is best-effort
                f.write("[failed: %s]\n" % e)
            f.write("\n")
    return path


def find_pids(names):
    """comm-name -> {pid: name}. Re-resolved every tick so restarts/multi-asic
    instances are picked up."""
    pids = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % entry) as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm in names:
            pids[int(entry)] = comm
    return pids


def read_pid_ticks(pid):
    """utime+stime of a pid, in clock ticks."""
    with open("/proc/%d/stat" % pid) as f:
        data = f.read()
    # comm may contain spaces/parens; fields resume after the last ')'
    fields = data.rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])   # utime + stime


def read_core_ticks():
    """cpuN -> (busy_ticks, total_ticks)."""
    cores = {}
    with open("/proc/stat") as f:
        for line in f:
            if not line.startswith("cpu") or line[3] == " ":
                continue   # skip the aggregate 'cpu ' line
            parts = line.split()
            vals = [int(v) for v in parts[1:]]
            total = sum(vals)
            idle = vals[3] + (vals[4] if len(vals) > 4 else 0)  # idle + iowait
            cores[parts[0]] = (total - idle, total)
    return cores


def record(args):
    os.makedirs(args.out, exist_ok=True)
    env_path = snapshot_env(args.out)
    print("env snapshot: %s" % env_path)

    hz = os.sysconf("SC_CLK_TCK")
    names = set(args.procs.split(","))
    csv_path = os.path.join(args.out, CSV_NAME)

    stop = {"flag": False}

    def on_signal(signum, frame):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    prev_pid_ticks = {}
    prev_cores = read_core_ticks()
    deadline = time.time() + args.duration if args.duration else None

    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ts", "kind", "name", "value"])
        print("sampling every %.1fs -> %s (stop with SIGTERM/Ctrl-C)"
              % (args.interval, csv_path))
        while not stop["flag"]:
            time.sleep(args.interval)
            now = time.time()
            ts = "%.1f" % now

            for pid, name in sorted(find_pids(names).items()):
                try:
                    ticks = read_pid_ticks(pid)
                except OSError:
                    continue   # exited between listing and reading
                if pid in prev_pid_ticks:
                    cpu = (ticks - prev_pid_ticks[pid]) / hz / args.interval * 100.0
                    w.writerow([ts, "proc", "%s(%d)" % (name, pid), "%.1f" % cpu])
                prev_pid_ticks[pid] = ticks

            cores = read_core_ticks()
            for core, (busy, total) in cores.items():
                pbusy, ptotal = prev_cores.get(core, (busy, total))
                dtotal = total - ptotal
                if dtotal > 0:
                    w.writerow([ts, "core", core,
                                "%.1f" % (100.0 * (busy - pbusy) / dtotal)])
            prev_cores = cores
            f.flush()

            if deadline and now >= deadline:
                break
    print("stopped; summarize with: %s summarize --out %s"
          % (sys.argv[0], args.out))


def summarize(args):
    csv_path = os.path.join(args.out, CSV_NAME)
    if not os.path.exists(csv_path):
        sys.exit("ERROR: %s not found (was record run?)" % csv_path)

    procs = {}   # name -> [values]
    cores = {}   # core -> [values]
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            v = float(row["value"])
            bucket = procs if row["kind"] == "proc" else cores
            bucket.setdefault(row["name"], []).append(v)

    if not procs and not cores:
        sys.exit("ERROR: no samples in %s" % csv_path)

    print("== per-process CPU% (of one core; >100 means multi-threaded) ==")
    print("%-22s %8s %8s %8s %8s" % ("process", "samples", "avg", "p95", "max"))
    saturated = []
    for name in sorted(procs, key=lambda n: -max(procs[n])):
        vals = sorted(procs[name])
        avg = sum(vals) / len(vals)
        p95 = vals[min(len(vals) - 1, int(0.95 * len(vals)))]
        mx = vals[-1]
        print("%-22s %8d %8.1f %8.1f %8.1f" % (name, len(vals), avg, p95, mx))
        if p95 >= 85.0:
            saturated.append((name, p95))

    if cores:
        hottest = max(cores.items(), key=lambda kv: max(kv[1]))
        print("\nhottest core: %s (max %.1f%% busy)"
              % (hottest[0], max(hottest[1])))

    print()
    if saturated:
        for name, p95 in saturated:
            print(">> %s sustained ~a full core (p95 %.1f%%) -- bottleneck "
                  "candidate" % (name, p95))
    else:
        print(">> no process sustained a full core; if T did not improve, the "
              "bottleneck is likely outside the DUT pipeline (feed, neighbors, "
              "hardware) or the batch is too small to saturate it")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["record", "summarize"])
    ap.add_argument("--out", required=True, help="stats directory")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--procs", default=DEFAULT_PROCS,
                    help="comma-separated comm names (default: %s)" % DEFAULT_PROCS)
    ap.add_argument("--duration", type=float, default=0,
                    help="record: auto-stop after N seconds (0 = until signal)")
    args = ap.parse_args()

    if args.mode == "record":
        record(args)
    else:
        summarize(args)


if __name__ == "__main__":
    main()
