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
#include "NeighborTransport.h"
#include "NeighborStatusSchedule.h"
#include <set>

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
enum class Mode { Basic, TrickleNoSuppression, Trickle, NeighborStatus };

bool usesTrickle(Mode mode) { return mode != Mode::Basic; }
bool suppressionEnabled(Mode mode) { return mode == Mode::Trickle; }

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
  bool neighborProfile = false;
  std::array<uint32_t, 5> allowed{};
  uint8_t allowedCount = 0;
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
  bool opportunityEvaluated = false;
  bool advertising = false;
  bool statusAdvertising = false;
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
NeighborController neighbors;
NeighborStatusSchedule statusSchedule;
uint32_t incarnation = 0, transportSequence = 0, trialScope = 0, nextStatusAt = 0;
bool rxParticipation = true, txParticipation = true;
bool adaptiveStatus() { return config.mode==Mode::NeighborStatus && neighbors.parameters.adaptive(); }
uint32_t statusJitter() { return random(0,neighbors.parameters.jitter+1); }
bool allObservedHave(uint32_t now) {
  return scheduler.hasPacket && std::string(neighbors.decision(scheduler.packet,now,false))=="ALL_OBSERVED_HAVE";
}
void syncStatus(uint32_t now) {
  if(!adaptiveStatus()) return;
  statusSchedule.syncInventory(scheduler.hasPacket ? std::vector<std::string>{stateIdentity(scheduler.packet)} : std::vector<std::string>{},now,statusJitter());
  statusSchedule.stable(now,allObservedHave(now),statusJitter());
  nextStatusAt=statusSchedule.nextAt;
}
void restartStatus() {
  nextStatusAt=millis()+1000+statusJitter();
  if(adaptiveStatus()) {
    statusSchedule.parameters=neighbors.parameters;
    statusSchedule.start(millis(),statusJitter());
    syncStatus(millis());
  }
}
std::set<std::string> frameObservations;
NeighborFrame activeFrame;
const NeighborFrame* eventFrame = nullptr;
SemaphoreHandle_t serialOutputMutex = nullptr;

struct ReceivedPacket {
  bool envelope = false;
  NeighborFrame frame;
  Packet packet;
  int rssi;
  char advertiser[18];
  uint32_t receivedAt;
  uint32_t generation;
  uint8_t primaryPhy;
  uint8_t secondaryPhy;
  bool legacy;
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
  if (mode == Mode::NeighborStatus) return "trickle_neighbor_status";
  if (mode == Mode::TrickleNoSuppression) return "trickle_no_suppression";
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
          const uint32_t* physicalReceivedAt = nullptr,
          const String& observerKey = String()) {
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
  if(config.mode==Mode::NeighborStatus) {
    document["neighbor_status_policy"]=neighbors.parameters.policy;
    if(adaptiveStatus()) document["status_reason"]=statusSchedule.reason;
  }
  if (config.neighborProfile) {
    document["transport_profile"] = "neighbor_graph_v1";
    document["scope"] = trialScope;
    if (eventFrame != nullptr) {
      document["transmitter_id"] = eventFrame->transmitter;
      document["boot_id"] = eventFrame->boot;
      document["transmission_sequence"] = eventFrame->sequence;
      document["transport_burst_id"] = burstIdentity(*eventFrame);
      document["frame_type"] = eventFrame->status ? "status" : "data";
      document["inventory_count"] = eventFrame->count;
      document["snapshot_complete"] = eventFrame->complete;
    }
  }
  if (strncmp(eventType, "ADVERTISE_BURST_", 16) == 0 ||
      strncmp(eventType,"DATA_BURST_",11)==0 || strncmp(eventType,"STATUS_BURST_",13)==0 ||
      strcmp(eventType, "SERVICE_STARTED") == 0) {
    radio.telemetry(document["radio"].to<JsonObject>());
  }
  const uint32_t eventTime =
      physicalReceivedAt != nullptr ? *physicalReceivedAt : millis();
  document["monotonic_ms"] = eventTime;
  if(config.neighborProfile) document["clock_domain"]="esp_boot_millis";
  if(config.mode==Mode::NeighborStatus && scheduler.hasPacket && strncmp(eventType,"NEIGHBOR_",9)==0) {
    const auto counts=neighbors.counts(scheduler.packet,eventTime);
    document["have_count"]=counts.have;document["missing_count"]=counts.missing;
    document["unknown_count"]=counts.unknown;document["status_age_ms"]=counts.maxAge;
    auto knowledge=document["neighbor_knowledge"].to<JsonObject>();
    for(const auto id:neighbors.observedTransmitters()) {
      const auto value=neighbors.knowledge(id,scheduler.packet,eventTime);
      knowledge[String(id)]=value==Knowledge::Have ? "HAVE" : value==Knowledge::Missing ? "MISSING" : "UNKNOWN";
    }
  }
  if(config.neighborProfile && (strcmp(eventType,"SCANNER_RECOVERY_CHECK")==0 ||
      strcmp(eventType,"RX_PARTICIPATION_CHANGED")==0 || strcmp(eventType,"NODE_PARTICIPATION_CHANGED")==0)) {
    document["scanner_registered"]=scanner && scanner->isScanning();
    document["rx_enabled"]=rxParticipation;document["tx_enabled"]=txParticipation;
    if(strcmp(eventType,"SCANNER_RECOVERY_CHECK")==0) document["burst_outcome"]=reason;
  }
  if(strcmp(eventType,"INITIAL_FORWARD_FAILED")==0) document["first_forward_pending"]=!scheduler.firstAdvertiseStarted;
  if (wallClockValid) document["timestamp_ms"] = wallOffsetMs + eventTime;
  document["clock_sync_valid"] = wallClockValid;
  if (wallClockValid) document["clock_offset_ms"] = 0;
  if (reason != nullptr) document["reason"] = reason;
  if(config.neighborProfile && (strncmp(eventType,"RX_PARTICIPATION_",17)==0 || strncmp(eventType,"NODE_PARTICIPATION_",19)==0)) {
    document["rx_enabled"]=rxParticipation; document["tx_enabled"]=txParticipation;
    if(reason && (strcmp(reason,"ENABLE")==0 || strcmp(reason,"DISABLE")==0)) document["requested_enabled"]=strcmp(reason,"ENABLE")==0;
    else if(reason && strcmp(reason,"FAILED")!=0) document["confirmed_enabled"]=rxParticipation;
  }
  if (usesTrickle(config.mode) && scheduler.hasPacket &&
      (strncmp(eventType, "TRICKLE_", 8) == 0 ||
       strncmp(eventType, "ADVERTISE_BURST_", 16) == 0)) {
    document["interval_ms"] = scheduler.intervalMs;
    document["interval_started_at_monotonic_ms"] = scheduler.intervalStartedAt;
    document["transmit_at_monotonic_ms"] = scheduler.transmitAt;
    document["interval_end_at_monotonic_ms"] = scheduler.intervalEndAt;
    document["consistency_count"] = scheduler.consistencyCount;
    document["k"] = 1;
    document["suppression_enabled"] = suppressionEnabled(config.mode);
    if (strcmp(eventType, "TRICKLE_CONSISTENT_HEARD") == 0) {
      document["c_before"] = scheduler.consistencyCount - 1;
      document["c_after"] = scheduler.consistencyCount;
    }
  }
  if (!observationId.isEmpty()) document["observation_id"] = observationId;
  if (!observerKey.isEmpty()) document["observer_key"] = observerKey;
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
  if(command=="set_rx_participation" || command=="set_node_participation") {
    if(ok) document["confirmed_enabled"] = rxParticipation;
    else document["confirmed_enabled"] = nullptr;
    document["rx_enabled"] = rxParticipation;
    document["tx_enabled"] = txParticipation;
    document["native_monotonic_ms"] = millis();
    if(wallClockValid) document["timestamp_ms"] = wallTimeMs();
  }
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
  if (value == "trickle_neighbor_status") return Mode::NeighborStatus;
  if (value == "trickle_no_suppression") return Mode::TrickleNoSuppression;
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
  if (!rxParticipation) return;
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
  frameObservations.clear();
  neighbors.reset(0);
  preferences.remove("packet");
  observationTracker.clear();
}

