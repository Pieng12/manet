import 'dart:convert';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/experiment_event.dart';
import 'package:pkmproject/models/experiment_metrics.dart';
import 'package:pkmproject/models/experiment_trial.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/research_session_service.dart';

class ResearchMetricsService {
  ResearchMetricsService({
    ExperimentLogger? logger,
    ResearchSessionService? researchSessionService,
  }) : _logger = logger ?? ExperimentLogger(),
       _researchSessionService =
           researchSessionService ?? ResearchSessionService();

  final ExperimentLogger _logger;
  final ResearchSessionService _researchSessionService;

  Future<ExperimentMetrics> loadMetrics({
    required String sessionId,
    String? trialId,
  }) async {
    final events = await _logger.events(sessionId: sessionId, trialId: trialId);
    final trials = trialId == null
        ? await _researchSessionService.trialsForSession(sessionId)
        : <ExperimentTrial>[];
    return calculate(events: events, trials: trials);
  }

  ExperimentMetrics calculate({
    required List<ExperimentEvent> events,
    required List<ExperimentTrial> trials,
  }) {
    final validCompletedTrials = trials
        .where((trial) => trial.result == 'SUCCESS' || trial.result == 'FAILED')
        .length;
    final successfulTrials = trials
        .where((trial) => trial.result == 'SUCCESS')
        .length;
    final accepted = _count(events, {ExperimentEventTypes.blePacketAccepted});
    final duplicates = _count(events, {
      ExperimentEventTypes.blePacketDuplicate,
    });
    final stale = _count(events, {ExperimentEventTypes.blePacketStale});
    final invalid = events.where(_isInvalidEvent).length;
    final ackSuppressed = events.where((event) {
      final detail = _detail(event);
      return detail['reason'] == 'ACK_TOMBSTONE_SUPPRESSED';
    }).length;
    final ackReceived = _count(events, {ExperimentEventTypes.ackReceived});
    final ackAccepted = _count(events, {
      ExperimentEventTypes.ackTransactionCommitted,
      ExperimentEventTypes.ackReplacedNewerTimestamp,
      ExperimentEventTypes.ackReplacedHigherStatus,
    });
    final ackDuplicate = _count(events, {ExperimentEventTypes.ackDuplicate});
    final ackStale = _count(events, {ExperimentEventTypes.ackRejectedOlder});
    final ackInvalid = events.where((event) {
      if (event.eventType == ExperimentEventTypes.ackRejectedFuture) {
        return true;
      }
      if (event.eventType != ExperimentEventTypes.bleRelayDropped) {
        return false;
      }
      final reason = _detail(event)['reason'];
      return reason == 'ACK_ACTIVE_REJECTED' ||
          reason == 'rejectedInvalid' ||
          reason == 'rejectedFuture';
    }).length;
    final txAttempts = _count(events, {
      ExperimentEventTypes.bleAdvertiseRequested,
    });
    final txSuccess = _count(events, {
      ExperimentEventTypes.bleAdvertiseStarted,
    });
    final relaySlots = _count(events, {ExperimentEventTypes.bleRelayStarted});
    final rssiSamples = events
        .where(
          (event) =>
              event.eventType == ExperimentEventTypes.blePacketReceived &&
              event.rssi != null,
        )
        .map((event) => event.rssi!)
        .toList();
    final hopInSamples = events
        .where(
          (event) =>
              event.eventType == ExperimentEventTypes.blePacketReceived &&
              event.hopIn != null,
        )
        .map((event) => event.hopIn!)
        .toList();
    final hopOutSamples = events
        .where(
          (event) =>
              event.eventType == ExperimentEventTypes.bleRelayStarted &&
              event.hopOut != null,
        )
        .map((event) => event.hopOut!)
        .toList();
    final localRelayLatencies = initialRelayLatencySamples(events);
    final e2eLatencies = endToEndLatencySamples(events);
    final ackTerminationLatencies = localLatencySamples(
      events,
      startType: ExperimentEventTypes.ackReceived,
      endType: ExperimentEventTypes.sosRelayTerminatedByAck,
    );
    final duplicateDenominator = accepted + duplicates;
    final latestHopValidation = latestHopValidationFromEvents(events);

    return ExperimentMetrics(
      successfulTrials: successfulTrials,
      validCompletedTrials: validCompletedTrials,
      dsrPercent: validCompletedTrials == 0
          ? null
          : successfulTrials / validCompletedTrials * 100,
      acceptedCount: accepted,
      duplicateCount: duplicates,
      staleCount: stale,
      invalidCount: invalid,
      ackSuppressedCount: ackSuppressed,
      duplicateRatioPercent: duplicateDenominator == 0
          ? null
          : duplicates / duplicateDenominator * 100,
      ackReceivedCount: ackReceived,
      ackAcceptedCount: ackAccepted,
      ackDuplicateCount: ackDuplicate,
      ackStaleCount: ackStale,
      ackInvalidCount: ackInvalid,
      txAttemptCount: txAttempts,
      txSuccessCount: txSuccess,
      relaySlotCount: relaySlots,
      transmissionOverhead: successfulTrials == 0
          ? null
          : txSuccess / successfulTrials,
      rssiStats: NumericStats.fromSamples(rssiSamples),
      hopInStats: NumericStats.fromSamples(hopInSamples),
      hopOutStats: NumericStats.fromSamples(hopOutSamples),
      localRelayLatencyMs: NumericStats.fromSamples(localRelayLatencies),
      e2eLatencyMs: NumericStats.fromSamples(e2eLatencies),
      ackTerminationLatencyMs: NumericStats.fromSamples(
        ackTerminationLatencies,
      ),
      latestHopValidation: latestHopValidation,
      currentPacket: currentPacketSnapshot(events),
      e2eRequiresPeerLog: e2eLatencies.isEmpty,
    );
  }

