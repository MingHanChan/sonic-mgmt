# Orchagent Route-Programming Performance Verification

A runbook + scripts to measure, on a real DUT, the route-programming speedup
from the three orchagent efficiency changes:

1. **swss.rec disabled by default** (orchagent hot-path I/O removed)
2. **NextHopGroupTable `std::map` -> `std::unordered_map`** (next-hop lookup O(log n) -> O(1))
3. **fpmsyncd -> orchagent route ZMQ direct path** (removes the Redis round-trip)

The headline metric **T** = the ASIC route-programming window: time from the
first to the last route `create` in `/var/log/swss/sairedis.rec`. sairedis.rec
is still enabled by default (`record_type=1`) after change #1, so this timing
source is always present. The same window measured over `remove` ops is the
**withdraw window** — route removal speed matters just as much during failure
convergence, so the orchestrators measure both.

```
improvement% = (T_baseline - T_treatment) / T_baseline * 100
```

> **What T does and does not cover.** sairedis.rec and the ASIC_DB key count
> are both written by the sairedis client library *inside orchagent*, i.e. they
> mark the orchagent egress boundary — syncd consumption and SDK/hardware
> programming happen after. For A/B comparison of these three changes that is
> the right boundary; for absolute end-to-end claims, cross-check with
> `hw_route_watch.sh` (below) that syncd kept up.

## Relationship to `tests/route/test_route_perf.py`

sonic-mgmt already ships `tests/route/test_route_perf.py`
(`test_perf_add_remove_routes`), which pushes routes with `swssconfig`, polls
`count_routes` on ASIC_DB and reports `end_time - start_time`. That test is the
framework-integrated, ptf/testbed-driven route-perf test.

This toolkit is a **companion**, not a replacement. It adds what the pytest test
does not cover for verifying these three specific changes:

- **A/B across the three changes** — toggles `swss.rec` (`-r`) and route ZMQ
  (`orch_northbond_route_zmq_enabled`) so you can attribute the gain.
- **Finer timing** from `sairedis.rec` (microsecond create timestamps) instead
  of ~1 s count-polling granularity.
- **Bottleneck attribution** — per-process/per-core CPU sampling during the
  burst tells you *which* stage the run was limited by.
- **`perf` profiling** of orchagent to see the NextHopGroupTable map->hash win.
- **DUT-direct** — runs over SSH with no ptf/minigraph/testbed, so you can spot
  check on any lab unit.

Use the pytest test for CI/regression; use this for the deployment A/B write-up.

## Layout

```
tests/route/perf_verify/
├── README.md                     # this runbook
├── docs/
│   └── bgp_announce_to_asic.md   # test case: BGP announce -> ASIC latency (end-to-end, see below)
└── scripts/
    ├── run_perf.sh               # Redis-path orchestrator: inject N routes (swssconfig), read add+del T, N iters, mean±std
    ├── inject_routes.py          # APPL_DB ROUTE_TABLE producer (swssconfig default; python/redis fallback)
    ├── run_t2_bgp.sh             # BGP-feed orchestrator (T1b: zmq off / T2: zmq on): mark, trigger peer, idle-wait, add+del T
    ├── gen_frr_routes.py         # generate FRR/vtysh static-route add/del batch for the BGP peer
    ├── measure_route_time.py     # parse sairedis.rec -> T (count, ms, rate; --op create|remove)
    ├── sample_proc_cpu.py        # /proc CPU sampler + env snapshot + bottleneck summary (--stats integration)
    ├── hw_route_watch.sh         # Broadcom cross-check: ASIC_DB vs bcmcmd completion lag
    ├── profile_orchagent.sh      # perf profile of orchagent to validate change #2
    ├── prep_bgp_burst.sh         # PEER side: preload N routes behind an outbound deny, release/withdraw as one burst
    ├── run_bgp_latency.sh        # DUT side: capture + trigger + wait, then the stage-resolved latency report
    └── bgp_latency_report.py     # tcpdump + sairedis.rec -> T_e2e / T_head / T_program + per-prefix p50/p99
```

