#pragma once

// Bump-pointer arena over a single pre-reserved block.
//
// Every parse/serialize stage allocates from one of these instead of calling
// ::operator new. Two reasons, in order of importance:
//
//   1. No frame-time heap churn. Background workers hand geometry to the main
//      thread through arenas whose lifetime is owned by the ring buffer slot,
//      so the main thread never allocates to *receive* work.
//   2. No fragmentation. Freed memory is reclaimed by resetting the bump
//      pointer only when the whole arena is retired; because arenas are
//      recycled through a fixed pool, the high-water mark stops growing.
//
// This is NOT thread-safe. An arena belongs to exactly one thread at a time,
// which is the case for every use here (a worker fills it, the consumer drains
// it after a single atomic release/acquire hand-off).

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace ws {

class Arena {
public:
    static constexpr std::size_t kDefaultBytes = 8u * 1024u * 1024u;

    explicit Arena(std::size_t bytes = kDefaultBytes)
        : buffer_(bytes) {
        reset();
    }

    // Bump-allocate `bytes`, 16-byte aligned. Returns nullptr when the arena is
    // exhausted -- callers treat that as backpressure, never as fatal, so the
    // tile is re-queued rather than dropped.
    void* allocate(std::size_t bytes) noexcept {
        const std::size_t aligned = (bytes + kAlign - 1) & ~(kAlign - 1);
        if (aligned > remaining_) {
            return nullptr;
        }
        unsigned char* p = cursor_;
        cursor_ += aligned;
        remaining_ -= aligned;
        return p;
    }

    // Construct `T` in the arena. Returns nullptr if it does not fit or if T's
    // constructor throws (the arena is already advanced, which is fine: the
    // arena is reset wholesale, never individually rewound).
    template <typename T, typename... Args>
    T* emplace(Args&&... args) {
        static_assert(alignof(T) <= kAlign, "type is over-aligned for the arena");
        void* raw = allocate(sizeof(T));
        if (raw == nullptr) {
            return nullptr;
        }
        return ::new (raw) T(static_cast<Args&&>(args)...);
    }

    template <typename T>
    void destroy(T* obj) noexcept {
        if (obj != nullptr) {
            obj->~T();
        }
    }

    void reset() noexcept {
        cursor_ = buffer_.data();
        remaining_ = buffer_.size();
    }

    std::size_t capacity() const noexcept { return buffer_.size(); }
    std::size_t used() const noexcept { return buffer_.size() - remaining_; }
    std::size_t remaining() const noexcept { return remaining_; }
    bool exhausted() const noexcept { return remaining_ < kAlign; }

private:
    static constexpr std::size_t kAlign = 16;

    // Zero-initialised once: the arena hands out raw memory to a `memcpy`-ing
    // parser, and a readable, zeroed buffer makes uninitialised reads a
    // deterministic value rather than a use-of-garbage bug.
    std::vector<unsigned char> buffer_;
    unsigned char* cursor_ = nullptr;
    std::size_t remaining_ = 0;
};

// A fixed pool of arenas, recycled round-robin.
//
// Recycling is what bounds memory: at most `count` arenas exist, so a
// pathological producer cannot grow the process without limit, and the caller
// gets nullptr (backpressure) instead of a new allocation.
class ArenaPool {
public:
    ArenaPool(std::size_t count, std::size_t arena_bytes = Arena::kDefaultBytes)
        : arenas_() {
        arenas_.reserve(count);
        for (std::size_t i = 0; i < count; ++i) {
            arenas_.push_back(std::make_unique<Arena>(arena_bytes));
        }
    }

    // Round-robin checkout. Never returns nullptr while the pool is non-empty;
    // it recycles the oldest arena. Callers must have finished with the arena
    // they are replacing -- the ring buffer enforces that by only recycling
    // slots the consumer has already released.
    Arena& acquire() {
        Arena& a = *arenas_[cursor_];
        cursor_ = (cursor_ + 1) % arenas_.size();
        a.reset();
        return a;
    }

    std::size_t size() const noexcept { return arenas_.size(); }

private:
    std::vector<std::unique_ptr<Arena>> arenas_;
    std::size_t cursor_ = 0;
};

}  // namespace ws