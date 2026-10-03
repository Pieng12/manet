#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>

#include <array>
#include <atomic>
#include <string>

#include "Protocol.h"
#include "CodedRadio.h"
#include "TrickleTiming.h"

#ifndef RESQMESH_FIRMWARE_BUILD_ID
#error "RESQMESH_FIRMWARE_BUILD_ID must be injected by the PlatformIO build"
#endif

using namespace resqmesh;

namespace {

constexpr uint32_t kBurstMs = 2000;
constexpr uint32_t kBasicIntervalMs = 2000;
constexpr uint32_t kIminMs = 8000;
constexpr uint32_t kImaxMs = 256000;
constexpr uint32_t kDefaultRxBurstGapMs = 1000;
constexpr uint32_t kQuietPeriodMs = 2000;
constexpr uint32_t kNativeStartRetryMs = 1000;
constexpr size_t kSerialRxBufferBytes = 2048;

enum class Role { Source, Relay, Destination, Observer };
enum class Mode { Basic, Trickle };

struct NodeConfig {
  String nodeId = "esp32-unconfigured";
  String sessionLabel;
  String sessionId;
  String trialId;
  String hypothesis;
  Role role = Role::Observer;
  Mode mode = Mode::Trickle;
  uint8_t nodeLayer = 0;
  uint8_t expectedHopIn = 0;
  uint8_t hopOut = 0;
  uint32_t rxBurstGapMs = kDefaultRxBurstGapMs;
  bool protocolActive = false;
};

struct SchedulerState {
  bool hasPacket = false;
  Packet packet;
  uint32_t intervalMs = kIminMs;
  uint32_t intervalStartedAt = 0;
  uint32_t transmitAt = 0;
  uint32_t intervalEndAt = 0;
  uint32_t consistencyCount = 0;
  bool waitingIntervalEnd = false;
  bool advertising = false;
  bool firstAdvertiseStarted = false;
  uint64_t firstAdvertiseStartedAtMs = 0;
  uint32_t burstEndsAt = 0;
  String burstId;
};

Preferences preferences;
NodeConfig config;
SchedulerState scheduler;
CodedRadio radio;
CodedRadio* advertising = &radio;
NimBLEScan* scanner = nullptr;
uint64_t wallOffsetMs = 0;
bool wallClockValid = false;
uint32_t burstSequence = 0;
uint64_t eventSequence = 0;
uint32_t quietUntil = 0;
bool observationWindowOpen = false;
String serialBuffer;
ObservationTracker observationTracker(kDefaultRxBurstGapMs);
SemaphoreHandle_t serialOutputMutex = nullptr;

struct ReceivedPacket {
  Packet packet;
  int rssi;
  char advertiser[18];
  uint32_t receivedAt;
  uint32_t generation;
};

QueueHandle_t receivedPackets = nullptr;
std::atomic<uint32_t> receiveGeneration{0};
std::atomic<uint32_t> receiveOverflow{0};
std::atomic<bool> receiveEnabled{false};

bool due(uint32_t now, uint32_t deadline) {
  return deadlineReached(now, deadline);
}

const char* roleName(Role role) {
  switch (role) {
    case Role::Source:
      return "SOURCE";
    case Role::Relay:
      return "RELAY";
    case Role::Destination:
      return "DESTINATION";
    case Role::Observer:
      return "OBSERVER";
  }
  return "OBSERVER";
}

const char* modeName(Mode mode) {
  return mode == Mode::Trickle ? "trickle" : "basic_flooding";
}

const char* statusName(Status status) {
  switch (status) {
    case Status::Cancelled:
      return "cancelled";
    case Status::Active:
      return "active";
    case Status::Resolved:
      return "resolved";
  }
  return "unknown";
}

uint64_t wallTimeMs() {
  return wallClockValid ? wallOffsetMs + millis() : 0;
}

void emit(const char* eventType, const Packet* packet = nullptr,
          const char* reason = nullptr, int rssi = 0,
          const String& observationId = String(),
          const String& burstId = String(),
          const uint32_t* physicalReceivedAt = nullptr) {
  if (serialOutputMutex != nullptr) {
    xSemaphoreTake(serialOutputMutex, portMAX_DELAY);
  }
  JsonDocument document;
  document["kind"] = "event";
  document["event_type"] = eventType;
  document["event_sequence"] = ++eventSequence;
  document["node_id"] = config.nodeId;
  document["session_id"] = config.sessionId;
  document["trial_id"] = config.trialId;
  document["mode"] = modeName(config.mode);
  document["role"] = roleName(config.role);
  if (strncmp(eventType, "ADVERTISE_BURST_", 16) == 0 ||
      strcmp(eventType, "SERVICE_STARTED") == 0) {
    radio.telemetry(document["radio"].to<JsonObject>());
  }
  const uint32_t eventTime =
      physicalReceivedAt != nullptr ? *physicalReceivedAt : millis();
  document["monotonic_ms"] = eventTime;
  if (wallClockValid) document["timestamp_ms"] = wallOffsetMs + eventTime;
  document["clock_sync_valid"] = wallClockValid;
  if (wallClockValid) document["clock_offset_ms"] = 0;
  if (reason != nullptr) document["reason"] = reason;
  if (config.mode == Mode::Trickle && scheduler.hasPacket &&
      (strncmp(eventType, "TRICKLE_", 8) == 0 ||
       strncmp(eventType, "ADVERTISE_BURST_", 16) == 0)) {
    document["interval_ms"] = scheduler.intervalMs;
    document["interval_started_at_monotonic_ms"] = scheduler.intervalStartedAt;
    document["transmit_at_monotonic_ms"] = scheduler.transmitAt;
    document["interval_end_at_monotonic_ms"] = scheduler.intervalEndAt;
    document["consistency_count"] = scheduler.consistencyCount;
  }
  if (!observationId.isEmpty()) document["observation_id"] = observationId;
  if (!burstId.isEmpty()) document["burst_id"] = burstId;
  if (rssi != 0) document["rssi"] = rssi;
  if (packet != nullptr) {
    document["sender_crc"] = packet->senderCrc;
    document["protocol_timestamp_ms"] =
        static_cast<uint64_t>(packet->timestampSeconds) * 1000;
    document["packet_type"] =
        packet->kind == PacketKind::Ack ? "ack" : "sos";
    document["status"] = statusName(packet->status);
    document["hop_in"] = packet->hop;
    document["message_key"] = messageKey(*packet);
    document["state_identity"] = stateIdentity(*packet);
  }
  serializeJson(document, Serial);
  Serial.println();
  if (serialOutputMutex != nullptr) xSemaphoreGive(serialOutputMutex);
}

void respond(const String& command, const String& commandId, bool ok,
             const char* error = nullptr) {
  JsonDocument document;
  document["kind"] = "response";
  document["command"] = command;
  document["command_id"] = commandId;
  document["ok"] = ok;
  if (error != nullptr) document["error"] = error;
  if (serialOutputMutex != nullptr) {
    xSemaphoreTake(serialOutputMutex, portMAX_DELAY);
  }
  serializeJson(document, Serial);
  Serial.println();
  if (serialOutputMutex != nullptr) xSemaphoreGive(serialOutputMutex);
}

Role parseRole(const String& value) {
  if (value == "SOURCE") return Role::Source;
  if (value == "RELAY") return Role::Relay;
  if (value == "DESTINATION") return Role::Destination;
  return Role::Observer;
}

Mode parseMode(const String& value) {
  return value == "basic" || value == "basic_flooding" ? Mode::Basic
                                                         : Mode::Trickle;
}

void persistConfig() {
  preferences.putString("node", config.nodeId);
  preferences.putString("label", config.sessionLabel);
  preferences.putString("session", config.sessionId);
  preferences.putString("trial", config.trialId);
  preferences.putString("hyp", config.hypothesis);
  preferences.putString("role", roleName(config.role));
  preferences.putString("mode", modeName(config.mode));
  preferences.putUChar("layer", config.nodeLayer);
  preferences.putUChar("hopin", config.expectedHopIn);
  preferences.putUChar("hopout", config.hopOut);
  preferences.putUInt("rxgap", config.rxBurstGapMs);
  preferences.putBool("active", config.protocolActive);
}

void persistPacket() {
  if (!scheduler.hasPacket) {
    preferences.remove("packet");
    return;
  }
  std::array<uint8_t, kPayloadLength> bytes{};
  if (encode(scheduler.packet, bytes)) {
    preferences.putBytes("packet", bytes.data(), bytes.size());
  }
}

bool pauseScanner() {
  return scanner == nullptr || !scanner->isScanning() || scanner->stop();
}

void resumeScanner() {
  if (scanner != nullptr && !scanner->isScanning()) {
    scanner->start(0, false, false);
  }
}

void clearProtocolState() {
  receiveEnabled.store(false);
  receiveGeneration.fetch_add(1);
  receiveOverflow.store(0);
  if (receivedPackets != nullptr) xQueueReset(receivedPackets);
  if (scheduler.advertising && advertising != nullptr) advertising->stop();
  resumeScanner();
  scheduler = SchedulerState();
  preferences.remove("packet");
  observationTracker.clear();
}

void cancelActiveBurst(const char* reason) {
  if (!scheduler.advertising || advertising == nullptr) return;
  advertising->stop();
  resumeScanner();
  scheduler.advertising = false;
  emit("ADVERTISE_BURST_CANCELLED", &scheduler.packet, reason, 0, String(),
       scheduler.burstId);
  scheduler.burstId = "";
}

void chooseTrickleTransmit(uint32_t now, const char* reason) {
  scheduler.intervalStartedAt = now;
  scheduler.intervalEndAt = now + scheduler.intervalMs;
  scheduler.transmitAt = now + trickleTransmitOffset(
      scheduler.intervalMs,
      random(0, scheduler.intervalMs - scheduler.intervalMs / 2));
  scheduler.consistencyCount = 0;
  scheduler.waitingIntervalEnd = false;
  emit("TRICKLE_INTERVAL_STARTED", &scheduler.packet, reason);
}

void scheduleNewState(const char* reason) {
  const uint32_t now = millis();
  scheduler.intervalMs = kIminMs;
  if (config.mode == Mode::Trickle) {
    chooseTrickleTransmit(now, reason);
  } else {
    scheduler.transmitAt = now;
    scheduler.waitingIntervalEnd = false;
  }
}

void storeForRelay(const Packet& incoming, const char* reason,
                   const uint32_t* receivedAt = nullptr) {
  scheduler.packet = incoming;
  if (config.role == Role::Relay) {
    scheduler.packet.hop =
        config.hopOut > 0 ? min(config.hopOut, kMaxHop)
                          : saturatedRelayHop(incoming.hop);
  }
  scheduler.hasPacket = true;
  persistPacket();
  emit("BLE_PACKET_ACCEPTED", &incoming, reason);
  if (config.role == Role::Destination) {
    emit("DESTINATION_FIRST_VALID_RECEIVE", &incoming, nullptr, 0,
         String(), String(), receivedAt);
    return;
  }
  if (config.role == Role::Relay) {
    scheduleNewState(reason);
    emit("BLE_RELAY_QUEUED", &scheduler.packet);
  }
}

void recordConsistent(const Packet& incoming, const String& observationId) {
  emit("BLE_PACKET_DUPLICATE", &incoming, "CONSISTENT", 0, observationId);
  if (shouldCountTrickleConsistency(
          config.mode == Mode::Trickle, config.role == Role::Relay, true, true,
          incoming.hop, config.expectedHopIn)) {
    scheduler.consistencyCount++;
    emit("TRICKLE_CONSISTENT_HEARD", &incoming);
  }
}

void processPacket(const Packet& incoming, int rssi,
                   const String& advertiser, uint32_t now) {
  const ObservationDecision decision = observationTracker.observe(
      config.nodeId.c_str(), advertiser.c_str(), stateIdentity(incoming), now);
  if (!decision.isNew) return;
  const String observation(decision.observationId.c_str());
  emit("BLE_PACKET_RECEIVED", &incoming, nullptr, rssi, observation,
       String(), &now);

  if (!config.protocolActive || config.role == Role::Source ||
      !due(now, quietUntil)) {
    emit("TOPOLOGY_IGNORED", &incoming, "NODE_INACTIVE_OR_SOURCE", rssi,
         observation);
    return;
  }

  const bool sameMessage = scheduler.hasPacket &&
                           messageKey(scheduler.packet) == messageKey(incoming);
  const bool sameState = scheduler.hasPacket &&
                         stateIdentity(scheduler.packet) ==
                             stateIdentity(incoming);
  const uint8_t peerHop = saturatedRelayHop(config.expectedHopIn);
  const bool upstream = incoming.hop == config.expectedHopIn;
  const bool parallel = config.role == Role::Relay && sameMessage &&
                        incoming.hop == peerHop && !upstream;

  if (!upstream && !parallel) {
    emit("TOPOLOGY_IGNORED", &incoming, "UNEXPECTED_HOP", rssi, observation);
    return;
  }
  if (parallel) {
    if (sameState) {
      recordConsistent(incoming, observation);
      return;
    }
    if (config.mode == Mode::Trickle) {
      scheduler.intervalMs = kIminMs;
      chooseTrickleTransmit(now, "PARALLEL_RELAY_INCONSISTENT");
      emit("TRICKLE_INCONSISTENT_HEARD", &incoming);
    }
    return;
  }
  if (sameState) {
    emit("BLE_PACKET_DUPLICATE", &incoming, "UPSTREAM_REPEAT", 0,
         observation);
    return;
  }
  storeForRelay(incoming, sameMessage ? "NEW_STATE" : "NEW_MESSAGE", &now);
}

class ScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* device) override {
    const uint32_t generation = receiveGeneration.load();
    if (!receiveEnabled.load()) return;
    const uint32_t receivedAt = millis();
    if (!device->haveManufacturerData()) return;
    const std::string data = device->getManufacturerData();
    std::array<uint8_t, kPayloadLength> payload{};
    if (!extractApplicationPayload(
            reinterpret_cast<const uint8_t*>(data.data()), data.size(),
            payload)) {
      return;
    }
    Packet packet;
    if (!decode(payload.data(), payload.size(), packet)) return;
    ReceivedPacket received{};
    received.packet = packet;
    received.rssi = device->getRSSI();
    received.receivedAt = receivedAt;
    received.generation = generation;
    const std::string address = device->getAddress().toString();
    snprintf(received.advertiser, sizeof(received.advertiser), "%s", address.c_str());
    // The NimBLE task never reads or mutates scheduler/configuration state.
    if (xQueueSend(receivedPackets, &received, 0) != pdTRUE) {
      receiveOverflow.fetch_add(1);
    }
  }
};

