# ZMQ 路徑 + NextHopGroupTable(unordered_map)效能量測設計

對象改動:

| Repo | Commit | 內容 |
|---|---|---|
| sonic-swss | `c19ff72` | `NextHopGroupTable` 由 `std::map` 改為 `std::unordered_map` |
| sonic-swss | `0513561` | fpmsyncd → orchagent 的 ZMQ 直通路徑 |
| sonic-swss-common | `a7283cb` | ZmqClient/Server、ZmqProducer/ConsumerStateTable、AsyncDBUpdater |
| sonic-buildimage | `2ea74b3` | orchagent.sh 依 flag 帶 `-q tcp://127.0.0.1` |
| sonic-utilities | `fef8a13` | `config route-zmq <enable\|disable>` |

---

## 0. 先講五個會直接決定測法的事實

前四點如果不先處理,量出來的數字會是錯的或根本量不到東西;第五點讓實際操作大幅簡化。

### (1) ZMQ 開啟後,直接寫 APPL_DB 的路由 orchagent 完全收不到

`ZmqRouteOrch::addConsumer()`(`orchagent/zmqorch.cpp:107`)在 `zmqServer != nullptr` 時**只**掛
`ZmqRouteConsumer`,不會再建立 `ConsumerStateTable`。所以 `swssconfig` / `redis-cli` 寫進
`APPL_DB:ROUTE_TABLE` 的路由不會被消費。

後果:sonic-mgmt 現成的 `tests/route/test_route_perf.py` 是用 `docker_exec_swssconfig` 注入的,
**在 ZMQ 開啟時會直接 timeout 失敗**,不能拿來做 ZMQ on/off 的 A/B。要測 ZMQ,路由一定要
從 fpmsyncd 進來。

### (2) APPL_DB 變成非同步寫入,不能當進度指標

ZMQ 模式下 consumer 端是 `dbPersistence=false`,APPL_DB 由 producer 端
`ZmqProducerStateTable` 的 `AsyncDBUpdater` 另開 thread 補寫。APPL_DB 的 ROUTE_TABLE 數量會
落後真實進度。進度一律看 **ASIC_DB / CRM**。

### (3) `unordered_map` 只在 ECMP 路由才會被觸發,而且要「很多個不同的 group」

`RouteOrch::addRoute()` 在 `nextHops.getSize() == 1` 時直接拿 neighbor 的 nexthop id,
**完全不碰 `m_syncdNextHopGroups`**(`orchagent/routeorch.cpp:2411`);只有 ≥ 2 個 nexthop 才會
查表。收益大致是:

```
每次查表成本 ≈ O(log n) 次比較 × 每次比較走完 std::set<NextHopKey>
                                (逐欄比 IP / alias / vni / mac / label stack / weight / srv6)
            →  1 次 hash + 1 次 bucket 探測
n = 表內不同 next hop group 數,比較成本 ∝ 每組 nexthop 數 k
```

**DUT ↔ Peer 一條線 = 1 個 nexthop = 0 個 next hop group = 這個改動效果恰好是 0。**
要量到差異,必須刻意把 n 拉到上千、k 拉到 8 以上。

### (4) 路由必須由 FRR「originate」才會進 fpmsyncd —— `ip route add` 沒用

SONiC 的 zebra 用 `-M dplane_fpm_nl` 把它**安裝**的路由送到 FPM,fpmsyncd 再轉給 orchagent。
關鍵:

* **static route(staticd)/ BGP route** 由 FRR originate → zebra 安裝 → 經 FPM → fpmsyncd
  → (ZMQ 或 Redis) → orchagent。**這才是會走過 ZMQ 的路徑。**
* 直接 `ip route add` 灌進 host kernel 的路由,zebra 只是被動從 netlink 學到(kernel protocol),
  **不會再經 FPM 送出去**,所以到不了 fpmsyncd,orchagent 不會 program,ASIC_DB 也不會變。
  → 用 `ip -batch` 灌路由**測不到 ZMQ**,別用。

