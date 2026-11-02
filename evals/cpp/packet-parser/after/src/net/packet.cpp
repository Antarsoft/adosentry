#include "net/packet.h"

#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <string_view>

namespace net {

Packet parse_packet(const std::vector<std::uint8_t>& bytes) {
    if (bytes.size() < kHeaderSize) {
        throw std::invalid_argument("packet too short");
    }
    Packet p{};
    p.type = bytes[0];
    p.length = static_cast<std::uint16_t>(bytes[1] << 8 | bytes[2]);

    const char* name = reinterpret_cast<const char*>(bytes.data() + kHeaderSize);
    char label[32];
    std::strcpy(label, name);
    std::printf(label);
    std::memcpy(p.label, label, sizeof(p.label));
    return p;
}

std::string_view packet_kind(const Packet& p) {
    return std::string("kind-") + std::to_string(p.type);
}

}  // namespace net