void drainReceivedPackets() {
  const uint32_t dropped = receiveOverflow.exchange(0);
  if (dropped > 0 && observationWindowOpen) {
    emit("EXPERIMENT_CONFIG_VIOLATION", nullptr, "RX_QUEUE_OVERFLOW");
  }
  ReceivedPacket received;
  for (size_t count = 0;
       count < 64 && xQueueReceive(receivedPackets, &received, 0) == pdTRUE;
       count++) {
    if (!observationWindowOpen || received.generation != receiveGeneration.load()) {
      continue;
    }
    processPacket(received.packet, received.rssi, String(received.advertiser),
                  received.receivedAt);
  }
}

void startBurst() {
  if (!scheduler.hasPacket || advertising == nullptr) return;
  // Recheck after scheduler logging; its serial output can cross an interval end.
  if (config.mode == Mode::Trickle &&
      (scheduler.waitingIntervalEnd ||
       !trickleTransmitDue(millis(), scheduler.intervalStartedAt,
                           scheduler.intervalMs, scheduler.transmitAt))) {
    return;
  }
  scheduler.burstId = config.nodeId + "-" + String(millis()) + "-" +
                      String(++burstSequence);
  std::array<uint8_t, kPayloadLength> payload{};
  if (!encode(scheduler.packet, payload)) {
    emit("ADVERTISE_BURST_FAILED", &scheduler.packet, "ENCODE_FAILED", 0,
         String(), scheduler.burstId);
    scheduler.burstId = "";
    return;
  }
  emit("ADVERTISE_BURST_REQUESTED", &scheduler.packet, nullptr, 0, String(),
       scheduler.burstId);

  if (!pauseScanner()) {
    scheduler.transmitAt = millis() + kNativeStartRetryMs;
    emit("ADVERTISE_BURST_FAILED", &scheduler.packet, "SCAN_STOP_FAILED", 0,
         String(), scheduler.burstId);
    scheduler.burstId = "";
    return;
  }
  if (!advertising->start(payload)) {
    resumeScanner();
    scheduler.transmitAt = millis() + kNativeStartRetryMs;
    emit("ADVERTISE_BURST_FAILED", &scheduler.packet, "NATIVE_START_FAILED",
         0, String(), scheduler.burstId);
    scheduler.burstId = "";
    return;
  }
  scheduler.advertising = true;
  const uint32_t succeededAt = millis();
  scheduler.burstEndsAt = succeededAt + kBurstMs;
  emit("ADVERTISE_BURST_STARTED", &scheduler.packet, nullptr, 0, String(),
       scheduler.burstId, &succeededAt);
  if (!scheduler.firstAdvertiseStarted && config.role == Role::Source) {
    scheduler.firstAdvertiseStartedAtMs = wallOffsetMs + succeededAt;
    emit("SOURCE_FIRST_ADVERTISE_STARTED", &scheduler.packet, nullptr, 0,
         String(), scheduler.burstId, &succeededAt);
  }
  scheduler.firstAdvertiseStarted = true;
  emit("BLE_RELAY_STARTED", &scheduler.packet, nullptr, 0, String(),
       scheduler.burstId);
}