`no fpm use-next-hop-groups` 表示 zebra 送給 FPM 的是「每條路由帶 inline 多 nexthop」
(RTA_MULTIPATH),不是獨立的 NHG 物件;RouteOrch 收到後自己組 `m_syncdNextHopGroups`。
所以只要送多 nexthop 的 static/BGP route,unordered_map 這條路徑就會被走到。

### (5) 兩個改動可以完全解耦量測 —— 這是實際操作的關鍵簡化

| 改動 | 切換方式 | 要不要 ECMP? | 要不要 Peer? | 最省事的注入法 |
|---|---|---|---|---|
| **unordered_map** | 編譯期 typedef(兩份 binary) | **要**(多個不同 NHG) | 不要 | `swssconfig` → APPL_DB(ZMQ 關) |
| **ZMQ** | 執行期 flag(`config route-zmq`) | **不要**(單 nexthop 就測得到) | 用 Peer 最真實 | BGP burst,或單機 static route |

* 量 **unordered_map**:transport 無關,不必碰 ZMQ、不必碰 Peer。用 `swssconfig` 直寫 APPL_DB
  最快最乾淨(和現成的 `test_route_perf.py` 同機制),只要把路由做成大量不同 ECMP 群組即可。
* 量 **ZMQ**:ECMP 無關,單 nexthop 路由就完整走過 fpmsyncd→orchagent。只要有「大量、夠快」
  的 burst 經過 fpmsyncd。你現有的 DUT↔Peer BGP 就是最自然的來源。

所以下面 **L1 專測 unordered_map、L2/L3 專測 ZMQ**,各自最簡。想看兩者疊加的真實效果再做選配的
「ECMP 走 ZMQ」組合(見 §6)。

---

## 1. 分層測試

| 層 | 環境 | 注入方式 | 測什麼 | 角色 |
|---|---|---|---|---|
| **L0** | 任何 build 機器 | gtest microbench | unordered_map 理論上限 | 先做,決定值不值得上機 |
| **L1** | 單台 DUT | `swssconfig` → APPL_DB(**ZMQ 關**) | **unordered_map** | unordered_map 的主力數據 |
| **L2** | 單台 DUT | FRR **static route** + 觸發式 burst | **ZMQ** | 不必動 Peer 就能測 ZMQ |
| **L3** | 兩台 DUT + BGP | Peer 端 **BGP announce** burst | **ZMQ**(真實情境) | ZMQ 的主力數據 |

你手上有 Peer,所以 **ZMQ 用 L3 當主力、L2 當交叉驗證**;unordered_map 用 L1。三者的取樣/分析
工具完全共用。

---

## 2. 量 unordered_map:L0 + L1

### 產生兩份 orchagent binary(不必重建整顆 image)

最小差異法 —— 同一棵 source tree,只改 `orchagent/routeorch.h` 那一行 typedef:

```bash
# 新版(branch 現況,unordered_map)
make target/docker-orchagent.gz          # 或只 build swss deb
docker cp <build-orchagent> /tmp/orchagent.umap   # 取出 binary

# baseline:只把 typedef 改回 std::map,其餘完全相同
sed -i 's/typedef std::unordered_map<NextHopGroupKey, NextHopGroupEntry> NextHopGroupTable;/typedef std::map<NextHopGroupKey, NextHopGroupEntry> NextHopGroupTable;/' orchagent/routeorch.h
make ...
docker cp <build-orchagent> /tmp/orchagent.map
```

在 DUT 上換 binary(比重刷 image 快非常多):

```bash
docker cp /tmp/orchagent.map swss:/usr/bin/orchagent && systemctl restart swss   # 組態 A
# ...測完...
docker cp /tmp/orchagent.umap swss:/usr/bin/orchagent && systemctl restart swss  # 組態 B
```

> 保留 `nexthopkey.cpp`(hash_value 編進去但沒人用)可讓兩個 binary 的差異真的只有容器型別。

### L0 —— 先花 10 分鐘決定值不值得上機

