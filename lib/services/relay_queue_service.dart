import 'dart:convert';
import 'dart:math';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/relay_queue_item.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/models/trickle_state.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/trickle_scheduler.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:pkmproject/utils/sos_state_ordering.dart';
import 'package:pkmproject/utils/sos_status_priority.dart';
import 'package:sqflite/sqflite.dart';

enum RelaySchedulerState {
  stopped,
  selecting,
  advertising,
  waitingNextSlot,
  failedRetryable,
  failedPermission,
  failedBluetoothDisabled,
  failedUnsupported,
}

class SosQueueStoreResult {
  const SosQueueStoreResult({
    required this.stored,
    this.trickleState,
    this.trickleResetPerformed = false,
    this.trickleInconsistentHeard = false,
    this.trickleReason,
  });

  final bool stored;
  final TrickleState? trickleState;
  final bool trickleResetPerformed;
  final bool trickleInconsistentHeard;
  final String? trickleReason;
}

class LogicalDuplicateRecordResult {
  const LogicalDuplicateRecordResult({required this.trickleRecorded});

  final bool trickleRecorded;
}

class _TrickleSosPreparation {
  const _TrickleSosPreparation({
    required this.state,
    required this.resetPerformed,
    required this.inconsistentHeard,
    required this.reason,
  });

  final TrickleState state;
  final bool resetPerformed;
  final bool inconsistentHeard;
  final String reason;
}

class RelayQueueService {
  RelayQueueService({
    Database? database,
    DatabaseHelper? databaseHelper,
    Random? random,
    ForwardingMode? mode,
    ClockSource? clock,
  }) : _database = database,
       _databaseHelper = databaseHelper ?? DatabaseHelper(),
       _random = random ?? Random(),
       _modeOverride = mode,
       _clock = clock ?? ExperimentClock.instance;

  final Database? _database;
  final DatabaseHelper _databaseHelper;
  final Random _random;
  final ForwardingMode? _modeOverride;
  final ClockSource _clock;
  int _consecutiveAckSlots = 0;

  static ForwardingMode? _sessionMode;

  ForwardingMode get mode =>
      _modeOverride ?? _sessionMode ?? MeshConfig.forwardingMode;

  static void configureSessionMode(ForwardingMode? mode) {
    _sessionMode = mode;
  }

  static ForwardingMode modeFromPersistedValue(String value) {
    return switch (value.toLowerCase()) {
      'trickle' => ForwardingMode.trickle,
      'basic' || 'basic_flooding' => ForwardingMode.basicFlooding,
      _ => throw ArgumentError('Unknown forwarding mode: $value'),
    };
  }

  ClockSource get clock => _clock;

  static const String stateQueued = 'queued';
  static const String stateAdvertising = 'advertising';
  static const String stateRelayed = 'relayed';
  static const String stateFailed = 'failed';

  int nextSosEligibleAt(int nowMs) {
    final jitterRange =
        MeshConfig.relayJitterMax.inMilliseconds -
        MeshConfig.relayJitterMin.inMilliseconds;
    final jitter =
        MeshConfig.relayJitterMin.inMilliseconds +
        (jitterRange <= 0 ? 0 : _random.nextInt(jitterRange + 1));
    return nowMs + MeshConfig.basicFloodingInterval.inMilliseconds + jitter;
  }

  int nextAckEligibleAt(int nowMs) {
    final jitterRange =
        MeshConfig.relayJitterMax.inMilliseconds -
        MeshConfig.relayJitterMin.inMilliseconds;
    final jitter =
        MeshConfig.relayJitterMin.inMilliseconds +
        (jitterRange <= 0 ? 0 : _random.nextInt(jitterRange + 1));
    return nowMs + MeshConfig.relayCooldown.inMilliseconds + jitter;
  }

  static String ackMessageId({
    required int senderCrc,
    required int ackTimestampMs,
    required int statusIndex,
  }) {
    return 'ack-$senderCrc-${canonicalProtocolTimestamp(ackTimestampMs)}';
  }

  static int priorityForSosStatus(SOSMessageStatus status) {
    return switch (status) {
      SOSMessageStatus.active => 0,
      SOSMessageStatus.cancelled => 50,
      SOSMessageStatus.resolved => 60,
    };
  }

  Duration slotDurationForMode([ForwardingMode? mode]) {
    return MeshConfig.sosAdvertiseBurstDuration;
  }

  Future<Database> get _db async => _database ?? _databaseHelper.database;

