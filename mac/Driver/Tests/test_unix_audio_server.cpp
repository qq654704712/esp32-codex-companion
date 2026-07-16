#include "AudioRingBuffer.hpp"
#include "UnixAudioServer.hpp"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <arpa/inet.h>
#include <array>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

int main() {
    const std::string path = "/tmp/codex-mic-test-" + std::to_string(getpid()) + ".sock";
    AudioRingBuffer<1024> ring;
    UnixAudioServer<1024> server(path, ring, getuid());
    assert(server.start());
    const std::array<float, 2> stale = {0.8f, 0.9f};
    assert(ring.write(stale.data(), stale.size()) == stale.size());

    const int socket = ::socket(AF_UNIX, SOCK_STREAM, 0);
    assert(socket >= 0);
    sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
    assert(connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);

    const std::array<unsigned char, 8> clearHeader = {'C', 'L', 'E', 'R', 0, 0, 0, 0};
    assert(write(socket, clearHeader.data(), clearHeader.size()) ==
           static_cast<ssize_t>(clearHeader.size()));

    const std::array<float, 4> samples = {0.1f, -0.2f, 0.3f, -0.4f};
    std::array<unsigned char, 8> header = {'C', 'M', 'I', 'C'};
    const std::uint32_t count = htonl(static_cast<std::uint32_t>(samples.size()));
    std::memcpy(header.data() + 4, &count, sizeof(count));
    assert(write(socket, header.data(), header.size()) == static_cast<ssize_t>(header.size()));
    assert(write(socket, samples.data(), sizeof(samples)) == static_cast<ssize_t>(sizeof(samples)));
    close(socket);

    for (int attempt = 0; attempt < 100 && ring.available() != samples.size(); ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::array<float, 4> received = {};
    assert(ring.read(received.data(), received.size()) == received.size());
    assert(received == samples);

    server.stop();
    assert(access(path.c_str(), F_OK) != 0);
    std::puts("unix audio server tests passed");
    return 0;
}