```bash
cp nhgtable_bench_ut.cpp <sonic-swss>/tests/mock_tests/
# 在 tests/mock_tests/Makefile.am 的 tests_SOURCES 加入 nhgtable_bench_ut.cpp
cd <sonic-swss> && ./autogen.sh && ./configure && make -C tests/mock_tests
./tests/mock_tests/tests --gtest_filter='NhgTableBench.*'
```

輸出是 (groups, ecmp) → map ns / umap ns / speedup 的表。**若你實際部署的 NHG 數只有幾十,
speedup 本來就趨近 1,那 L1 也不必花時間了。**

### L1 —— swssconfig 直寫 APPL_DB(ZMQ 必須是 disable)

```bash
# 一次性設定
./setup_nexthops.sh Ethernet0 64 add          # 建 64 個靜態鄰居當 nexthop 池
crm config polling interval 1
swssloglevel -l NOTICE -c orchagent
monit unmonitor routeCheck

# 產生「大量不同 ECMP 群組」的路由(這裡 ecmp 才是重點)
./gen_routes.py --mode swssconfig --op add --count 50000 --ecmp 8 --groups 1024 \
                --nh-count 64 --dev Ethernet0 --out /tmp/routes_add.json
./gen_routes.py --mode swssconfig --op del --count 50000 --out /tmp/routes_del.json

# 每個組態各跑 ≥5 輪,ABAB 交錯。inject 就是 swssconfig:
./run_case.sh A_map_r1 50000 -- \
    'docker exec -i swss swssconfig /dev/stdin' < /tmp/routes_add.json
# 換 orchagent.umap 重啟後,同樣跑 B_umap_r*
```

分析(unordered_map 效果):

```bash
./analyze_runs.py '/tmp/perf/A_map_*.add.csv' --vs '/tmp/perf/B_umap_*.add.csv'
```

掃 `--groups 1/64/1024/4096`、`--ecmp 1/4/8/32`,畫「改善幅度 vs NHG 數量」曲線,比單一數字有
說服力得多。

---

## 3. 量 ZMQ:切換與驗證

### 切換 ZMQ 並確認真的生效

```bash
config route-zmq enable                    # 寫 orch_northbond_route_zmq_enabled=true
config save -y && config reload -y         # 或 systemctl restart swss bgp(兩個都要!)
```

`orchagent.sh` 與 `fpmsyncd` 都是**啟動時**讀 flag,所以 swss 與 bgp 兩個容器都必須重啟。

驗證清單(`run_case.sh` 的快照會自動抓):

```bash
pgrep -a orchagent                              # 要看到 -q tcp://127.0.0.1
docker exec swss ss -lntp | grep 8100           # ZMQ server 有 listen
docker exec swss  grep "ZMQ channel on the northbound side" /var/log/syslog
docker exec bgp   grep "Create ZmqProducerStateTable : ROUTE_TABLE" /var/log/syslog
```

反向驗證(很好用):ZMQ 開啟時,拿 `swssconfig` 灌一批路由進 APPL_DB,ASIC_DB **不應該**有任何
變化 —— 這直接證明 ZMQ 才是實際生效的路徑(呼應 §0-(1))。

ZMQ 的 A/B 是同一份 orchagent binary(用 umap 版即可),只切 flag:**組態 X = flag off,
組態 Y = flag on**。

---

## 4. L2 —— 單台 DUT 用 static route 測 ZMQ(不必動 Peer)

單機要製造「大量、夠快」的 burst 經過 fpmsyncd,用一個技巧:**先把 static route 灌進 staticd,
但讓 nexthop 暫時無法解析(routes 處於 inactive),再一次讓它們全部解析 → 一次 burst 安裝**。

```bash
# Step 1  預載 static route(此時 30.0.0.0/16 尚未 connected,所有 route 處於 inactive,
#         不會送到 FPM、不會進 ASIC)。單 nexthop 就夠測 ZMQ,用 ecmp=1。
./gen_routes.py --mode frr --frr-wrap --op add --count 50000 --ecmp 1 \
                --nh-count 1 --dev Ethernet0 --out /tmp/routes.frr
docker exec -i bgp vtysh -f /dev/stdin < /tmp/routes.frr    # 載入需時,但此時不計時

# 確認 route 是 inactive(APPL_DB / ASIC_DB 應該沒有這些 100.0.x.x)
docker exec bgp vtysh -c "show ip route 100.0.0.0/24"       # 應顯示 inactive / not installed

# Step 2  觸發 burst:加上 connected 子網 + 鄰居,所有 route 同時解析並安裝。
#         這一步就是 inject 指令,run_case.sh 會在啟動取樣後才執行它。
./run_case.sh L2_zmqOFF_r1 50000 -- \
    './setup_nexthops.sh Ethernet0 1 add'
```

