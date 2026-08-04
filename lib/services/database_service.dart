import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('sos_database.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    const idType = 'INTEGER PRIMARY KEY AUTOINCREMENT';
    const textType = 'TEXT NOT NULL';
    const intType = 'INTEGER NOT NULL';

    await db.execute('''
CREATE TABLE pending_sos_messages ( 
  id $idType, 
  message_id $textType,
  payload $textType,
  timestamp $intType
  )
''');
  }

  Future<int> insertMessage(Map<String, dynamic> message) async {
    final db = await instance.database;
    return await db.insert('pending_sos_messages', message);
  }

  Future<List<Map<String, dynamic>>> getMessages() async {
    final db = await instance.database;
    return await db.query('pending_sos_messages', orderBy: 'timestamp ASC');
  }

  Future<int> deleteMessage(int id) async {
    final db = await instance.database;
    return await db.delete(
      'pending_sos_messages',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future close() async {
    final db = await instance.database;
    db.close();
  }
}