  Future<AckApplyResult> acceptAndQueueAck({
    required int senderCrc,
    required int ackTimestampMs,
    required SOSMessageStatus status,
    int hopCount = 0,
    int? nowMs,
    int? schedulerNowMs,
    String? processedObservationId,
    String? trialId,
    bool failAfterTombstoneForTest = false,
  }) async {
    final db = await _db;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final schedulerNow = schedulerNowMs ?? _clock.monotonicTimeMs();
    final canonicalAckTimestamp = canonicalProtocolTimestamp(ackTimestampMs);

    if (!isValidAckStatus(status)) return AckApplyResult.rejectedInvalid;
    if (canonicalAckTimestamp >
        canonicalProtocolTimestamp(
          now + MeshConfig.maxClockSkew.inMilliseconds,
        )) {
      return AckApplyResult.rejectedFuture;
    }

    return db.transaction((txn) async {
      var effectiveTrialId = trialId;
      if (effectiveTrialId == null) {
        final matchingSos = await txn.query(
          'sos_messages',
          columns: const ['trial_id'],
          where: 'sender_crc = ? AND protocol_timestamp_ms = ?',
          whereArgs: [senderCrc, canonicalAckTimestamp],
          limit: 1,
        );
        effectiveTrialId = matchingSos.isEmpty
            ? null
            : matchingSos.first['trial_id'] as String?;
      }
      final existingTombstone = await txn.query(
        'ack_tombstones',
        where: 'sender_crc = ? AND ack_timestamp_ms = ?',
        whereArgs: [senderCrc, canonicalAckTimestamp],
        limit: 1,
      );
      final result = _classifyAck(
        existingTombstone.isEmpty ? null : existingTombstone.first,
        timestampMs: canonicalAckTimestamp,
        status: status,
      );
      if (result.rejected) {
        await _completeProcessedObservationInExecutor(
          txn,
          processedObservationId,
          now,
        );
        return result;
      }

      final payloadBase64 = base64Encode(
        BlePacket.packAck(
          senderCrc: senderCrc,
          ackTimestampMs: canonicalAckTimestamp,
          status: status,
          hopCount: hopCount,
        ),
      );

      if (result.shouldRelay) {
        await txn.insert('ack_tombstones', {
          'sender_crc': senderCrc,
          'ack_timestamp_ms': canonicalAckTimestamp,
          'status': status.index,
          'payload_base64': payloadBase64,
          'updated_at': now,
          'trial_id': effectiveTrialId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      if (failAfterTombstoneForTest) {
        throw StateError('Simulated ACK transaction failure');
      }

      final ackedMessageIds = await _markAckedSosInExecutor(
        txn,
        senderCrc: senderCrc,
        ackTimestampMs: canonicalAckTimestamp,
      );
      final trickleScheduler = TrickleScheduler(
        database: txn,
        random: _random,
        clock: _clock,
      );
      for (final messageId in ackedMessageIds) {
        await txn.delete(
          'relay_queue',
          where: 'message_id = ? AND packet_type = ?',
          whereArgs: [messageId, 'sos'],
        );
        await trickleScheduler.deleteState(messageId);
      }

      final compactMessageId = ackMessageId(
        senderCrc: senderCrc,
        ackTimestampMs: canonicalAckTimestamp,
        statusIndex: status.index,
      );
      await _compactAckQueueInExecutor(txn, compactMessageId: compactMessageId);

      final existingQueue = await txn.query(
        'relay_queue',
        where: 'message_id = ? AND packet_type = ?',
        whereArgs: [compactMessageId, 'ack'],
        limit: 1,
      );
      if (result == AckApplyResult.duplicate && existingQueue.isNotEmpty) {
        await _completeProcessedObservationInExecutor(
          txn,
          processedObservationId,
          now,
        );
        return result;
      }

      await _upsertInExecutor(
        txn,
        RelayQueueItem(
          messageId: compactMessageId,
          packetType: 'ack',
          priority: 100,
          nextEligibleAt: schedulerNow,
          queueState: stateQueued,
          payloadBase64: payloadBase64,
          trialId: effectiveTrialId,
        ),
        resetMetrics: result.shouldRelay,
      );
      await _completeProcessedObservationInExecutor(
        txn,
        processedObservationId,
        now,
      );
      return result;
    });
  }

  Future<bool> storeAndQueueSos({
    required SOSMessage message,
    int priority = 0,
    required int nextEligibleAt,
    bool failAfterStoreForTest = false,
    bool queueForRelay = true,
  }) async {
    final result = await storeAndQueueSosWithResult(
      message: message,
      priority: priority,
      nextEligibleAt: nextEligibleAt,
      failAfterStoreForTest: failAfterStoreForTest,
      queueForRelay: queueForRelay,
    );
    return result.stored;
  }

  Future<SosQueueStoreResult> storeAndQueueSosWithResult({
    required SOSMessage message,
    int priority = 0,
    required int nextEligibleAt,
    String? processedObservationId,
    bool failAfterStoreForTest = false,
    bool queueForRelay = true,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final latestExisting = await _latestMessageForSenderInExecutor(
        txn,
        message,
      );
      if (latestExisting != null &&
          _compareMessageState(message, latestExisting) <= 0) {
        return const SosQueueStoreResult(stored: false);
      }

      if (latestExisting != null) {
        message.relayCount = 0;
        message.lastRelayedAt = 0;
      }

      final existingRows = await _messageRowsForSenderInExecutor(txn, message);
      final trickleScheduler = TrickleScheduler(
        database: txn,
        random: _random,
        clock: _clock,
      );
      for (final row in existingRows) {
        final existingId = row['id'] as String?;
        if (existingId == null || existingId == message.id) continue;
        await txn.delete(
          'relay_queue',
          where: 'message_id = ? AND packet_type = ?',
          whereArgs: [existingId, 'sos'],
        );
        await txn.delete(
          'sos_messages',
          where: 'id = ?',
          whereArgs: [existingId],
        );
        await trickleScheduler.deleteState(existingId);
      }

      await txn.insert(
        'sos_messages',
        message.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (failAfterStoreForTest) {
        throw StateError('Simulated SOS transaction failure');
      }

      if (!queueForRelay) {
        await _completeProcessedObservationInExecutor(
          txn,
          processedObservationId,
          nextEligibleAt,
        );
        return const SosQueueStoreResult(stored: true);
      }

      var sosNextEligibleAt = nextEligibleAt;
      _TrickleSosPreparation? tricklePreparation;
      if (mode == ForwardingMode.trickle) {
        tricklePreparation = await _prepareTrickleForStoredSos(
          trickleScheduler,
          message: message,
          latestExisting: latestExisting,
          nowMs: nextEligibleAt,
        );
        sosNextEligibleAt = tricklePreparation.state.transmitAt;
      }

      await _upsertInExecutor(
        txn,
        RelayQueueItem(
          messageId: message.id,
          packetType: 'sos',
          priority: priority,
          nextEligibleAt: sosNextEligibleAt,
          relayCount: message.relayCount,
          lastRelayedAt: message.lastRelayedAt,
          queueState: stateQueued,
          trialId: message.trialId,
        ),
        resetMetrics: latestExisting != null,
      );
      await _completeProcessedObservationInExecutor(
        txn,
        processedObservationId,
        nextEligibleAt,
      );
      return SosQueueStoreResult(
        stored: true,
        trickleState: tricklePreparation?.state,
        trickleResetPerformed: tricklePreparation?.resetPerformed ?? false,
        trickleInconsistentHeard:
            tricklePreparation?.inconsistentHeard ?? false,
        trickleReason: tricklePreparation?.reason,
      );
    });
  }

  Future<int> enqueueSos(
    SOSMessage message, {
    int priority = 0,
    int? nextEligibleAt,
  }) async {
    return _upsert(
      RelayQueueItem(
        messageId: message.id,
        packetType: 'sos',
        priority: priority,
        nextEligibleAt: nextEligibleAt ?? 0,
        relayCount: message.relayCount,
        lastRelayedAt: message.lastRelayedAt,
        queueState: stateQueued,
        trialId: message.trialId,
      ),
    );
  }

  Future<int> enqueueAck({
    required String messageId,
    required String payloadBase64,
    int priority = 100,
    int? nextEligibleAt,
  }) async {
    BlePacket? packet;
    try {
      packet = BlePacket.unpack(base64Decode(payloadBase64));
    } catch (_) {
      packet = null;
    }
    if (packet == null ||
        !packet.isAck ||
        packet.status == SOSMessageStatus.active) {
      return 0;
    }
    final result = await acceptAndQueueAck(
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      status: packet.status,
      hopCount: packet.hopCount,
      nowMs: nextEligibleAt,
      schedulerNowMs: nextEligibleAt,
    );
    return result.rejected ? 0 : 1;
  }

  Future<int> recoverAckQueueFromTombstones({int? nowMs}) async {
    final db = await _db;
    final now = nowMs ?? _clock.monotonicTimeMs();
    return db.transaction((txn) async {
      final tombstones = await txn.query('ack_tombstones');
      var restored = 0;
      for (final tombstone in tombstones) {
        final senderCrc = tombstone['sender_crc'] as int?;
        final ackTimestampMs = tombstone['ack_timestamp_ms'] as int?;
        final statusIndex = tombstone['status'] as int?;
        if (senderCrc == null ||
            ackTimestampMs == null ||
            statusIndex == null ||
            statusIndex < 0 ||
            statusIndex >= SOSMessageStatus.values.length) {
          continue;
        }
        final status = SOSMessageStatus.values[statusIndex];
        if (!isValidAckStatus(status)) continue;

        final payloadBase64 = _payloadForTombstone(
          tombstone,
          senderCrc: senderCrc,
          ackTimestampMs: ackTimestampMs,
          status: status,
        );
        final compactMessageId = ackMessageId(
          senderCrc: senderCrc,
          ackTimestampMs: ackTimestampMs,
          statusIndex: status.index,
        );
        await _compactAckQueueInExecutor(
          txn,
          compactMessageId: compactMessageId,
        );

        final existing = await txn.query(
          'relay_queue',
          where: 'message_id = ? AND packet_type = ?',
          whereArgs: [compactMessageId, 'ack'],
          limit: 1,
        );
        final existingPayload = existing.isEmpty
            ? null
            : existing.first['payload_base64'] as String?;
        if (existing.isNotEmpty &&
            _isAckPayloadMatching(
              existingPayload,
              senderCrc: senderCrc,
              ackTimestampMs: ackTimestampMs,
              status: status,
            )) {
          continue;
        }

        await _upsertInExecutor(
          txn,
          RelayQueueItem(
            messageId: compactMessageId,
            packetType: 'ack',
            priority: 100,
            nextEligibleAt: now,
            queueState: stateQueued,
            payloadBase64: payloadBase64,
            trialId: tombstone['trial_id'] as String?,
          ),
          resetMetrics: existing.isEmpty,
        );
        restored++;
      }
      return restored;
    });
  }

  Future<int> recoverSosQueueFromMessages({int? nowMs}) async {
    final db = await _db;
    final now = nowMs ?? _clock.monotonicTimeMs();
    return db.transaction((txn) async {
      final rows = await txn.query(
        'sos_messages',
        where:
            'ack_received_at IS NULL AND local_state NOT IN (?, ?) '
            'AND id NOT IN (SELECT message_id FROM relay_queue WHERE packet_type = ?)',
        whereArgs: ['acked', 'synced', 'sos'],
      );
      final latestBySender = <String, SOSMessage>{};
      for (final row in rows) {
        final message = SOSMessage.fromDbMap(row);
        final key = message.senderCrc?.toString() ?? message.senderId;
        final existing = latestBySender[key];
        if (existing == null || _compareMessageState(message, existing) > 0) {
          latestBySender[key] = message;
        }
      }

      var restored = 0;
      final trickleScheduler = TrickleScheduler(
        database: txn,
        random: _random,
        clock: _clock,
      );
      for (final message in latestBySender.values) {
        final nextEligibleAt = mode == ForwardingMode.trickle
            ? (await trickleScheduler.ensureState(
                messageId: message.id,
                nowMs: now,
                reason: 'startup_recovery',
              )).transmitAt
            : _recoveredSosEligibleAt(message, now);
        await _upsertInExecutor(
          txn,
          RelayQueueItem(
            messageId: message.id,
            packetType: 'sos',
            priority: priorityForSosStatus(message.status),
            nextEligibleAt: nextEligibleAt,
            relayCount: message.relayCount,
            lastRelayedAt: message.lastRelayedAt,
            queueState: stateQueued,
            trialId: message.trialId,
          ),
        );
        restored++;
      }
      return restored;
    });
  }

  Future<RelayQueueItem?> nextEligible(int nowMs) async {
    final db = await _db;
    if (_consecutiveAckSlots >= MeshConfig.maxConsecutiveAckSlots) {
      final sos = await _nextEligibleOfType(db, nowMs, 'sos');
      if (sos != null) {
        _consecutiveAckSlots = 0;
        return sos;
      }
    }

    final rows = await db.query(
      'relay_queue',
      where: 'next_eligible_at <= ? AND queue_state != ?',
      whereArgs: [nowMs, 'disabled'],
      orderBy: 'priority DESC, relay_count ASC, last_relayed_at ASC, id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final selected = RelayQueueItem.fromDbMap(rows.first);
    if (selected.isAck) {
      _consecutiveAckSlots++;
    } else {
      _consecutiveAckSlots = 0;
    }
    return selected;
  }

  Future<int?> earliestNextEligibleAt() async {
    final db = await _db;
    final result = await db.rawQuery(
      "SELECT MIN(next_eligible_at) AS next_at "
      "FROM relay_queue WHERE queue_state != ?",
      ['disabled'],
    );
    return result.first['next_at'] as int?;
  }

  Future<RelayQueueItem?> _nextEligibleOfType(
    DatabaseExecutor db,
    int nowMs,
    String packetType,
  ) async {
    final rows = await db.query(
      'relay_queue',
      where: 'next_eligible_at <= ? AND queue_state != ? AND packet_type = ?',
      whereArgs: [nowMs, 'disabled', packetType],
      orderBy: 'priority DESC, relay_count ASC, last_relayed_at ASC, id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RelayQueueItem.fromDbMap(rows.first);
  }

  Future<RelayQueueItem?> getItem(String messageId, String packetType) async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [messageId, packetType],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RelayQueueItem.fromDbMap(rows.first);
  }

  Future<void> markAdvertisingStarted(
    RelayQueueItem item, {
    required int nowMs,
    Duration slotDuration = MeshConfig.sosAdvertiseBurstDuration,
  }) async {
    final db = await _db;
    await db.update(
      'relay_queue',
      {
        'queue_state': stateAdvertising,
        'next_eligible_at': nowMs + slotDuration.inMilliseconds,
      },
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
  }

  Future<void> markAdvertisingSucceeded(
    RelayQueueItem item, {
    required int nowMs,
    Duration slotDuration = MeshConfig.sosAdvertiseBurstDuration,
    int? nextEligibleAtOverride,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'relay_queue',
        where: 'message_id = ? AND packet_type = ?',
        whereArgs: [item.messageId, item.packetType],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final current = RelayQueueItem.fromDbMap(rows.first);
      final nextRelayCount = current.relayCount + 1;
      final nextEligibleAt =
          nextEligibleAtOverride ??
          (item.isAck
              ? nextAckEligibleAt(nowMs + slotDuration.inMilliseconds)
              : nextSosEligibleAt(nowMs + slotDuration.inMilliseconds));

      await txn.update(
        'relay_queue',
        {
          'relay_count': nextRelayCount,
          'last_relayed_at': nowMs,
          'next_eligible_at': nextEligibleAt,
          'queue_state': stateRelayed,
        },
        where: 'message_id = ? AND packet_type = ?',
        whereArgs: [item.messageId, item.packetType],
      );

      if (item.isSos) {
        await txn.rawUpdate(
          '''
UPDATE sos_messages
SET relay_count = relay_count + 1,
    last_relayed_at = ?,
    local_state = CASE
      WHEN local_state IN ('acked', 'synced') THEN local_state
      ELSE 'relayed'
    END
WHERE id = ?
''',
          [nowMs, item.messageId],
        );
      }
    });
    if (_database == null) {
      await _databaseHelper.refreshMessages();
    }
  }

  Future<void> markAdvertisingFailed(
    RelayQueueItem item, {
    required int nowMs,
    Duration retryDelay = MeshConfig.relayCooldown,
  }) async {
    final db = await _db;
    await db.update(
      'relay_queue',
      {
        'queue_state': stateFailed,
        'next_eligible_at': nowMs + retryDelay.inMilliseconds,
      },
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
  }

  Future<void> markAdvertisingBlocked(
    RelayQueueItem item, {
    int? restoreNextEligibleAt,
  }) async {
    final db = await _db;
    final values = <String, Object?>{'queue_state': stateFailed};
    if (restoreNextEligibleAt != null) {
      values['next_eligible_at'] = restoreNextEligibleAt;
    }
    await db.update(
      'relay_queue',
      values,
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
  }

  Future<void> markRelayed(
    RelayQueueItem item, {
    required int nowMs,
    Duration slotDuration = MeshConfig.sosAdvertiseBurstDuration,
  }) {
    return markAdvertisingSucceeded(
      item,
      nowMs: nowMs,
      slotDuration: slotDuration,
    );
  }

  Future<bool> recordConsistentSosObservation({
    required String messageId,
    required String observationId,
    required String observerKey,
    required int nowMs,
  }) async {
    if (mode != ForwardingMode.trickle) return false;
    final db = await _db;
    return TrickleScheduler(
      database: db,
      random: _random,
      clock: _clock,
    ).recordConsistentObservation(
      messageId: messageId,
      observationId: observationId,
      observerKey: observerKey,
      nowMs: nowMs,
    );
  }

  Future<LogicalDuplicateRecordResult> recordLogicalDuplicateObservation({
    required String messageId,
    required String? observationId,
    required String observerKey,
    required int nowMs,
    int? completedAtMs,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE sos_messages '
        'SET duplicate_count = duplicate_count + 1 '
        'WHERE id = ?',
        [messageId],
      );

      var trickleRecorded = false;
      if (mode == ForwardingMode.trickle) {
        final effectiveObservationId = observationId?.trim().isNotEmpty == true
            ? observationId!.trim()
            : '$messageId|$observerKey|$nowMs';
        trickleRecorded =
            await TrickleScheduler(
              database: txn,
              random: _random,
              clock: _clock,
            ).recordConsistentObservation(
              messageId: messageId,
              observationId: effectiveObservationId,
              observerKey: observerKey,
              nowMs: nowMs,
            );
      }

      final completedObservationId = observationId?.trim();
      if (completedObservationId != null && completedObservationId.isNotEmpty) {
        await DatabaseHelper.completeBleObservationInDb(
          txn,
          completedObservationId,
          completedAtMs ?? nowMs,
        );
      }

      return LogicalDuplicateRecordResult(trickleRecorded: trickleRecorded);
    });
  }

  Future<TrickleInconsistencyResult?> recordTopologyInconsistency({
    required String messageId,
    required int nowMs,
    String? observationId,
    int? completedAtMs,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      TrickleInconsistencyResult? result;
      if (mode == ForwardingMode.trickle) {
        result =
            await TrickleScheduler(
              database: txn,
              random: _random,
              clock: _clock,
            ).handleInconsistentInformation(
              messageId: messageId,
              nowMs: nowMs,
              reason: 'parallel_relay_inconsistent_state',
            );
      }
      final completedObservationId = observationId?.trim();
      if (completedObservationId != null && completedObservationId.isNotEmpty) {
        await DatabaseHelper.completeBleObservationInDb(
          txn,
          completedObservationId,
          completedAtMs ?? nowMs,
        );
      }
      return result;
    });
  }

  static Future<void> _completeProcessedObservationInExecutor(
    DatabaseExecutor db,
    String? observationId,
    int nowMs,
  ) async {
    final id = observationId?.trim();
    if (id == null || id.isEmpty) return;
    await DatabaseHelper.completeBleObservationInDb(db, id, nowMs);
  }

  Future<TrickleState?> trickleStateFor(String messageId) async {
    final db = await _db;
    return TrickleScheduler(database: db, clock: _clock).stateFor(messageId);
  }

  Future<List<TrickleState>> allTrickleStates() async {
    final db = await _db;
    final rows = await db.query('trickle_states', orderBy: 'message_id ASC');
    return rows.map(TrickleState.fromDbMap).toList();
  }

  Future<TrickleTransmitDecision> handleTrickleQueueEvent({
    required RelayQueueItem item,
    required int nowMs,
  }) async {
    final db = await _db;
    final decision = await TrickleScheduler(
      database: db,
      random: _random,
      clock: _clock,
    ).handleQueueEvent(messageId: item.messageId, nowMs: nowMs);
    if (!decision.shouldAdvertise) {
      await db.update(
        'relay_queue',
        {
          'next_eligible_at': decision.nextEligibleAt,
          'queue_state': stateQueued,
        },
        where: 'message_id = ? AND packet_type = ?',
        whereArgs: [item.messageId, item.packetType],
      );
    }
    return decision;
  }

  Future<int> removeMessage(String messageId) async {
    final db = await _db;
    await TrickleScheduler(database: db, clock: _clock).deleteState(messageId);
    return db.delete(
      'relay_queue',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<int> removeItem(RelayQueueItem item) async {
    final db = await _db;
    if (item.isSos) {
      await TrickleScheduler(
        database: db,
        clock: _clock,
      ).deleteState(item.messageId);
    }
    return db.delete(
      'relay_queue',
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
  }

  Future<int> removeExpiredSos(int nowMs) async {
    return 0;
  }

  Future<int> removeExpiredAcks(int nowMs) async {
    final db = await _db;
    final rows = await db.query('relay_queue', where: "packet_type = 'ack'");
    var removed = 0;
    for (final row in rows) {
      final item = RelayQueueItem.fromDbMap(row);
      final payload = item.payloadBase64;
      if (payload == null) {
        removed += await removeItem(item);
        continue;
      }

      BlePacket? packet;
      try {
        packet = BlePacket.unpack(
          base64Decode(payload),
          referenceTime: DateTime.fromMillisecondsSinceEpoch(nowMs),
        );
      } catch (_) {
        packet = null;
      }
      if (packet == null || !packet.isAck) {
        removed += await removeItem(item);
      }
    }
    return removed;
  }

  Future<int> removeMaxRelayCountItems() async {
    return 0;
  }

  Future<List<RelayQueueItem>> getAllItems() async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      orderBy: 'priority DESC, relay_count ASC, last_relayed_at ASC, id ASC',
    );
    return rows.map(RelayQueueItem.fromDbMap).toList();
  }

  Future<int> queueSize() async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM relay_queue',
    );
    return result.first['count'] as int? ?? 0;
  }

  Future<bool> hasActiveItems() async => (await queueSize()) > 0;

  Future<int> queueSizeByType(String packetType) async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM relay_queue WHERE packet_type = ?',
      [packetType],
    );
    return result.first['count'] as int? ?? 0;
  }