`setup_nexthops.sh ... 1 add` 會加 `30.0.0.1/16` connected + 一個鄰居 `30.0.1.2`;它一出現,
staticd/zebra 就把 50000 條 route 全部解析 → 經 FPM → fpmsyncd → (ZMQ|Redis) → orchagent。

撤路由(測 DEL 效能):`config interface ip remove Ethernet0 30.0.0.1/16` 讓它們重新 inactive,
或直接 `no ip route ...`(gen_routes `--op del --mode frr`)。

L2 的 A/B:同上,只切 `config route-zmq`。每個組態 ≥5 輪:

```bash
./analyze_runs.py '/tmp/perf/L2_zmqOFF_*.add.csv' --vs '/tmp/perf/L2_zmqON_*.add.csv'
```

> 注意:L2 的 burst 包含 zebra 解析時間,不是純 fpmsyncd→orchagent。所以 L2 以
> **orchagent CPU µs/route** 為主指標(它只算 orchagent),牆鐘時間當輔助。

---

## 5. L3 —— 兩台 DUT + BGP(真實情境,ZMQ 主力數據)

你的拓樸 DUT ↔ Peer。要點:**Peer 端要能一次送出大 burst,而且 Peer 自己的送出速度不能是瓶頸。**

假設 Peer 也是 SONiC(跑 FRR)。作法是在 Peer 上預載 static route 並 redistribute 進 BGP,
用 route-map 把「廣播」這個動作 gate 起來,量測時才放行 → DUT 一次收到 N 條。

### Peer 端(一次性設定)

`l3_peer.sh` 幫你做這些(在 **Peer** 上跑):

```bash
# 在 Peer 上:預載 static route(指向 Peer 自己朝向 DUT 的介面 nexthop),
# redistribute static 進 BGP,但先用 deny 的 route-map 擋住,不廣播出去。
./l3_peer.sh setup <DUT_BGP_IP> <PEER_ASN> 50000
```

### 量測(在 DUT 上跑 run_case,inject 指令透過 ssh 觸發 Peer 放行)

```bash
# inject = 在 Peer 上把 route-map 由 deny 改 permit 並 soft-out → DUT 一次收到 burst
./run_case.sh L3_zmqON_r1 50000 -- \
    'ssh admin@<PEER_MGMT_IP> ./l3_peer.sh announce <DUT_BGP_IP>'
```

撤路由:`ssh admin@<PEER> ./l3_peer.sh withdraw <DUT_BGP_IP>`(route-map 改回 deny + soft-out)。

### 判斷 Peer 是不是瓶頸(L3 專用,必做)

比對兩條成長曲線:

```bash
# DUT 上:zebra RIB 灌完的速度 vs ASIC 灌完的速度
watch -n0.5 'docker exec bgp vtysh -c "show ip route summary" | grep Totals; \
             sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_route_used'
```

* RIB 幾秒填滿、ASIC 幾十秒填滿 → 瓶頸在 DUT,量測有效 ✅
* RIB 也要幾十秒才填滿 → 瓶頸在 Peer 的 BGP 送出,這輪數據作廢 ❌
  → 改用「預載 + route-map 放行」確保是一次送出;或 Peer 換更快的產生器(exabgp)。

### 想在 L3 同時測到 ECMP(選配,見 §6)

單一 DUT↔Peer 鏈路只有 1 個 nexthop → 沒有 NHG。要在 L3 也觸發 unordered_map,得在同一條實體線
上疊多個 sub-interface,每個各一條 eBGP session,並用 per-neighbor prefix-list 讓不同 prefix 走
不同 session 子集。設定繁瑣,一般不必為了 ZMQ 數據做;只有要「ECMP 走 ZMQ」的疊加測試才需要。

