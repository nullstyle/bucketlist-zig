// Symbolic harness for unmodified schedule function bodies extracted from Core.
// This file is project code; core_schedule_extracted.hpp is generated at runtime
// with Core's copyright notice and adjacent Apache-2.0 license. See docs/oracle.md.
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#define releaseAssert(x) assert(x)
#define ZoneScoped

namespace stellar {
using uint32 = uint32_t;
using Rows = std::map<std::string, std::optional<std::string>>;

uint32_t roundDown(uint32_t value, uint32_t divisor) {
    return value - value % divisor;
}

struct Config {
    bool ARTIFICIALLY_REDUCE_MERGE_COUNTS_FOR_TESTING = false;
    bool DISABLE_XDR_FSYNC = true;
    bool ARTIFICIALLY_PESSIMIZE_MERGES_FOR_TESTING = false;
};
struct Application {
    Config config;
    Config const& getConfig() const { return config; }
};
struct SymbolicBucket {
    static constexpr uint32_t FIRST_PROTOCOL_SHADOWS_REMOVED = 12;
    Rows rows;
    uint32_t getBucketVersion() const { return 23; }
};
using LiveBucket = SymbolicBucket;
bool protocolVersionStartsFrom(uint32_t version, uint32_t floor) {
    return version >= floor;
}

template <typename BucketT> struct BucketListBase;

// The domain adapter has only newest-wins puts/deletes. It has no Core XDR,
// INIT/lifecycle handling, shadow suppression, hashing, I/O or worker pool.
template <typename BucketT> struct FutureBucket {
    std::shared_ptr<BucketT> output;
    bool merging = false;

    FutureBucket() = default;
    FutureBucket(Application&, std::shared_ptr<BucketT> older,
                 std::shared_ptr<BucketT> newer,
                 std::vector<std::shared_ptr<BucketT>> const& shadows,
                 uint32_t, bool, uint32_t level) {
        assert(shadows.empty());
        output = std::make_shared<BucketT>();
        output->rows = older->rows;
        for (auto const& entry : newer->rows) output->rows[entry.first] = entry.second;
        if (!BucketListBase<BucketT>::keepTombstoneEntries(level)) {
            for (auto it = output->rows.begin(); it != output->rows.end();) {
                if (!it->second) it = output->rows.erase(it);
                else ++it;
            }
        }
        merging = true;
    }
    bool isMerging() const { return merging; }
    bool isLive() const { return static_cast<bool>(output); }
    std::shared_ptr<BucketT> resolve() { merging = false; return output; }
};

template <typename BucketT> struct BucketLevel {
    uint32_t mLevel;
    std::shared_ptr<BucketT> mCurr = std::make_shared<BucketT>();
    std::shared_ptr<BucketT> mSnap = std::make_shared<BucketT>();
    FutureBucket<BucketT> mNext;

    explicit BucketLevel(uint32_t level) : mLevel(level) {}
    std::shared_ptr<BucketT> getCurr() const { return mCurr; }
    std::shared_ptr<BucketT> getSnap() const { return mSnap; }
    FutureBucket<BucketT>& getNext() { return mNext; }
    void setNext(FutureBucket<BucketT> next) { mNext = std::move(next); }
    bool hasInProgressMerge() const { return mNext.isLive(); }
    void commit() {
        if (mNext.isLive()) {
            mCurr = mNext.resolve();
            mNext = FutureBucket<BucketT>();
        }
    }
    std::shared_ptr<BucketT> snap(); // Exact Core implementation extracted below.
    void prepare(Application&, uint32_t, uint32_t, std::shared_ptr<BucketT>,
                 std::vector<std::shared_ptr<BucketT>> const&, bool);

    template <typename... VectorT>
    void prepareFirstLevel(Application& app, uint32_t sequence, uint32_t protocol,
                           bool count, bool, VectorT const&... input) {
        auto fresh = std::make_shared<BucketT>();
        auto add = [&](Rows const& rows) {
            for (auto const& entry : rows) fresh->rows[entry.first] = entry.second;
        };
        (add(input), ...);
        prepare(app, sequence, protocol, fresh, {}, count);
    }
};

template <typename BucketT> struct BucketListBase {
    inline static uint32_t kNumLevels = 11;
    std::vector<BucketLevel<BucketT>> mLevels;

    explicit BucketListBase(uint32_t depth) {
        kNumLevels = depth;
        for (uint32_t i = 0; i < depth; ++i) mLevels.emplace_back(i);
    }
    static bool shouldMergeWithEmptyCurr(uint32_t, uint32_t);
    static uint32_t levelSize(uint32_t);
    static uint32_t levelHalf(uint32_t);
    static bool levelShouldSpill(uint32_t, uint32_t);
    static bool keepTombstoneEntries(uint32_t);
    template <typename... VectorT>
    void addBatchInternal(Application&, uint32_t, uint32_t, VectorT const&...);
    void resolveAnyReadyFutures() {
        for (auto& level : mLevels)
            if (level.mNext.isLive()) level.mNext.resolve();
    }
};

// Inserted source is verbatim from the pinned Git object. No translation or
// search/replace is performed on these Core function definitions.
#include "core_schedule_extracted.hpp"

void writeBucket(uint32_t sequence, uint32_t index, char role,
                 std::shared_ptr<SymbolicBucket> const& bucket) {
    std::cout << sequence << ' ' << index << ' ' << role << ' ';
    if (!bucket) {
        std::cout << "-1\n";
        return;
    }
    std::cout << bucket->rows.size();
    for (auto const& entry : bucket->rows)
        std::cout << ' ' << entry.first << ' ' << (entry.second ? *entry.second : "-");
    std::cout << '\n';
}
void writeState(uint32_t sequence, BucketListBase<SymbolicBucket> const& list) {
    for (uint32_t i = 0; i < list.mLevels.size(); ++i) {
        auto const& level = list.mLevels[i];
        writeBucket(sequence, i, 'c', level.mCurr);
        writeBucket(sequence, i, 's', level.mSnap);
        writeBucket(sequence, i, 'n', level.mNext.output);
    }
}
} // namespace stellar

int main(int argc, char** argv) {
    using namespace stellar;
    if (argc != 2 && argc != 3) return 2;
    auto const depth = static_cast<uint32_t>(std::stoul(argv[1]));
    if (depth == 0 || depth > 11) return 2;
    BucketListBase<SymbolicBucket> list(depth);
    if (argc == 3 && std::string(argv[2]) == "geometry") {
        for (uint32_t level = 0; level < depth; ++level) {
            auto const half = list.levelHalf(level);
            auto const prev = level == 0 ? 0 : list.levelHalf(level - 1);
            for (auto n : {0u, 1u, half - 1, half, half + 1, half * 2 - 1,
                           half * 2, half * 2 + 1, half - prev}) {
                std::cout << level << ' ' << n << ' ' << list.levelSize(level)
                          << ' ' << half << ' ' << list.levelShouldSpill(n, level)
                          << ' ' << list.shouldMergeWithEmptyCurr(n, level) << '\n';
            }
        }
        return 0;
    }
    Application app;
    writeState(0, list);
    uint32_t sequence, count;
    while (std::cin >> sequence >> count) {
        Rows rows;
        for (uint32_t i = 0; i < count; ++i) {
            std::string key, value;
            if (!(std::cin >> key >> value)) return 3;
            rows[key] = value == "-" ? std::nullopt : std::optional<std::string>(value);
        }
        list.addBatchInternal(app, sequence, 23, rows);
        writeState(sequence, list);
    }
}
