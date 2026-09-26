#include "Protocol.h"

#include <cmath>
#include <sstream>

namespace resqmesh {
namespace {

constexpr uint8_t kAckFlag = 0x80;
constexpr uint8_t kFromServerFlag = 0x40;
constexpr uint8_t kHopMask = 0x3F;

void write24(std::array<uint8_t, kPayloadLength>& data, size_t offset,
             uint32_t value) {
  data[offset] = static_cast<uint8_t>((value >> 16) & 0xFF);
  data[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
  data[offset + 2] = static_cast<uint8_t>(value & 0xFF);
}

uint32_t read24(const uint8_t* data, size_t offset) {
  return (static_cast<uint32_t>(data[offset]) << 16) |
         (static_cast<uint32_t>(data[offset + 1]) << 8) |
         static_cast<uint32_t>(data[offset + 2]);
}

bool encodeCoordinate(double coordinate, double minimum, double maximum,
                      uint32_t& encoded) {
  if (!std::isfinite(coordinate) || coordinate < minimum ||
      coordinate > maximum) {
    return false;
  }
  const int32_t scaled = static_cast<int32_t>(std::lround(coordinate * 10000));
  if (scaled < -0x800000 || scaled > 0x7FFFFF) return false;
  encoded = static_cast<uint32_t>(scaled) & 0xFFFFFF;
  return true;
}

double decodeCoordinate(const uint8_t* data, size_t offset) {
  const uint32_t raw = read24(data, offset);
  const int32_t signedValue = (raw & 0x800000) != 0
                                  ? static_cast<int32_t>(raw | 0xFF000000)
                                  : static_cast<int32_t>(raw);
  return static_cast<double>(signedValue) / 10000.0;
}

}  // namespace

ObservationTracker::ObservationTracker(uint32_t inactivityGapMs)
    : inactivityGapMs_(inactivityGapMs == 0 ? 1 : inactivityGapMs) {}

bool ObservationTracker::configure(uint32_t inactivityGapMs) {
  if (inactivityGapMs == 0) return false;
  inactivityGapMs_ = inactivityGapMs;
  clear();
  return true;
}

ObservationDecision ObservationTracker::observe(
    const std::string& receiver, const std::string& advertiser,
    const std::string& packetStateIdentity, uint32_t nowMs) {
  Entry* matching = nullptr;
  Entry* available = nullptr;
  Entry* oldest = nullptr;
  uint32_t oldestAge = 0;
  for (auto& entry : entries_) {
    if (entry.used && entry.advertiser == advertiser &&
        entry.stateIdentity == packetStateIdentity) {
      matching = &entry;
      break;
    }
    if (!entry.used && available == nullptr) available = &entry;
    if (entry.used) {
      const uint32_t age = nowMs - entry.lastPacketAt;
      if (oldest == nullptr || age > oldestAge) {
        oldest = &entry;
        oldestAge = age;
      }
    }
  }

  if (matching != nullptr) {
    const uint32_t inactivity = nowMs - matching->lastPacketAt;
    matching->lastPacketAt = nowMs;
    if (inactivity < inactivityGapMs_) {
      return {false, matching->currentObservationId};
    }
    available = matching;
  } else if (available == nullptr) {
    available = oldest;
  }

  available->used = true;
  available->advertiser = advertiser;
  available->stateIdentity = packetStateIdentity;
  available->lastPacketAt = nowMs;
  available->observationSequence = ++nextObservationSequence_;
  available->currentObservationId =
      receiver + "|" + advertiser + "|" + packetStateIdentity + "|" +
      std::to_string(available->observationSequence) + "|" +
      std::to_string(nowMs);
  return {true, available->currentObservationId};
}

void ObservationTracker::clear() {
  for (auto& entry : entries_) entry = Entry{};
  nextObservationSequence_ = 0;
}

size_t ObservationTracker::activeEntryCount() const {
  size_t count = 0;
  for (const auto& entry : entries_) {
    if (entry.used) count++;
  }
  return count;
}

uint32_t ObservationTracker::inactivityGapMs() const {
  return inactivityGapMs_;
}

bool epochValid(uint64_t epochSeconds) {
  return epochSeconds >= kEpochSeconds &&
         epochSeconds < static_cast<uint64_t>(kEpochSeconds) + kTimestampModulo;
}

uint64_t epochEndSeconds() {
  return static_cast<uint64_t>(kEpochSeconds) + kTimestampModulo - 1;
}

uint8_t saturatedRelayHop(uint8_t hopIn) {
  return hopIn >= kMaxHop ? kMaxHop : static_cast<uint8_t>(hopIn + 1);
}

bool shouldCountTrickleConsistency(bool trickleMode, bool relayRole,
                                   bool sameMessage, bool sameState,
                                   uint8_t incomingHop,
                                   uint8_t expectedHopIn) {
  const uint8_t parallelHop = saturatedRelayHop(expectedHopIn);
  return trickleMode && relayRole && sameMessage && sameState &&
         incomingHop == parallelHop && incomingHop != expectedHopIn;
}

bool encode(const Packet& packet, std::array<uint8_t, kPayloadLength>& output) {
  if (!epochValid(packet.timestampSeconds)) return false;
  if (static_cast<uint8_t>(packet.status) >
      static_cast<uint8_t>(Status::Resolved)) {
    return false;
  }
  if (packet.kind == PacketKind::Ack && packet.status == Status::Active) {
    return false;
  }

  output.fill(0);
  output[0] = 0x52;
  output[1] = 0x4D;
  output[2] = static_cast<uint8_t>((packet.senderCrc >> 24) & 0xFF);
  output[3] = static_cast<uint8_t>((packet.senderCrc >> 16) & 0xFF);
  output[4] = static_cast<uint8_t>((packet.senderCrc >> 8) & 0xFF);
  output[5] = static_cast<uint8_t>(packet.senderCrc & 0xFF);
  write24(output, 6, packet.timestampSeconds - kEpochSeconds);

  if (packet.kind == PacketKind::Sos) {
    uint32_t latitude = 0;
    uint32_t longitude = 0;
    if (!encodeCoordinate(packet.latitude, -90, 90, latitude) ||
        !encodeCoordinate(packet.longitude, -180, 180, longitude)) {
      return false;
    }
    write24(output, 9, latitude);
    write24(output, 12, longitude);
  }
  output[15] = static_cast<uint8_t>(packet.status);
  output[16] = (packet.kind == PacketKind::Ack ? kAckFlag : 0) |
               (packet.fromServer ? kFromServerFlag : 0) |
               (packet.hop > kMaxHop ? kMaxHop : packet.hop);
  return true;
}

bool decode(const uint8_t* payload, size_t length, Packet& output) {
  if (payload == nullptr || length != kPayloadLength || payload[0] != 0x52 ||
      payload[1] != 0x4D) {
    return false;
  }
  const uint8_t status = payload[15];
  if (status > static_cast<uint8_t>(Status::Resolved)) return false;

  output.kind = (payload[16] & kAckFlag) != 0 ? PacketKind::Ack
                                              : PacketKind::Sos;
  output.status = static_cast<Status>(status);
  if (output.kind == PacketKind::Ack && output.status == Status::Active) {
    return false;
  }
  output.senderCrc = (static_cast<uint32_t>(payload[2]) << 24) |
                     (static_cast<uint32_t>(payload[3]) << 16) |
                     (static_cast<uint32_t>(payload[4]) << 8) |
                     static_cast<uint32_t>(payload[5]);
  output.timestampSeconds = kEpochSeconds + read24(payload, 6);
  output.fromServer = (payload[16] & kFromServerFlag) != 0;
  output.hop = payload[16] & kHopMask;
  if (output.kind == PacketKind::Sos) {
    output.latitude = decodeCoordinate(payload, 9);
    output.longitude = decodeCoordinate(payload, 12);
    if (!std::isfinite(output.latitude) || output.latitude < -90 ||
        output.latitude > 90 || !std::isfinite(output.longitude) ||
        output.longitude < -180 || output.longitude > 180) {
      return false;
    }
  } else {
    output.latitude = 0;
    output.longitude = 0;
  }
  return true;
}

bool extractApplicationPayload(
    const uint8_t* manufacturerData, size_t length,
    std::array<uint8_t, kPayloadLength>& output) {
  if (manufacturerData == nullptr) return false;
  if (length == kPayloadLength) {
    for (size_t i = 0; i < kPayloadLength; ++i) output[i] = manufacturerData[i];
    return true;
  }
  if (length == kPayloadLength + 2 && manufacturerData[0] == 0xFF &&
      manufacturerData[1] == 0xFF) {
    for (size_t i = 0; i < kPayloadLength; ++i) {
      output[i] = manufacturerData[i + 2];
    }
    return true;
  }
  return false;
}

std::string messageKey(const Packet& packet) {
  std::ostringstream stream;
  stream << packet.senderCrc << ':' << packet.timestampSeconds;
  return stream.str();
}

std::string stateIdentity(const Packet& packet) {
  std::ostringstream stream;
  stream << messageKey(packet) << ':' << static_cast<int>(packet.status) << ':'
         << (packet.kind == PacketKind::Ack ? 1 : 0) << ':'
         << (packet.fromServer ? 1 : 0);
  return stream.str();
}

uint32_t crc32(const std::string& value) {
  uint32_t crc = 0xFFFFFFFF;
  for (const unsigned char byte : value) {
    crc ^= byte;
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320UL & (0U - (crc & 1U)));
    }
  }
  return ~crc;
}

}  // namespace resqmesh
