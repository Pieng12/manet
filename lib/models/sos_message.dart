// pkmproject/lib/models/sos_message.dart

enum SOSMessageStatus { cancelled, active, resolved }

class SOSMessage {
  static const int kBaseTimestamp = 1704067200; // 2024-01-01 00:00:00 UTC

  String id; // UUID, corresponds to local_message_id on server
  String senderId; // Corresponds to sender_device_id on server
  int? senderCrc; // Optional CRC32 short id
  bool fromServer; // Flag indicating server-originated broadcast
  String? senderName;
  String content;
  double latitude;
  double longitude;
  SOSMessageStatus status;
  int
  createdAt; // Epoch milliseconds (local creation time / server's occurred_at)
  int updatedAt; // Epoch milliseconds (local update time / server's updated_at)
  int isSynced; // 0 = Not synced, 1 = Synced

  SOSMessage({
    required this.id,
    required this.senderId,
    this.senderCrc,
    this.fromServer = false,
    this.senderName,
    required this.content,
    required this.latitude,
    required this.longitude,
    this.status = SOSMessageStatus.active,
    required this.createdAt,
    required this.updatedAt,
    this.isSynced = 0,
  });

  // Convert a SOSMessage object into a Map object for database insertion/update
  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'sender_id': senderId,
      'sender_name': senderName,
      'content': content,
      'latitude': latitude,
      'longitude': longitude,
      'status': status.index, // Store enum as integer
      'created_at': createdAt,
      'updated_at': updatedAt,
      'is_synced': isSynced,
      'sender_crc': senderCrc,
      'from_server': fromServer ? 1 : 0,
    };
  }

  // Convert a Map object from database into a SOSMessage object
  factory SOSMessage.fromDbMap(Map<String, dynamic> map) {
    return SOSMessage(
      id: map['id'],
      senderId: map['sender_id'],
      senderCrc: map['sender_crc'],
      fromServer: (map['from_server'] ?? 0) == 1,
      senderName: map['sender_name'],
      content: map['content'],
      latitude: map['latitude'],
      longitude: map['longitude'],
      status: SOSMessageStatus
          .values[map['status']], // Convert integer back to enum
      createdAt: map['created_at'],
      updatedAt: map['updated_at'],
      isSynced: map['is_synced'],
    );
  }

  // Convert a SOSMessage object into a Map object suitable for JSON encoding (e.g., for mesh)
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'content': content,
      'latitude': latitude,
      'longitude': longitude,
      'status': status.name, // Use the enum name as string
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  String _formatTimestamp(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    final microsecond = dt.microsecond.toString().padLeft(6, '0');
    return '${year}-${month}-${day}T${hour}:${minute}:${second}.${microsecond}Z';
  }

  // Convert a SOSMessage object into a Map object suitable for API upload
  Map<String, dynamic> toApiJson() {
    // Note: The occurred_at and timestamp fields are using `updatedAt` to reflect the latest state
    // of the message (e.g., when it was cancelled or replaced).
    final String apiTimestamp = _formatTimestamp(updatedAt);

    return {
      'local_message_id': id,
      'sender_device_id': senderId,
      'sender_name': senderName,
      'content': content,
      'latitude': latitude,
      'longitude': longitude,
      'status': status.name.toUpperCase(),
      'occurred_at': apiTimestamp,
      'device_id': senderId,
      'sender_crc': senderCrc,
      'from_server': fromServer,
      'battery_level': 100.0,
      'timestamp': apiTimestamp,
    };
  }

  // Convert a Map object from API response into a SOSMessage object
  factory SOSMessage.fromApiJson(Map<String, dynamic> json) {
    return SOSMessage(
      id: json['local_message_id'],
      senderId: json['sender_device_id'],
      senderCrc: json.containsKey('sender_crc')
          ? json['sender_crc'] as int
          : null,
      fromServer: json.containsKey('from_server')
          ? (json['from_server'] == true)
          : false,
      senderName: json['sender_name'],
      content: json['content'],
      latitude: json['latitude'],
      longitude: json['longitude'],
      status: SOSMessageStatus.values.firstWhere(
        (e) =>
            e.toString().split('.').last.toUpperCase() ==
            json['status'].toUpperCase(),
      ),
      createdAt: DateTime.parse(json['occurred_at']).millisecondsSinceEpoch,
      updatedAt: DateTime.parse(json['updated_at']).millisecondsSinceEpoch,
      isSynced: 1, // Data from server is always synced
    );
  }
}
