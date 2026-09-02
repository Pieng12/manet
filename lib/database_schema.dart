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

const String createAckTombstonesTableSql = '''
CREATE TABLE ack_tombstones (
  sender_crc INTEGER PRIMARY KEY,
  ack_timestamp_ms INTEGER NOT NULL,
  status INTEGER NOT NULL,
  payload_base64 TEXT NULL,
  updated_at INTEGER NOT NULL
);
''';

const String createTrickleStatesTableSql = '''
CREATE TABLE trickle_states (
  message_id TEXT PRIMARY KEY,
  interval_ms INTEGER NOT NULL,
  interval_started_at INTEGER NOT NULL,
  transmit_at INTEGER NOT NULL,
  interval_end_at INTEGER NOT NULL,
  consistency_count INTEGER NOT NULL DEFAULT 0,
  phase TEXT NOT NULL,
  last_reset_reason TEXT NULL,
  updated_at INTEGER NOT NULL
);
''';

const String createTrickleObservationsTableSql = '''
CREATE TABLE trickle_observations (
  message_id TEXT NOT NULL,
  interval_started_at INTEGER NOT NULL,
  observation_id TEXT NOT NULL,
  observer_key TEXT NULL,
  first_seen_at INTEGER NOT NULL,
  PRIMARY KEY(message_id, interval_started_at, observation_id)
);
''';

const String createTrickleObservationsIndexSql =
    'CREATE INDEX IF NOT EXISTS idx_trickle_observations_message_interval '
    'ON trickle_observations(message_id, interval_started_at)';

const String createProcessedBleObservationsTableSql = '''
CREATE TABLE processed_ble_observations (
  observation_id TEXT PRIMARY KEY,
  packet_type TEXT NOT NULL,
  state TEXT NOT NULL,
  first_received_at INTEGER NOT NULL,
  processed_at INTEGER NOT NULL,
  source_path TEXT NULL,
  updated_at INTEGER NOT NULL
);
''';

const String createProcessedBleObservationsStateIndexSql =
    'CREATE INDEX IF NOT EXISTS idx_processed_ble_observations_state_updated '
    'ON processed_ble_observations(state, updated_at)';

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
  ended_at INTEGER NULL,
  name TEXT NULL,
  node_role TEXT NULL,
  target_hop INTEGER NULL,
  topology_label TEXT NULL,
  scenario_label TEXT NULL,
  notes TEXT NULL,
  status TEXT NOT NULL DEFAULT 'RUNNING',
  app_version TEXT NULL,
  trial_timeout_seconds INTEGER NULL,
  session_kind TEXT NOT NULL DEFAULT 'AUTO',
  device_manufacturer TEXT NULL,
  android_sdk INTEGER NULL,
  app_version_code TEXT NULL,
  build_id TEXT NULL,
  trickle_imin_ms INTEGER NULL,
  trickle_imax_ms INTEGER NULL,
  trickle_imax_doublings INTEGER NULL,
  trickle_k INTEGER NULL,
  sos_advertise_burst_ms INTEGER NULL
);
''';

const Map<String, String> experimentSessionColumnDefinitions = {
  'name': 'TEXT NULL',
  'node_role': 'TEXT NULL',
  'target_hop': 'INTEGER NULL',
  'topology_label': 'TEXT NULL',
  'scenario_label': 'TEXT NULL',
  'notes': 'TEXT NULL',
  'status': "TEXT NOT NULL DEFAULT 'RUNNING'",
  'app_version': 'TEXT NULL',
  'trial_timeout_seconds': 'INTEGER NULL',
  'session_kind': "TEXT NOT NULL DEFAULT 'AUTO'",
  'device_manufacturer': 'TEXT NULL',
  'android_sdk': 'INTEGER NULL',
  'app_version_code': 'TEXT NULL',
  'build_id': 'TEXT NULL',
  'trickle_imin_ms': 'INTEGER NULL',
  'trickle_imax_ms': 'INTEGER NULL',
  'trickle_imax_doublings': 'INTEGER NULL',
  'trickle_k': 'INTEGER NULL',
  'sos_advertise_burst_ms': 'INTEGER NULL',
};

const String createExperimentTrialsTableSql = '''
CREATE TABLE experiment_trials (
  trial_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  trial_number INTEGER NOT NULL,
  trial_code TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at INTEGER NULL,
  status TEXT NOT NULL,
  result TEXT NULL,
  failure_reason TEXT NULL,
  notes TEXT NULL
);
''';

const String createExperimentEventsTableSql = '''
CREATE TABLE experiment_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  trial_id TEXT NULL,
  event_type TEXT NOT NULL,
  message_id TEXT NULL,
  sender_crc INTEGER NULL,
  timestamp_ms INTEGER NOT NULL,
  event_timestamp_ms INTEGER NULL,
  elapsed_realtime_ms INTEGER NULL,
  protocol_timestamp_ms INTEGER NULL,
  node_role TEXT NULL,
  forwarding_mode TEXT NULL,
  packet_type TEXT NULL,
  status TEXT NULL,
  hop_in INTEGER NULL,
  hop_out INTEGER NULL,
  hop_count INTEGER NULL,
  rssi INTEGER NULL,
  payload_hash TEXT NULL,
  detail_json TEXT NULL
);
''';

const Map<String, String> experimentEventColumnDefinitions = {
  'trial_id': 'TEXT NULL',
  'event_timestamp_ms': 'INTEGER NULL',
  'elapsed_realtime_ms': 'INTEGER NULL',
  'protocol_timestamp_ms': 'INTEGER NULL',
  'node_role': 'TEXT NULL',
  'forwarding_mode': 'TEXT NULL',
  'packet_type': 'TEXT NULL',
  'status': 'TEXT NULL',
  'hop_in': 'INTEGER NULL',
  'hop_out': 'INTEGER NULL',
};

const List<String> experimentIndexSql = [
  'CREATE INDEX IF NOT EXISTS idx_experiment_sessions_kind_open '
      'ON experiment_sessions(session_kind, ended_at)',
  'CREATE INDEX IF NOT EXISTS idx_experiment_trials_session_status '
      'ON experiment_trials(session_id, status)',
  'CREATE INDEX IF NOT EXISTS idx_experiment_events_session_trial_time '
      'ON experiment_events(session_id, trial_id, event_timestamp_ms)',
];
