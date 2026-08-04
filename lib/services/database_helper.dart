// pkmproject/lib/database_helper.dart

import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart'; // Import our SQL schema
import 'package:pkmproject/models/sos_message.dart'; // Import the SOSMessage model
import 'package:pkmproject/utils/sos_status_priority.dart';

class DatabaseHelper {
  static const int databaseVersion = 7;

  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  // 1. "Radio Station" (StreamController)
  final _messageStreamController =
      StreamController<List<SOSMessage>>.broadcast();

  // Cache for current value (since broadcast streams don't replay)
  List<SOSMessage> _currentMessages = [];
  List<SOSMessage> get currentMessages => _currentMessages;

  factory DatabaseHelper() {
    return _instance;
  }

  DatabaseHelper._internal();

  // 2. Getter for UI to listen to
  Stream<List<SOSMessage>> get messageStream => _messageStreamController.stream;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  // 3. Function to fetch data and broadcast it
  Future<void> refreshMessages() async {
    try {
      final messages = await getAllMessages();
      _currentMessages = messages; // Update cache
      _messageStreamController.add(messages);
    } catch (e) {
      // If database not ready yet, send empty list to avoid blocking UI
      _currentMessages = [];
      _messageStreamController.add([]);
    }
  }

  // Initialize database and load initial data immediately
  Future<void> initialize() async {
    await database; // Ensure database is initialized
    await refreshMessages(); // Load initial data
  }

