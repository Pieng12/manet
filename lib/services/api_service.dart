import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:pkmproject/config/mesh_config.dart';
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
  return '$year-$month-${day}T$hour:$minute:$second.${microsecond}Z';
}

class ApiService {
  static const String _baseUrl = MeshConfig.apiBaseUrl;

  static Uri _apiUri(String path, {String? baseUrl}) {
    final base = Uri.parse(baseUrl ?? _baseUrl);
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$basePath/$cleanPath',
      query: null,
      fragment: null,
    );
  }

  static Uri _healthUri({String? baseUrl}) {
    final base = Uri.parse(baseUrl ?? _baseUrl);
    return base.replace(path: '/health', query: null, fragment: null);
  }

  static Future<Map<String, dynamic>> sendSosMessage(
    Map<String, dynamic> messagePayload, {
    http.Client? client,
    String? baseUrl,
  }) async {
    final url = _apiUri('sos', baseUrl: baseUrl);
    final httpClient = client ?? http.Client();
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

      final response = await httpClient.post(
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
    } on ApiException {
      rethrow;
    } catch (e) {
      throw Exception("Network error while sending SOS message: $e");
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Future<Map<String, dynamic>> uploadData(
    List<Map<String, dynamic>> messages, {
    http.Client? client,
    String? baseUrl,
  }) async {
    final url = _apiUri('sync/upload', baseUrl: baseUrl);
    final httpClient = client ?? http.Client();
    final idempotentMessages = messages
        .map((message) => _withIdempotencyFields(message))
        .toList();

    try {
      final response = await httpClient.post(
        url,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Accept': 'application/json',
        },
        body: jsonEncode({'messages': idempotentMessages}),
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
    } on ApiException {
      rethrow;
    } catch (e) {
      throw Exception("Network error while uploading data: $e");
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Future<Map<String, dynamic>> downloadData(
    int sinceTimestamp, {
    http.Client? client,
    String? baseUrl,
  }) async {
    final url = _apiUri(
      'sync/download',
      baseUrl: baseUrl,
    ).replace(queryParameters: {'since': sinceTimestamp.toString()});
    final httpClient = client ?? http.Client();

    try {
      final response = await httpClient.get(
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
    } on ApiException {
      rethrow;
    } catch (e) {
      throw Exception("Network error while downloading data: $e");
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Future<bool> ping({
    Duration timeout = MeshConfig.gatewayHealthTimeout,
    int maxRetry = MeshConfig.gatewayHealthMaxRetry,
    http.Client? client,
    String? baseUrl,
  }) async {
    final httpClient = client ?? http.Client();
    final url = _healthUri(baseUrl: baseUrl);
    try {
      for (var attempt = 0; attempt <= maxRetry; attempt++) {
        try {
          final response = await httpClient
              .get(url, headers: {'Accept': 'application/json'})
              .timeout(timeout);
          if (response.statusCode >= 200 && response.statusCode < 300) {
            return true;
          }
        } catch (e) {
          if (attempt == maxRetry) {
            print('[ApiService] Health check failed: $e');
          }
        }
      }
      return false;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Map<String, dynamic> _withIdempotencyFields(
    Map<String, dynamic> message,
  ) {
    final updatedAt =
        message['updated_at'] ?? message['updatedAt'] ?? message['timestamp'];
    final senderCrc = message['sender_crc'];
    final localMessageId =
        message['local_message_id'] ?? message['id'] ?? 'unknown';
    final senderDeviceId =
        message['sender_device_id'] ?? message['device_id'] ?? 'unknown';

    return {
      ...message,
      'updated_at': updatedAt,
      'idempotency_key':
          '$localMessageId:$senderDeviceId:${senderCrc ?? ''}:$updatedAt',
    };
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