All scripts run **on the DUT** (they need `sonic-db-cli`, docker access to the
`swss` container, and for profiling `perf`). Copy the `scripts/` dir to the
DUT, or run from the `sonic-mgmt` container over SSH.

## Prerequisites

- Two SONiC images on hand: **baseline** (unmodified `QUANTA_202211`) and
  **treatment** (with the three changes + the swss-common ZMQ backport).
- A quiet DUT — concretely: no BGP flaps, flex counters off for the run
  (`counterpoll show`, disable what is enabled), CRM polling left at/above the
  default 300 s (`crm config polling interval`). The `--stats` env snapshot
  records all of this per run so results stay auditable.
- `perf` on the DUT for change #2 profiling (`linux-tools` / `linux-perf`),
  **and debug symbols for orchagent** — a production image is stripped; use an
  image built with `INSTALL_DEBUG_TOOLS=y` or install the matching `swss-dbg` /
  `libsairedis-dbg` debs, or the report is unreadable addresses.
- **Know the ASIC route-table ceiling and stay under it.** The defaults here
  target a platform whose limit is **32000**, so the scripts default to
  `--count 30000` with a `--max-routes 32000` guard. Overshooting the ceiling
  is *silent*: swssconfig, orchagent and syncd all report success while the
  ASIC_DB count stops advancing partway, and any T from that truncated batch
  looks plausible but is void. Check the real limit with
  `crm show resources | grep ipv4_route` and set `--count` / `--max-routes` to
  match. Leftover routes from a previous run eat the same budget — the
  orchestrators count what is already there before injecting.
- Pick a route scale that matches your production table within that ceiling,
  plus an ECMP variant since NextHopGroupTable benefits scale with the
  number/size of next-hop groups.

## Measurement matrix

Run the SAME workload in each row, on the SAME DUT hardware:

| Row | Image | swss.rec | route ZMQ | Feed | Isolates |
|-----|-------|----------|-----------|------|----------|
| **B**   | baseline  | on (`-r 3`)  | n/a     | swssconfig | reference `T_B` |
| **T1**  | treatment | off (`-r 1`) | disable | swssconfig | change #1 + #2 (Redis path) |
| **T1b** | treatment | off (`-r 1`) | disable | BGP peer   | reference for #3 |
| **T2**  | treatment | off (`-r 1`) | enable  | BGP peer   | adds change #3 (ZMQ path) |

- change #1 + #2 improvement = `(T_B   - T_T1) / T_B   * 100`
- change #3 (incremental)     = `(T_T1b - T_T2) / T_T1b * 100`

**Do not** compute #3 as T1 vs T2: those two rows use different feeds
(swssconfig skips zebra/fpmsyncd entirely), so their T values are not
comparable. T1b exists precisely so the #3 comparison holds the feed, the
route set and the pipeline length constant, flipping only the ZMQ flag.
For a single end-to-end headline number, optionally run **B-bgp** (baseline
image, BGP feed) and quote `(T_B-bgp - T_T2) / T_B-bgp * 100`.

> To split #1 from #2 exactly you'd need an extra build with only one of them,
> or read #2 straight off the perf profile (see "Validating change #2").

---

## Rows B / T1 — Redis-path benchmark (swssconfig feed)

