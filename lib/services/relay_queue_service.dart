import 'dart:convert';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/relay_queue_item.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:sqflite/sqflite.dart';

class RelayQueueService {
  RelayQueueService({Database? database, DatabaseHelper? databaseHelper})
    : _database = database,
      _databaseHelper = databaseHelper ?? DatabaseHelper();

  final Database? _database;
  final DatabaseHelper _databaseHelper;

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
        payloadBase64: payloadBase64,
      ),
    );
  }

  Future<RelayQueueItem?> nextEligible(int nowMs) async {
    await removeExpiredSos(nowMs);
    await removeExpiredAcks(nowMs);
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: 'next_eligible_at <= ?',
      whereArgs: [nowMs],
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

  Future<void> markRelayed(
    RelayQueueItem item, {
    required int nowMs,
    Duration slotDuration = MeshConfig.relaySlotDuration,
  }) async {
    final db = await _db;
    await db.update(
      'relay_queue',
      {
        'relay_count': item.relayCount + 1,
        'last_relayed_at': nowMs,
        'next_eligible_at': nowMs + slotDuration.inMilliseconds,
      },
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
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
        packet = BlePacket.unpack(base64Decode(payload));
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
        'payload_base64': item.payloadBase64 ?? current.payloadBase64,
      },
      where: 'message_id = ? AND packet_type = ?',
      whereArgs: [item.messageId, item.packetType],
    );
  }
}