  List<int> localLatencySamples(
    List<ExperimentEvent> events, {
    required String startType,
    required String endType,
  }) {
    final startsByKey = <String, ExperimentEvent>{};
    final samples = <int>[];
    for (final event in events) {
      final key = logicalPacketKey(event);
      if (key == null) continue;
      if (event.eventType == startType) {
        startsByKey[key] = event;
      } else if (event.eventType == endType) {
        final start = startsByKey[key];
        if (start == null) continue;
        final interval = localIntervalMs(start, event);
        if (interval != null) samples.add(interval);
      }
    }
    return samples;
  }

  List<int> initialRelayLatencySamples(List<ExperimentEvent> events) {
    final acceptedByKey = <String, ExperimentEvent>{};
    final completedKeys = <String>{};
    final samples = <int>[];
    for (final event in events) {
      final key = logicalPacketKey(event);
      if (key == null) continue;
      if (event.eventType == ExperimentEventTypes.blePacketAccepted) {
        acceptedByKey.putIfAbsent(key, () => event);
      } else if (event.eventType == ExperimentEventTypes.bleRelayStarted &&
          !completedKeys.contains(key)) {
        final accepted = acceptedByKey[key];
        if (accepted == null) continue;
        final interval = localIntervalMs(accepted, event);
        if (interval != null) samples.add(interval);
        completedKeys.add(key);
      }
    }
    return samples;
  }

  List<int> endToEndLatencySamples(List<ExperimentEvent> events) {
    final sourceStarts = <String, int>{};
    final samples = <int>[];
    for (final event in events) {
      final key = logicalPacketKey(event);
      if (key == null) continue;
      if (event.eventType == 'SOURCE_FIRST_ADVERTISE') {
        sourceStarts[key] = _wallTime(event);
      } else if (event.eventType == 'DESTINATION_FIRST_RECEIVE') {
        final start = sourceStarts[key];
        if (start == null) continue;
        final end = _wallTime(event);
        if (end >= start) samples.add(end - start);
      }
    }
    return samples;
  }

  HopValidation validateHop({required int hopIn, required int hopOut}) {
    return HopValidation(
      hopIn: hopIn,
      hopOut: hopOut,
      expectedHopOut: hopIn >= MeshConfig.maxProtocolHop
          ? MeshConfig.maxProtocolHop
          : hopIn + 1,
    );
  }

