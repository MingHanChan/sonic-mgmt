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

## 0. 先講四個會直接決定測法的事實

這四點如果不先處理,量出來的數字會是錯的或根本量不到東西。

### (1) ZMQ 開啟後,直接寫 APPL_DB 的路由 orchagent 完全收不到

`ZmqRouteOrch::addConsumer()`(`orchagent/zmqorch.cpp:107`)在 `zmqServer != nullptr` 時**只**掛
`ZmqRouteConsumer`,不會再建立 `ConsumerStateTable`。所以 `swssconfig` / `redis-cli` 寫進
`APPL_DB:ROUTE_TABLE` 的路由不會被消費。

後果:sonic-mgmt 現成的 `tests/route/test_route_perf.py` 是用 `docker_exec_swssconfig` 注入的
(`tests/route/test_route_perf.py:210`),**在 ZMQ 開啟時會直接 timeout 失敗**,不能拿來做
ZMQ on/off 的 A/B。要測 ZMQ,路由一定要從 fpmsyncd 進來。

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
要量到差異,必須刻意把 n 拉到上千、k 拉到 8 以上。這是整份設計最關鍵的一點。

### (4) 兩個改動的切換方式不同,所以要分開量

* `unordered_map` 是**編譯期** typedef → 需要兩份 orchagent binary。
* ZMQ 是**執行期** flag → `config route-zmq enable|disable` 即可切換,免重編。

---

## 1. 分層測試(由內而外,每層回答不同問題)

| 層 | 環境 | 注入方式 | 能測到什麼 | 回答的問題 |
|---|---|---|---|---|
| **L0** | 任何 build 機器 | gtest microbench | 只有 unordered_map | 在我的 (n, k) 之下,這個改動的**理論上限**是多少? |
| **L1** | 單台 DUT,不需要 BGP | `swssconfig` → APPL_DB | 只有 unordered_map(ZMQ 必須關) | orchagent 內部的改善有多少,零 FRR 噪音 |
| **L2** | 單台 DUT,不需要 Peer | `ip -batch` → kernel → zebra → FPM → fpmsyncd | **ZMQ + unordered_map 都測得到** | 主力數據來源 |
| **L3** | 兩台 DUT + BGP | Peer 端 BGP 廣播 | 端到端真實情境 | 實際部署會改善多少 |

建議把 **L2 當主力**(可重複、可控、注入夠快),**L3 當真實情境驗證**。原因在第 4 節說明。

---

## 2. 測試矩陣

### 產生兩份 orchagent binary(不必重建整顆 image)

最小差異法 —— 同一棵 source tree,只改 `orchagent/routeorch.h` 那一行 typedef:

```bash
# 新版(branch 現況)
make target/docker-orchagent.gz          # 或只 build swss deb
cp .../orchagent orchagent.umap

# baseline:只把 typedef 改回 std::map,其餘完全相同
sed -i 's/typedef std::unordered_map<NextHopGroupKey, NextHopGroupEntry> NextHopGroupTable;/typedef std::map<NextHopGroupKey, NextHopGroupEntry> NextHopGroupTable;/' orchagent/routeorch.h
make ...
cp .../orchagent orchagent.map
```

換 binary(比重刷 image 快非常多):

```bash
docker cp orchagent.map swss:/usr/bin/orchagent
systemctl restart swss
```

> 保留 `nexthopkey.cpp`(hash_value 編進去但沒人用)可以讓兩個 binary 的差異真的只有容器型別,
> 排除掉其他變因。

### 三(四)個組態

| 組態 | orchagent binary | `config route-zmq` | 用途 |
|---|---|---|---|
| **A** | `std::map` | disable | baseline |
| **B** | `std::unordered_map` | disable | **B − A = unordered_map 的效果** |
| **C** | `std::unordered_map` | enable | **C − B = ZMQ 的效果** |
| D(選配) | `std::map` | enable | 檢查兩者是否有交互作用 |

D 值得跑一次:ZMQ 讓 orchagent 消化變快之後,NHG 查表在 CPU 佔比會上升,unordered_map 的
相對收益有可能被**放大**。只跑 A/B/C 會看不到這件事。

### 切換 ZMQ 並確認真的生效

```bash
config route-zmq enable      # 寫 DEVICE_METADATA|localhost:orch_northbond_route_zmq_enabled
config save -y && config reload -y      # 或 systemctl restart swss bgp(兩個都要!)
```

`orchagent.sh` 與 `fpmsyncd` 都是**啟動時**讀 flag,所以 swss 與 bgp 兩個容器都必須重啟。

驗證清單(`run_case.sh` 會自動抓):