Uses `inject_routes.py`, which by default generates a swssconfig JSON batch and
runs `swssconfig` inside the swss container — the same C++ buffered-pipeline
channel `tests/route/test_route_perf.py` uses. This isolates the
orchagent-internal changes (#1, #2).

> **Why swssconfig and not a python producer:** the injector must be faster
> than orchagent's consumption or T measures the injector. `run_perf.sh`
> enforces this: any iteration whose produce-side time exceeds **T/3** is
> discarded as producer-bound. The `--via redis` fallback (python
> ProducerStateTable, buffered when the bindings allow) exists for setups
> where docker exec is unavailable — watch the produce times it prints.

On the DUT:

```bash
cd scripts

# run_perf.sh aborts if the route-ZMQ flag is on (orchagent would not consume
# APPL_DB ROUTE_TABLE) -- no manual flag check needed.

# 30k single-nexthop routes, 6 iterations (first discarded), with CPU sampling
./run_perf.sh --count 30000 --nexthop 192.168.1.1@Ethernet0 --iters 6 --stats /tmp/perfstats_t1

# ECMP variant (stresses NextHopGroupTable the most)
./run_perf.sh --count 30000 \
    --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4,192.168.1.3@Ethernet8,192.168.1.4@Ethernet12 \
    --iters 6
```

`run_perf.sh` prints per-iteration add/del T and a `T mean ± stddev` summary
for both windows. Record the means for **B** (baseline image) and **T1**
(treatment image, ZMQ off).

> Pick `--nexthop` IPs that resolve to real neighbors on your DUT (so the routes
> actually program to hardware). `ip neigh` / the interfaces in your config.

---

## Rows T1b / T2 — end-to-end BGP feed

With `orch_northbond_route_zmq_enabled=true`, orchagent's route consumer is a
`ZmqConsumerStateTable`; it no longer reads APPL_DB `ROUTE_TABLE`, so
`inject_routes.py` will NOT reach it. Routes must arrive through **fpmsyncd**,
i.e. a real BGP feed. Run the SAME BGP workload twice — once with the flag off
(**T1b**) and once with it on (**T2**); that pair isolates change #3.

1. Set the flag for the row (uses the new CLI from sonic-utilities):

   ```bash
   config route-zmq disable        # T1b row      (enable for the T2 row)
   config save -y && config reload -y      # or: systemctl restart swss bgp
   ```

Then advertise a fixed route set from the peer. Two options depending on what
the peer is: **method A (FRR/vtysh)** when the peer is a SONiC/FRR box (the usual
air-gapped SONiC-to-SONiC lab), or **method B (exabgp/gobgp)** when the peer is a
generic Linux host.

### Method A -- peer is a SONiC/FRR box (recommended for a SONiC-to-SONiC lab)

No package install needed: the peer's FRR already speaks BGP and the session to
the DUT is already up. Originate a batch of static routes and let FRR
redistribute them into BGP.

1. One-time, on the peer, enable static redistribution:

   ```bash
   frr-vtysh -c "configure terminal" \
             -c "router bgp <PEER_AS>" \
             -c "address-family ipv4 unicast" \
             -c "redistribute static"
   ```

2. Generate the add/withdraw batches (same route set as B/T1, on the peer):

   ```bash
   ./scripts/gen_frr_routes.py add --count 30000 --base 10.0.0.0 > /tmp/routes_add.conf
   ./scripts/gen_frr_routes.py del --count 30000 --base 10.0.0.0 > /tmp/routes_del.conf
   ```

3. Drive the run from the DUT with the BGP orchestrator (marks time, waits for
   the ASIC count to go idle, reads add T, then withdraw T). `--require-zmq`
   pins which row you are measuring — it aborts on a flag mismatch, and every
   result line is labeled with the flag state, so T1b and T2 numbers cannot be
   mixed up. It can trigger the peer over ssh, or prompt you to run `frr-vtysh`
   manually:

   ```bash
   # T1b row, auto-trigger (script ssh-es the peer, measures add + withdraw):
   ./scripts/run_t2_bgp.sh --expect 30000 --require-zmq false \
       --peer admin@192.168.1.1 --add-file /tmp/routes_add.conf \
       --del-file /tmp/routes_del.conf --stats /tmp/perfstats_t1b

   # T2 row, same command with the flag flipped on the DUT first:
   ./scripts/run_t2_bgp.sh --expect 30000 --require-zmq true \
       --peer admin@192.168.1.1 --add-file /tmp/routes_add.conf \
       --del-file /tmp/routes_del.conf --stats /tmp/perfstats_t2

   # or manual (it prompts; run 'frr-vtysh < /tmp/routes_add.conf' on the peer):
   ./scripts/run_t2_bgp.sh --expect 30000 --require-zmq true --measure-del
   ```

   > Feed the batch with `frr-vtysh < file` (stdin), NOT `vtysh -f <hostpath>`:
   > `frr-vtysh` execs into the `bgp` container, which has its own filesystem and
   > cannot see a path on the host.

`run_t2_bgp.sh` detects completion with an idle timer (waits as long as the count
keeps advancing, so a programming run longer than any fixed timeout is fine) and
prints T for the add and (with `--del-file`/`--measure-del`) the withdraw.
Repeat a few times and average — the orchestrator is single-shot by design so
the peer batch stays under your control.

### Method B -- peer is a generic Linux host (exabgp / gobgp)

Advertise the same route set with **exabgp** on the test host / a neighbor
container:

   ```
   # exabgp.conf (announce 30k /32 from a single peer)
   neighbor <DUT_BGP_IP> {
       router-id 10.9.9.9;
       local-address <PEER_IP>;
       local-as <PEER_AS>;
       peer-as <DUT_AS>;
       family { ipv4 unicast; }
       api { processes [ announcer ]; }
   }
   process announcer {
       run /usr/bin/python3 /path/to/announce_30k.py;   # loops 'announce route 10.0.i.j/32 next-hop <PEER_IP>'
       encoder text;
   }
   ```

   (gobgp works equally well: `gobgp global rib add` in a loop, or a MRT
   injection.) Keep the exact same route set for all rows so T is comparable.

Time it the same way — the ASIC window is still in sairedis.rec. You can reuse
the BGP orchestrator (its idle-wait + T read are transport agnostic; just
trigger exabgp/gobgp when it prompts), or do it by hand:

   ```bash
   MARK=$(date +"%Y-%m-%d.%H:%M:%S"); sleep 1
   # ... trigger the exabgp/gobgp announcement of the full set ...
   # wait until ASIC route count stabilises at the expected total, then:
   ./scripts/measure_route_time.py /var/log/swss/sairedis.rec --since "$MARK"
   ```

### Reading T1b vs T2

The ZMQ win shows up as lower T **and** lower `redis-server` CPU during the
burst — the `--stats` summary shows both signatures side by side. If instead
`zebra`/`fpmsyncd` saturate a core while `orchagent` idles, the FEED is the
bottleneck and the row pair cannot resolve change #3 (speed up the feed or
grow the batch).

