import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pkmproject/models/gateway_ack.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/api_service.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';

void main() {
  const baseUrl = 'https://example.test/api';

  test('health check uses fixed /health endpoint', () async {
    Uri? requestedUrl;
    final client = MockClient((request) async {
      requestedUrl = request.url;
      return http.Response('{"ok":true}', 200);
    });

    final healthy = await ApiService.ping(client: client, baseUrl: baseUrl);

    expect(healthy, true);
    expect(requestedUrl, Uri.parse('https://example.test/health'));
  });

  test('health check retries failed attempts', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      if (attempts == 1) {
        return http.Response('unavailable', 503);
      }
      return http.Response('{"ok":true}', 200);
    });

    final healthy = await ApiService.ping(
      client: client,
      baseUrl: baseUrl,
      maxRetry: 2,
    );

    expect(healthy, true);
    expect(attempts, 2);
  });

  test('upload sends idempotency identity fields', () async {
    Map<String, dynamic>? body;
    Uri? requestedUrl;
    final client = MockClient((request) async {
      requestedUrl = request.url;
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('{"acknowledged":true,"ack_data":[]}', 200);
    });

    final response = await ApiService.uploadData(
      [
        {
          'local_message_id': 'local-1',
          'sender_device_id': 'device-a',
          'sender_crc': 12345,
          'updated_at': '2026-08-04T05:00:00.000000Z',
          'status': 'ACTIVE',
        },
      ],
      client: client,
      baseUrl: baseUrl,
    );

    expect(response['acknowledged'], true);
    expect(requestedUrl, Uri.parse('https://example.test/api/sync/upload'));
    final messages = body!['messages'] as List<dynamic>;
    final message = messages.single as Map<String, dynamic>;
    expect(message['updated_at'], '2026-08-04T05:00:00.000000Z');
    expect(
      message['idempotency_key'],
      'local-1:device-a:12345:2026-08-04T05:00:00.000000Z',
    );
  });

  test('gateway ACK contract parses required fields', () {
    final now = DateTime.parse('2026-08-04T05:00:00Z').millisecondsSinceEpoch;
    final ack = GatewayAck.fromJson({
      'sender_crc': 12345,
      'ack_timestamp': '2026-08-04T05:00:00.123Z',
      'status': 'RESOLVED',
      'sender_device_id': 'device-a',
      'local_message_id': 'local-1',
    }, nowMs: now);

    expect(ack.senderCrc, 12345);
    expect(
      ack.ackTimestampMs,
      canonicalProtocolTimestamp(
        DateTime.parse('2026-08-04T05:00:00.123Z').millisecondsSinceEpoch,
      ),
    );
    expect(ack.status, SOSMessageStatus.resolved);
    expect(ack.senderDeviceId, 'device-a');
    expect(ack.localMessageId, 'local-1');
  });

  test('gateway ACK contract rejects ambiguous payloads', () {
    expect(
      () => GatewayAck.fromJson({'sender_crc': 12345, 'timestamp': 1}),
      throwsFormatException,
    );
  });

  test('gateway ACK contract rejects ACTIVE status', () {
    expect(
      () => GatewayAck.fromJson({
        'sender_crc': 12345,
        'ack_timestamp': '2026-08-04T05:00:00Z',
        'status': 'ACTIVE',
      }),
      throwsFormatException,
    );
  });

  test('gateway ACK contract rejects missing or unknown status', () {
    expect(
      () => GatewayAck.fromJson({
        'sender_crc': 12345,
        'ack_timestamp': '2026-08-04T05:00:00Z',
      }),
      throwsFormatException,
    );
    expect(
      () => GatewayAck.fromJson({
        'sender_crc': 12345,
        'ack_timestamp': '2026-08-04T05:00:00Z',
        'status': 'DONE',
      }),
      throwsFormatException,
    );
  });

  test('gateway ACK contract rejects far future timestamp', () {
    final now = DateTime.parse('2026-08-04T05:00:00Z').millisecondsSinceEpoch;

    expect(
      () => GatewayAck.fromJson({
        'sender_crc': 12345,
        'ack_timestamp': '2026-08-04T05:06:01Z',
        'status': 'RESOLVED',
      }, nowMs: now),
      throwsFormatException,
    );
  });
}
