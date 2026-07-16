#pragma once

#include "AudioRingBuffer.hpp"

#include <arpa/inet.h>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#include <vector>

template <std::size_t Capacity>
class UnixAudioServer {
  public:
    UnixAudioServer(std::string path, AudioRingBuffer<Capacity>& ring,
                    uid_t allowedUid, mode_t socketMode = 0600)
        : path_(std::move(path)), ring_(ring), allowedUid_(allowedUid),
          socketMode_(socketMode) {}

    ~UnixAudioServer() { stop(); }

    UnixAudioServer(const UnixAudioServer&) = delete;
    UnixAudioServer& operator=(const UnixAudioServer&) = delete;

    bool start() {
        if (running_.load() || path_.size() >= sizeof(sockaddr_un::sun_path)) {
            return false;
        }
        ::unlink(path_.c_str());
        listeningSocket_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
        if (listeningSocket_ < 0) return false;
        sockaddr_un address = {};
        address.sun_family = AF_UNIX;
        std::strncpy(address.sun_path, path_.c_str(), sizeof(address.sun_path) - 1);
        if (::bind(listeningSocket_, reinterpret_cast<sockaddr*>(&address),
                   sizeof(address)) != 0 ||
            ::chmod(path_.c_str(), socketMode_) != 0 || ::listen(listeningSocket_, 2) != 0) {
            ::close(listeningSocket_);
            listeningSocket_ = -1;
            ::unlink(path_.c_str());
            return false;
        }
        running_.store(true);
        worker_ = std::thread([this] { run(); });
        return true;
    }

    void stop() {
        if (!running_.exchange(false)) return;
        if (listeningSocket_ >= 0) {
            ::shutdown(listeningSocket_, SHUT_RDWR);
            ::close(listeningSocket_);
            listeningSocket_ = -1;
        }
        if (worker_.joinable()) worker_.join();
        ::unlink(path_.c_str());
    }

  private:
    static constexpr std::uint32_t maximumMessageSamples = 96'000;

    void run() {
        while (running_.load()) {
            const int client = ::accept(listeningSocket_, nullptr, nullptr);
            if (client < 0) {
                if (errno == EINTR) continue;
                break;
            }
            handleClient(client);
            ::close(client);
        }
    }

    void handleClient(int client) {
        uid_t peerUid = 0;
        gid_t peerGid = 0;
        if (::getpeereid(client, &peerUid, &peerGid) != 0 || peerUid != allowedUid_) {
            return;
        }
        while (running_.load()) {
            std::uint8_t header[8];
            if (!readExact(client, header, sizeof(header))) return;
            std::uint32_t networkCount;
            std::memcpy(&networkCount, header + 4, sizeof(networkCount));
            const std::uint32_t count = ntohl(networkCount);
            if (std::memcmp(header, "CLER", 4) == 0 && count == 0) {
                ring_.clear();
                continue;
            }
            if (std::memcmp(header, "CMIC", 4) != 0) return;
            if (count == 0 || count > maximumMessageSamples) return;
            std::vector<float> samples(count);
            if (!readExact(client, reinterpret_cast<std::uint8_t*>(samples.data()),
                           samples.size() * sizeof(float))) {
                return;
            }
            ring_.write(samples.data(), samples.size());
        }
    }

    bool readExact(int socket, std::uint8_t* output, std::size_t length) const {
        std::size_t offset = 0;
        while (offset < length) {
            const ssize_t received = ::read(socket, output + offset, length - offset);
            if (received == 0) return false;
            if (received < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            offset += static_cast<std::size_t>(received);
        }
        return true;
    }

    std::string path_;
    AudioRingBuffer<Capacity>& ring_;
    uid_t allowedUid_;
    mode_t socketMode_;
    std::atomic<bool> running_{false};
    int listeningSocket_ = -1;
    std::thread worker_;
};