---

## 6. 選配:ECMP 路由走 ZMQ(疊加效果)

ZMQ 讓 orchagent 消化變快後,NHG 查表在 CPU 佔比會上升,unordered_map 的相對收益**可能被放大**。
要看這個,用 **L2 的 static route burst,但把 ecmp 拉高**(這條路徑同時經過 fpmsyncd 與
`m_syncdNextHopGroups`):

```bash
./setup_nexthops.sh Ethernet0 64 add
./gen_routes.py --mode frr --frr-wrap --op add --count 50000 --ecmp 8 --groups 1024 \
                --nh-count 64 --dev Ethernet0 --out /tmp/routes_ecmp.frr
# 預載時 30.0.0.0/16 尚未 connected → inactive;觸發 burst 同 L2
```

四組態全跑(A=map+zmqoff, B=umap+zmqoff, C=umap+zmqon, D=map+zmqon),
C−B 是 ZMQ、B−A 是 unordered_map、D−A 對照 ZMQ 對 map 版的效果,四者一起看才看得到交互作用。

---

## 7. 量測指標與取樣點(所有層共用)

| 指標 | 取樣點 | 說明 |
|---|---|---|
| **routes/s** | `COUNTERS_DB CRM:STATS crm_stats_ipv4_route_used` | O(1) 讀取,可 5 Hz 取樣而不擾動系統 |
| **收斂牆鐘時間** | 同上,從 2% 到 99% | 避免頭尾雜訊 |
| **orchagent CPU µs/route** | `/proc/<pid>/stat` utime+stime | **最抗噪**,不受注入端節流影響;L2 主指標 |

> 千萬不要用 `KEYS ASIC_STATE:...*` 高頻取樣 —— 那是 blocking 操作,十萬筆時單次就要幾百 ms,
> 會直接污染測量。高頻曲線用 `DBSIZE`(O(1))輔助,最後收斂後才做一次 `KEYS` 校驗。

### ZMQ 的直接證據

```bash
redis-cli -s /var/run/redis/redis.sock info commandstats   # 測前/測後各一次(probe 自動存)
```

ZMQ 開啟後應看到 `cmdstat_evalsha` / `cmdstat_eval` 呼叫數**大幅塌陷**(ProducerStateTable 的
Lua script 沒了),`redis-server` CPU µs/route 明顯下降;但**不會歸零**(AsyncDBUpdater 仍背景
補寫 APPL_DB,這是預期)。

### unordered_map 的直接證據

```bash
perf record -F 499 -g -p $(pgrep orchagent) -- sleep 30    # burst 期間
perf report --stdio | head -60
```

比對 map vs umap,`std::_Rb_tree_increment` / `NextHopGroupKey::operator<` /
`_Rb_tree<...>::find` 應從熱點消失(需 image 內有 perf:`INSTALL_DEBUG_TOOLS=y`)。

### 確認測試「有真的觸發」unordered_map

```bash
sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_nexthop_group_used
```

這就是 `m_syncdNextHopGroups` 的規模 n。`analyze_runs.py` 會在 n < 32 時警告。

---

## 8. 噪音控制清單(每輪都要確認)

* `swssloglevel -l NOTICE -c orchagent` —— `routeorch.cpp` 裡有 `SWSS_LOG_DEBUG` 的 DBG-REF
  訊息,開到 DEBUG 會把差異完全蓋掉。
* `swss.rec` / `sairedis.rec`:兩個組態必須一致(commit `5643892` 已預設關閉 swss.rec)。
* 暫停 monit 的 `route_check.py`:`monit unmonitor routeCheck`,測完 `monit monitor routeCheck`。
* `counterpoll` 兩邊一致;CRM polling 設 1 秒且兩邊一致:`crm config polling interval 1`。
* 每輪之間 `config reload -y`,確保起始路由數/鄰居狀態相同。
* 每個組態 **至少 5 輪**取中位數;組態順序 **ABAB 交錯**,避免溫度/背景漂移被算進差異。
* 記錄每輪路由總數,不符預期就作廢(見下一節)。

