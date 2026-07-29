#!/usr/bin/env python3
"""
analyze_runs.py -- 把 route_perf_probe.py 產生的 CSV 換算成可比較的指標。

    ./analyze_runs.py baseline.csv                 # 單一 run
    ./analyze_runs.py baseline.csv zmq_on.csv      # A/B 比較
    ./analyze_runs.py 'base_*.csv' --vs 'zmq_*.csv'  # 多 run 取中位數

輸出:
  routes            這一輪實際新增(或刪除)的路由數
  wall_s            從第一筆路由進 ASIC 到最後一筆的牆鐘時間
  routes/s          吞吐量(主要指標)
  <proc>_us/route   每條路由花掉的 CPU 微秒數(次要但更抗噪的指標)
  nhg_used          期間建立的 next hop group 數 -- 用來確認 unordered_map
                    這個改動到底有沒有被觸發(太小就代表沒測到)
"""

import argparse
import csv
import glob
import os
import statistics
import sys

CLK_TCK = os.sysconf("SC_CLK_TCK")


def load(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("empty csv: %s" % path)
    return rows


def analyse(path, lo_pct=0.02, hi_pct=0.99):
    rows = load(path)
    v4 = [int(r["crm_stats_ipv4_route_used"]) for r in rows]
    v6 = [int(r["crm_stats_ipv6_route_used"]) for r in rows]
    tot = [a + b for a, b in zip(v4, v6)]
    ts = [float(r["ts"]) for r in rows]

    start, end = tot[0], max(tot)
    delta = end - start
    direction = "add"
    if delta <= 0:  # 刪除情境
        end = min(tot)
        delta = start - end
        direction = "del"
    if delta <= 0:
        sys.exit("%s: route count never changed -- 注入沒有生效?" % path)

    def idx_at(frac):
        target = start + delta * frac if direction == "add" else start - delta * frac
        for i, v in enumerate(tot):
            if (direction == "add" and v >= target) or (direction == "del" and v <= target):
                return i
        return len(tot) - 1

    i0, i1 = idx_at(lo_pct), idx_at(hi_pct)
    if i1 <= i0:
        i1 = len(tot) - 1
    wall = ts[i1] - ts[i0]
    counted = abs(tot[i1] - tot[i0])

    res = {
        "file": os.path.basename(path),
        "direction": direction,
        "routes": counted,
        "routes_total": delta,
        "wall_s": wall,
        "routes_per_s": counted / wall if wall > 0 else float("nan"),
        "nhg_used_delta": int(rows[i1]["crm_stats_nexthop_group_used"])
        - int(rows[i0]["crm_stats_nexthop_group_used"]),
        "nhg_used_peak": max(int(r["crm_stats_nexthop_group_used"]) for r in rows),
    }

    for key in rows[0]:
        if not key.endswith("_utime"):
            continue
        proc = key[: -len("_utime")]
        du = int(rows[i1][proc + "_utime"]) - int(rows[i0][proc + "_utime"])
        ds = int(rows[i1][proc + "_stime"]) - int(rows[i0][proc + "_stime"])
        cpu_s = (du + ds) / float(CLK_TCK)
        res["%s_cpu_s" % proc] = cpu_s
        res["%s_us_per_route" % proc] = cpu_s * 1e6 / counted if counted else float("nan")
        res["%s_rss_mb" % proc] = int(rows[i1][proc + "_rss"]) / (1024.0 * 1024.0)
    return res


def median_of(paths):
    runs = [analyse(p) for p in paths]
    keys = runs[0].keys()
    out = {"file": "%d runs: %s" % (len(runs), os.path.basename(paths[0]))}
    for k in keys:
        vals = [r[k] for r in runs if isinstance(r[k], (int, float))]
        if vals:
            out[k] = statistics.median(vals)
    out["direction"] = runs[0]["direction"]
    return out, runs


def show(res, title):
    print("\n=== %s (%s) ===" % (title, res["file"]))
    print("  direction        : %s" % res["direction"])
    print("  routes measured  : %d" % res["routes"])
    print("  wall time        : %.3f s" % res["wall_s"])
    print("  throughput       : %.1f routes/s" % res["routes_per_s"])
    print("  nhg created      : %d (peak in table: %d)"
          % (res.get("nhg_used_delta", -1), res.get("nhg_used_peak", -1)))
    if res.get("nhg_used_peak", 0) < 32:
        print("  !! next hop group 數量太少,unordered_map 這個改動幾乎不會被觸發")
    for k in sorted(res):
        if k.endswith("_us_per_route"):
            proc = k[: -len("_us_per_route")]
            print("  %-16s : %8.1f us/route   (total %.2f s CPU, rss %.0f MB)"
                  % (proc, res[k], res["%s_cpu_s" % proc], res["%s_rss_mb" % proc]))


def compare(a, b):
    print("\n=== A/B 比較 (A=baseline, B=new) ===")
    print("  %-30s %12s %12s %10s" % ("metric", "A", "B", "change"))

    def line(name, va, vb, higher_is_better):
        if va in (0, None) or vb is None:
            return
        pct = (vb - va) / va * 100.0
        good = (pct > 0) == higher_is_better
        print("  %-30s %12.1f %12.1f %+9.1f%% %s"
              % (name, va, vb, pct, "(better)" if good else "(worse)"))

    line("routes/s", a["routes_per_s"], b["routes_per_s"], True)
    line("wall_s", a["wall_s"], b["wall_s"], False)
    for k in sorted(a):
        if k.endswith("_us_per_route") and k in b:
            line(k, a[k], b[k], False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a", help="baseline CSV 或 glob")
    ap.add_argument("b", nargs="?", help="要比較的 CSV 或 glob")
    ap.add_argument("--vs", help="等同於位置參數 b")
    args = ap.parse_args()

    pa = sorted(glob.glob(args.a)) or [args.a]
    ra, _ = median_of(pa)
    show(ra, "A")

    target = args.b or args.vs
    if target:
        pb = sorted(glob.glob(target)) or [target]
        rb, _ = median_of(pb)
        show(rb, "B")
        compare(ra, rb)


if __name__ == "__main__":
    main()
