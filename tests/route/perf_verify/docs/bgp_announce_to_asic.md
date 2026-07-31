# Test case: BGP announce → ASIC programming latency

**ID** `route_perf_bgp_announce_to_asic`
**Scope** two boxes, one eBGP session, one mass announcement.
**Question it answers** *after the DUT receives a mass BGP announcement, how long
until those routes are in the ASIC?*

```
        ┌────────────┐   eBGP session    ┌────────────────────────────────┐
        │    PEER    │──────────────────▶│              DUT               │
        │  (FRR/BGP) │   N prefixes in   │ bgpd → zebra → fpmsyncd →      │
        │            │   one burst       │ (APPL_DB | ZMQ) → orchagent →  │
        └────────────┘                   │ sairedis → ASIC_DB → syncd     │
                                         └────────────────────────────────┘
             ▲                                ▲                    ▲
             │                                │                    │
        prep_bgp_burst.sh              tcpdump: A, A'       sairedis.rec: D, D'
        (arm + release)                  (clock starts)      (clock stops)
```

---

## 1. Metric definition

| Mark | Meaning | Source |
|------|---------|--------|
| `A`  | first BGP UPDATE from the peer hits the DUT | `tcpdump`, kernel timestamp |
| `A'` | last BGP UPDATE from the peer | same capture |
| `D`  | first SAI route create for an announced prefix | `sairedis.rec` |
| `D'` | last SAI route create for an announced prefix | `sairedis.rec` |

```
T_e2e     = D' - A     ← the headline: "收到 BGP announce → 全部寫進 ASIC"
T_head    = D  - A       receive → orchagent's first SAI call
                         (TCP + bgpd parse/bestpath + zebra + fpmsyncd + queueing)
T_program = D' - D       orchagent's SAI programming window
arrival   = A' - A       how bursty the peer actually was — a validity gate, not a result
```

