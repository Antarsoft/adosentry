#pragma once

#include <array>
#include <cstddef>
#include <mutex>
#include <optional>

namespace util {

template <typename T, std::size_t Capacity>
class RingBuffer {
    static_assert(Capacity > 0, "capacity must be positive");

public:
    bool push(T value) {
        std::scoped_lock lock(mutex_);
        if (size_ == Capacity) {
            return false;
        }
        items_[(head_ + size_) % Capacity] = std::move(value);
        ++size_;
        return true;
    }

    std::optional<T> pop() {
        std::scoped_lock lock(mutex_);
        if (size_ == 0) {
            return std::nullopt;
        }
        T value = std::move(items_[head_]);
        head_ = (head_ + 1) % Capacity;
        --size_;
        return value;
    }

    [[nodiscard]] std::size_t size() const {
        std::scoped_lock lock(mutex_);
        return size_;
    }

private:
    mutable std::mutex mutex_;
    std::array<T, Capacity> items_{};
    std::size_t head_ = 0;
    std::size_t size_ = 0;
};

}  // namespace util
