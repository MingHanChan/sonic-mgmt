#!/usr/bin/env python3
"""
route_perf_probe.py -- 在 SONiC DUT 上取樣 route programming 進度與各 process CPU。

在 DUT 的 host 上執行(不是在容器內),於觸發 route burst 之前啟動:

    ./route_perf_probe.py --out /tmp/run_zmq_on_1.csv --duration 300

輸出 CSV 給 analyze_runs.py 分析。另外會輸出 <out>.info.json,內含測試前後
redis INFO commandstats / stats 的快照,用來量化 ZMQ 省下的 Redis 操作。

取樣點的選擇說明:
  * CRM used counters (COUNTERS_DB CRM:STATS) 是 O(1) 讀取,可以高頻取樣而
    幾乎不擾動待測系統;它反映 orchagent 已經完成 addRoutePost 的路由數。
  * ASIC_DB / APPL_DB 用 DBSIZE(O(1))當作輔助曲線;不要用 KEYS 掃描,
    那是 blocking 操作,會直接污染量測結果。
  * 注意:ZMQ 開啟後 APPL_DB 是由 producer 端 AsyncDBUpdater 非同步寫入,
    APPL_DB 的成長曲線會落後 ASIC_DB,不能拿來當進度指標。
"""

import argparse
import glob
import json
import os
import sys
import time

try:
    import redis
except ImportError:
    sys.exit("need python3 redis module: apt-get install python3-redis / pip3 install redis")

CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")

CRM_FIELDS = [
    "crm_stats_ipv4_route_used",
    "crm_stats_ipv6_route_used",
    "crm_stats_nexthop_group_used",
    "crm_stats_nexthop_group_member_used",
    "crm_stats_ipv4_nexthop_used",
    "crm_stats_ipv4_neighbor_used",
]

DEFAULT_PROCS = ["orchagent", "fpmsyncd", "syncd", "redis-server"]


def find_pids(pattern):
    """Return every pid whose cmdline contains `pattern`.

    SONiC 的容器共用 host 的 PID namespace 視野,所以在 host 上掃 /proc
    就看得到 swss/bgp/syncd/database 容器內的 process。
    """
    pids = []
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(path, "rb") as f:
                cmdline = f.read().replace(b"\0", b" ").decode(errors="replace")
        except (IOError, OSError):
            continue
        if not cmdline:
            continue
        # 排除自己與其他 wrapper
        if "route_perf_probe" in cmdline:
            continue
        if pattern in cmdline:
            pids.append(int(path.split("/")[2]))
    return sorted(pids)


def read_cpu(pid):
    """(utime_ticks, stime_ticks, rss_bytes) for a pid, or None if it is gone."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            line = f.read()
        # comm 可能含空白與括號,從最後一個 ')' 之後開始切
        rest = line[line.rindex(")") + 2:].split()
        utime = int(rest[11])
        stime = int(rest[12])
        with open("/proc/%d/statm" % pid) as f:
            rss_pages = int(f.read().split()[1])
        return utime, stime, rss_pages * PAGE_SIZE
    except (IOError, OSError, ValueError, IndexError):
        return None


def read_total_cpu():
    with open("/proc/stat") as f:
        parts = f.readline().split()[1:]
    vals = [int(v) for v in parts]
    return sum(vals), vals[3]  # total, idle


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="output CSV path")
    ap.add_argument("--duration", type=float, default=300.0, help="總取樣秒數")
    ap.add_argument("--interval", type=float, default=0.2, help="取樣間隔秒數")
    ap.add_argument("--socket", default="/var/run/redis/redis.sock")
    ap.add_argument("--procs", default=",".join(DEFAULT_PROCS),
                    help="要追蹤 CPU 的 process cmdline 關鍵字,逗號分隔")
    ap.add_argument("--stop-when-idle", type=float, default=0.0,
                    help=">0 時,CRM route used 連續這麼多秒沒變化就提早結束")
    args = ap.parse_args()

    procs = [p for p in args.procs.split(",") if p]
    pidmap = {p: find_pids(p) for p in procs}
    for name, pids in pidmap.items():
        print("[probe] %-14s pids=%s" % (name, pids or "NONE"), file=sys.stderr)

    appl = redis.Redis(unix_socket_path=args.socket, db=0)
    asic = redis.Redis(unix_socket_path=args.socket, db=1)
    cnts = redis.Redis(unix_socket_path=args.socket, db=2)

    info_before = {
        "commandstats": cnts.info("commandstats"),
        "stats": cnts.info("stats"),
        "ts": time.time(),
    }

    header = ["ts"] + CRM_FIELDS + ["appl_dbsize", "asic_dbsize", "cpu_total", "cpu_idle"]
    for p in procs:
        header += ["%s_utime" % p, "%s_stime" % p, "%s_rss" % p]

    fh = open(args.out, "w")
    fh.write(",".join(header) + "\n")

    t_end = time.time() + args.duration
    next_t = time.time()
    last_route_val = None
    last_change = time.time()

    try:
        while time.time() < t_end:
            now = time.time()
            crm = cnts.hmget("CRM:STATS", CRM_FIELDS)
            crm = [int(v) if v is not None else -1 for v in crm]
            row = [("%.6f" % now)] + [str(v) for v in crm]
            row += [str(appl.dbsize()), str(asic.dbsize())]
            tot, idle = read_total_cpu()
            row += [str(tot), str(idle)]
            for p in procs:
                u = s = r = 0
                alive = False
                for pid in pidmap[p]:
                    v = read_cpu(pid)
                    if v:
                        alive = True
                        u += v[0]
                        s += v[1]
                        r += v[2]
                if not alive:  # process 重啟過,重新解析 pid
                    pidmap[p] = find_pids(p)
                row += [str(u), str(s), str(r)]
            fh.write(",".join(row) + "\n")
            fh.flush()

            if args.stop_when_idle > 0:
                cur = crm[0] + crm[1]
                if cur != last_route_val:
                    last_route_val = cur
                    last_change = now
                elif last_route_val not in (None, 0) and now - last_change > args.stop_when_idle:
                    print("[probe] route count idle for %.1fs, stopping" % args.stop_when_idle,
                          file=sys.stderr)
                    break

            next_t += args.interval
            sleep = next_t - time.time()
            if sleep > 0:
                time.sleep(sleep)
            else:
                next_t = time.time()
    except KeyboardInterrupt:
        pass
    finally:
        fh.close()

    info_after = {
        "commandstats": cnts.info("commandstats"),
        "stats": cnts.info("stats"),
        "ts": time.time(),
    }
    with open(args.out + ".info.json", "w") as f:
        json.dump({"before": info_before, "after": info_after}, f, indent=2, default=str)
    print("[probe] wrote %s and %s.info.json" % (args.out, args.out), file=sys.stderr)


if __name__ == "__main__":
    main()