  Future<int> _upsert(RelayQueueItem item) async {
    final db = await _db;
    return _upsertInExecutor(db, item);
  }

  Future<int> _upsertInExecutor(
    DatabaseExecutor db,
    RelayQueueItem item, {
    bool resetMetrics = false,
  }) async {
    final existing = await db.query(
      'relay_queue',
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
      limit: 1,
    );

    if (existing.isEmpty) {
      return db.insert('relay_queue', item.toDbMap());
    }

    final current = RelayQueueItem.fromDbMap(existing.first);
    if (item.isAck) {
      final currentAckTimestamp = _ackTimestampFromPayload(
        current.payloadBase64,
      );
      final incomingAckTimestamp = _ackTimestampFromPayload(item.payloadBase64);
      if (currentAckTimestamp != null &&
          incomingAckTimestamp != null &&
          currentAckTimestamp > incomingAckTimestamp) {
        return 0;
      }
    }
    return db.update(
      'relay_queue',
      {
        'priority': item.priority > current.priority
            ? item.priority
            : current.priority,
        'next_eligible_at': item.nextEligibleAt,
        'queue_state': item.queueState,
        'payload_base64': item.payloadBase64 ?? current.payloadBase64,
        if (resetMetrics) 'relay_count': 0,
        if (resetMetrics) 'last_relayed_at': 0,
      },
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
  }

  Future<void> _compactAckQueueInExecutor(
    DatabaseExecutor db, {
    required String compactMessageId,
  }) async {
    final prefix = '$compactMessageId-';
    await db.delete(
      'relay_queue',
      where:
          "packet_type = 'ack' AND message_id != ? AND "
          "(message_id = ? OR message_id LIKE ?)",
      whereArgs: [compactMessageId, compactMessageId, '$prefix%'],
    );
  }

  AckApplyResult _classifyAck(
    Map<String, dynamic>? existing, {
    required int timestampMs,
    required SOSMessageStatus status,
  }) {
    if (existing == null) return AckApplyResult.inserted;
    final existingTimestamp = canonicalProtocolTimestamp(
      existing['ack_timestamp_ms'] as int? ?? 0,
    );
    if (existingTimestamp > timestampMs) return AckApplyResult.rejectedOlder;
    if (timestampMs > existingTimestamp) {
      return AckApplyResult.replacedNewerTimestamp;
    }

    final existingStatusIndex = existing['status'] as int? ?? -1;
    final existingStatus =
        existingStatusIndex >= 0 &&
            existingStatusIndex < SOSMessageStatus.values.length
        ? SOSMessageStatus.values[existingStatusIndex]
        : SOSMessageStatus.cancelled;
    if (sosStatusPriority(status) > sosStatusPriority(existingStatus)) {
      return AckApplyResult.replacedHigherStatus;
    }
    if (sosStatusPriority(status) < sosStatusPriority(existingStatus)) {
      return AckApplyResult.rejectedOlder;
    }
    return AckApplyResult.duplicate;
  }

  Future<List<String>> _markAckedSosInExecutor(
    DatabaseExecutor db, {
    required int senderCrc,
    required int ackTimestampMs,
  }) async {
    final rows = await db.query(
      'sos_messages',
      columns: ['id', 'protocol_timestamp_ms', 'created_at'],
      where:
          'sender_crc = ? AND ack_received_at IS NULL '
          'AND local_state NOT IN (?, ?) '
          'AND protocol_timestamp_ms = ?',
      whereArgs: [
        senderCrc,
        'acked',
        'synced',
        canonicalProtocolTimestamp(ackTimestampMs),
      ],
    );
    final ackedIds = <String>[];
    for (final row in rows) {
      final id = row['id'] as String?;
      if (id == null) continue;
      await db.update(
        'sos_messages',
        {
          'is_synced': 1,
          'ack_received_at': ackTimestampMs,
          'synced_at': ackTimestampMs,
          'local_state': 'acked',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      ackedIds.add(id);
    }
    return ackedIds;
  }

  Future<List<Map<String, dynamic>>> _messageRowsForSenderInExecutor(
    DatabaseExecutor db,
    SOSMessage message,
  ) {
    if (message.senderCrc != null) {
      return db.query(
        'sos_messages',
        where: 'sender_id = ? OR sender_crc = ?',
        whereArgs: [message.senderId, message.senderCrc],
      );
    }
    return db.query(
      'sos_messages',
      where: 'sender_id = ?',
      whereArgs: [message.senderId],
    );
  }

  Future<SOSMessage?> _latestMessageForSenderInExecutor(
    DatabaseExecutor db,
    SOSMessage message,
  ) async {
    final rows = await _messageRowsForSenderInExecutor(db, message);
    if (rows.isEmpty) return null;
    return rows.map(SOSMessage.fromDbMap).reduce(preferredSosState);
  }

  int _compareMessageState(SOSMessage a, SOSMessage b) {
    return compareSosState(a, b);
  }

  Future<_TrickleSosPreparation> _prepareTrickleForStoredSos(
    TrickleScheduler scheduler, {
    required SOSMessage message,
    required SOSMessage? latestExisting,
    required int nowMs,
  }) async {
    if (latestExisting == null || message.id != latestExisting.id) {
      final reason = latestExisting == null ? 'new_state' : 'new_logical_state';
      final state = await scheduler.reset(
        messageId: message.id,
        nowMs: nowMs,
        reason: reason,
      );
      return _TrickleSosPreparation(
        state: state,
        resetPerformed: true,
        inconsistentHeard: latestExisting != null,
        reason: reason,
      );
    }

    if (_isBetterHopUpdate(message, latestExisting)) {
      const reason = 'better_hop_event';
      final state = await scheduler.reset(
        messageId: message.id,
        nowMs: nowMs,
        reason: 'better_hop_event',
      );
      return _TrickleSosPreparation(
        state: state,
        resetPerformed: true,
        inconsistentHeard: false,
        reason: reason,
      );
    }

    final result = await scheduler.handleInconsistentInformation(
      messageId: message.id,
      nowMs: nowMs,
      reason: 'incoming_inconsistent_state',
    );
    return _TrickleSosPreparation(
      state: result.state,
      resetPerformed: result.resetPerformed,
      inconsistentHeard: true,
      reason: result.reason,
    );
  }

  bool _isBetterHopUpdate(SOSMessage message, SOSMessage existing) {
    return message.updatedAt == existing.updatedAt &&
        message.status == existing.status &&
        message.hopCount < existing.hopCount;
  }

  int _recoveredSosEligibleAt(SOSMessage message, int nowMs) {
    if (message.status == SOSMessageStatus.cancelled ||
        message.status == SOSMessageStatus.resolved ||
        message.lastRelayedAt <= 0 ||
        message.relayCount <= 0) {
      return nowMs;
    }
    final eligibleAt = nextSosEligibleAt(message.lastRelayedAt);
    return eligibleAt < nowMs ? nowMs : eligibleAt;
  }

  String _payloadForTombstone(
    Map<String, dynamic> tombstone, {
    required int senderCrc,
    required int ackTimestampMs,
    required SOSMessageStatus status,
  }) {
    final payloadBase64 = tombstone['payload_base64'] as String?;
    if (_isAckPayloadMatching(
      payloadBase64,
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      status: status,
    )) {
      return payloadBase64!;
    }
    return base64Encode(
      BlePacket.packAck(
        senderCrc: senderCrc,
        ackTimestampMs: ackTimestampMs,
        status: status,
      ),
    );
  }

  bool _isAckPayloadMatching(
    String? payloadBase64, {
    required int senderCrc,
    required int ackTimestampMs,
    required SOSMessageStatus status,
  }) {
    if (payloadBase64 == null) return false;
    try {
      final packet = BlePacket.unpack(
        base64Decode(payloadBase64),
        referenceTime: DateTime.fromMillisecondsSinceEpoch(ackTimestampMs),
      );
      return packet != null &&
          packet.isAck &&
          packet.senderCrc == senderCrc &&
          packet.timestampMs == ackTimestampMs &&
          packet.status == status;
    } catch (_) {
      return false;
    }
  }

  int? _ackTimestampFromPayload(String? payloadBase64) {
    if (payloadBase64 == null) return null;
    try {
      final packet = BlePacket.unpack(base64Decode(payloadBase64));
      if (packet == null || !packet.isAck) return null;
      return packet.timestampMs;
    } catch (_) {
      return null;
    }
  }
}
