#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace resqmesh {

constexpr size_t kPayloadLength = 17;
constexpr uint16_t kManufacturerId = 0xFFFF;
constexpr const char* kProtocolVersion = "resqmesh-ble17-v1";
constexpr uint32_t kEpochSeconds = 1780272000UL;
constexpr const char* kEpochId = "resqmesh-2026-06-01";
constexpr uint32_t kTimestampModulo = 1UL << 24;
constexpr uint8_t kMaxHop = 63;

enum class PacketKind : uint8_t { Sos = 0, Ack = 1 };
enum class Status : uint8_t { Cancelled = 0, Active = 1, Resolved = 2 };

struct Packet {
  PacketKind kind = PacketKind::Sos;
  uint32_t senderCrc = 0;
  uint32_t timestampSeconds = 0;
  double latitude = 0;
  double longitude = 0;
  Status status = Status::Active;
  bool fromServer = false;
  uint8_t hop = 0;
};

bool epochValid(uint64_t epochSeconds);
uint64_t epochEndSeconds();
uint8_t saturatedRelayHop(uint8_t hopIn);
bool shouldCountTrickleConsistency(bool trickleMode, bool relayRole,
                                   bool sameMessage, bool sameState,
                                   uint8_t incomingHop,
                                   uint8_t expectedHopIn);
bool encode(const Packet& packet, std::array<uint8_t, kPayloadLength>& output);
bool decode(const uint8_t* payload, size_t length, Packet& output);
bool extractApplicationPayload(
    const uint8_t* manufacturerData,
    size_t length,
    std::array<uint8_t, kPayloadLength>& output);
std::string messageKey(const Packet& packet);
std::string stateIdentity(const Packet& packet);
uint32_t crc32(const std::string& value);

}  // namespace resqmesh
