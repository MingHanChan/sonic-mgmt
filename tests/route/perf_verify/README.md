# Orchagent Route-Programming Performance Verification

A runbook + scripts to measure, on a real DUT, the route-programming speedup
from the three orchagent efficiency changes:

1. **swss.rec disabled by default** (orchagent hot-path I/O removed)
2. **NextHopGroupTable `std::map` -> `std::unordered_map`** (next-hop lookup O(log n) -> O(1))
3. **fpmsyncd -> orchagent route ZMQ direct path** (removes the Redis round-trip)

The headline metric **T** = the ASIC route-programming window: time from the
first to the last route `create` in `/var/log/swss/sairedis.rec`. sairedis.rec
is still enabled by default (`record_type=1`) after change #1, so this timing
source is always present.

```
improvement% = (T_baseline - T_treatment) / T_baseline * 100
```

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
- **`perf` profiling** of orchagent to see the NextHopGroupTable map->hash win.
- **DUT-direct** — runs over SSH with no ptf/minigraph/testbed, so you can spot
  check on any lab unit.

Use the pytest test for CI/regression; use this for the deployment A/B write-up.

## Layout

```
tests/route/perf_verify/
├── README.md                     # this runbook
└── scripts/
    ├── run_perf.sh               # T1 orchestrator: inject N routes (APPL_DB), wait, read T, N iters, mean±std
    ├── inject_routes.py          # APPL_DB ROUTE_TABLE producer (Redis-path micro-benchmark)
    ├── run_t2_bgp.sh             # T2 orchestrator: mark, (ssh) trigger BGP peer, idle-wait, read T
    ├── gen_frr_routes.py         # generate FRR/vtysh static-route add/del batch for the BGP peer
    ├── measure_route_time.py     # parse sairedis.rec -> T (count, ms, rate)
    └── profile_orchagent.sh      # perf profile of orchagent to validate change #2
```

All scripts run **on the DUT** (they need `swsscommon`, `sonic-db-cli`, and for
profiling `perf`). Copy the `scripts/` dir to the DUT, or run from the
`sonic-mgmt` container over SSH.

## Prerequisites

- Two SONiC images on hand: **baseline** (unmodified `QUANTA_202211`) and
  **treatment** (with the three changes + the swss-common ZMQ backport).
- A quiet DUT (no BGP flaps / heavy counter polling during a run).
- `perf` on the DUT for change #2 profiling (`linux-tools` / `linux-perf`).
- Pick a route scale that matches your production table (e.g. 100k /32, and an
  ECMP variant since NextHopGroupTable benefits scale with the number/size of
  next-hop groups).

## Measurement matrix

Run the SAME workload in each row, on the SAME DUT hardware:

| Row | Image | swss.rec | route ZMQ | Isolates |
|-----|-------|----------|-----------|----------|
| **B**  | baseline  | on (`-r 3`)  | n/a       | reference `T_base` |
| **T1** | treatment | off (`-r 1`) | disable   | change #1 + #2 (Redis path) |
| **T2** | treatment | off (`-r 1`) | enable    | adds change #3 (ZMQ path) |

- change #1 + #2 improvement = `(T_B  - T_T1) / T_B  * 100`
- change #3 (incremental)     = `(T_T1 - T_T2) / T_T1 * 100`
- total                       = `(T_B  - T_T2) / T_B  * 100`

> To split #1 from #2 exactly you'd need an extra build with only one of them,
> or read #2 straight off the perf profile (see "Validating change #2").

---

## Scenario B / T1 — Redis-path micro-benchmark (reproducible)