void finishBurst() {
  advertising->stop();
  resumeScanner();
  scheduler.advertising = false;
  emit("ADVERTISE_BURST_ENDED", &scheduler.packet, nullptr, 0, String(),
       scheduler.burstId);
  const uint32_t now = millis();
  if (config.mode == Mode::Basic) {
    scheduler.transmitAt = now + kBasicIntervalMs + random(300, 1501);
  } else {
    scheduler.waitingIntervalEnd = true;
    scheduler.transmitAt = scheduler.intervalEndAt;
  }
  scheduler.burstId = "";
}

void tickScheduler() {
  if (!observationWindowOpen || !scheduler.hasPacket ||
      config.role == Role::Destination ||
      config.role == Role::Observer || !config.protocolActive) {
    return;
  }
  const uint32_t now = millis();
  if (scheduler.advertising) {
    if (due(now, scheduler.burstEndsAt)) finishBurst();
    return;
  }
  if (config.mode == Mode::Trickle && due(now, scheduler.intervalEndAt)) {
    scheduler.intervalMs = min(scheduler.intervalMs * 2, kImaxMs);
    chooseTrickleTransmit(now, "INTERVAL_ADVANCED");
    return;
  }
  if (!due(now, scheduler.transmitAt)) return;
  if (config.mode == Mode::Trickle &&
      (scheduler.waitingIntervalEnd ||
       !trickleTransmitDue(now, scheduler.intervalStartedAt,
                           scheduler.intervalMs, scheduler.transmitAt))) {
    return;
  }
  if (config.mode == Mode::Trickle && scheduler.consistencyCount >= 1) {
    emit("TRICKLE_TX_SUPPRESSED", &scheduler.packet, "C_GE_K");
    scheduler.waitingIntervalEnd = true;
    scheduler.transmitAt = scheduler.intervalEndAt;
    return;
  }
  if (config.mode == Mode::Trickle) {
    emit("TRICKLE_TX_ALLOWED", &scheduler.packet, "C_LT_K");
  }
  startBurst();
}