void cancelActiveBurst(const char* reason) {
  if (!scheduler.advertising || advertising == nullptr) return;
  advertising->stop();
  resumeScanner();
  scheduler.advertising = false;
  eventFrame = config.neighborProfile ? &activeFrame : nullptr;
  emit(scheduler.statusAdvertising ? "STATUS_BURST_CANCELLED" : "ADVERTISE_BURST_CANCELLED", scheduler.statusAdvertising ? nullptr : &scheduler.packet, reason, 0, String(),
       scheduler.burstId);
  if(config.neighborProfile && !scheduler.statusAdvertising) emit("DATA_BURST_CANCELLED",&scheduler.packet,reason,0,String(),scheduler.burstId);
  if(config.neighborProfile) emit("SCANNER_RECOVERY_CHECK",nullptr,"CANCELLED");
  scheduler.statusAdvertising = false;
  eventFrame = nullptr;
  scheduler.burstId = "";
}

void chooseTrickleTransmit(uint32_t now, const char* reason) {
  scheduler.opportunityEvaluated = false;
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
  scheduler.firstAdvertiseStarted = false;
  if (config.mode==Mode::NeighborStatus) emit("INITIAL_FORWARD_PENDING",&scheduler.packet);
  const uint32_t now = millis();
  scheduler.intervalMs = kIminMs;
  if (usesTrickle(config.mode)) {
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
  if (config.neighborProfile) {
    emit("NODE_FIRST_VALID_RECEIVE", &incoming, nullptr, 0, String(), String(), receivedAt);
  }
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

void recordConsistent(const Packet& incoming, const String& observationId, const String& advertiser) {
  emit("BLE_PACKET_DUPLICATE", &incoming, "CONSISTENT", 0, observationId);
  if (shouldCountTrickleConsistency(
          usesTrickle(config.mode), config.role == Role::Relay, true, true,
          incoming.hop, config.expectedHopIn)) {
    scheduler.consistencyCount++;
    emit("TRICKLE_CONSISTENT_HEARD", &incoming, nullptr, 0, observationId, String(), nullptr, advertiser);
  }
}

void processPacket(const Packet& incoming, int rssi,
                   const String& advertiser, uint32_t now,
                   uint8_t primaryPhy, uint8_t secondaryPhy, bool legacy) {
  const ObservationDecision decision = observationTracker.observe(
      config.nodeId.c_str(), advertiser.c_str(), stateIdentity(incoming), now);
  if (!decision.isNew) return;
  const String observation(decision.observationId.c_str());
  emit("BLE_PACKET_RECEIVED", &incoming, nullptr, rssi, observation,
       String(), &now);
  JsonDocument phy;
  phy["kind"] = "event";
  phy["event_type"] = "BLE_RX_PHY_OBSERVED";
  phy["event_sequence"] = ++eventSequence;
  phy["node_id"] = config.nodeId;
  phy["session_id"] = config.sessionId;
  phy["trial_id"] = config.trialId;
  phy["mode"] = modeName(config.mode);
  phy["observation_id"] = observation;
  phy["message_key"] = messageKey(incoming);
  phy["timestamp_ms"] = wallOffsetMs + now;
  phy["monotonic_ms"] = now;
  phy["clock_sync_valid"] = wallClockValid;
  phy["clock_offset_ms"] = 0;
  phy["primary_phy"] = primaryPhy;
  phy["secondary_phy"] = secondaryPhy;
  phy["legacy"] = legacy;
  phy["coding"] = "unknown";
  xSemaphoreTake(serialOutputMutex, portMAX_DELAY);
  serializeJson(phy, Serial);
  Serial.println();
  xSemaphoreGive(serialOutputMutex);

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
      recordConsistent(incoming, observation, advertiser);
      return;
    }
    if (usesTrickle(config.mode)) {
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
    const auto* raw = reinterpret_cast<const uint8_t*>(data.data());
    const size_t skip = data.size()>=2 && raw[0]==0xff && raw[1]==0xff ? 2 : 0;
    NeighborFrame frame;
    const bool isEnvelope = data.size()>skip+1 && raw[skip]==0x52 && raw[skip+1]==0x4e;
    std::array<uint8_t, kPayloadLength> payload{};
    if (!isEnvelope && !extractApplicationPayload(
            reinterpret_cast<const uint8_t*>(data.data()), data.size(),
            payload)) {
      return;
    }
    Packet packet;
    if (isEnvelope) {
      if (!decodeFrame(raw+skip,data.size()-skip,frame)) return;
      packet=frame.packet;
    } else if (!decode(payload.data(), payload.size(), packet)) return;
    ReceivedPacket received{};
    received.envelope = isEnvelope;
    received.frame = frame;
    received.packet = packet;
    received.rssi = device->getRSSI();
    received.receivedAt = receivedAt;
    received.generation = generation;
    received.primaryPhy = device->getPrimaryPhy();
    received.secondaryPhy = device->getSecondaryPhy();
    received.legacy = device->isLegacyAdvertisement();
    const std::string address = device->getAddress().toString();
    snprintf(received.advertiser, sizeof(received.advertiser), "%s", address.c_str());
    // The NimBLE task never reads or mutates scheduler/configuration state.
    if (xQueueSend(receivedPackets, &received, 0) != pdTRUE) {
      receiveOverflow.fetch_add(1);
    }
  }
};

void processFrame(const ReceivedPacket& rx) {
  const auto& f=rx.frame;
  if (!config.neighborProfile || !config.protocolActive || !rxParticipation || f.scope!=trialScope || !due(rx.receivedAt,quietUntil)) return;
  bool allowed=false;
  for(size_t i=0;i<config.allowedCount;++i) allowed=allowed || config.allowed[i]==f.transmitter;
  if (!allowed) return;
  if(!wallClockValid || !frameTimeValid(f,wallTimeMs()/1000)) return;
  if(!f.status && f.packet.kind==PacketKind::Ack) return;
  const auto identity=burstIdentity(f);
  if (!frameObservations.insert(identity).second) return;
  if (frameObservations.size()>4096) { emit("EXPERIMENT_CONFIG_VIOLATION",nullptr,"FRAME_OBSERVATION_CAPACITY"); return; }
  eventFrame=&f;
  const String observation=(config.nodeId+"|"+String(identity.c_str()));
  const uint32_t at=rx.receivedAt;
  const bool discovered=!neighbors.known(f.transmitter);
  if (config.mode==Mode::NeighborStatus && neighbors.observe(f,at,millis())) {
    if(adaptiveStatus() && neighbors.peerChanged) statusSchedule.peerChanged(millis(),statusJitter());
    if(f.status && scheduler.hasPacket) neighbors.requestMissingPeer(f.transmitter,scheduler.packet,millis());
    if(discovered) emit("NEIGHBOR_DISCOVERED",f.status ? nullptr : &f.packet,nullptr,rx.rssi,observation,String(),&at);
    emit("NEIGHBOR_STATUS_UPDATED",f.status ? nullptr : &f.packet,nullptr,rx.rssi,observation,String(),&at);
    if(scheduler.hasPacket && neighbors.repairAllowed(scheduler.packet,millis(),scheduler.intervalMs,kIminMs)) {
      scheduler.intervalMs=kIminMs;
      chooseTrickleTransmit(millis(),"NEIGHBOR_REPAIR");
      emit("REPAIR_NEEDED",&scheduler.packet,"NEW_NEIGHBOR_OR_CHANGED_SNAPSHOT");
    }
    if(neighbors.takeRepairDeferred()) emit("REPAIR_DEFERRED_COOLDOWN",scheduler.hasPacket ? &scheduler.packet : nullptr,"RESET_COOLDOWN");
  }
  if (f.status) {
    emit("STATUS_RECEIVED",nullptr,nullptr,rx.rssi,observation,String(),&at);
    eventFrame=nullptr; return;
  }
  const auto& p=f.packet;
  // Completion ACK is disabled in the graph research profile.
  if (p.kind==PacketKind::Ack) { eventFrame=nullptr; return; }
  bool stale=false;
  if(scheduler.hasPacket && p.senderCrc==scheduler.packet.senderCrc) {
    const auto a=inventoryState(p), b=inventoryState(scheduler.packet);
    auto priority=[](uint8_t s){return s==1 ? 0 : s==0 ? 1 : 2;};
    stale=p.timestampSeconds<scheduler.packet.timestampSeconds || (a.seconds==b.seconds && priority(a.flags & 63)<priority(b.flags & 63));
  }
  if (stale) { emit("BLE_PACKET_STALE",&p); eventFrame=nullptr; return; }
  emit("DATA_RECEIVED",&p,nullptr,rx.rssi,observation,String(),&at);
  emit("BLE_PACKET_RECEIVED",&p,nullptr,rx.rssi,observation,String(),&at);
  JsonDocument phy;
  phy["kind"]="event"; phy["event_type"]="BLE_RX_PHY_OBSERVED"; phy["event_sequence"]=++eventSequence;
  phy["node_id"]=config.nodeId; phy["session_id"]=config.sessionId; phy["trial_id"]=config.trialId;
  phy["observation_id"]=observation; phy["timestamp_ms"]=wallOffsetMs+at;
  phy["primary_phy"]=rx.primaryPhy; phy["secondary_phy"]=rx.secondaryPhy; phy["legacy"]=rx.legacy; phy["coding"]="unknown";
  xSemaphoreTake(serialOutputMutex,portMAX_DELAY); serializeJson(phy,Serial); Serial.println(); xSemaphoreGive(serialOutputMutex);
  const bool same=scheduler.hasPacket && stateIdentity(p)==stateIdentity(scheduler.packet);
  if(same) {
    emit("BLE_PACKET_DUPLICATE",&p,nullptr,rx.rssi,observation);
    if(usesTrickle(config.mode) && f.transmitter!=p.senderCrc && !due(at,scheduler.intervalEndAt) && due(at,scheduler.intervalStartedAt)) {
      scheduler.consistencyCount++;
      emit("TRICKLE_CONSISTENT_HEARD",&p,nullptr,0,observation);
    }
  } else if(config.role!=Role::Source) storeForRelay(p,"GRAPH_NEW_STATE",&at);
  eventFrame=nullptr;
}

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
    if(received.envelope) { processFrame(received); continue; }
    if(config.neighborProfile) continue;
    processPacket(received.packet, received.rssi, String(received.advertiser),
                  received.receivedAt, received.primaryPhy, received.secondaryPhy, received.legacy);
  }
}