```bash
pgrep -a orchagent                      # 要看到 -q tcp://127.0.0.1
docker exec swss ss -lntp | grep 8100   # ZMQ server 有 listen
docker exec swss  grep "ZMQ channel on the northbound side" /var/log/syslog
docker exec bgp   grep "Create ZmqProducerStateTable : ROUTE_TABLE" /var/log/syslog
```

反向驗證(很好用):ZMQ 開啟時,拿 `swssconfig` 灌一批路由進 APPL_DB,ASIC_DB **不應該**有任何
變化 —— 這直接證明 ZMQ 才是實際生效的路徑。

---

## 3. 量測指標與取樣點

### 主指標

| 指標 | 取樣點 | 說明 |
|---|---|---|
| **routes/s** | `COUNTERS_DB CRM:STATS crm_stats_ipv4_route_used` | O(1) 讀取,可 5 Hz 取樣而不擾動系統 |
| **收斂牆鐘時間** | 同上,從 2% 到 99% | 避免頭尾雜訊 |
| **orchagent CPU µs/route** | `/proc/<pid>/stat` utime+stime | **最抗噪的指標**,不受注入端節流影響 |

> 千萬不要用 `KEYS ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY*` 高頻取樣 —— 那是 blocking 操作,
> 十萬筆時單次就要幾百 ms,會直接污染測量。只在最後收斂後做一次當作校驗。
> 高頻曲線用 `DBSIZE`(O(1))輔助即可。

### ZMQ 改動的直接證據

```bash
redis-cli -s /var/run/redis/redis.sock info commandstats   # 測前/測後各一次
```

`route_perf_probe.py` 會自動存成 `<out>.info.json`。ZMQ 開啟後應該看到:

* `cmdstat_evalsha` / `cmdstat_eval` 呼叫數**大幅塌陷**(ProducerStateTable 的 Lua script 沒了)
* `redis-server` 的 CPU µs/route 明顯下降
* 但**不會歸零** —— AsyncDBUpdater 仍在背景用一般 HSET 補寫 APPL_DB(這是預期行為)

### unordered_map 改動的直接證據

光看總時間會分不清是誰的功勞,用 perf 直接證明:

```bash
perf record -F 499 -g -p $(pgrep orchagent) -- sleep 30    # burst 期間
perf report --stdio | head -60
```

比對 A vs B,應該看到這些 symbol 從熱點消失:

* `std::_Rb_tree_increment` / `_Rb_tree_find`
* `NextHopGroupKey::operator<`
* `std::_Rb_tree<...NextHopGroupKey...>::find`

需要 image 內有 perf(`INSTALL_DEBUG_TOOLS=y`)。

### 瓶頸判定 —— 這是最容易被忽略、但決定數據有沒有意義的檢查

1. **注入端**:`run_case.sh` 會印出 `ip -batch` 的耗時。它必須 **遠小於** 收斂時間。
   若注入本身就要 30 秒而收斂 32 秒,那量到的是注入速度,不是 orchagent。
2. **syncd/SAI**:同時看 `syncd` 的 CPU。如果 syncd 已經 100% 滿載,orchagent 端的改善
   **不會反映在端到端時間上**。這種情況要以 `orchagent CPU µs/route` 為主要指標,
   並在報告裡明確說明「瓶頸在 SAI/ASIC,orchagent 的改善被遮蔽」。
3. **L3 專用**:比對 `show ip route summary`(zebra RIB 成長速度)與 ASIC_DB 成長速度。
   若 RIB 3 秒填滿、ASIC 40 秒填滿 → 瓶頸在 DUT,量測有效;
   若 RIB 30 秒、ASIC 32 秒 → 瓶頸在 Peer 的 BGP 送出速度,這輪數據作廢。

### 確認測試「有真的觸發」unordered_map

```bash
sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_nexthop_group_used
```

這個數字就是 `m_syncdNextHopGroups` 的規模(n)。`analyze_runs.py` 會在 n < 32 時直接警告。
n 只有個位數卻宣稱量到 20% 改善,那 20% 是雜訊。

---

## 4. 兩台 DUT + BGP(L3)的具體做法

你現在的拓樸 DUT ↔ Peer 單一 BGP session,直接跑會遇到兩個問題:
**(a) 只有 1 個 nexthop,NHG 那半邊測不到;(b) Peer 的 BGP 送出速度可能才是瓶頸。**

### Step 1:造出多個 nexthop

* 有多條實體線 → 每條各配 /31 + 一條 eBGP session,最直接。
* 只有一條線 → 建 N 個 Dot1Q sub-interface(兩邊對稱):

