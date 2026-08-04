import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:pkmproject/models/sos_message.dart';

String _formatTimestamp(dynamic rawTs) {
  if (rawTs == null || rawTs == 0) {
    // Fallback to current time if timestamp is null
    rawTs = DateTime.now().millisecondsSinceEpoch;
  }

  DateTime dt;
  if (rawTs is int) {
    dt = DateTime.fromMillisecondsSinceEpoch(rawTs, isUtc: true);
  } else if (rawTs is String) {
    dt = DateTime.parse(rawTs).toUtc();
  } else {
    dt = DateTime.now().toUtc();
  }

  final year = dt.year.toString().padLeft(4, '0');
  final month = dt.month.toString().padLeft(2, '0');
  final day = dt.day.toString().padLeft(2, '0');
  final hour = dt.hour.toString().padLeft(2, '0');
  final minute = dt.minute.toString().padLeft(2, '0');
  final second = dt.second.toString().padLeft(2, '0');
  final microsecond = dt.microsecond.toString().padLeft(6, '0');
  return '${year}-${month}-${day}T${hour}:${minute}:${second}.${microsecond}Z';
}

class ApiService {
  static const String _baseUrl = String.fromEnvironment(
    'RESQMESH_API_BASE_URL',
    defaultValue: 'https://resqmesh-backend-production.up.railway.app/api',
  );

  static Future<Map<String, dynamic>> sendSosMessage(
    Map<String, dynamic> messagePayload,
  ) async {
    final url = Uri.parse('$_baseUrl/sos');
    try {
      final rawTs =
          messagePayload['updatedAt'] ??
          messagePayload['timestamp'] ??
          messagePayload['createdAt'] ??
          messagePayload['occurred_at'];

      final String apiTimestamp = _formatTimestamp(rawTs);

      final Map<String, dynamic> bodyMap = {
        'local_message_id':
            messagePayload['id'] ?? messagePayload['local_message_id'],
        'device_id':
            messagePayload['device_id'] ??
            messagePayload['sender_device_id'] ??
            messagePayload['senderId'] ??
            messagePayload['originDeviceId'] ??
            'unknown',
        'latitude': (messagePayload['latitude'] is num)
            ? (messagePayload['latitude'] as num).toDouble()
            : double.tryParse(messagePayload['latitude']?.toString() ?? '') ??
                  0.0,
        'longitude': (messagePayload['longitude'] is num)
            ? (messagePayload['longitude'] as num).toDouble()
            : double.tryParse(messagePayload['longitude']?.toString() ?? '') ??
                  0.0,
        'battery_level':
            messagePayload['battery_level'] ??
            messagePayload['batteryLevel'] ??
            messagePayload['battery'] ??
            0,
        'timestamp': apiTimestamp,
        'message':
            messagePayload['message'] ??
            messagePayload['content'] ??
            messagePayload['senderName'] ??
            '',
        'status': (messagePayload['status'] is int)
            ? (SOSMessageStatus.values[messagePayload['status'] as int]).name
                  .toUpperCase()
            : (messagePayload['status'] as String?)?.toUpperCase() ?? 'ACTIVE',
      };

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Accept': 'application/json',
        },
        body: jsonEncode(bodyMap),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body);
      } else {
        throw ApiException(
          "Failed to send SOS message",
          statusCode: response.statusCode,
          body: response.body,
          url: url.toString(),
        );
      }
    } catch (e) {
      throw Exception("Network error while sending SOS message: $e");
    }
  }

  static Future<Map<String, dynamic>> uploadData(
    List<Map<String, dynamic>> messages,
  ) async {
    final url = Uri.parse('$_baseUrl/sync/upload');

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Accept': 'application/json',
        },
        body: jsonEncode({'messages': messages}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body);
      } else {
        throw ApiException(
          "Failed to upload data",
          statusCode: response.statusCode,
          body: response.body,
          url: url.toString(),
        );
      }
    } catch (e) {
      throw Exception("Network error while uploading data: $e");
    }
  }

  static Future<Map<String, dynamic>> downloadData(int sinceTimestamp) async {
    final url = Uri.parse('$_baseUrl/sync/download?since=$sinceTimestamp');

    try {
      final response = await http.get(
        url,
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body);
      } else {
        throw ApiException(
          "Failed to download data",
          statusCode: response.statusCode,
          body: response.body,
          url: url.toString(),
        );
      }
    } catch (e) {
      throw Exception("Network error while downloading data: $e");
    }
  }

  // Lightweight ping endpoint to verify server reachability
  static Future<bool> ping({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      // Try root endpoint first (Railway might not have /up endpoint)
      final url = Uri.parse('$_baseUrl/../');
      final response = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (e) {
      print('[ApiService] Ping failed: $e');
      return false;
    }
  }
}

class ApiException implements Exception {
  final String message;
  final int statusCode;
  final String body;
  final String url;

  const ApiException(
    this.message, {
    required this.statusCode,
    required this.body,
    required this.url,
  });

  bool get isNotFound => statusCode == 404;

  @override
  String toString() {
    return '$message. Status: $statusCode, URL: $url, Body: $body';
  }
}