---

## Test case: BGP announce -> ASIC programming latency

Rows T1b/T2 above report `last create - first create`, which is orchagent's
programming window only. If the question is instead **"the peer dumped N routes
at us — how long until they were in the ASIC?"**, that window starts too late:
everything from the wire to orchagent's first SAI call (TCP, bgpd parse and
bestpath, zebra, fpmsyncd, the APPL_DB/ZMQ hop, orchagent's queue) sits outside
it, and on a 30k burst that head is seconds.

`docs/bgp_announce_to_asic.md` is a self-contained test case for that question.
It anchors T0 on the wire (`tcpdump` of the peer's first BGP UPDATE) and T1 at
the last SAI create for the announced set, so it reports:

```
T_e2e     = D' - A    announce received -> all routes in ASIC   <- headline
T_head    = D  - A    receive -> orchagent's first SAI call
T_program = D' - D    orchagent's SAI programming window        <- what T1b/T2 report
```

plus a per-prefix p50/p90/p99 and a hard validity gate on how bursty the arrival
actually was. Both anchors are passive, so unlike a count-polling measurement
nothing in the metric depends on how fast the harness polls.

```bash
# on the peer: arm (slow, outside the window)
./prep_bgp_burst.sh prepare --dut-ip 10.0.0.0 --asn 65100 --count 30000

# on the DUT: capture, release the burst, report
./run_bgp_latency.sh --peer admin@10.0.0.1 --peer-ip 10.0.0.1 --dut-ip 10.0.0.0 \
    --peer-asn 65100 --count 30000 --out /tmp/bgpperf --measure-withdraw
```

> The burst matters. Feeding `ip route` lines into vtysh live announces a
> *trickle* at the peer's parse rate, and any DUT number measured off it is
> really a peer measurement — `prep_bgp_burst.sh` exists to separate the two,
> and the report fails the run when the arrival was not a burst.

---

## CPU sampling & the environment snapshot (`--stats`)

Both orchestrators take `--stats <dir>`; they start `sample_proc_cpu.py`
alongside the run and print its summary at the end. It samples
orchagent/syncd/redis-server/fpmsyncd/zebra/bgpd and every core once per
second from /proc (no sysstat dependency), and snapshots the noise-relevant
config (route-ZMQ flag, counterpoll, CRM interval, orchagent args, image
version) into `<dir>/env.txt`.

Interpretation: orchagent's main loop is single-threaded, so **whichever
process pins one core near 100% during the burst is the bottleneck stage**:

- `orchagent` ≈100% -> orchagent-bound: changes #1/#2 are the lever.
- `redis-server` high on B/T1/T1b and low on T2 -> the Redis hop removal is real.
- `zebra`/`fpmsyncd` pinned with orchagent idle-ish -> feed-bound; fix before A/B.
- nothing pinned -> batch too small, neighbors unresolved, or waits dominate.

Standalone use: `sample_proc_cpu.py record --out DIR` / `summarize --out DIR`.

## Hardware-side cross-check (`hw_route_watch.sh`, Broadcom)

Because sairedis.rec/ASIC_DB mark the orchagent egress, a lagging syncd would
be invisible to T. Once per scenario (not every iteration), start the watcher
before the injection:

```bash
./scripts/hw_route_watch.sh --expect 30000 &     # may need --count-cmd 'sudo bcmcmd "l3 defip show"'
./scripts/run_perf.sh --count 30000 --nexthop 192.168.1.1@Ethernet0 --iters 1
```

It polls ASIC_DB and `bcmcmd "l3 defip show"` side by side and reports the lag
between the two completion times. Small lag (≈ polling granularity) -> the
sairedis.rec window is a fair proxy for hardware completion; large lag ->
quote the hardware time. Each bcmcmd at 30k entries can take a few seconds,
so raise `--interval` at high scale; this is a cross-check, not the headline.

---

## Validating change #2 (NextHopGroupTable) directly

The map->unordered_map win is a CPU-profile change. Kick the profiler just
before injecting an ECMP-heavy batch:

```bash
./scripts/profile_orchagent.sh 60 /tmp/orchagent_perf.txt &
./scripts/run_perf.sh --count 30000 --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4 --iters 1
```

In the report, on the **baseline** image you should see a large share under the
red-black tree comparison path (`std::_Rb_tree...`, `NextHopGroupKey::operator<`)
— upstream measured ~30% of orchagent CPU in next-hop lookup. On the
**treatment** image that collapses into a cheap `std::_Hashtable` / `hash<...>`
probe. The shrink in that share is change #2's contribution.

**Symbols required**: the script warns when most samples are unresolved
addresses. That means a stripped production build — use an
`INSTALL_DEBUG_TOOLS=y` image or install the matching `swss-dbg` /
`libsairedis-dbg` debs, and use a `perf` that matches the running kernel.

---

## Reading the result

For each row, take the `T mean` from the orchestrator summary, then:

| Quantity | Formula | Example |
|----------|---------|---------|
| #1+#2 (Redis path)   | `(T_B   - T_T1) / T_B`   | (5.0s - 4.0s)/5.0s = **20%** |
| #3 (ZMQ, incremental) | `(T_T1b - T_T2) / T_T1b` | (4.2s - 3.4s)/4.2s = **19%** |
| end-to-end (optional B-bgp row) | `(T_B-bgp - T_T2) / T_B-bgp` | — |

Report `mean ± stddev` across the counted iterations, not a single run, for
both the add and the withdraw window, and attach the `--stats` bottleneck
summary for each row. If stddev exceeds ~5% of the mean, find the noise source
before comparing rows.

## Parity check (do this once per image pair)

A transport that silently drops events makes T look *better*. Before quoting
numbers, verify on the treatment image with ZMQ on:

- FRR RIB, APPL_DB `ROUTE_TABLE` (written asynchronously by the producer's
  AsyncDBUpdater) and ASIC_DB route counts all match the expected set exactly
  (`run_t2_bgp.sh --expect` already cross-checks the ASIC_DB delta).
- A warm restart after a ZMQ-path run reconciles cleanly (APPL_DB is the warm
  restart source, so the async write-back must be complete and correct).
- orchagent RSS before/after (both changes trade memory for speed):
  `grep VmRSS /proc/$(pidof orchagent)/status`.

## Gotchas

- **Warm-up**: the orchestrators discard iteration 1. Keep it.
- **Never stage a file into the swss container with `docker cp`.** SONiC starts
  its containers with `--tmpfs /tmp` (`docker_image_ctl.j2`,
  `mount_default_tmpfs`), and `docker cp` writes to the rootfs layer
  *underneath* a tmpfs mount instead of into it: the copy exits 0 while the
  file remains invisible inside the container, and `swssconfig` fails with
  `Failed to open file /tmp/...`. `inject_routes.py` streams the batch in via
  `docker exec -i` (the container's own mount namespace) and verifies the byte
  count; use the same approach for anything else you stage there. Same family
  of gotcha as `frr-vtysh < file` vs `vtysh -f <hostpath>` above.
- **Producer-bound iterations are discarded** (produce time > T/3). `swssconfig`
  is already the fastest injector available (C++ buffered pipeline); its ceiling
  on a given DUT is fixed (measured ~2000–2500 routes/s on a modest control-plane
  CPU). If orchagent programs at a similar rate, T is dominated by the feed and
  **every** iteration is discarded — that is not a bug, the Redis micro-benchmark
  just cannot isolate orchagent on that unit. `run_perf.sh` says so at the end and
  points you at the feed-independent tools: `profile_orchagent.sh` for change #2
  and `run_t2_bgp.sh` (BGP feed) for change #3. A bigger `--count` does not help —
  produce time scales with it too.
- **Routes are recorded in BULK.** orchagent writes SAI route ops as bulk `C`
  (create) / `R` (remove) records — one sairedis.rec line packs ~hundreds of
  routes — so ~50 lines for 30000 routes is normal, not truncation. The
  orchestrator prints both counts (`add 30000 routes / 50 SAI ops`) and gates
  validity on the **ASIC_DB delta** (the real route count), never on the line
  count; T is still first-op to last-op across those bulk lines.
- **Same route set & ECMP distribution** across all rows — NextHopGroupTable
  gains scale with the number and size of next-hop groups.
- **Fixed batch size**: orchagent.sh already pins `-b 8192`; keep both images
  identical.
- **Neighbors must resolve**: unresolved next hops won't program to the ASIC and
  will skew / stall the count.
- **Counters off, CRM slow**: flex counters (`counterpoll`) and fast CRM
  polling add orchagent/syncd CPU noise; the env snapshot records what was on.
- **Start from a clean table**: a `SET` on a prefix RouteOrch already holds
  takes the *update* path and emits **no SAI create**, so leftover routes in
  the injected prefix range silently shrink the batch to whatever is genuinely
  new. This shows up as the **ASIC_DB delta** falling short of `--count` (the
  orchestrator's `ONLY <delta>/<count> routes reached ASIC_DB` discard), not as
  a low SAI-op line count (that is just bulk recording — see above). Withdraw on
  the peer *and* `inject_routes.py del` on the DUT between scenarios, and confirm
  the count is back to its pre-test baseline.
- **One writer to sairedis.rec**: scope every measurement with `--since <marker>`
  so you never mix two runs.
- **sairedis.rec rotates**: logrotate (`files/image_config/logrotate/rsyslog.j2`,
  fired every 10 min by cron) rotates `/var/log/swss/sairedis*.rec` at `size 1M`
  (small-disk images) or `16M`, keeping segments (`rotate 5000`, `.1` plain and
  `.2+` gz) and SIGHUPing orchagent to reopen. A run that straddles a rotation
  therefore has its records split across `sairedis.rec`, `.rec.1`, `.rec.2.gz` …
  `measure_route_time.py` stitches those siblings back together when `--since` is
  given and tolerates logrotate mutating a segment mid-read, so this no longer
  corrupts T. If a segment is genuinely deleted (disk pressure), the ASIC_DB
  delta still validates the route count and the affected iteration surfaces as a
  T outlier caught by the stddev check.
- **T1 vs T2 are different feeds** — never quote them against each other; the
  ZMQ comparison is T1b vs T2 only.
- **Multi-ASIC**: run per-namespace (`sonic-db-cli -n asic0 ...`, sairedis.rec is
  `sairedis.asic0.rec`, container `swss0`), one namespace at a time.
