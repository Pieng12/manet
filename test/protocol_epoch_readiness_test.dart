import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/services/protocol_epoch_readiness.dart';

void main() {
  final startMs = MeshConfig.protocolEpochSeconds * 1000;
  final endExclusiveMs = (MeshConfig.protocolEpochSeconds + (1 << 24)) * 1000;

  test('24-bit epoch accepts both representable boundaries', () {
    expect(ProtocolEpochReadiness.at(startMs).isValid, isTrue);
    expect(ProtocolEpochReadiness.at(endExclusiveMs - 1).isValid, isTrue);
  });

  test('24-bit epoch rejects times outside its exact range', () {
    expect(ProtocolEpochReadiness.at(startMs - 1).isValid, isFalse);
    expect(ProtocolEpochReadiness.at(endExclusiveMs).isValid, isFalse);
  });

  test('readiness exposes stable epoch metadata and remaining days', () {
    final readiness = ProtocolEpochReadiness.at(startMs);
    final json = readiness.toJson();

    expect(json['epoch_id'], MeshConfig.protocolEpochId);
    expect(json['epoch_start'], '2026-06-01T00:00:00.000Z');
    expect(json['representable_end'], isNotNull);
    expect(readiness.remainingDays, closeTo((1 << 24) / 86400, 0.000001));
  });
}
