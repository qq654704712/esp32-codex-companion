#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>

template <std::size_t Capacity>
class AudioRingBuffer {
    static_assert(Capacity > 0);

  public:
    std::size_t write(const float* samples, std::size_t count) noexcept {
        const std::uint64_t write = writeIndex_.load(std::memory_order_relaxed);
        const std::uint64_t read = readIndex_.load(std::memory_order_acquire);
        const std::size_t free = Capacity - static_cast<std::size_t>(write - read);
        const std::size_t accepted = std::min(count, free);
        for (std::size_t index = 0; index < accepted; ++index) {
            storage_[(write + index) % Capacity] = samples[index];
        }
        writeIndex_.store(write + accepted, std::memory_order_release);
        dropped_.fetch_add(count - accepted, std::memory_order_relaxed);
        return accepted;
    }

    std::size_t read(float* output, std::size_t count) noexcept {
        const std::uint64_t read = readIndex_.load(std::memory_order_relaxed);
        const std::uint64_t write = writeIndex_.load(std::memory_order_acquire);
        const std::size_t copied =
            std::min(count, static_cast<std::size_t>(write - read));
        for (std::size_t index = 0; index < copied; ++index) {
            output[index] = storage_[(read + index) % Capacity];
        }
        std::fill(output + copied, output + count, 0.0f);
        readIndex_.store(read + copied, std::memory_order_release);
        return copied;
    }

    std::size_t available() const noexcept {
        const std::uint64_t write = writeIndex_.load(std::memory_order_acquire);
        const std::uint64_t read = readIndex_.load(std::memory_order_acquire);
        return static_cast<std::size_t>(write - read);
    }

    std::uint64_t droppedSamples() const noexcept {
        return dropped_.load(std::memory_order_relaxed);
    }

    void clear() noexcept {
        const std::uint64_t write = writeIndex_.load(std::memory_order_acquire);
        readIndex_.store(write, std::memory_order_release);
    }

  private:
    alignas(64) float storage_[Capacity] = {};
    alignas(64) std::atomic<std::uint64_t> writeIndex_{0};
    alignas(64) std::atomic<std::uint64_t> readIndex_{0};
    std::atomic<std::uint64_t> dropped_{0};
};
