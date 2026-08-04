// pkmproject/lib/database_schema.dart

const String createSosMessagesTableSql = '''
CREATE TABLE sos_messages (
  id TEXT PRIMARY KEY,
  sender_id TEXT,
  sender_name TEXT NULL,
  content TEXT,
  latitude REAL,
  longitude REAL,
  status INTEGER, 
  created_at INTEGER,
  updated_at INTEGER,
  is_synced INTEGER DEFAULT 0,
  sender_crc INTEGER NULL,
  from_server INTEGER DEFAULT 0,
  hop_count INTEGER NOT NULL DEFAULT 0,
  max_hop INTEGER NOT NULL DEFAULT 5,
  expires_at INTEGER NOT NULL DEFAULT 0,
  first_seen_at INTEGER NOT NULL DEFAULT 0,
  last_relayed_at INTEGER NOT NULL DEFAULT 0,
  relay_count INTEGER NOT NULL DEFAULT 0,
  duplicate_count INTEGER NOT NULL DEFAULT 0,
  ack_received_at INTEGER NULL,
  synced_at INTEGER NULL,
  local_state TEXT NOT NULL DEFAULT 'pending'
);
''';

const Map<String, String> sosMessagesColumnDefinitions = {
  'sender_crc': 'INTEGER NULL',
  'from_server': 'INTEGER DEFAULT 0',
  'hop_count': 'INTEGER NOT NULL DEFAULT 0',
  'max_hop': 'INTEGER NOT NULL DEFAULT 5',
  'expires_at': 'INTEGER NOT NULL DEFAULT 0',
  'first_seen_at': 'INTEGER NOT NULL DEFAULT 0',
  'last_relayed_at': 'INTEGER NOT NULL DEFAULT 0',
  'relay_count': 'INTEGER NOT NULL DEFAULT 0',
  'duplicate_count': 'INTEGER NOT NULL DEFAULT 0',
  'ack_received_at': 'INTEGER NULL',
  'synced_at': 'INTEGER NULL',
  'local_state': "TEXT NOT NULL DEFAULT 'pending'",
};

const String createRelayQueueTableSql = '''
CREATE TABLE relay_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL,
  packet_type TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  next_eligible_at INTEGER NOT NULL DEFAULT 0,
  relay_count INTEGER NOT NULL DEFAULT 0,
  last_relayed_at INTEGER NOT NULL DEFAULT 0,
  queue_state TEXT NOT NULL DEFAULT 'queued',
  payload_base64 TEXT NULL,
  UNIQUE(message_id, packet_type)
);
''';

const Map<String, String> relayQueueColumnDefinitions = {
  'priority': 'INTEGER NOT NULL DEFAULT 0',
  'next_eligible_at': 'INTEGER NOT NULL DEFAULT 0',
  'relay_count': 'INTEGER NOT NULL DEFAULT 0',
  'last_relayed_at': 'INTEGER NOT NULL DEFAULT 0',
  'queue_state': "TEXT NOT NULL DEFAULT 'queued'",
  'payload_base64': 'TEXT NULL',
};

const String createExperimentSessionsTableSql = '''
CREATE TABLE experiment_sessions (
  session_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  device_model TEXT NOT NULL,
  android_version TEXT NOT NULL,
  forwarding_mode TEXT NOT NULL,
  max_hop INTEGER NOT NULL,
  message_lifetime_ms INTEGER NOT NULL,
  relay_cooldown_ms INTEGER NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at INTEGER NULL
);
''';

const String createExperimentEventsTableSql = '''
CREATE TABLE experiment_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  message_id TEXT NULL,
  sender_crc INTEGER NULL,
  timestamp_ms INTEGER NOT NULL,
  hop_count INTEGER NULL,
  rssi INTEGER NULL,
  payload_hash TEXT NULL,
  detail_json TEXT NULL
);
''';