void startBurst() {
  if (!scheduler.hasPacket || advertising == nullptr) return;
  // Recheck after scheduler logging; its serial output can cross an interval end.
  if (usesTrickle(config.mode) &&
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
  std::vector<uint8_t> framed;
  if(config.neighborProfile) {
    activeFrame=NeighborFrame{}; activeFrame.packet=scheduler.packet;
    activeFrame.transmitter=crc32(config.nodeId.c_str());
    const uint32_t oldBoot=incarnation;
    if(!advanceBurstIdentity(incarnation,transportSequence) || (oldBoot!=incarnation && preferences.putUInt("incarnation",incarnation)!=sizeof(uint32_t))) {
      txParticipation=false;emit("EXPERIMENT_CONFIG_VIOLATION",nullptr,"INCARNATION_PERSISTENCE_FAILED_OR_EXHAUSTED");return;
    }
    activeFrame.boot=incarnation;
    activeFrame.sequence=transportSequence; activeFrame.scope=trialScope;
    if(!encodeFrame(activeFrame,framed)) return;
    scheduler.burstId=String(burstIdentity(activeFrame).c_str());
    eventFrame=&activeFrame;
  }
  emit("ADVERTISE_BURST_REQUESTED", &scheduler.packet, nullptr, 0, String(), scheduler.burstId);
  if(config.neighborProfile) emit("DATA_BURST_REQUESTED",&scheduler.packet,nullptr,0,String(),scheduler.burstId);

  if (!pauseScanner()) {
    scheduler.transmitAt = millis() + kNativeStartRetryMs;
    emit("ADVERTISE_BURST_FAILED", &scheduler.packet, "SCAN_STOP_FAILED", 0,
         String(), scheduler.burstId);
    if(config.neighborProfile) emit("DATA_BURST_FAILED",&scheduler.packet,"SCAN_STOP_FAILED",0,String(),scheduler.burstId);
    if(config.mode==Mode::NeighborStatus && !scheduler.firstAdvertiseStarted) emit("INITIAL_FORWARD_FAILED",&scheduler.packet,"SCAN_STOP_FAILED");
    if(config.neighborProfile) emit("SCANNER_RECOVERY_CHECK",nullptr,"FAILED");
    scheduler.burstId = "";
    eventFrame=nullptr;
    return;
  }
  if (!(config.neighborProfile ? advertising->start(framed.data(),framed.size()) : advertising->start(payload))) {
    resumeScanner();
    scheduler.transmitAt = millis() + kNativeStartRetryMs;
    emit("ADVERTISE_BURST_FAILED", &scheduler.packet, "NATIVE_START_FAILED",
         0, String(), scheduler.burstId);
    if(config.neighborProfile) emit("DATA_BURST_FAILED",&scheduler.packet,"NATIVE_START_FAILED",0,String(),scheduler.burstId);
    if(config.mode==Mode::NeighborStatus && !scheduler.firstAdvertiseStarted) emit("INITIAL_FORWARD_FAILED",&scheduler.packet,"NATIVE_START_FAILED");
    if(config.neighborProfile) emit("SCANNER_RECOVERY_CHECK",nullptr,"FAILED");
    scheduler.burstId = "";
    eventFrame=nullptr;
    return;
  }
  scheduler.advertising = true;
  const uint32_t succeededAt = millis();
  scheduler.burstEndsAt = succeededAt + kBurstMs;
  emit("ADVERTISE_BURST_STARTED", &scheduler.packet, nullptr, 0, String(),
       scheduler.burstId, &succeededAt);
  if(config.neighborProfile) emit("DATA_BURST_STARTED",&scheduler.packet,nullptr,0,String(),scheduler.burstId,&succeededAt);
  if(config.mode==Mode::NeighborStatus && !scheduler.firstAdvertiseStarted) emit("INITIAL_FORWARD_STARTED",&scheduler.packet);
  if (!scheduler.firstAdvertiseStarted && config.role == Role::Source) {
    scheduler.firstAdvertiseStartedAtMs = wallOffsetMs + succeededAt;
    emit("SOURCE_FIRST_ADVERTISE_STARTED", &scheduler.packet, nullptr, 0,
         String(), scheduler.burstId, &succeededAt);
  }
  scheduler.firstAdvertiseStarted = true;
  if(adaptiveStatus()) {
    syncStatus(succeededAt);
    if(statusSchedule.dataSucceeded(stateIdentity(scheduler.packet),succeededAt,allObservedHave(succeededAt),statusJitter())) {
      emit("STATUS_COALESCED_WITH_DATA",&scheduler.packet,"DATA_STARTED");
    }
    nextStatusAt=statusSchedule.nextAt;
  }
  emit("BLE_RELAY_STARTED", &scheduler.packet, nullptr, 0, String(),
       scheduler.burstId);
  eventFrame=nullptr;
}

void finishBurst() {
  advertising->stop();
  resumeScanner();
  scheduler.advertising = false;
  if(scheduler.statusAdvertising) {
    scheduler.statusAdvertising=false;
    eventFrame=&activeFrame;
    emit("STATUS_BURST_ENDED",nullptr,nullptr,0,String(),scheduler.burstId);
    emit("SCANNER_RECOVERY_CHECK",nullptr,"ENDED");
    eventFrame=nullptr;
    scheduler.burstId="";
    return;
  }
  emit("ADVERTISE_BURST_ENDED", &scheduler.packet, nullptr, 0, String(),
       scheduler.burstId);
  if(config.neighborProfile) {
    eventFrame=&activeFrame;
    emit("DATA_BURST_ENDED",&scheduler.packet,"TARGET_DURATION_REACHED",0,String(),scheduler.burstId);
    emit("SCANNER_RECOVERY_CHECK",nullptr,"ENDED");
    eventFrame=nullptr;
  }
  const uint32_t now = millis();
  if (config.mode == Mode::Basic) {
    scheduler.transmitAt = now + kBasicIntervalMs + random(300, 1501);
  } else {
    scheduler.waitingIntervalEnd = true;
    scheduler.transmitAt = scheduler.intervalEndAt;
  }
  scheduler.burstId = "";
}

void startStatusBurst() {
  activeFrame=NeighborFrame{}; activeFrame.status=true;
  activeFrame.transmitter=crc32(config.nodeId.c_str());
  const uint32_t oldBoot=incarnation;
  if(!advanceBurstIdentity(incarnation,transportSequence) || (oldBoot!=incarnation && preferences.putUInt("incarnation",incarnation)!=sizeof(uint32_t))) {
    txParticipation=false;emit("EXPERIMENT_CONFIG_VIOLATION",nullptr,"INCARNATION_PERSISTENCE_FAILED_OR_EXHAUSTED");return;
  }
  activeFrame.boot=incarnation;
  activeFrame.sequence=transportSequence; activeFrame.scope=trialScope;
  if(scheduler.hasPacket) { activeFrame.count=1; activeFrame.inventory[0]=inventoryState(scheduler.packet); }
  std::vector<uint8_t> bytes;
  const auto& params=neighbors.parameters;
  const auto inventory=statusSchedule.inventory;
  const char* statusReason=adaptiveStatus() ? statusSchedule.reason : "PERIODIC";
  if(!adaptiveStatus()) nextStatusAt=millis()+params.statusPeriod+random(0,params.jitter+1);
  if(!encodeFrame(activeFrame,bytes)) return;
  eventFrame=&activeFrame;
  scheduler.burstId=String(burstIdentity(activeFrame).c_str());
  emit("STATUS_BURST_REQUESTED",nullptr,statusReason,0,String(),scheduler.burstId);
  if(!pauseScanner() || !advertising->start(bytes.data(),bytes.size())) {
    if(adaptiveStatus()) { statusSchedule.failed(millis(),statusJitter());nextStatusAt=statusSchedule.nextAt; }
    resumeScanner(); emit("STATUS_BURST_FAILED",nullptr,"NATIVE_START_FAILED"); emit("SCANNER_RECOVERY_CHECK",nullptr,"FAILED"); eventFrame=nullptr; return;
  }
  scheduler.advertising=true; scheduler.statusAdvertising=true;
  const uint32_t now=millis(); scheduler.burstEndsAt=now+params.statusBurst;
  emit("STATUS_BURST_STARTED",nullptr,statusReason,0,String(),scheduler.burstId,&now);
  if(adaptiveStatus()) { statusSchedule.statusSucceeded(inventory,now,allObservedHave(now),statusJitter());nextStatusAt=statusSchedule.nextAt; }
  eventFrame=nullptr;
}

void tickScheduler() {
  if (!observationWindowOpen || !txParticipation ||
      config.role == Role::Destination ||
      config.role == Role::Observer || !config.protocolActive) {
    return;
  }
  const uint32_t now = millis();
  syncStatus(now);
  if(config.mode==Mode::NeighborStatus) for(const auto& expired:neighbors.newlyExpired(now)) {
    eventFrame=&expired;emit("NEIGHBOR_STATUS_EXPIRED",nullptr,"FRESHNESS_ELAPSED");eventFrame=nullptr;
  }
  if (scheduler.advertising) {
    if (due(now, scheduler.burstEndsAt)) finishBurst();
    return;
  }
  // Never occupy set 0 across an imminent DATA opportunity. Empty inventory still discovers peers.
  if(config.mode==Mode::NeighborStatus && due(now,nextStatusAt) &&
     (!scheduler.hasPacket || (scheduler.waitingIntervalEnd && !due(now,scheduler.intervalEndAt)) ||
      (!due(now,scheduler.transmitAt) && scheduler.transmitAt-now>neighbors.parameters.statusBurst+250))) {
    startStatusBurst(); return;
  }
  if(!scheduler.hasPacket) return;
  if (usesTrickle(config.mode) && due(now, scheduler.intervalEndAt)) {
    if (trickleOpportunityMissed(now, scheduler.intervalStartedAt,
                                scheduler.intervalMs, scheduler.opportunityEvaluated)) {
      scheduler.opportunityEvaluated = true;
      emit("TRICKLE_TX_MISSED", &scheduler.packet, "SCHEDULER_LATE", 0,
           String(), String(), &now);
    }
    scheduler.intervalMs = min(scheduler.intervalMs * 2, kImaxMs);
    chooseTrickleTransmit(now, "INTERVAL_ADVANCED");
    return;
  }
  if (!due(now, scheduler.transmitAt)) return;
  if (usesTrickle(config.mode) &&
      (scheduler.waitingIntervalEnd ||
       !trickleTransmitDue(now, scheduler.intervalStartedAt,
                           scheduler.intervalMs, scheduler.transmitAt))) {
    return;
  }
  const char* neighborReason=config.mode==Mode::NeighborStatus ? neighbors.decision(scheduler.packet,now,!scheduler.firstAdvertiseStarted) : nullptr;
  if (usesTrickle(config.mode) && !scheduler.opportunityEvaluated) {
    scheduler.opportunityEvaluated = true;
    emit("TRICKLE_TX_OPPORTUNITY", &scheduler.packet,
         (neighborReason ? strcmp(neighborReason,"ALL_OBSERVED_HAVE")!=0 : trickleAllowsTransmission(suppressionEnabled(config.mode), scheduler.consistencyCount, 1))
             ? "ALLOWED" : "SUPPRESSED");
  }
  if(neighborReason) emit(strcmp(neighborReason,"ALL_OBSERVED_HAVE")==0 ? "NEIGHBOR_TX_SUPPRESSED" : "NEIGHBOR_TX_ALLOWED",&scheduler.packet,neighborReason);
  if (usesTrickle(config.mode) &&
      (neighborReason ? strcmp(neighborReason,"ALL_OBSERVED_HAVE")==0 : !trickleAllowsTransmission(suppressionEnabled(config.mode), scheduler.consistencyCount, 1))) {
    emit("TRICKLE_TX_SUPPRESSED", &scheduler.packet, neighborReason ? neighborReason : "C_GE_K");
    scheduler.waitingIntervalEnd = true;
    scheduler.transmitAt = scheduler.intervalEndAt;
    return;
  }
  if (usesTrickle(config.mode)) {
    emit("TRICKLE_TX_ALLOWED", &scheduler.packet,
         neighborReason ? neighborReason : suppressionEnabled(config.mode) ? "C_LT_K" : "SUPPRESSION_DISABLED");
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
  document["transport_profile"] = config.neighborProfile ? "neighbor_graph_v1" : "legacy";
  document["transport_version"] = config.neighborProfile ? kNeighborProtocol : kProtocolVersion;
  document["data_frame_length"] = config.neighborProfile ? 39 : 17;
  document["neighbor_design_version"] = 1;
  if(config.neighborProfile) {
    document["transmitter_id"]=crc32(config.nodeId.c_str());
    document["scope"]=trialScope;
    auto allowed=document["allowed_transmitters"].to<JsonArray>();
    for(size_t i=0;i<config.allowedCount;++i) allowed.add(config.allowed[i]);
    auto params=document["neighbor_parameters"].to<JsonObject>();
    params["status_period_ms"]=neighbors.parameters.statusPeriod;
    params["status_burst_ms"]=neighbors.parameters.statusBurst;
    params["freshness_ms"]=neighbors.parameters.freshness;
    params["neighbor_status_policy"]=neighbors.parameters.policy;
    if(neighbors.parameters.adaptive()) {
      params["status_min_period_ms"]=neighbors.parameters.statusMinPeriod;
      params["empty_retry_min_ms"]=neighbors.parameters.emptyRetryMin;
      params["empty_retry_max_ms"]=neighbors.parameters.emptyRetryMax;
      params["data_grace_ms"]=neighbors.parameters.dataGrace;
    }
    params["discovery_jitter_ms"]=neighbors.parameters.jitter;
    params["reset_cooldown_ms"]=neighbors.parameters.resetCooldown;
    params["neighbor_capacity"]=neighbors.parameters.capacity;
  }
  document["rx_participation"] = rxParticipation;
  document["tx_participation"] = txParticipation;
  document["measurement_timing_version"] = 2;
  document["method_design_version"] = 3;
  document["suppression_enabled"] = suppressionEnabled(config.mode);
  document["supported_modes"] = "basic_flooding,trickle_no_suppression,trickle,trickle_neighbor_status";
  document["trickle_imin_ms"] = kIminMs;
  document["trickle_imax_ms"] = kImaxMs;
  document["trickle_k"] = 1;
  document["burst_duration_ms"] = kBurstMs;
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

NeighborParameters readNeighborParameters(JsonDocument& document) {
  NeighborParameters p;
  p.policy=document["neighbor_status_policy"] | "periodic_v1";
  p.statusPeriod=document["status_period_ms"] | (p.adaptive() ? 60000 : 12000);
  p.freshness=document["freshness_ms"] | (p.adaptive() ? 150000 : 45000);
  p.statusBurst=document["status_burst_ms"] | 500;
  p.jitter=document["discovery_jitter_ms"] | 1500;
  p.resetCooldown=document["reset_cooldown_ms"] | 8000;
  p.capacity=document["neighbor_capacity"] | 16;
  p.statusMinPeriod=document["status_min_period_ms"] | 15000;
  p.emptyRetryMin=document["empty_retry_min_ms"] | 4000;
  p.emptyRetryMax=document["empty_retry_max_ms"] | 32000;
  p.dataGrace=document["data_grace_ms"] | 10000;
  return p;
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
    if(config.neighborProfile && !config.trialId.isEmpty() && preferences.getBool("nwindow",false)) {
      observationWindowOpen=true;receiveEnabled.store(rxParticipation);
      resumeScanner();
      restartStatus();
    }
    respond(command, commandId, true);
    return;
  }
  if (command == "readiness" || command == "get_status") {
    emitReadiness(commandId);
    return;
  }
  if (command == "configure_session") {
    if (observationWindowOpen) { respond(command,commandId,false,"TRIAL_RUNNING"); return; }
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
        requestedMode != "basic_flooding" && requestedMode != "trickle_no_suppression" && requestedMode != "trickle_neighbor_status") {
      respond(command, commandId, false, "INVALID_MODE");
      return;
    }
    const uint32_t requestedRxBurstGapMs =
        document["rx_burst_gap_ms"] | 0;
    if (requestedRxBurstGapMs == 0) {
      respond(command, commandId, false, "INVALID_rx_burst_gap_ms");
      return;
    }
    const String requestedProfile=document["transport_profile"] | "legacy";
    if(requestedProfile!="legacy" && requestedProfile!="neighbor_graph_v1") { respond(command,commandId,false,"UNSUPPORTED_TRANSPORT_PROFILE");return; }
    if(requestedMode=="trickle_neighbor_status" && requestedProfile!="neighbor_graph_v1") { respond(command,commandId,false,"NEIGHBOR_PROFILE_REQUIRED");return; }
    if(requestedProfile=="neighbor_graph_v1") {
      const String node=document["node_id"] | "";
      const auto ids=document["allowed_transmitters"].as<JsonArray>();
      std::set<uint32_t> unique;
      if(node.isEmpty() || ids.isNull() || ids.size()==0 || ids.size()>5 || (requestedRole!="SOURCE" && requestedRole!="RELAY")) { respond(command,commandId,false,"INVALID_GRAPH");return; }
      for(JsonVariant value:ids) {
        const uint32_t id=value.as<uint32_t>();
        if(!value.is<uint32_t>() || id==0 || id==crc32(node.c_str()) || !unique.insert(id).second) { respond(command,commandId,false,"INVALID_TRANSMITTER");return; }
      }
      const auto candidate=readNeighborParameters(document);
      if(!candidate.valid() || document["discovery_jitter_ms"].as<int64_t>()<0) { respond(command,commandId,false,"INVALID_NEIGHBOR_PARAMETERS");return; }
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
    const String profile=document["transport_profile"] | "legacy";
    config.neighborProfile=profile=="neighbor_graph_v1";
    if(requestedMode=="trickle_neighbor_status" && !config.neighborProfile) { respond(command,commandId,false,"NEIGHBOR_PROFILE_REQUIRED"); return; }
    config.allowedCount=0;
    if(config.neighborProfile) {
      const auto allowed=document["allowed_transmitters"].as<JsonArray>();
      if(allowed.isNull() || allowed.size()>5) { respond(command,commandId,false,"INVALID_GRAPH"); return; }
      for(JsonVariant value:allowed) {
        const uint32_t id=value.as<uint32_t>();
        if(!id || id==crc32(config.nodeId.c_str())) { respond(command,commandId,false,"INVALID_TRANSMITTER"); return; }
        config.allowed[config.allowedCount++]=id;
      }
      auto& p=neighbors.parameters;
      p=readNeighborParameters(document);
      if(!p.valid()) { respond(command,commandId,false,"INVALID_NEIGHBOR_PARAMETERS"); return; }
      std::string serialized; serializeJson(document["allowed_transmitters"],serialized);
      preferences.putString("adjacency",serialized.c_str());
      preferences.putUInt("nperiod",p.statusPeriod); preferences.putUInt("nburst",p.statusBurst);
      preferences.putUInt("nfresh",p.freshness); preferences.putUInt("njitter",p.jitter);
      preferences.putUInt("ncool",p.resetCooldown); preferences.putUInt("ncap",p.capacity);
      preferences.putString("npolicy",p.policy.c_str());
      preferences.putUInt("nmin",p.statusMinPeriod);preferences.putUInt("nemin",p.emptyRetryMin);
      preferences.putUInt("nemax",p.emptyRetryMax);preferences.putUInt("ngrace",p.dataGrace);
    }
    preferences.putBool("ngraph",config.neighborProfile);
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
    trialScope=crc32(config.trialId.c_str());
    neighbors.reset(trialScope);
    rxParticipation=txParticipation=true;
    if(config.neighborProfile) { preferences.putBool("nrx",true);preferences.putBool("ntx",true); }
    resumeScanner();
    restartStatus();
    observationWindowOpen = true;
    if(config.neighborProfile) preferences.putBool("nwindow",true);
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
      if(config.neighborProfile) preferences.putBool("nwindow",false);
      receiveGeneration.fetch_add(1);
      emit("TRIAL_WINDOW_ENDED");
    }
    respond(command, commandId, true);
    return;
  }
  if(command=="set_rx_participation" || command=="set_node_participation") {
    const bool enabled=document["enabled"] | false;
    emit(command=="set_rx_participation" ? "RX_PARTICIPATION_REQUESTED" : "NODE_PARTICIPATION_REQUESTED",nullptr,enabled ? "ENABLE" : "DISABLE");
    rxParticipation=enabled;
    if(config.neighborProfile) preferences.putBool("nrx",enabled);
    bool confirmed=true;
    if(command=="set_node_participation") { txParticipation=enabled; if(config.neighborProfile) preferences.putBool("ntx",enabled); if(!enabled) cancelActiveBurst("PARTICIPATION_DISABLED"); }
    if(enabled) { resumeScanner(); confirmed=scanner && scanner->isScanning(); if(confirmed && adaptiveStatus()) restartStatus(); }
    else confirmed=pauseScanner();
    receiveEnabled.store(enabled && observationWindowOpen);
    emit(command=="set_rx_participation" ? "RX_PARTICIPATION_CHANGED" : "NODE_PARTICIPATION_CHANGED",nullptr,confirmed ? (enabled ? "ENABLED_CONFIRMED" : "DISABLED_CONFIRMED") : "FAILED");
    respond(command,commandId,confirmed,confirmed ? nullptr : "PARTICIPATION_NOT_CONFIRMED");
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
    if(config.neighborProfile) preferences.putBool("nwindow",false);
    clearProtocolState();
    rxParticipation=txParticipation=true;
    if(config.neighborProfile) { preferences.putBool("nrx",true);preferences.putBool("ntx",true); }
    resumeScanner();
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
  incarnation=preferences.getUInt("incarnation",0)+1;
  if(incarnation==0) { emit("EXPERIMENT_CONFIG_VIOLATION",nullptr,"INCARNATION_EXHAUSTED"); return; }
  if(preferences.putUInt("incarnation",incarnation)!=sizeof(uint32_t)) {
    incarnation=0;txParticipation=false;emit("EXPERIMENT_CONFIG_VIOLATION",nullptr,"INCARNATION_PERSISTENCE_FAILED");return;
  }
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
  config.neighborProfile=preferences.getBool("ngraph",false);
  if(config.neighborProfile) {
    JsonDocument adjacency; deserializeJson(adjacency,preferences.getString("adjacency","[]"));
    for(JsonVariant value:adjacency.as<JsonArray>()) if(config.allowedCount<5) config.allowed[config.allowedCount++]=value.as<uint32_t>();
    auto& p=neighbors.parameters;
    p.policy=preferences.getString("npolicy","periodic_v1").c_str();
    p.statusMinPeriod=preferences.getUInt("nmin",15000);p.emptyRetryMin=preferences.getUInt("nemin",4000);
    p.emptyRetryMax=preferences.getUInt("nemax",32000);p.dataGrace=preferences.getUInt("ngrace",10000);
    p.statusPeriod=preferences.getUInt("nperiod",12000); p.statusBurst=preferences.getUInt("nburst",500);
    p.freshness=preferences.getUInt("nfresh",45000); p.jitter=preferences.getUInt("njitter",1500);
    p.resetCooldown=preferences.getUInt("ncool",8000); p.capacity=preferences.getUInt("ncap",16);
    trialScope=crc32(config.trialId.c_str()); neighbors.reset(trialScope);
    rxParticipation=preferences.getBool("nrx",true);txParticipation=preferences.getBool("ntx",true);
    if(!rxParticipation) pauseScanner();
  }
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
