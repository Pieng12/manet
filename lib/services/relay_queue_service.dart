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
  }) : _database = database,
       _databaseHelper = databaseHelper ?? DatabaseHelper(),
       _random = random ?? Random();

  final Database? _database;
  final DatabaseHelper _databaseHelper;
  final Random _random;

  static const String stateQueued = 'queued';
  static const String stateAdvertising = 'advertising';
  static const String stateRelayed = 'relayed';
  static const String stateFailed = 'failed';

  int sosCooldownEligibleAt(int nowMs) {
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
    return 'ack-$senderCrc-$ackTimestampMs-$statusIndex';
  }

  Future<Database> get _db async => _database ?? _databaseHelper.database;

  Future<int> enqueueSos(
    SOSMessage message, {
    int priority = 0,
    int? nextEligibleAt,
  }) async {
    if (message.isExpired || message.hopCount > message.maxHop) {
      await removeMessage(message.id);
      return 0;
    }

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
  }) {
    return _upsert(
      RelayQueueItem(
        messageId: messageId,
        packetType: 'ack',
        priority: priority,
        nextEligibleAt: nextEligibleAt ?? 0,
        queueState: stateQueued,
        payloadBase64: payloadBase64,
      ),
    );
  }

  Future<RelayQueueItem?> nextEligible(int nowMs) async {
    await removeExpiredSos(nowMs);
    await removeExpiredAcks(nowMs);
    await removeMaxRelayCountItems();
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: 'next_eligible_at <= ? AND relay_count < ? AND queue_state != ?',
      whereArgs: [nowMs, MeshConfig.maxRelayCount, 'disabled'],
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
      final reachedLimit = nextRelayCount >= MeshConfig.maxRelayCount;
      final nextEligibleAt = item.isSos
          ? sosCooldownEligibleAt(nowMs)
          : nowMs + slotDuration.inMilliseconds;

      if (reachedLimit) {
        await txn.delete(
          'relay_queue',
          where: 'message_id = ? AND packet_type = ?',
          whereArgs: [item.messageId, item.packetType],
        );
      } else {
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
      }

      if (item.isSos) {
        await txn.rawUpdate(
          '''
UPDATE sos_messages
SET relay_count = relay_count + 1,
    last_relayed_at = ?,
    local_state = CASE
      WHEN local_state IN ('acked', 'synced', 'expired') THEN local_state
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
        'next_eligible_at': item.isSos
            ? sosCooldownEligibleAt(nowMs)
            : nowMs + retryDelay.inMilliseconds,
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
    final db = await _db;
    await db.rawUpdate(
      '''
UPDATE sos_messages
SET local_state = 'expired'
WHERE expires_at <= ?
AND local_state NOT IN ('acked', 'synced', 'expired')
''',
      [nowMs],
    );
    return db.rawDelete(
      '''
DELETE FROM relay_queue
WHERE packet_type = 'sos'
AND message_id IN (
  SELECT id FROM sos_messages
  WHERE expires_at <= ?
     OR local_state = 'expired'
     OR is_synced = 1
     OR hop_count > max_hop
)
''',
      [nowMs],
    );
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
      if (packet == null ||
          !packet.isAck ||
          nowMs >= packet.timestampMs + MeshConfig.ackLifetime.inMilliseconds) {
        removed += await removeItem(item);
      }
    }
    return removed;
  }

  Future<int> removeMaxRelayCountItems() async {
    final db = await _db;
    return db.delete(
      'relay_queue',
      where: 'relay_count >= ?',
      whereArgs: [MeshConfig.maxRelayCount],
    );
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
}
