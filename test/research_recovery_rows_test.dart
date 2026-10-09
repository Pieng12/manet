import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/widgets/research_recovery_rows.dart';

void main() {
  Future<void> show(WidgetTester tester, Map<String, dynamic> summary) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: ResearchRecoveryRows(summary: summary),
          ),
        ),
      ),
    );
  }

  testWidgets('old summary does not invent recovery', (tester) async {
    await show(tester, {'N': 5, 'dsr_percent': 100});
    expect(find.text('Rata-rata pemulihan'), findsNothing);
  });
  testWidgets('failed and unverified targets never display zero delay', (
    tester,
  ) async {
    await show(tester, {
      'recovery_measurement_version': 'same-node-recovery-v1',
      'recovery_received_targets': 1,
      'recovery_eligible_targets': 2,
      'recovery_defined_targets': 0,
      'recovery_mean_ms': null,
      'recovery_receivers': [
        {
          'receiver': 'esp-r2b',
          'recovery_eligible': true,
          'recovery_status': 'TIMING_UNVERIFIED',
        },
        {
          'receiver': 'esp-destination',
          'recovery_eligible': true,
          'recovery_status': 'NOT_RECOVERED_WITHIN_WINDOW',
        },
      ],
    });
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('Tidak terdefinisi'), findsOneWidget);
    expect(find.text('Bukti waktu belum cukup'), findsOneWidget);
    expect(find.text('Belum menerima hingga akhir window'), findsOneWidget);
    expect(find.text('0.00 ms'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('verified recovery is numeric and S0 has no target rows', (
    tester,
  ) async {
    await show(tester, {
      'recovery_measurement_version': 'same-node-recovery-v1',
      'recovery_mean_ms': 1234.5,
      'recovery_receivers': [
        {
          'receiver': 'esp-destination',
          'recovery_eligible': true,
          'recovery_status': 'RECOVERED',
          'recovery_delay_ms': 1234.5,
        },
        {
          'receiver': 'esp-r1a',
          'recovery_eligible': false,
          'recovery_status': 'NOT_APPLICABLE',
        },
      ],
    });
    expect(find.text('1234.50 ms'), findsNWidgets(2));
    expect(find.text('esp-r1a'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
