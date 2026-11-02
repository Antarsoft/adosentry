#include "net/packet.h"

#include <cstring>
#include <stdexcept>

namespace net {

Packet parse_packet(const std::vector<std::uint8_t>& bytes) {
    if (bytes.size() < kHeaderSize) {
        throw std::invalid_argument("packet too short");
    }
    Packet p{};
    p.type = bytes[0];
    p.length = static_cast<std::uint16_t>(bytes[1] << 8 | bytes[2]);
    return p;
}

}  // namespace net
