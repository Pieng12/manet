// pkmproject/lib/database_helper.dart

import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:pkmproject/database_schema.dart'; // Import our SQL schema
import 'package:pkmproject/models/sos_message.dart'; // Import the SOSMessage model

class DatabaseHelper {
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
      version: 2,
      onCreate: (db, version) async {
        await db.execute(createSosMessagesTableSql);
        print("[DatabaseHelper] Table created in onCreate");
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute(
              'ALTER TABLE sos_messages ADD COLUMN sender_crc INTEGER NULL',
            );
            await db.execute(
              'ALTER TABLE sos_messages ADD COLUMN from_server INTEGER DEFAULT 0',
            );
          } catch (e) {
            print(
              "[DatabaseHelper] Upgrade column error (maybe already exists): $e",
            );
          }
        }
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
      },
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
      where: 'is_synced = ?',
      whereArgs: [0],
    );
    return List.generate(maps.length, (i) {
      return SOSMessage.fromDbMap(maps[i]);
    });
  }

  Future<int> updateSyncStatus(String uuid) async {
    final db = await database;
    // IMPORTANT: Only update is_synced, NOT updated_at.
    // updated_at should only change when the user creates/updates the SOS message.
    // Syncing is a backend operation and should not modify the message timestamp.
    final result = await db.update(
      'sos_messages',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [uuid],
    );
    if (result > 0) {
      refreshMessages(); // Broadcast change
    }
    return result;
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
        .reduce((a, b) => a.updatedAt > b.updatedAt ? a : b);

    return incomingMessage.updatedAt > latestExisting.updatedAt;
  }

  Future<void> replaceWithLatestMessage(SOSMessage message) async {
    final db = await database;
    await db.transaction((txn) async {
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
    refreshMessages(); // Broadcast change
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
}
