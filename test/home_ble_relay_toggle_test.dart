import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/screen/home_screen.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('id.ac.usu.resqmesh/mesh');

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> tapBleToggle(WidgetTester tester) async {
    final toggle = find.byTooltip(
      find.byTooltip('BLE Relay Running').evaluate().isNotEmpty
          ? 'BLE Relay Running'
          : 'BLE Relay Stopped',
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Map<String, dynamic> capabilities({
    required bool scan,
    required bool advertise,
    required bool service,
    bool bluetooth = true,
  }) {
    return {
      'nativeScanActive': scan,
      'nativeAdvertisingActive': advertise,
      'foregroundServiceActive': service,
      'bluetoothEnabled': bluetooth,
      'scannerAvailable': true,
      'advertiserAvailable': true,
    };
  }

  void installNativeMock({
    required List<String> calls,
    required Map<String, dynamic> Function() readCapabilities,
    void Function(MethodCall call)? onCall,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          onCall?.call(call);

          return switch (call.method) {
            'getBleCapabilities' => readCapabilities(),
            'startBleWakeUpScan' => true,
            'stopBleWakeUpScan' => true,
            'startBackgroundService' => true,
            'stopBackgroundService' => true,
            'requestSchedulerTick' => true,
            'setRelayModeEnabled' => true,
            'setHasPendingRelayWork' => true,
            'hasPendingRelayWork' => false,
            _ => null,
          };
        });
  }

  testWidgets('native running with stale false Dart cache invokes STOP path', (
    tester,
  ) async {
    final calls = <String>[];
    var native = capabilities(scan: true, advertise: false, service: true);
    installNativeMock(
      calls: calls,
      readCapabilities: () => native,
      onCall: (call) {
        if (call.method == 'stopBleWakeUpScan') {
          native = capabilities(scan: false, advertise: false, service: true);
        }
        if (call.method == 'stopBackgroundService') {
          native = capabilities(scan: false, advertise: false, service: false);
        }
      },
    );

    await pumpHome(tester);
    calls.clear();

    await tapBleToggle(tester);

    expect(
      calls,
      containsAllInOrder([
        'getBleCapabilities',
        'setRelayModeEnabled',
        'stopBleWakeUpScan',
        'stopBackgroundService',
        'getBleCapabilities',
      ]),
    );
    expect(calls, isNot(contains('startBleWakeUpScan')));
    expect(find.text('Relay BLE dihentikan.'), findsOneWidget);
  });

  testWidgets('native stopped with stale true Dart cache invokes START path', (
    tester,
  ) async {
    final calls = <String>[];
    var native = capabilities(scan: false, advertise: false, service: false);
    var applyCommandState = false;
    installNativeMock(
      calls: calls,
      readCapabilities: () => native,
      onCall: (call) {
        if (!applyCommandState) return;
        if (call.method == 'startBackgroundService') {
          native = capabilities(scan: false, advertise: false, service: true);
        }
        if (call.method == 'startBleWakeUpScan') {
          native = capabilities(scan: true, advertise: false, service: true);
        }
      },
    );
    NativeBridgeService.debugSetBleWakeUpScanningForTest(true);

    await pumpHome(tester);
    calls.clear();
    applyCommandState = true;

    await tapBleToggle(tester);

    expect(
      calls,
      containsAllInOrder([
        'getBleCapabilities',
        'setRelayModeEnabled',
        'startBackgroundService',
        'startBleWakeUpScan',
        'requestSchedulerTick',
        'getBleCapabilities',
      ]),
    );
    expect(calls, isNot(contains('stopBleWakeUpScan')));
  });

  testWidgets('start success requires scan and service but not advertising', (
    tester,
  ) async {
    final calls = <String>[];
    var native = capabilities(scan: false, advertise: false, service: false);
    var applyCommandState = false;
    installNativeMock(
      calls: calls,
      readCapabilities: () => native,
      onCall: (call) {
        if (!applyCommandState) return;
        if (call.method == 'startBackgroundService') {
          native = capabilities(scan: false, advertise: false, service: true);
        }
        if (call.method == 'startBleWakeUpScan') {
          native = capabilities(scan: true, advertise: false, service: true);
        }
      },
    );

    await pumpHome(tester);
    calls.clear();
    applyCommandState = true;

    await tapBleToggle(tester);

    expect(calls, contains('startBleWakeUpScan'));
    expect(find.text('Relay BLE aktif memantau sekitar.'), findsOneWidget);
    expect(find.byTooltip('BLE Relay Running'), findsOneWidget);
  });

  testWidgets('stop refreshes native state and renders relay off', (
    tester,
  ) async {
    final calls = <String>[];
    var native = capabilities(scan: true, advertise: true, service: true);
    installNativeMock(
      calls: calls,
      readCapabilities: () => native,
      onCall: (call) {
        if (call.method == 'stopBleWakeUpScan') {
          native = capabilities(scan: false, advertise: false, service: true);
        }
        if (call.method == 'stopBackgroundService') {
          native = capabilities(scan: false, advertise: false, service: false);
        }
      },
    );

    await pumpHome(tester);
    await tapBleToggle(tester);

    expect(find.byTooltip('BLE Relay Stopped'), findsOneWidget);
  });

  testWidgets('stop failure does not claim confirmed success', (tester) async {
    final calls = <String>[];
    final native = capabilities(scan: true, advertise: false, service: false);
    installNativeMock(calls: calls, readCapabilities: () => native);

    await pumpHome(tester);
    await tapBleToggle(tester);

    expect(find.text('Relay BLE dihentikan.'), findsNothing);
    expect(
      find.text(
        'Relay BLE belum sepenuhnya berhenti. Periksa status service/scan.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('BLE Relay Running'), findsOneWidget);
  });

  testWidgets('periodic refresh reads native capabilities', (tester) async {
    final calls = <String>[];
    var native = capabilities(scan: false, advertise: false, service: false);
    installNativeMock(calls: calls, readCapabilities: () => native);

    await pumpHome(tester);
    calls.clear();

    native = capabilities(scan: true, advertise: false, service: true);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(calls, contains('getBleCapabilities'));
    expect(find.byTooltip('BLE Relay Running'), findsOneWidget);
  });
}