Uses `inject_routes.py`, which pushes routes into APPL_DB `ROUTE_TABLE` via the
`ProducerStateTable` protocol — exactly what orchagent consumes on the classic
Redis path. This isolates the orchagent-internal changes (#1, #2).

On the DUT:

```bash
cd scripts

# make sure route ZMQ is OFF for B and T1
sonic-db-cli CONFIG_DB hget "DEVICE_METADATA|localhost" "orch_northbond_route_zmq_enabled"   # expect empty/false

# 100k single-nexthop routes, 6 iterations (first discarded)
./run_perf.sh --count 100000 --nexthop 192.168.1.1@Ethernet0 --iters 6

# ECMP variant (stresses NextHopGroupTable the most)
./run_perf.sh --count 50000 \
    --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4,192.168.1.3@Ethernet8,192.168.1.4@Ethernet12 \
    --iters 6
```

`run_perf.sh` prints per-iteration T and a `T mean ± stddev` summary. Record the
mean for **B** (baseline image) and **T1** (treatment image, ZMQ off).

> Pick `--nexthop` IPs that resolve to real neighbors on your DUT (so the routes
> actually program to hardware). `ip neigh` / the interfaces in your config.

---

## Scenario T2 — end-to-end ZMQ path (real BGP)

With `orch_northbond_route_zmq_enabled=true`, orchagent's route consumer is a
`ZmqConsumerStateTable`; it no longer reads APPL_DB `ROUTE_TABLE`, so
`inject_routes.py` will NOT reach it. Routes must arrive through **fpmsyncd**,
i.e. a real BGP feed. This is also the truest end-to-end measurement.

1. Enable the feature (uses the new CLI from sonic-utilities):

   ```bash
   config route-zmq enable
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

2. Generate the add/withdraw batches (same route set as T1, on the peer):

   ```bash
   ./scripts/gen_frr_routes.py add --count 100000 --base 10.0.0.0 > /tmp/routes_add.conf
   ./scripts/gen_frr_routes.py del --count 100000 --base 10.0.0.0 > /tmp/routes_del.conf
   ```

3. Drive the run from the DUT with the T2 orchestrator (marks time, waits for the
   ASIC count to go idle, reads T). It can trigger the peer over ssh, or prompt
   you to run `frr-vtysh` manually:

   ```bash
   # auto-trigger (script ssh-es the peer):
   ./scripts/run_t2_bgp.sh --expect 100000 --peer admin@192.168.1.1 --add-file /tmp/routes_add.conf
   # or manual (it prompts, you run 'frr-vtysh < /tmp/routes_add.conf' on the peer):
   ./scripts/run_t2_bgp.sh --expect 100000
   ```

   > Feed the batch with `frr-vtysh < file` (stdin), NOT `vtysh -f <hostpath>`:
   > `frr-vtysh` execs into the `bgp` container, which has its own filesystem and
   > cannot see a path on the host. Withdraw with
   > `frr-vtysh < /tmp/routes_del.conf` between iterations.

`run_t2_bgp.sh` detects completion with an idle timer (waits as long as the count
keeps advancing, so a programming run longer than any fixed timeout is fine) and
prints T. Then compare against T1 -- see "Compare T2 vs T1" below.

### Method B -- peer is a generic Linux host (exabgp / gobgp)

Advertise the same route set with **exabgp** on the test host / a neighbor
container:

   ```
   # exabgp.conf (announce 100k /32 from a single peer)
   neighbor <DUT_BGP_IP> {
       router-id 10.9.9.9;
       local-address <PEER_IP>;
       local-as <PEER_AS>;
       peer-as <DUT_AS>;
       family { ipv4 unicast; }
       api { processes [ announcer ]; }
   }
   process announcer {
       run /usr/bin/python3 /path/to/announce_100k.py;   # loops 'announce route 10.0.i.j/32 next-hop <PEER_IP>'
       encoder text;
   }
   ```

   (gobgp works equally well: `gobgp global rib add` in a loop, or a MRT
   injection.) Keep the exact same route set for B/T1/T2 so T is comparable.

Time it the same way — the ASIC window is still in sairedis.rec. You can reuse
the T2 orchestrator (its idle-wait + T read are transport agnostic; just trigger
exabgp/gobgp when it prompts), or do it by hand:

   ```bash
   MARK=$(date +"%Y-%m-%d.%H:%M:%S"); sleep 1
   # ... trigger the exabgp/gobgp announcement of the full set ...
   # wait until ASIC route count stabilises at the expected total, then:
   ./scripts/measure_route_time.py /var/log/swss/sairedis.rec --since "$MARK"
   ```

### Compare T2 vs T1 (both methods)

Compare `T_T2` against `T_T1`. The ZMQ win shows up as lower T **and** lower
`redis-server` CPU during the burst:

```bash
pidstat -p "$(pidof redis-server)" 1      # sample during the announcement
```

---

## Validating change #2 (NextHopGroupTable) directly

The map->unordered_map win is a CPU-profile change. Kick the profiler just
before injecting an ECMP-heavy batch:

```bash
./scripts/profile_orchagent.sh 60 /tmp/orchagent_perf.txt &
./scripts/run_perf.sh --count 50000 --nexthop 192.168.1.1@Ethernet0,192.168.1.2@Ethernet4 --iters 1
```

In the report, on the **baseline** image you should see a large share under the
red-black tree comparison path (`std::_Rb_tree...`, `NextHopGroupKey::operator<`)
— upstream measured ~30% of orchagent CPU in next-hop lookup. On the
**treatment** image that collapses into a cheap `std::_Hashtable` / `hash<...>`
probe. The shrink in that share is change #2's contribution.

---

## Reading the result

For each row, take the `T mean` from `run_perf.sh` (or `measure_route_time.py`
for the BGP path), then:

| Quantity | Formula | Example |
|----------|---------|---------|
| #1+#2 (Redis) | `(T_B - T_T1)/T_B`   | (5.0s - 4.0s)/5.0s = **20%** |
| #3 (ZMQ, incr.) | `(T_T1 - T_T2)/T_T1` | (4.0s - 3.4s)/4.0s = **15%** |
| total | `(T_B - T_T2)/T_B`   | (5.0s - 3.4s)/5.0s = **32%** |

Report `mean ± stddev` across the counted iterations, not a single run.

## Gotchas

- **Warm-up**: `run_perf.sh` already drops iteration 1. Keep it.
- **Same route set & ECMP distribution** across B/T1/T2 — NextHopGroupTable
  gains scale with the number and size of next-hop groups.
- **Fixed batch size**: orchagent.sh already pins `-b 8192`; keep both images
  identical.
- **Neighbors must resolve**: unresolved next hops won't program to the ASIC and
  will skew / stall the count.
- **One writer to sairedis.rec**: scope every measurement with `--since <marker>`
  so you never mix two runs.
- **Multi-ASIC**: run per-namespace (`sonic-db-cli -n asic0 ...`, sairedis.rec is
  `sairedis.asic0.rec`), one namespace at a time.
