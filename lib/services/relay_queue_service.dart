import 'dart:convert';
import 'dart:math';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/relay_queue_item.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:pkmproject/utils/sos_status_priority.dart';
import 'package:sqflite/sqflite.dart';

class RelayQueueService {
  RelayQueueService({
    Database? database,
    DatabaseHelper? databaseHelper,
    Random? random,
    ForwardingMode? mode,
  }) : _database = database,
       _databaseHelper = databaseHelper ?? DatabaseHelper(),
       _random = random ?? Random(),
       _mode = mode ?? MeshConfig.forwardingMode;

  final Database? _database;
  final DatabaseHelper _databaseHelper;
  final Random _random;
  final ForwardingMode _mode;
  int _consecutiveAckSlots = 0;

  static const String stateQueued = 'queued';
  static const String stateAdvertising = 'advertising';
  static const String stateRelayed = 'relayed';
  static const String stateFailed = 'failed';

  int sosCooldownEligibleAt(int nowMs, {int relayCount = 0}) {
    final backoffMs = _mode == ForwardingMode.basicFlooding
        ? MeshConfig.basicFloodingInterval.inMilliseconds
        : adaptiveBackoffForRelayCount(relayCount).inMilliseconds;
    final jitterRange =
        MeshConfig.relayJitterMax.inMilliseconds -
        MeshConfig.relayJitterMin.inMilliseconds;
    final jitter =
        MeshConfig.relayJitterMin.inMilliseconds +
        (jitterRange <= 0 ? 0 : _random.nextInt(jitterRange + 1));
    return nowMs + backoffMs + jitter;
  }

  Duration adaptiveBackoffForRelayCount(int relayCount) {
    final exponent = relayCount.clamp(0, 8);
    final candidateMs =
        MeshConfig.adaptiveBackoffBase.inMilliseconds * (1 << exponent);
    final cappedMs = candidateMs > MeshConfig.adaptiveBackoffMax.inMilliseconds
        ? MeshConfig.adaptiveBackoffMax.inMilliseconds
        : candidateMs;
    return Duration(milliseconds: cappedMs);
  }

  static String ackMessageId({
    required int senderCrc,
    required int ackTimestampMs,
    required int statusIndex,
  }) {
    return 'ack-$senderCrc';
  }

  static int priorityForSosStatus(SOSMessageStatus status) {
    return switch (status) {
      SOSMessageStatus.active => 0,
      SOSMessageStatus.cancelled => 50,
      SOSMessageStatus.resolved => 60,
    };
  }

  Duration slotDurationForMode([ForwardingMode? mode]) {
    final effectiveMode = mode ?? _mode;
    return effectiveMode == ForwardingMode.basicFlooding
        ? MeshConfig.basicFloodingSlotDuration
        : MeshConfig.relaySlotDuration;
  }

  Future<Database> get _db async => _database ?? _databaseHelper.database;