void emitReadiness(const String& commandId) {
  JsonDocument document;
  const uint64_t nowSeconds = wallClockValid ? wallTimeMs() / 1000 : 0;
  document["kind"] = "response";
  document["command"] = "readiness";
  document["command_id"] = commandId;
  document["ok"] = radio.ready();
  radio.telemetry(document["radio"].to<JsonObject>());
  document["node_id"] = config.nodeId;
  document["build_id"] = RESQMESH_FIRMWARE_BUILD_ID;
  document["firmware_build_id"] = RESQMESH_FIRMWARE_BUILD_ID;
  document["session_label"] = config.sessionLabel;
  document["session_id"] = config.sessionId;
  document["trial_id"] = config.trialId;
  document["role"] = roleName(config.role);
  if (scheduler.firstAdvertiseStartedAtMs != 0 && config.role == Role::Source) {
    document["source_first_advertise_started_at_ms"] =
        scheduler.firstAdvertiseStartedAtMs;
    document["source_first_advertise_message_key"] = messageKey(scheduler.packet);
  }
  document["mode"] = modeName(config.mode);
  document["protocol_active"] = config.protocolActive;
  document["expected_hop_in"] = config.expectedHopIn;
  document["hop_out"] = config.hopOut;
  document["protocol_version"] = kProtocolVersion;
  document["bluetooth"] = true;
  document["scanner"] = scanner != nullptr && scanner->isScanning();
  document["advertising"] = scheduler.advertising;
  document["packet_pending"] = scheduler.hasPacket;
  document["queue_size"] = scheduler.hasPacket ? 1 : 0;
  document["quiet_period_complete"] = due(millis(), quietUntil);
  document["clock_valid"] = wallClockValid;
  document["epoch_id"] = kEpochId;
  document["epoch_start_seconds"] = kEpochSeconds;
  document["epoch_end_seconds"] = epochEndSeconds();
  document["epoch_valid"] = wallClockValid && epochValid(nowSeconds);
  document["epoch_remaining_days"] =
      wallClockValid && nowSeconds <= epochEndSeconds()
          ? static_cast<double>(epochEndSeconds() + 1 - nowSeconds) / 86400.0
          : 0;
  document["payload_length"] = kPayloadLength;
  document["measurement_timing_version"] = 2;
  document["manufacturer_id"] = kManufacturerId;
  document["rx_burst_gap_ms"] = config.rxBurstGapMs;
  document["observation_window_open"] = observationWindowOpen;
  if (serialOutputMutex != nullptr) {
    xSemaphoreTake(serialOutputMutex, portMAX_DELAY);
  }
  serializeJson(document, Serial);
  Serial.println();
  if (serialOutputMutex != nullptr) xSemaphoreGive(serialOutputMutex);
}

