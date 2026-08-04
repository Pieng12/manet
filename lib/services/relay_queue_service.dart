import 'dart:convert';
import 'dart:math';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/relay_queue_item.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
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

  Future<Database> get _db async => _database ?? _databaseHelper.database;

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
    final db = await _db;
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

    final stored = await DatabaseHelper.upsertAckTombstoneInDb(
      db,
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      status: packet.status,
      payloadBase64: payloadBase64,
    );
    if (!stored) return 0;

    final compactMessageId = ackMessageId(
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      statusIndex: packet.status.index,
    );
    await db.delete(
      'relay_queue',
      where: "packet_type = 'ack' AND message_id LIKE ? AND message_id != ?",
      whereArgs: ['ack-${packet.senderCrc}%', compactMessageId],
    );

    return _upsert(
      RelayQueueItem(
        messageId: compactMessageId,
        packetType: 'ack',
        priority: priority,
        nextEligibleAt: nextEligibleAt ?? 0,
        queueState: stateQueued,
        payloadBase64: payloadBase64,
      ),
    );
  }

  Future<RelayQueueItem?> nextEligible(int nowMs) async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: 'next_eligible_at <= ? AND queue_state != ?',
      whereArgs: [nowMs, 'disabled'],
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

  Future<int> _upsert(RelayQueueItem item) async {
    final db = await _db;
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
      },
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
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