  Future<Database> _initDatabase() async {
    String path = await getDatabasesPath();
    String databasePath = join(path, 'pkm_database.db');

    return await openDatabase(
      databasePath,
      version: databaseVersion,
      onCreate: (db, version) async {
        await db.execute(createSosMessagesTableSql);
        await db.execute(createRelayQueueTableSql);
        await db.execute(createAckTombstonesTableSql);
        await db.execute(createExperimentSessionsTableSql);
        await db.execute(createExperimentEventsTableSql);
        print("[DatabaseHelper] Table created in onCreate");
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await migrateDatabase(db, oldVersion, newVersion);
      },
      onOpen: (db) async {
        // SELF-HEALING: Ensure table exists even if onCreate skipped it
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='sos_messages'",
        );
        if (tables.isEmpty) {
          print(
            "[DatabaseHelper] 🛠️ SELF-HEALING: sos_messages missing! Creating...",
          );
          await db.execute(createSosMessagesTableSql);
        }
        await ensureSosMessageColumns(db);
        await ensureRelayQueueTable(db);
        await ensureRelayQueueColumns(db);
        await ensureAckTombstonesTable(db);
        await ensureExperimentTables(db);
      },
    );
  }

  static Future<void> migrateDatabase(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await ensureSosMessageColumns(db);
    }

    if (oldVersion < 3) {
      await ensureSosMessageColumns(db);
      await _backfillStage1Columns(db);
    }

    if (oldVersion < 4) {
      await ensureRelayQueueTable(db);
    }

    if (oldVersion < 5) {
      await ensureExperimentTables(db);
    }

    if (oldVersion < 6) {
      await ensureRelayQueueTable(db);
      await ensureRelayQueueColumns(db);
    }

    if (oldVersion < 7) {
      await ensureAckTombstonesTable(db);
    }
  }

  static Future<void> ensureAckTombstonesTable(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='ack_tombstones'",
    );
    if (tables.isEmpty) {
      await db.execute(createAckTombstonesTableSql);
    }
  }

  static Future<void> ensureExperimentTables(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name IN ('experiment_sessions', 'experiment_events')",
    );
    final tableNames = tables.map((row) => row['name'] as String).toSet();
    if (!tableNames.contains('experiment_sessions')) {
      await db.execute(createExperimentSessionsTableSql);
    }
    if (!tableNames.contains('experiment_events')) {
      await db.execute(createExperimentEventsTableSql);
    }
  }

  static Future<void> ensureRelayQueueTable(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='relay_queue'",
    );
    if (tables.isEmpty) {
      await db.execute(createRelayQueueTableSql);
    }
    await ensureRelayQueueColumns(db);
  }

  static Future<void> ensureRelayQueueColumns(Database db) async {
    final existingColumns = await _tableColumnNames(db, 'relay_queue');
    for (final entry in relayQueueColumnDefinitions.entries) {
      if (existingColumns.contains(entry.key)) continue;
      await db.execute(
        'ALTER TABLE relay_queue ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }

  static Future<void> ensureSosMessageColumns(Database db) async {
    final existingColumns = await _sosMessageColumnNames(db);
    for (final entry in sosMessagesColumnDefinitions.entries) {
      if (existingColumns.contains(entry.key)) continue;
      await db.execute(
        'ALTER TABLE sos_messages ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }

  static Future<Set<String>> _sosMessageColumnNames(Database db) async {
    return _tableColumnNames(db, 'sos_messages');
  }

  static Future<Set<String>> _tableColumnNames(
    Database db,
    String tableName,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($tableName)');
    return columns.map((column) => column['name'] as String).toSet();
  }

  static Future<void> _backfillStage1Columns(Database db) async {
    final lifetimeMs = MeshConfig.defaultMessageLifetime.inMilliseconds;
    await db.rawUpdate(
      'UPDATE sos_messages '
      'SET expires_at = created_at + ? '
      'WHERE expires_at = 0 OR expires_at IS NULL',
      [lifetimeMs],
    );
    await db.rawUpdate(
      'UPDATE sos_messages '
      'SET first_seen_at = created_at '
      'WHERE first_seen_at = 0 OR first_seen_at IS NULL',
    );
    await db.rawUpdate(
      "UPDATE sos_messages SET local_state = 'pending' "
      "WHERE local_state IS NULL OR local_state = ''",
    );
  }

  Future<int> createMessage(SOSMessage message) async {
    final db = await database;
    final id = await db.insert(
      'sos_messages',
      message.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    refreshMessages(); // Broadcast change
    return id;
  }

  Future<List<SOSMessage>> getUnsyncedMessages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sos_messages',
      where:
          'is_synced = ? AND local_state NOT IN (?, ?) '
          'AND ack_received_at IS NULL AND from_server = ?',
      whereArgs: [0, 'acked', 'synced', 0],
    );
    return List.generate(maps.length, (i) {
      return SOSMessage.fromDbMap(maps[i]);
    });
  }

  Future<List<SOSMessage>> getGatewayUploadCandidates({int? nowMs}) async {
    final db = await database;
    final maps = await db.query(
      'sos_messages',
      where:
          'is_synced = ? AND ack_received_at IS NULL '
          'AND from_server = ? AND local_state NOT IN (?, ?)',
      whereArgs: [0, 0, 'acked', 'synced'],
      orderBy: 'updated_at DESC',
    );
    return maps.map(SOSMessage.fromDbMap).toList();
  }

  Future<int> updateSyncStatus(String uuid) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    // IMPORTANT: Only update is_synced, NOT updated_at.
    // updated_at should only change when the user creates/updates the SOS message.
    // Syncing is a backend operation and should not modify the message timestamp.
    final result = await db.update(
      'sos_messages',
      {'is_synced': 1, 'synced_at': now, 'local_state': 'synced'},
      where: 'id = ?',
      whereArgs: [uuid],
    );
    if (result > 0) {
      await db.delete(
        'relay_queue',
        where: 'message_id = ?',
        whereArgs: [uuid],
      );
      refreshMessages(); // Broadcast change
    }
    return result;
  }

  Future<int> updateAckStatus(String uuid, int ackReceivedAt) async {
    final db = await database;
    final result = await db.update(
      'sos_messages',
      {
        'is_synced': 1,
        'ack_received_at': ackReceivedAt,
        'synced_at': ackReceivedAt,
        'local_state': 'acked',
      },
      where: 'id = ?',
      whereArgs: [uuid],
    );
    if (result > 0) {
      await db.delete(
        'relay_queue',
        where: 'message_id = ?',
        whereArgs: [uuid],
      );
      refreshMessages();
    }
    return result;
  }

  Future<bool> upsertAckTombstone({
    required int senderCrc,
    required int ackTimestampMs,
    required SOSMessageStatus status,
    String? payloadBase64,
  }) async {
    final db = await database;
    return upsertAckTombstoneInDb(
      db,
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      status: status,
      payloadBase64: payloadBase64,
    );
  }

  static Future<bool> upsertAckTombstoneInDb(
    DatabaseExecutor db, {
    required int senderCrc,
    required int ackTimestampMs,
    required SOSMessageStatus status,
    String? payloadBase64,
  }) async {
    if (!isValidAckStatus(status)) return false;

    final existing = await db.query(
      'ack_tombstones',
      where: 'sender_crc = ?',
      whereArgs: [senderCrc],
      limit: 1,
    );

    String? payloadToStore = payloadBase64;
    if (existing.isNotEmpty) {
      final existingRow = existing.first;
      final existingTimestamp = existingRow['ack_timestamp_ms'] as int? ?? 0;
      final existingStatusIndex = existingRow['status'] as int? ?? -1;
      final existingStatus =
          existingStatusIndex >= 0 &&
              existingStatusIndex < SOSMessageStatus.values.length
          ? SOSMessageStatus.values[existingStatusIndex]
          : SOSMessageStatus.cancelled;
      if (existingTimestamp > ackTimestampMs) return false;
      if (existingTimestamp == ackTimestampMs &&
          sosStatusPriority(existingStatus) > sosStatusPriority(status)) {
        return false;
      }
      if (payloadToStore == null &&
          existingTimestamp == ackTimestampMs &&
          existingStatus == status) {
        payloadToStore = existingRow['payload_base64'] as String?;
      }
    }

    await db.insert('ack_tombstones', {
      'sender_crc': senderCrc,
      'ack_timestamp_ms': ackTimestampMs,
      'status': status.index,
      'payload_base64': payloadToStore,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  Future<int?> latestAckTimestampForSenderCrc(int senderCrc) async {
    final db = await database;
    return latestAckTimestampForSenderCrcInDb(db, senderCrc);
  }

  static Future<int?> latestAckTimestampForSenderCrcInDb(
    DatabaseExecutor db,
    int senderCrc,
  ) async {
    final rows = await db.query(
      'ack_tombstones',
      columns: ['ack_timestamp_ms'],
      where: 'sender_crc = ?',
      whereArgs: [senderCrc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['ack_timestamp_ms'] as int?;
  }

  Future<bool> isSuppressedByAckTombstone({
    required int senderCrc,
    required int sosTimestampMs,
  }) async {
    final db = await database;
    return isSuppressedByAckTombstoneInDb(
      db,
      senderCrc: senderCrc,
      sosTimestampMs: sosTimestampMs,
    );
  }

  static Future<bool> isSuppressedByAckTombstoneInDb(
    DatabaseExecutor db, {
    required int senderCrc,
    required int sosTimestampMs,
  }) async {
    final ackTimestamp = await latestAckTimestampForSenderCrcInDb(
      db,
      senderCrc,
    );
    return ackTimestamp != null && ackTimestamp >= sosTimestampMs;
  }

  Future<void> ensureMonotonicStateTimestamp(SOSMessage message) async {
    final db = await database;
    await ensureMonotonicStateTimestampInDb(db, message);
  }

  static Future<void> ensureMonotonicStateTimestampInDb(
    DatabaseExecutor db,
    SOSMessage message,
  ) async {
    final latestTimestamp = await _latestTimestampForSenderInDb(db, message);
    if (latestTimestamp == null) return;

    final latestSecond = latestTimestamp ~/ 1000;
    if (message.updatedAt ~/ 1000 > latestSecond) return;

    final originalUpdatedAt = message.updatedAt;
    message.updatedAt = (latestSecond + 1) * 1000;
    if (message.createdAt == originalUpdatedAt) {
      message.createdAt = message.updatedAt;
    }
  }

  static Future<int?> _latestTimestampForSenderInDb(
    DatabaseExecutor db,
    SOSMessage message,
  ) async {
    int? latest;
    final existingRows = message.senderCrc != null
        ? await db.query(
            'sos_messages',
            columns: ['updated_at'],
            where: 'sender_id = ? OR sender_crc = ?',
            whereArgs: [message.senderId, message.senderCrc],
            orderBy: 'updated_at DESC',
            limit: 1,
          )
        : await db.query(
            'sos_messages',
            columns: ['updated_at'],
            where: 'sender_id = ?',
            whereArgs: [message.senderId],
            orderBy: 'updated_at DESC',
            limit: 1,
          );
    if (existingRows.isNotEmpty) {
      latest = existingRows.first['updated_at'] as int?;
    }

    if (message.senderCrc != null) {
      final ackTimestamp = await latestAckTimestampForSenderCrcInDb(
        db,
        message.senderCrc!,
      );
      if (ackTimestamp != null && (latest == null || ackTimestamp > latest)) {
        latest = ackTimestamp;
      }
    }
    return latest;
  }

  Future<int> upsertMessage(SOSMessage message) async {
    final db = await database;
    // Don't hardcode isSynced to 1 here.
    // It should preserve its original value (0 for mesh-received messages).
    List<Map<String, dynamic>> existing;
    if (message.senderCrc != null) {
      existing = await db.query(
        'sos_messages',
        where: 'sender_id = ? OR sender_crc = ?',
        whereArgs: [message.senderId, message.senderCrc],
      );
    } else {
      existing = await db.query(
        'sos_messages',
        where: 'sender_id = ?',
        whereArgs: [message.senderId],
      );
    }

    if (existing.isEmpty) {
      final result = await db.insert(
        'sos_messages',
        message.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      refreshMessages();
      return result;
    }

    final existingMessage = SOSMessage.fromDbMap(existing.first);
    if (message.updatedAt > existingMessage.updatedAt) {
      // This is a full replacement, not just an upsert
      await replaceWithLatestMessage(message);
      // refreshMessages is called inside replaceWithLatestMessage
      return 1;
    }

    return 0; // No change
  }

  Future<int> getLastSyncTimestamp() async {
    final db = await database;
    final List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT MAX(updated_at) as max_timestamp FROM sos_messages WHERE is_synced = 1',
    );
    return result.first['max_timestamp'] as int? ?? 0;
  }

  Future<List<SOSMessage>> getAllMessages({int? limit}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sos_messages',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return List.generate(maps.length, (i) {
      return SOSMessage.fromDbMap(maps[i]);
    });
  }

  Future<SOSMessage?> getLatestMessageForSender({
    required String senderId,
    int? senderCrc,
  }) async {
    final db = await database;

    final List<Map<String, dynamic>> maps;
    if (senderCrc != null) {
      maps = await db.query(
        'sos_messages',
        where: 'sender_id = ? OR sender_crc = ?',
        whereArgs: [senderId, senderCrc],
      );
    } else {
      maps = await db.query(
        'sos_messages',
        where: 'sender_id = ?',
        whereArgs: [senderId],
      );
    }

    if (maps.isEmpty) return null;
    return maps.map(SOSMessage.fromDbMap).reduce(_newerMessage);
  }

  Future<SOSMessage?> getMessageById(String messageId) async {
    final db = await database;
    final maps = await db.query(
      'sos_messages',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return SOSMessage.fromDbMap(maps.first);
  }

  Future<int> incrementDuplicateCount(String messageId) async {
    final db = await database;
    final result = await db.rawUpdate(
      'UPDATE sos_messages '
      'SET duplicate_count = duplicate_count + 1 '
      'WHERE id = ?',
      [messageId],
    );
    if (result > 0) {
      refreshMessages();
    }
    return result;
  }

  Future<bool> isMessageNewer(SOSMessage incomingMessage) async {
    final db = await database;

    List<Map<String, dynamic>> existingMessages;
    if (incomingMessage.senderCrc != null) {
      existingMessages = await db.query(
        'sos_messages',
        where: 'sender_id = ? OR sender_crc = ?',
        whereArgs: [incomingMessage.senderId, incomingMessage.senderCrc],
      );
    } else {
      existingMessages = await db.query(
        'sos_messages',
        where: 'sender_id = ?',
        whereArgs: [incomingMessage.senderId],
      );
    }

    if (existingMessages.isEmpty) {
      return true;
    }

    final latestExisting = existingMessages
        .map((m) => SOSMessage.fromDbMap(m))
        .reduce(_newerMessage);

    return incomingMessage.updatedAt > latestExisting.updatedAt ||
        (incomingMessage.updatedAt == latestExisting.updatedAt &&
            sosStatusPriority(incomingMessage.status) >
                sosStatusPriority(latestExisting.status));
  }

  Future<void> replaceWithLatestMessage(SOSMessage message) async {
    final db = await database;
    await replaceWithLatestMessageInDb(db, message);
    refreshMessages(); // Broadcast change
  }

  static Future<void> replaceWithLatestMessageInDb(
    Database db,
    SOSMessage message,
  ) async {
    await db.transaction((txn) async {
      final existingRows = message.senderCrc != null
          ? await txn.query(
              'sos_messages',
              columns: ['id'],
              where: 'sender_id = ? OR sender_crc = ?',
              whereArgs: [message.senderId, message.senderCrc],
            )
          : await txn.query(
              'sos_messages',
              columns: ['id'],
              where: 'sender_id = ?',
              whereArgs: [message.senderId],
            );

      SOSMessage? latestExisting;
      for (final row in existingRows) {
        final rows = await txn.query(
          'sos_messages',
          where: 'id = ?',
          whereArgs: [row['id']],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final candidate = SOSMessage.fromDbMap(rows.first);
        if (latestExisting == null ||
            candidate.updatedAt > latestExisting.updatedAt ||
            (candidate.updatedAt == latestExisting.updatedAt &&
                sosStatusPriority(candidate.status) >
                    sosStatusPriority(latestExisting.status))) {
          latestExisting = candidate;
        }
      }

      if (latestExisting != null) {
        if (latestExisting.updatedAt > message.updatedAt ||
            (latestExisting.updatedAt == message.updatedAt &&
                sosStatusPriority(latestExisting.status) >
                    sosStatusPriority(message.status))) {
          return;
        }

        if (message.updatedAt > latestExisting.updatedAt ||
            (message.updatedAt == latestExisting.updatedAt &&
                sosStatusPriority(message.status) >
                    sosStatusPriority(latestExisting.status))) {
          message.relayCount = 0;
          message.lastRelayedAt = 0;
        }
      }

      for (final row in existingRows) {
        final existingId = row['id'] as String?;
        if (existingId == null || existingId == message.id) continue;
        await txn.delete(
          'relay_queue',
          where: 'message_id = ?',
          whereArgs: [existingId],
        );
      }

      // Delete any existing record that matches the sender_id or sender_crc
      if (message.senderCrc != null) {
        await txn.delete(
          'sos_messages',
          where: 'sender_id = ? OR sender_crc = ?',
          whereArgs: [message.senderId, message.senderCrc],
        );
      } else {
        await txn.delete(
          'sos_messages',
          where: 'sender_id = ?',
          whereArgs: [message.senderId],
        );
      }

      await txn.insert(
        'sos_messages',
        message.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> cleanupOldDuplicates() async {
    try {
      final db = await database;
      final allMessages = await db.query('sos_messages');
      if (allMessages.isEmpty) return;

      final Map<String, SOSMessage> latestByDevice = {};
      final idsToDelete = <String>{};

      for (final msgMap in allMessages) {
        final msg = SOSMessage.fromDbMap(msgMap);
        final existing = latestByDevice[msg.senderId];
        if (existing == null) {
          latestByDevice[msg.senderId] = msg;
        } else if (msg.updatedAt > existing.updatedAt) {
          idsToDelete.add(existing.id);
          latestByDevice[msg.senderId] = msg;
        } else {
          idsToDelete.add(msg.id);
        }
      }

      if (idsToDelete.isNotEmpty) {
        await db.transaction((txn) async {
          for (final id in idsToDelete) {
            await txn.delete('sos_messages', where: 'id = ?', whereArgs: [id]);
          }
        });
        refreshMessages(); // Broadcast change
      }
    } catch (e) {
      print("[DatabaseHelper] ⚠️ Error during cleanupOldDuplicates: $e");
    }
  }

  /// Delete a message by ID (only for non-own messages or cancelled/resolved own messages)
  Future<bool> deleteMessage(String messageId, String currentDeviceId) async {
    final db = await database;
    final messages = await db.query(
      'sos_messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );

    if (messages.isEmpty) return false;

    final msg = SOSMessage.fromDbMap(messages.first);

    // Prevent deleting own active SOS
    if (msg.senderId == currentDeviceId &&
        msg.status == SOSMessageStatus.active) {
      return false;
    }

    final result = await db.delete(
      'sos_messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );

    if (result > 0) {
      refreshMessages(); // Broadcast change
    }

    return result > 0;
  }

  void dispose() {
    _messageStreamController.close();
  }

  static SOSMessage _newerMessage(SOSMessage a, SOSMessage b) {
    if (a.updatedAt != b.updatedAt) {
      return a.updatedAt > b.updatedAt ? a : b;
    }
    return sosStatusPriority(a.status) >= sosStatusPriority(b.status) ? a : b;
  }
}