  Future<AckApplyResult> acceptAndQueueAck({
    required int senderCrc,
    required int ackTimestampMs,
    required SOSMessageStatus status,
    int hopCount = 0,
    int? nowMs,
    bool failAfterTombstoneForTest = false,
  }) async {
    final db = await _db;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final canonicalAckTimestamp = canonicalProtocolTimestamp(ackTimestampMs);

    if (!isValidAckStatus(status)) return AckApplyResult.rejectedInvalid;
    if (canonicalAckTimestamp >
        canonicalProtocolTimestamp(
          now + MeshConfig.maxClockSkew.inMilliseconds,
        )) {
      return AckApplyResult.rejectedFuture;
    }

    return db.transaction((txn) async {
      final existingTombstone = await txn.query(
        'ack_tombstones',
        where: 'sender_crc = ?',
        whereArgs: [senderCrc],
        limit: 1,
      );
      final result = _classifyAck(
        existingTombstone.isEmpty ? null : existingTombstone.first,
        timestampMs: canonicalAckTimestamp,
        status: status,
      );
      if (result.rejected) return result;

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
      for (final messageId in ackedMessageIds) {
        await txn.delete(
          'relay_queue',
          where: 'message_id = ? AND packet_type = ?',
          whereArgs: [messageId, 'sos'],
        );
      }

      final compactMessageId = ackMessageId(
        senderCrc: senderCrc,
        ackTimestampMs: canonicalAckTimestamp,
        statusIndex: status.index,
      );
      await _compactAckQueueInExecutor(
        txn,
        senderCrc: senderCrc,
        compactMessageId: compactMessageId,
      );

      final existingQueue = await txn.query(
        'relay_queue',
        where: 'message_id = ? AND packet_type = ?',
        whereArgs: [compactMessageId, 'ack'],
        limit: 1,
      );
      if (result == AckApplyResult.duplicate && existingQueue.isNotEmpty) {
        return result;
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
        ),
        resetMetrics: result.shouldRelay,
      );
      return result;
    });
  }

  Future<bool> storeAndQueueSos({
    required SOSMessage message,
    int priority = 0,
    required int nextEligibleAt,
    bool failAfterStoreForTest = false,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final latestExisting = await _latestMessageForSenderInExecutor(
        txn,
        message,
      );
      if (latestExisting != null &&
          _compareMessageState(message, latestExisting) <= 0) {
        return false;
      }

      if (latestExisting != null) {
        message.relayCount = 0;
        message.lastRelayedAt = 0;
      }

      final existingRows = await _messageRowsForSenderInExecutor(txn, message);
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
      }

      await txn.insert(
        'sos_messages',
        message.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (failAfterStoreForTest) {
        throw StateError('Simulated SOS transaction failure');
      }
      await _upsertInExecutor(
        txn,
        RelayQueueItem(
          messageId: message.id,
          packetType: 'sos',
          priority: priority,
          nextEligibleAt: nextEligibleAt,
          relayCount: message.relayCount,
          lastRelayedAt: message.lastRelayedAt,
          queueState: stateQueued,
        ),
        resetMetrics: latestExisting != null,
      );
      return true;
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
    );
    return result.rejected ? 0 : 1;
  }

  Future<int> recoverAckQueueFromTombstones({int? nowMs}) async {
    final db = await _db;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
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
          senderCrc: senderCrc,
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
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
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
      for (final message in latestBySender.values) {
        final nextEligibleAt = _recoveredSosEligibleAt(message, now);
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
    Duration slotDuration = MeshConfig.relaySlotDuration,
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
    Duration slotDuration = MeshConfig.relaySlotDuration,
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
      final nextEligibleAt = sosCooldownEligibleAt(
        nowMs,
        relayCount: nextRelayCount,
      );

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
        'next_eligible_at': sosCooldownEligibleAt(
          nowMs,
          relayCount: item.relayCount,
        ),
      },
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
  }

  Future<void> markRelayed(
    RelayQueueItem item, {
    required int nowMs,
    Duration slotDuration = MeshConfig.relaySlotDuration,
  }) {
    return markAdvertisingSucceeded(
      item,
      nowMs: nowMs,
      slotDuration: slotDuration,
    );
  }

  Future<int> removeMessage(String messageId) async {
    final db = await _db;
    return db.delete(
      'relay_queue',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<int> removeItem(RelayQueueItem item) async {
    final db = await _db;
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
    required int senderCrc,
    required String compactMessageId,
  }) async {
    await db.delete(
      'relay_queue',
      where:
          "packet_type = 'ack' AND message_id != ? AND "
          "(message_id = ? OR message_id LIKE ?)",
      whereArgs: [compactMessageId, 'ack-$senderCrc', 'ack-$senderCrc-%'],
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
    return AckApplyResult.duplicate;
  }

  Future<List<String>> _markAckedSosInExecutor(
    DatabaseExecutor db, {
    required int senderCrc,
    required int ackTimestampMs,
  }) async {
    final rows = await db.query(
      'sos_messages',
      columns: ['id', 'updated_at'],
      where:
          'sender_crc = ? AND ack_received_at IS NULL '
          'AND local_state NOT IN (?, ?)',
      whereArgs: [senderCrc, 'acked', 'synced'],
    );
    final ackedIds = <String>[];
    for (final row in rows) {
      final id = row['id'] as String?;
      final updatedAt = canonicalProtocolTimestamp(row['updated_at'] as int);
      if (id == null || updatedAt > ackTimestampMs) continue;
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
    return rows.map(SOSMessage.fromDbMap).reduce((a, b) {
      return _compareMessageState(a, b) >= 0 ? a : b;
    });
  }

  int _compareMessageState(SOSMessage a, SOSMessage b) {
    final aTimestamp = canonicalProtocolTimestamp(a.updatedAt);
    final bTimestamp = canonicalProtocolTimestamp(b.updatedAt);
    if (aTimestamp != bTimestamp) return aTimestamp.compareTo(bTimestamp);
    return sosStatusPriority(a.status).compareTo(sosStatusPriority(b.status));
  }

  int _recoveredSosEligibleAt(SOSMessage message, int nowMs) {
    if (message.status == SOSMessageStatus.cancelled ||
        message.status == SOSMessageStatus.resolved ||
        message.lastRelayedAt <= 0 ||
        message.relayCount <= 0) {
      return nowMs;
    }
    final backoffMs = adaptiveBackoffForRelayCount(
      message.relayCount,
    ).inMilliseconds;
    final jitterRange =
        MeshConfig.relayJitterMax.inMilliseconds -
        MeshConfig.relayJitterMin.inMilliseconds;
    final jitter =
        MeshConfig.relayJitterMin.inMilliseconds +
        (jitterRange <= 0 ? 0 : _random.nextInt(jitterRange + 1));
    final eligibleAt = message.lastRelayedAt + backoffMs + jitter;
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