```bash
# DUT 與 Peer 各做一次,i = 100..163 → 64 條 session
config subinterface add Ethernet0.$i $i
config interface ip add Ethernet0.$i 10.0.$i.0/31      # Peer 用 .1
# BGP neighbor 照既有方式加(config bgp / CONFIG_DB BGP_NEIGHBOR)
```

* 確認 `maximum-paths` ≥ N:`vtysh -c "show run bgp" | grep maximum-paths`

### Step 2:Peer 端「預先載入、延後廣播」

不要在計時區間內讓 Peer 自己也在寫 ASIC —— 那會把 Peer 的處理時間混進數字裡。做法:

```bash
# Peer 上,先把路由灌進去(這段不計時)
ip -force -batch /tmp/routes_add.batch
vtysh -c "conf t" -c "router bgp <asn>" -c "address-family ipv4 unicast" \
      -c "redistribute kernel route-map BURST"
# BURST route-map 一開始是 deny

# 量測時才放行 —— 這才是「N 條路由一次到達」的乾淨事件
vtysh -c "conf t" -c "route-map BURST permit 10"
vtysh -c "clear bgp <dut-ip> soft out"
```

撤銷路由(DEL 效能)就把 route-map 改回 deny 再 soft out。

### Step 3:製造多個「不同的」 ECMP group

只做 Step 1 的話,所有 prefix 都從全部 N 條 session 收到 → 只會有 **1 個** NHG,
unordered_map 依然測不到。要讓不同 prefix 走不同的 session 子集:

每個 neighbor 掛不同的 outbound prefix-list,把 prefix 切成 G 個 block,
block g 只由某個 session 子集廣播。`gen_routes.py` 的分組邏輯可以直接拿來產生這份對應表
(同樣的 `--groups G --ecmp K` 語意)。

### 為什麼建議以 L2 為主力

Step 1~3 在兩台實體機上要花不少設定功夫,而且 Peer 端很容易變成瓶頸。**L2 用
`ip -batch` 把 multipath kernel route 灌進 DUT 自己的 kernel**,路徑是
`kernel → netlink → zebra → FPM → fpmsyncd → (ZMQ|Redis) → orchagent`,
**一樣完整走過 ZMQ 這條新路徑**,但:

* 注入速度快(`ip -batch` 每秒數萬條),不會成為瓶頸
* nexthop 組合完全可控(`--ecmp` / `--groups` 直接指定)
* 不依賴 Peer,重複性高

所以:**L2 產生可比較的數字,L3 驗證真實情境下的收益方向一致**。兩者都做,報告才完整。

---

## 5. 噪音控制清單(每輪都要確認)

* `swssloglevel -l NOTICE -c orchagent` —— `routeorch.cpp` 裡有 `SWSS_LOG_DEBUG` 的 DBG-REF
  訊息,開到 DEBUG 會把差異完全蓋掉。
* `swss.rec` / `sairedis.rec`:兩個組態必須一致(commit `5643892` 已預設關閉 swss.rec)。
* 暫停 monit 的 `route_check.py`(它會對 APPL_DB/ASIC_DB 做 KEYS):`monit unmonitor routeCheck`,
  測完再 `monit monitor routeCheck`。
* `counterpoll` 設定兩邊一致;CRM polling 設 1 秒(量測需要)且兩邊一致:
  `crm config polling interval 1`。
* 每輪之間 `config reload -y`,確保起始路由數/鄰居狀態相同。
* 每個組態 **至少 5 輪**,取中位數;組態順序 **ABAB 交錯**,避免溫度/背景漂移被算進差異。
* 記錄每輪的路由總數,不符預期就作廢(見下一節)。

---

## 6. 必須和效能一起做的正確性檢查

效能數字如果建立在壞掉的功能上就沒有意義。ZMQ 這個改動的風險點:

| # | 檢查 | 為什麼重要 |
|---|---|---|
| 1 | **最終路由數必須完全等於預期** | ZMQ 沒有 Redis 那層持久化。burst 過大時若 ZMQ 佇列溢出,結果是**靜默少路由**,而不是變慢 |
| 2 | `route_check.py` 必須通過 | APPL_DB 現在是非同步寫入,要確認最終仍會收斂一致 |
| 3 | 只重啟 orchagent(fpmsyncd 不動) | orchagent down 的期間 ZMQ 訊息會遺失,靠 `routeresync` 補;要驗證補得回來 |
| 4 | 只重啟 bgp 容器 | ZmqClient 重連行為 |
| 5 | **warm reboot / BGP graceful restart** | `WarmStartHelper` 現在拿到的是 ZMQ producer(`routesync.h` 的成員順序也跟著調整過),這是最高風險區 |
| 6 | orchagent RSS 峰值 | `ZmqRouteConsumer::execute()` 是「pop 到空為止才 doTask」,大 burst 下 `m_toSync` 會膨脹 |
| 7 | ECMP 資料面驗證 | 打流量確認真的走 ECMP、沒有黑洞 |

