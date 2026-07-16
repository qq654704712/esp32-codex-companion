#include "AudioRingBuffer.hpp"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <array>
#include <cassert>
#include <cstdio>

int main() {
    AudioRingBuffer<8> buffer;
    const std::array<float, 4> input = {0.1f, 0.2f, 0.3f, 0.4f};
    assert(buffer.write(input.data(), input.size()) == input.size());

    std::array<float, 6> output = {};
    assert(buffer.read(output.data(), output.size()) == 4);
    assert(output[0] == 0.1f && output[3] == 0.4f);
    assert(output[4] == 0.0f && output[5] == 0.0f);

    const std::array<float, 10> oversized = {};
    assert(buffer.write(oversized.data(), oversized.size()) == 8);
    assert(buffer.droppedSamples() == 2);

    buffer.clear();
    assert(buffer.available() == 0);
    std::puts("ring buffer tests passed");
    return 0;
}