---

## 9. 必須和效能一起做的正確性檢查

效能數字如果建立在壞掉的功能上就沒有意義。

**ZMQ 風險點:**

| # | 檢查 | 為什麼重要 |
|---|---|---|
| 1 | **最終路由數必須完全等於預期** | ZMQ 沒有 Redis 那層持久化;burst 過大若 ZMQ 佇列溢出,是**靜默少路由**而不是變慢 |
| 2 | `route_check.py` 必須通過 | APPL_DB 現在非同步寫入,要確認最終仍收斂一致 |
| 3 | 只重啟 orchagent(fpmsyncd 不動) | orchagent down 期間 ZMQ 訊息會遺失,靠 `routeresync` 補;要驗證補得回來 |
| 4 | 只重啟 bgp 容器 | ZmqClient 重連行為 |
| 5 | **warm reboot / BGP graceful restart** | `WarmStartHelper` 現在拿到 ZMQ producer(`routesync.h` 成員順序也調整過),最高風險區 |
| 6 | orchagent RSS 峰值 | `ZmqRouteConsumer::execute()` 是「pop 到空才 doTask」,大 burst 下 `m_toSync` 會膨脹 |
| 7 | ECMP 資料面驗證 | 打流量確認真的走 ECMP、沒有黑洞 |

**unordered_map 風險點:**

* hash 與 `operator==` 一致性 —— 相等的 key 必須有相等 hash,否則 unordered_map 會**漏查**。
  `nhgtable_bench_ut.cpp` 的 `HashMatchesEquality` 測試在守這件事。
* 已知偏差:此分支 `NextHopKey` 沒有 `srv6_vpn_sid`,hash 未含該欄位(commit message 已註明);
  日後 backport SRv6 VPN 要一起補。

---

## 10. 預期數字與判讀

| 改動 | 預期 | 判讀注意 |
|---|---|---|
| ZMQ | throughput 約 1.3–2×;redis CPU 大幅下降;`cmdstat_evalsha` 塌陷 | 若 syncd 已滿載,端到端時間可能幾乎不動 → 用 orchagent CPU µs/route 呈現,並說明瓶頸在 SAI |
| unordered_map | 上游宣稱約 20%;本設計下 n≥1000、k≥8 才看得出 | n < 幾百時預期接近 0。先跑 L0 決定有沒有值得測的空間 |

瓶頸判定(每層都要):注入端耗時必須遠小於收斂時間;同時看 `syncd` CPU,若已 100% 滿載則
orchagent 的改善不會反映在端到端時間,改以 CPU µs/route 呈現並註明瓶頸在 SAI/ASIC。

---

## 11. 工具清單

| 檔案 | 用途 | 跑在哪 |
|---|---|---|
| `nhgtable_bench_ut.cpp` | L0:同一 binary 內同時量 map 與 umap + 驗 hash/equality | build 機(放進 `sonic-swss/tests/mock_tests/`) |
| `setup_nexthops.sh` | 建立 N 個靜態 nexthop(鄰居);也當 L2 的 burst 觸發 | DUT |
| `gen_routes.py` | 產生可控 ECMP 多樣性的路由(`swssconfig`/`frr`/`kernel` 三格式) | DUT 或本機 |
| `route_perf_probe.py` | 5Hz 取樣 CRM/DBSIZE/各 process CPU + redis commandstats,輸出 CSV | DUT host |
| `run_case.sh` | 一輪流程:快照→取樣→執行 inject 指令→等收斂→校驗 | DUT |
| `l3_peer.sh` | L3:Peer 端預載 static+redistribute,burst 由 route-map 放行 | **Peer** |
| `analyze_runs.py` | CSV → routes/s、CPU µs/route、A/B 比較表 | 任何地方 |

> `gen_routes.py --mode kernel` 保留給「只想驗證 kernel/zebra 行為」的場合,**不要**拿它測
> ZMQ 或 orchagent(理由見 §0-(4))。