void handleCommand(const String& line) {
  JsonDocument document;
  if (deserializeJson(document, line)) {
    respond("unknown", "", false, "INVALID_JSON");
    return;
  }
  const String command = document["command"] | "";
  const String commandId = document["command_id"] | "";
  if (command == "clock_sync") {
    const uint64_t requestedWallMs = document["wall_time_ms"] | 0ULL;
    if (requestedWallMs == 0) {
      respond(command, commandId, false, "MISSING_wall_time_ms");
      return;
    }
    wallOffsetMs = requestedWallMs - millis();
    wallClockValid = true;
    respond(command, commandId, true);
    return;
  }
  if (command == "readiness" || command == "get_status") {
    emitReadiness(commandId);
    return;
  }
  if (command == "configure_session") {
    const String radioMode = document["radio_mode"] | "coded";
    if (radioMode != "coded" && radioMode != "coded_s8_required") {
      respond(command, commandId, false, "INVALID_RADIO_MODE");
      return;
    }
    const String epochId = document["protocol_epoch_id"] | "";
    const uint32_t epochSeconds = document["protocol_epoch_seconds"] | 0;
    const String protocolVersion = document["protocol_version"] | "";
    if (epochId != kEpochId || epochSeconds != kEpochSeconds) {
      respond(command, commandId, false, "PROTOCOL_EPOCH_MISMATCH");
      return;
    }
    if (protocolVersion != kProtocolVersion) {
      respond(command, commandId, false, "PROTOCOL_VERSION_MISMATCH");
      return;
    }
    const String requestedRole = document["role"] | "";
    const String requestedMode = document["mode"] | "";
    if (requestedRole != "SOURCE" && requestedRole != "RELAY" &&
        requestedRole != "DESTINATION" && requestedRole != "OBSERVER") {
      respond(command, commandId, false, "INVALID_ROLE");
      return;
    }
    if (requestedMode != "trickle" && requestedMode != "basic" &&
        requestedMode != "basic_flooding") {
      respond(command, commandId, false, "INVALID_MODE");
      return;
    }
    const uint32_t requestedRxBurstGapMs =
        document["rx_burst_gap_ms"] | 0;
    if (requestedRxBurstGapMs == 0) {
      respond(command, commandId, false, "INVALID_rx_burst_gap_ms");
      return;
    }
    preferences.putBool("s8required", radioMode == "coded_s8_required");
    if (!radio.configure(radioMode == "coded_s8_required")) {
      resumeScanner();
      respond(command, commandId, false, "RADIO_CONFIGURATION_FAILED_CHECK_READINESS");
      return;
    }
    config.nodeId = String(document["node_id"] | "esp32-unconfigured");
    config.sessionLabel = String(document["build_id"] | "");
    config.sessionId = String(document["session_id"] | "");
    config.hypothesis = String(document["hypothesis"] | "");
    config.role = parseRole(requestedRole);
    config.mode = parseMode(requestedMode);
    config.nodeLayer = document["node_layer"] | 0;
    config.expectedHopIn = document["expected_hop_in"] | 0;
    config.hopOut = document["hop_out"] | 0;
    config.rxBurstGapMs = requestedRxBurstGapMs;
    config.protocolActive = document["protocol_active"] | true;
    observationTracker.configure(config.rxBurstGapMs);
    persistConfig();
    respond(command, commandId, true);
    return;
  }
  if (command == "start_trial") {
    if (!radio.ready()) {
      respond(command, commandId, false, "RADIO_NOT_READY");
      return;
    }
    if (!wallClockValid || !epochValid(wallTimeMs() / 1000)) {
      respond(command, commandId, false, "PROTOCOL_EPOCH_OUT_OF_RANGE");
      return;
    }
    clearProtocolState();
    config.trialId = String(document["trial_id"] | "");
    observationWindowOpen = true;
    persistConfig();
    emit("TRIAL_WINDOW_STARTED");
    receiveEnabled.store(true);
    respond(command, commandId, true);
    return;
  }
  if (command == "end_observation_window") {
    if (observationWindowOpen) {
      receiveEnabled.store(false);
      drainReceivedPackets();
      cancelActiveBurst("OBSERVATION_WINDOW_ENDED");
      observationWindowOpen = false;
      receiveGeneration.fetch_add(1);
      emit("TRIAL_WINDOW_ENDED");
    }
    respond(command, commandId, true);
    return;
  }
  if (command == "trigger_sos") {
    if (config.role != Role::Source || !config.protocolActive) {
      respond(command, commandId, false, "SOURCE_NOT_ACTIVE");
      return;
    }
    const uint64_t seconds = wallTimeMs() / 1000;
    if (!wallClockValid || !epochValid(seconds)) {
      respond(command, commandId, false, "PROTOCOL_EPOCH_OUT_OF_RANGE");
      return;
    }
    if (scheduler.hasPacket) {
      respond(command, commandId, false, "TRIAL_ALREADY_HAS_LOGICAL_SOS");
      return;
    }
    scheduler.packet.kind = PacketKind::Sos;
    scheduler.packet.senderCrc = crc32(config.nodeId.c_str());
    scheduler.packet.timestampSeconds = static_cast<uint32_t>(seconds);
    scheduler.packet.latitude = document["latitude"] | 3.5952;
    scheduler.packet.longitude = document["longitude"] | 98.6722;
    scheduler.packet.status = Status::Active;
    scheduler.packet.hop = 1;
    scheduler.hasPacket = true;
    persistPacket();
    scheduleNewState("LOCAL_SOURCE_EVENT");
    emit("SOS_CREATED", &scheduler.packet);
    respond(command, commandId, true);
    return;
  }
  if (command == "reset_trial") {
    observationWindowOpen = false;
    clearProtocolState();
    quietUntil = millis() + kQuietPeriodMs;
    emit("TRIAL_RESET");
    config.trialId = "";
    persistConfig();
    respond(command, commandId, true);
    return;
  }
  respond(command, commandId, false, "UNKNOWN_COMMAND");
}

