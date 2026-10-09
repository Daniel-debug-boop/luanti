#pragma once

// Single-producer / single-consumer lock-free ring.
//
// One thread produces (a parse worker), one consumes (the main thread). The
// ring itself performs no allocation on either path: push() moves an existing
// value into a pre-existing slot, pop() moves it back out.
//
// Memory ordering, stated because it is the whole point:
//
//   Producer: fills slot payload, then store(slot.state, READY, release).
//   Consumer: load(slot.state, acquire) == READY, then reads the payload.
//
// The release/acquire pair means every write the producer made to the payload
// is visible to the consumer before it reads it. Relaxed ordering here would be
// a data race that usually works, which is the worst kind.
//
// The ring is bounded and never blocks: a full ring means the consumer is
// behind, and the producer reports backpressure rather than growing memory or
// deadlocking against the thread it would be waiting for.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace ws {

template <typename T>
class SpscRing {
public:
    enum class State : std::uint8_t { Empty = 0, Ready = 1 };

    explicit SpscRing(std::size_t capacity)
        : slots_(capacity != 0 ? capacity : 1),
          states_(capacity != 0 ? capacity : 1) {
        capacity_ = slots_.size();
        for (auto& s : states_) {
            s.store(State::Empty, std::memory_order_relaxed);
        }
    }

    // Producer side. Returns false when the ring is full; the caller decides
    // whether to retry, re-queue the tile, or shed the load.
    bool try_push(T&& value) {
        const std::size_t w = write_.load(std::memory_order_relaxed);
        const std::size_t s = w % capacity_;

        if (states_[s].load(std::memory_order_acquire) == State::Ready) {
            dropped_.fetch_add(1, std::memory_order_relaxed);
            return false;
        }

        slots_[s] = std::move(value);
        // Release: everything written into the slot above is visible to a
        // consumer that observes this flag with acquire.
        states_[s].store(State::Ready, std::memory_order_release);
        write_.store(w + 1, std::memory_order_relaxed);
        pushed_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    // Consumer side. Returns false when nothing is ready.
    bool try_pop(T& out) {
        const std::size_t r = read_.load(std::memory_order_relaxed);
        const std::size_t s = r % capacity_;

        // Acquire: pairs with the producer's release above, so the payload
        // writes are visible before we read them.
        if (states_[s].load(std::memory_order_acquire) != State::Ready) {
            return false;
        }

        out = std::move(slots_[s]);
        states_[s].store(State::Empty, std::memory_order_release);
        read_.store(r + 1, std::memory_order_relaxed);
        popped_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    bool empty() const {
        return read_.load(std::memory_order_relaxed) == write_.load(std::memory_order_acquire);
    }

    std::size_t capacity() const noexcept { return capacity_; }
    std::uint64_t pushed() const noexcept { return pushed_.load(std::memory_order_relaxed); }
    std::uint64_t popped() const noexcept { return popped_.load(std::memory_order_relaxed); }
    std::uint64_t dropped() const noexcept { return dropped_.load(std::memory_order_relaxed); }

private:
    std::vector<T> slots_;
    std::vector<std::atomic<State>> states_;
    std::size_t capacity_ = 0;

    // Cache-line padded so the producer's write_ and the consumer's read_ do not
    // share a line. False sharing here costs more than the rest of the ring.
    alignas(64) std::atomic<std::size_t> write_{0};
    alignas(64) std::atomic<std::size_t> read_{0};
    alignas(64) std::atomic<std::uint64_t> pushed_{0};
    std::atomic<std::uint64_t> popped_{0};
    std::atomic<std::uint64_t> dropped_{0};
};

}  // namespace ws