  HopValidation? latestHopValidationFromEvents(List<ExperimentEvent> events) {
    final acceptedByKey = <String, ExperimentEvent>{};
    final completedKeys = <String>{};
    HopValidation? latest;
    for (final event in events) {
      final key = logicalPacketKey(event);
      if (key == null) continue;
      if (event.eventType == ExperimentEventTypes.blePacketAccepted &&
          event.hopIn != null) {
        acceptedByKey.putIfAbsent(key, () => event);
      } else if (event.eventType == ExperimentEventTypes.bleRelayStarted &&
          event.hopOut != null &&
          !completedKeys.contains(key)) {
        final accepted = acceptedByKey[key];
        if (accepted?.hopIn != null) {
          latest = validateHop(hopIn: accepted!.hopIn!, hopOut: event.hopOut!);
          completedKeys.add(key);
        }
      }
    }
    return latest;
  }

  CurrentPacketSnapshot? currentPacketSnapshot(List<ExperimentEvent> events) {
    ExperimentEvent? latestAccepted;
    for (final event in events.reversed) {
      if (event.eventType == ExperimentEventTypes.blePacketAccepted) {
        latestAccepted = event;
        break;
      }
    }
    if (latestAccepted == null) return null;
    final acceptedAt = _wallTime(latestAccepted);
    final key = logicalPacketKey(latestAccepted);
    ExperimentEvent? stored;
    ExperimentEvent? queued;
    ExperimentEvent? relayStarted;
    if (key != null) {
      for (final event in events) {
        if (logicalPacketKey(event) != key) continue;
        if (_wallTime(event) < acceptedAt) continue;
        if (event.eventType == ExperimentEventTypes.blePacketStored) {
          stored ??= event;
        } else if (event.eventType == ExperimentEventTypes.bleRelayQueued) {
          queued ??= event;
        } else if (event.eventType == ExperimentEventTypes.bleRelayStarted) {
          relayStarted ??= event;
        }
      }
    }
    final detail = _detail(latestAccepted);
    return CurrentPacketSnapshot(
      senderCrc: latestAccepted.senderCrc,
      protocolTimestampMs: latestAccepted.protocolTimestampMs,
      status: latestAccepted.status ?? detail['status']?.toString(),
      packetType: latestAccepted.packetType ?? detail['kind']?.toString(),
      hopIn: latestAccepted.hopIn,
      rssi: latestAccepted.rssi,
      fromServer: detail['from_server'] is bool
          ? detail['from_server'] as bool
          : null,
      payloadHash: latestAccepted.payloadHash,
      receivedAtMs:
          latestAccepted.eventTimestampMs ?? latestAccepted.timestampMs,
      storedAtMs: stored?.eventTimestampMs ?? stored?.timestampMs,
      relayQueuedAtMs: queued?.eventTimestampMs ?? queued?.timestampMs,
      hopOut: relayStarted?.hopOut,
      advertisedAtMs:
          relayStarted?.eventTimestampMs ?? relayStarted?.timestampMs,
    );
  }

  int? localIntervalMs(ExperimentEvent start, ExperimentEvent end) {
    final startElapsed = start.elapsedRealtimeMs;
    final endElapsed = end.elapsedRealtimeMs;
    final interval = startElapsed != null && endElapsed != null
        ? endElapsed - startElapsed
        : _wallTime(end) - _wallTime(start);
    return interval < 0 ? null : interval;
  }

  int? crossDeviceWallClockIntervalMs(
    ExperimentEvent start,
    ExperimentEvent end,
  ) {
    final interval = _wallTime(end) - _wallTime(start);
    return interval < 0 ? null : interval;
  }

  String? logicalPacketKey(ExperimentEvent event) {
    final packetType = event.packetType;
    final status = event.status;
    final protocolTimestamp = event.protocolTimestampMs;
    final senderCrc = event.senderCrc;
    if (packetType != null &&
        status != null &&
        protocolTimestamp != null &&
        senderCrc != null) {
      return '$packetType|$senderCrc|$protocolTimestamp|$status';
    }
    return event.payloadHash ?? event.messageId;
  }

  static int _count(Iterable<ExperimentEvent> events, Set<String> types) {
    return events.where((event) => types.contains(event.eventType)).length;
  }

  static bool _isInvalidEvent(ExperimentEvent event) {
    if (event.eventType != ExperimentEventTypes.bleRelayDropped) return false;
    final reason = _detail(event)['reason']?.toString().toUpperCase();
    return reason != null && reason.contains('INVALID');
  }

  static int _wallTime(ExperimentEvent event) {
    return event.eventTimestampMs ?? event.timestampMs;
  }

  static Map<String, dynamic> _detail(ExperimentEvent event) {
    final raw = event.detailJson;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}