unordered_map 的風險點:

* hash 與 `operator==` 的一致性 —— 相等的 key 必須有相等的 hash,否則 unordered_map 會**漏查**。
  `nhgtable_bench_ut.cpp` 的 `HashMatchesEquality` 測試就是在守這件事。
* 已知偏差:此分支的 `NextHopKey` 沒有 `srv6_vpn_sid`,hash 未包含該欄位(commit message 已註明)。
  若之後 backport SRv6 VPN 相關改動,這裡要一起補。

---

## 7. 預期數字與判讀

| 改動 | 預期 | 判讀注意 |
|---|---|---|
| ZMQ | throughput 約 1.3–2×;redis CPU 大幅下降;`cmdstat_evalsha` 呼叫數塌陷 | 若 syncd 已滿載,端到端時間可能幾乎不動 —— 這時要用 orchagent CPU µs/route 呈現,並說明瓶頸在 SAI |
| unordered_map | 上游宣稱約 20%;本設計下 n≥1000、k≥8 才看得出來 | n < 幾百時預期接近 0。**先跑 L0 microbench** 決定你的 (n, k) 有沒有值得測的空間,再決定 DUT 上要不要花時間 |

---

## 8. 工具與操作步驟

本目錄檔案:

| 檔案 | 用途 | 跑在哪 |
|---|---|---|
| `nhgtable_bench_ut.cpp` | L0:同一支 binary 內同時量 map 與 unordered_map | build 機器(放進 `sonic-swss/tests/mock_tests/`) |
| `setup_nexthops.sh` | 建立 N 個靜態 nexthop(鄰居) | DUT |
| `gen_routes.py` | 產生可控 ECMP 多樣性的路由批次檔(kernel / swssconfig / frr 三種格式) | DUT 或本機 |
| `route_perf_probe.py` | 高頻取樣 CRM / DBSIZE / 各 process CPU,輸出 CSV | DUT host |
| `run_case.sh` | 一輪完整流程:快照 → 取樣 → 注入 → 等收斂 → 校驗 | DUT |
| `analyze_runs.py` | CSV → routes/s、CPU µs/route、A/B 比較表 | 任何地方 |

### L0(先做,10 分鐘,決定後面值不值得花時間)

```bash
cp nhgtable_bench_ut.cpp sonic-swss/tests/mock_tests/
# 在 tests/mock_tests/Makefile.am 的 tests_SOURCES 加入 nhgtable_bench_ut.cpp
cd sonic-swss && ./autogen.sh && ./configure && make -C tests/mock_tests
./tests/mock_tests/tests --gtest_filter='NhgTableBench.*'
```

輸出會是一張 (groups, ecmp) → map ns / umap ns / speedup 的表。

### L2(主力數據)

```bash
# 一次性設定
./setup_nexthops.sh Ethernet0 64 add
crm config polling interval 1
swssloglevel -l NOTICE -c orchagent
monit unmonitor routeCheck

./gen_routes.py --mode kernel --op add --count 50000 --ecmp 8 --groups 1024 \
                --nh-count 64 --dev Ethernet0 --out /tmp/routes_add.batch
./gen_routes.py --mode kernel --op del --count 50000 --out /tmp/routes_del.batch

# 每個組態各跑 5 輪,組態間 ABAB 交錯
./run_case.sh A_map_nozmq_r1 /tmp/routes_add.batch /tmp/routes_del.batch 50000
# ... 換 binary / 切 flag,重複 ...

./analyze_runs.py '/tmp/perf/A_*.add.csv' --vs '/tmp/perf/B_*.add.csv'   # unordered_map 效果
./analyze_runs.py '/tmp/perf/B_*.add.csv' --vs '/tmp/perf/C_*.add.csv'   # ZMQ 效果
```

### 掃描參數空間

把 `--groups` 掃 `1 / 64 / 1024 / 4096`、`--ecmp` 掃 `1 / 4 / 8 / 32`,畫成
「改善幅度 vs NHG 數量」的曲線。這張圖比單一數字有說服力得多,而且能直接告訴你
**在你們實際部署的 NHG 規模下,這個改動值多少**。

### L1(選配)

同樣的 `gen_routes.py` 改 `--mode swssconfig`,用
`docker exec -i swss swssconfig /dev/stdin < routes.json` 注入。**ZMQ 必須是 disable。**
好處是完全繞開 FRR/fpmsyncd,orchagent 以外的噪音最小,適合單獨確認 unordered_map 的數字。