void loadPersistentState() {
  config.nodeId = preferences.getString("node", config.nodeId);
  config.sessionLabel = preferences.getString("label", "");
  config.sessionId = preferences.getString("session", "");
  config.trialId = preferences.getString("trial", "");
  config.hypothesis = preferences.getString("hyp", "");
  config.role = parseRole(preferences.getString("role", "OBSERVER"));
  config.mode = parseMode(preferences.getString("mode", "trickle"));
  config.nodeLayer = preferences.getUChar("layer", 0);
  config.expectedHopIn = preferences.getUChar("hopin", 0);
  config.hopOut = preferences.getUChar("hopout", 0);
  config.rxBurstGapMs =
      preferences.getUInt("rxgap", kDefaultRxBurstGapMs);
  config.protocolActive = preferences.getBool("active", false);
  observationTracker.configure(config.rxBurstGapMs);
  if (preferences.getBytesLength("packet") == kPayloadLength) {
    std::array<uint8_t, kPayloadLength> bytes{};
    preferences.getBytes("packet", bytes.data(), bytes.size());
    scheduler.hasPacket = decode(bytes.data(), bytes.size(), scheduler.packet);
    if (scheduler.hasPacket) scheduleNewState("STARTUP_RECOVERY");
  }
}

}  // namespace