Plus the **per-prefix distribution**: every announced prefix gets its own create
timestamp (sairedis bulk lines carry each entry's `"dest"`), so the run reports
p50 / p90 / p99 / max of "this prefix's announcement → this prefix in the ASIC",
at one-bulk-line resolution (~hundreds of routes, i.e. the granularity orchagent
actually programs at). For convergence work the p99 matters more than the mean.

**Why both anchors are passive.** `A` comes from a packet capture and `D'` from a
log orchagent writes regardless. Nothing in the measurement path polls the DUT,
so the numbers do not move when the harness polls faster or slower. ASIC_DB is
still polled, but only to decide *when the run is over* — it never enters `T`.

## 2. Why this is not `run_t2_bgp.sh`

`run_t2_bgp.sh` reports `last create − first create`, i.e. `T_program` only. Two
consequences make it the wrong tool for this question:

- **It starts the clock too late.** Everything from the wire to orchagent's first
  SAI call — `T_head` — is outside the window. On a 30k burst that head segment
  is seconds, and it is precisely where the fpmsyncd→orchagent transport (change
  #3) lives. A latency question needs it counted.
- **It cannot tell a burst from a trickle.** With no view of the arrival, a run
  where the peer dribbled routes out over 40 s reports a large `T` that looks
  like a slow DUT. This test measures `A' − A` and **fails the run** when the
  arrival is not short compared to `T_e2e`.

Keep `run_t2_bgp.sh` for the T1b/T2 A/B of the ZMQ change; use this test for
"how fast does the DUT absorb a peer's route dump".

## 3. Prerequisites

- eBGP session up between DUT and peer, peer's next-hop resolved on the DUT.
- On the DUT: `tcpdump`, `sudo`, `docker`, `sonic-db-cli`, `vtysh`, python3.
- On the peer: `vtysh` and the ability to add static routes (see §4 for the cost).
- **Route-table headroom** — `crm show resources | grep ipv4_route`. Overshooting
  the ASIC ceiling is silent: the count stops advancing and every number is void.
  Both scripts check, on their own box, before doing anything.
- **The peer needs headroom too.** `redistribute static` on a SONiC peer means
  those N routes are programmed into the *peer's* ASIC as well. `prep_bgp_burst.sh
  prepare` refuses to run if the peer cannot take them; a peer without a hardware
  FIB (plain Linux + FRR, exabgp, gobgp) avoids the problem entirely.
- **Clocks and timezones must match between the host and the swss container** —
  `tcpdump` timestamps come from the host kernel, `sairedis.rec` timestamps are
  local-time strings written inside the container. `run_bgp_latency.sh` aborts if
  they disagree by more than 2 s, because the failure is otherwise invisible: a
  constant offset just looks like a very slow (or impossibly fast) DUT.
- A quiet DUT: flex counters off (`counterpoll show`), CRM polling at its default
  300 s, no unrelated BGP churn.

## 4. Setup — how the burst is produced

The peer must advertise N prefixes **as one burst**. Feeding N `ip route` lines
into vtysh does not do that: vtysh parses line by line, zebra installs line by
line, fpmsyncd programs line by line, and bgpd redistributes each route as it
appears. The DUT sees a trickle at a few hundred to a couple of thousand
prefixes per second, and any "programming time" measured off it is really the
*peer's* rate.

So `prep_bgp_burst.sh` splits the slow part from the trigger:

| Action | What it does | Cost |
|--------|--------------|------|
| `prepare` | applies an outbound **deny** route-map for the test block only, enables `redistribute static`, preloads the N statics | minutes — deliberately outside the window |
| `release` | `no neighbor <DUT> route-map … out` + `clear ip bgp <DUT> soft out` | two commands; bgpd already holds the table and just writes it out |
| `withdraw` | re-applies the deny + soft out → all N prefixes withdrawn at once | same |
| `cleanup` | removes the statics and every config line the script added | minutes |

The deny matches only the smallest prefix covering the test block, so the peer's
real advertisements keep flowing and the DUT's table is otherwise undisturbed.
`prepare` also pins `advertisement-interval 0` on the neighbor — a non-zero MRAI
would chop the release into timer-spaced chunks and `A' − A` would be measuring
the timer.

## 5. Procedure

**On the peer** (once per scale):

```bash
./prep_bgp_burst.sh prepare --dut-ip <DUT session IP> --asn <PEER_AS> \
                            --count 30000 --base 10.0.0.0
```

Confirm on the DUT that `PfxRcd` for this peer has **not** moved — if it has, the
filter is not matching and the routes leaked out during the preload.

**On the DUT** (once per measurement):

```bash
./run_bgp_latency.sh --peer admin@<peer mgmt IP> --peer-ip <peer session IP> \
    --dut-ip <DUT session IP> --peer-asn <PEER_AS> \
    --count 30000 --base 10.0.0.0 \
    --out /tmp/bgpperf --stats /tmp/bgpperf/cpu \
    --measure-withdraw
```

It runs preflight, starts the capture, ssh-es the peer to `release`, waits for
the ASIC count to reach the target (wall-clock idle detection), stops the
capture and prints the report. `--no-trigger` prompts you to release by hand
instead. `--measure-withdraw` repeats the whole thing for the withdraw burst.

**Between runs**: `withdraw` on the peer and confirm the DUT's ASIC count is back
to its pre-test baseline. A prefix RouteOrch already holds takes the *update*
path and emits no SAI create, so leftovers silently shrink the next batch.

**Repeat ≥ 3 times, discard the first** (cold caches, cold bgpd), and quote
mean ± stddev.

**Teardown**: `./prep_bgp_burst.sh cleanup --dut-ip … --asn … --count 30000`.

## 6. Expected results and pass criteria

The report ends with a `VERDICT`. Exit codes: `0` valid, `2` invalid, `1` the run
could not be read at all.

**Functional pass** — all four must hold:

1. `PfxRcd` delta on the DUT == `--count` (bgpd received the whole set).
2. ASIC_DB route delta == `--count`.
3. All `--count` announced prefixes have a SAI create in `sairedis.rec`.
4. `A' − A ≤ 25%` of `T_e2e` (default `--burst-ratio`) — otherwise the run
   measured the peer, not the DUT, and the numbers must not be quoted.

**Performance** — no universal absolute threshold; it is platform, scale and
image specific. Gate on a recorded baseline for the *same* DUT, scale and route
shape:

```
regression% = (T_e2e_new - T_e2e_baseline) / T_e2e_baseline * 100
```

Flag anything beyond ~10%, and check `T_head` and `T_program` separately before
concluding — a regression in one is a completely different bug from the other.

**Withdraw** is a first-class result, not a footnote: quote `T_e2e(remove)`
alongside the add. Removal speed is what failure convergence actually depends on.

## 7. Reading the split

| Shape | Means | Where to look next |
|-------|-------|--------------------|
| `T_head` small, `T_program` dominant | orchagent/SAI-bound — the normal case at scale | `--stats` should show orchagent pinning a core; `profile_orchagent.sh` |
| `T_head` dominant | the feed inside the DUT is slow: bgpd bestpath, zebra, fpmsyncd, or the APPL_DB hop | `--stats`: which of `bgpd`/`zebra`/`fpmsyncd`/`redis-server` is pinned |
| `T_head` large **and** `redis-server` hot | the Redis hop — the case the route-ZMQ path is meant to remove; re-run with the flag flipped | compare `T_head` with `orch_northbond_route_zmq_enabled` on vs off |
| p99 ≫ p50 | programming is bursty/stalling, not uniformly slow | the ASIC_DB progress curve in the report, and syslog for orchagent warnings |
| arrival span ≈ `T_e2e` | feed-bound; the result is void | re-arm with `prepare`/`release`, check peer CPU |

The report labels every run with the route-ZMQ flag state. Compare like with
like: a ZMQ-on run against a ZMQ-off run is a valid pair; either against a
`swssconfig` micro-benchmark is not.

## 8. What this does *not* cover

`sairedis.rec` and ASIC_DB are both written by the sairedis client library
**inside orchagent** — they mark the orchagent egress, before syncd consumes the
op and the SDK touches silicon. For a "when did the DUT finish accepting the
announcement" question that is the right boundary. For an absolute
hardware-completion claim, cross-check once per scenario with
`hw_route_watch.sh --expect <count>` (Broadcom: ASIC_DB vs `bcmcmd "l3 defip
show"`), or send dataplane traffic to a sample of the announced prefixes and
time when it starts forwarding.

## 9. Variants worth running

- **ZMQ on / off** — the same run with `orch_northbond_route_zmq_enabled` flipped
  isolates the fpmsyncd→orchagent transport, and unlike `T_program` alone this
  test can see the part of the win that lives in `T_head`.
- **ECMP** — announce the same prefixes from two peers, or with several next
  hops, so NextHopGroupTable is exercised. Gains from the map→hash change scale
  with the number and size of next-hop groups.
- **IPv6** — same procedure with `ipv6 route`/`address-family ipv6 unicast` and
  the ipv6 prefix-list; the report's prefix matcher is address-family agnostic.
- **Scale sweep** — 1k / 10k / 30k. `T_e2e` should be close to linear; a knee
  means a queue or a table is saturating.
- **Withdraw-then-readvertise** — `withdraw` immediately followed by `release`
  is a decent proxy for a peer flap.

## 10. Troubleshooting

| Symptom | Cause |
|---------|-------|
| `no BGP UPDATE packets >= 60 bytes` | wrong `--peer-ip` or `--iface`; multi-asic needs `--netns asic0`; the peer never released |
| `first SAI create precedes the first UPDATE` | swss container clock/timezone ≠ host's, or a stale marker |
| `only X/N announced prefixes have a SAI create` | ASIC table full, an inbound filter on the DUT, or the peer never finished preloading |
| `PfxRcd` delta < `--count` | inbound route-map/prefix-list on the DUT, `maximum-prefix`, or the peer's outbound filter still on |
| arrival burst ≈ `T_e2e` | routes were announced one by one — use `prepare` + `release`, don't feed `ip route` live |
| count never reaches the target | peer preload truncated by the *peer's* own route-table ceiling |
| `tcpdump did not start` | needs `sudo`; on multi-asic it must run inside the ASIC namespace (`--netns`) |

Multi-asic: run one namespace at a time — `--netns asicN --container swssN
--recfile /var/log/swss/sairedis.asicN.rec`.
