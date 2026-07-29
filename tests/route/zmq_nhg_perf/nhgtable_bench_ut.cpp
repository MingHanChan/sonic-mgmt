/*
 * nhgtable_bench_ut.cpp -- 在同一支 binary 內同時量 std::map 與
 * std::unordered_map 版本的 NextHopGroupTable 查表成本。
 *
 * 放到 sonic-swss/tests/mock_tests/ 並在 tests/mock_tests/Makefile.am 的
 * tests_SOURCES 加上這個檔案,然後:
 *
 *   ./autogen.sh && ./configure && make -C tests/mock_tests
 *   ./tests/mock_tests/tests --gtest_filter='NhgTableBench.*'
 *
 * 這支測試不需要 DUT、不需要 baseline image,一次跑完就直接給出
 * 「同樣的 key、同樣的資料量下,unordered_map 比 map 快幾倍」的比值,
 * 而且是用真正的 NextHopGroupKey / NextHopKey,不是模擬結構。
 *
 * 用它先回答一個關鍵問題:在你打算跑的 (群組數 n, 每組 nexthop 數 k) 之下,
 * 這個改動的理論上限有多少?如果 n 只有幾十,上限本來就趨近 0,
 * 那就不必期待在 DUT 上量到差異。
 */

#include "gtest/gtest.h"

#include <chrono>
#include <map>
#include <random>
#include <sstream>
#include <unordered_map>
#include <vector>

#include "nexthopgroupkey.h"

namespace nhgbench
{

/* 產生 n 個各有 k 個 nexthop 的 group key,nexthop 從 m 個位址中取 */
static std::vector<NextHopGroupKey> makeKeys(size_t n, size_t k, size_t m, unsigned seed)
{
    std::mt19937 rng(seed);
    std::vector<std::string> pool;
    for (size_t i = 0; i < m; i++)
    {
        std::ostringstream os;
        os << "30.0." << (1 + i / 250) << "." << (2 + i % 250) << "@Ethernet0";
        pool.push_back(os.str());
    }

    std::vector<NextHopGroupKey> keys;
    keys.reserve(n);
    std::vector<size_t> idx(m);
    for (size_t i = 0; i < m; i++) idx[i] = i;

    while (keys.size() < n)
    {
        std::shuffle(idx.begin(), idx.end(), rng);
        std::string s;
        for (size_t j = 0; j < k; j++)
        {
            if (j) s += ",";
            s += pool[idx[j]];
        }
        keys.emplace_back(s);
    }
    return keys;
}

template <typename Table>
static double timeLookups(const std::vector<NextHopGroupKey> &keys, size_t iterations)
{
    Table table;
    for (size_t i = 0; i < keys.size(); i++)
    {
        table[keys[i]] = static_cast<int>(i);
    }

    /* 查詢順序刻意打散,避免 cache 過度友善而高估任一邊 */
    std::mt19937 rng(12345);
    std::vector<size_t> order(iterations);
    for (size_t i = 0; i < iterations; i++)
    {
        order[i] = rng() % keys.size();
    }

    volatile size_t sink = 0;
    auto t0 = std::chrono::steady_clock::now();
    for (size_t i = 0; i < iterations; i++)
    {
        auto it = table.find(keys[order[i]]);
        if (it != table.end()) sink += static_cast<size_t>(it->second);
    }
    auto t1 = std::chrono::steady_clock::now();
    (void)sink;
    return std::chrono::duration<double, std::nano>(t1 - t0).count() / iterations;
}

struct Case { size_t n; size_t k; };

TEST(NhgTableBench, MapVsUnorderedMap)
{
    const size_t POOL = 128;
    const size_t ITER = 200000;
    const std::vector<Case> cases = {
        {1, 4}, {16, 4}, {64, 4}, {256, 4}, {1024, 4}, {4096, 4},
        {1024, 8}, {1024, 16}, {1024, 32},
    };

    printf("\n%8s %6s %14s %14s %10s\n", "groups", "ecmp", "map ns/lookup",
           "umap ns/lookup", "speedup");
    for (const auto &c : cases)
    {
        auto keys = makeKeys(c.n, c.k, POOL, 42);
        double t_map  = timeLookups<std::map<NextHopGroupKey, int>>(keys, ITER);
        double t_umap = timeLookups<std::unordered_map<NextHopGroupKey, int>>(keys, ITER);
        printf("%8zu %6zu %14.1f %14.1f %9.2fx\n", c.n, c.k, t_map, t_umap,
               t_map / t_umap);
        EXPECT_GT(t_map, 0.0);
        EXPECT_GT(t_umap, 0.0);
    }
}

/* 順便驗證 hash 與 operator== 的一致性:相等的 key 一定要有相等的 hash,
 * 否則 unordered_map 會漏查(這是這類改動最容易出的正確性 bug) */
TEST(NhgTableBench, HashMatchesEquality)
{
    NextHopGroupKey a("30.0.1.2@Ethernet0,30.0.1.3@Ethernet0");
    NextHopGroupKey b("30.0.1.3@Ethernet0,30.0.1.2@Ethernet0");  /* 順序不同 */
    ASSERT_EQ(a, b);
    ASSERT_EQ(std::hash<NextHopGroupKey>()(a), std::hash<NextHopGroupKey>()(b));

    NextHopGroupKey c("30.0.1.2@Ethernet0,30.0.1.4@Ethernet0");
    ASSERT_FALSE(a == c);
}

}  // namespace nhgbench