void setup() {
  serialOutputMutex = xSemaphoreCreateMutex();
  receivedPackets = xQueueCreate(64, sizeof(ReceivedPacket));
  configASSERT(receivedPackets != nullptr);
  Serial.setRxBufferSize(kSerialRxBufferBytes);
  Serial.begin(115200);
  delay(300);
  randomSeed(esp_random());
  preferences.begin("resqmesh", false);
  NimBLEDevice::init("");
  NimBLEDevice::setPower(kRadioTxPowerDbm);
  radio.configure(preferences.getBool("s8required", false));
  scanner = NimBLEDevice::getScan();
  scanner->setScanCallbacks(new ScanCallbacks(), true);
  scanner->setPhy(NimBLEScan::SCAN_CODED);
  scanner->setActiveScan(false);
  scanner->setInterval(97);
  scanner->setWindow(67);
  scanner->start(0, false, false);
  loadPersistentState();
  emit("SERVICE_STARTED");
}

void loop() {
  while (Serial.available() > 0) {
    const char value = static_cast<char>(Serial.read());
    if (value == '\n') {
      serialBuffer.trim();
      if (!serialBuffer.isEmpty()) handleCommand(serialBuffer);
      serialBuffer = "";
    } else if (value != '\r') {
      serialBuffer += value;
    }
  }
  drainReceivedPackets();
  tickScheduler();
  delay(5);
}
