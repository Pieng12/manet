import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/range_test_service.dart';
import 'package:pkmproject/widgets/range_test_tab.dart';

class MemoryPilot extends RangeTestService {
  MemoryPilot()
    : super(clock: FixedExperimentClock(wallMs: 1000000, monotonicMs: 0));
  final points = <Map<String, dynamic>>[];
  final diagnostics = <String>[];
  bool ended = false;
  bool sourceKnown = true;
  bool prepared = false;
  Map<String, dynamic>? fix;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> recordFix(RangeFix value) async {
    fix = value.toJson();
  }

  @override
  Future<void> setSource(
    double lat,
    double lon,
    String method, {
    double? accuracy,
  }) async {
    sourceKnown = true;
  }

  @override
  Future<void> diagnostic(String code, String detail) async {
    diagnostics.add(code);
  }

  @override
  Future<void> cancelPoint(String reason) async {
    for (final point in points) {
      if (point['status'] == 'running') {
        point['status'] = 'invalid';
        point['reason'] = reason;
      }
    }
  }

  @override
  Future<Map<String, dynamic>> snapshot() async => {
    'run': {
      'run_id': 'coded-range-test',
      'status': ended
          ? 'finished'
          : prepared
          ? 'prepared'
          : 'running',
      'source_latitude': sourceKnown ? 3.5 : null,
      'source_longitude': sourceKnown ? 98.5 : null,
      'source_position_method': 'manual',
      'ends_at_ms': 2200000,
    },
    'last_receive': null,
    'last_position': fix,
    'receives': [],
    'points': points,
  };
}

void main() {
  late MemoryPilot pilot;
  setUp(() {
    pilot = MemoryPilot();
  });

  Future<void> mount(
    WidgetTester tester, {
    bool scanner = true,
    Future<Stream<RangeFix>> Function()? locations,
    bool map = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RangeTestTab(
            service: pilot,
            capabilities: () async => {'nativeScanActive': scanner},
            screenAwake: (_) async {},
            showMap: map,
            locationStream:
                locations ?? () async => const Stream<RangeFix>.empty(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
    'permission denied: receives remain visible, distance unavailable',
    (tester) async {
      await mount(
        tester,
        locations: () async => throw StateError('permission denied'),
      );
      expect(find.textContaining('permission denied'), findsOneWidget);
      expect(find.text('Belum ada penerimaan baru'), findsOneWidget);
      expect(find.text('Tidak tersedia'), findsWidgets);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets('GPS stream failure allows retry without claiming out of range', (
    tester,
  ) async {
    final stream = StreamController<RangeFix>.broadcast();
    var attempts = 0;
    await mount(
      tester,
      locations: () async {
        attempts++;
        return stream.stream;
      },
    );
    stream.addError(StateError('GPS lost'));
    await tester.pump();
    await tester.scrollUntilVisible(find.textContaining('GPS lost'), 300);
    expect(find.textContaining('GPS lost'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Coba lokasi kembali'));
    await tester.tap(find.byTooltip('Coba lokasi kembali'));
    await tester.pump();
    expect(attempts, 2);
    await unmount(tester);
    await stream.close();
  });

  testWidgets('scanner failure cancels running point with explicit reason', (
    tester,
  ) async {
    pilot.points.add({
      'status': 'running',
      'planned_end_ms': 1060000,
      'started_at_ms': 1000000,
      'receive_count': 0,
      'receive_result': 'no_receive_observed',
    });
    await mount(tester, scanner: false);
    expect(find.text('Scanner bermasalah'), findsOneWidget);
    expect(pilot.points.single['reason'], 'SCANNER_UNAVAILABLE');
    await unmount(tester);
  });

  testWidgets('background cancels point, no location background tracking', (
    tester,
  ) async {
    pilot.points.add({
      'status': 'running',
      'planned_end_ms': 1060000,
      'started_at_ms': 1000000,
      'receive_count': 0,
      'receive_result': 'no_receive_observed',
    });
    await mount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(pilot.points.single['reason'], 'APP_BACKGROUND');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await unmount(tester);
  });

  testWidgets('completed observation is distinct from session/source stop', (
    tester,
  ) async {
    pilot.points.add({
      'status': 'completed',
      'receive_count': 0,
      'receive_result': 'no_receive_observed',
    });
    await mount(tester);
    await tester.scrollUntilVisible(find.text('Pengamatan Selesai'), 400);
    expect(
      find.textContaining('Tidak ada penerimaan teramati'),
      findsOneWidget,
    );
    expect(find.text('Sesi selesai'), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('offline map can hide tiles without hiding source and RX state', (
    tester,
  ) async {
    await mount(tester, map: true);
    await tester.ensureVisible(find.byTooltip('Tile peta'));
    await tester.tap(find.byTooltip('Tile peta'));
    await tester.pump();
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(TileLayer), findsNothing);
    tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .jumpTo(0);
    await tester.pump();
    expect(find.text('Belum ada penerimaan baru'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets(
    'map pin remains available when GPS and source position are absent',
    (tester) async {
      pilot.sourceKnown = false;
      pilot.prepared = true;
      await mount(
        tester,
        map: true,
        locations: () async => throw StateError('GPS unavailable'),
      );
      await tester.ensureVisible(find.byTooltip('Tile peta'));
      await tester.tap(find.byTooltip('Tile peta'));
      await tester.pump();
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(
        tester.widget<FlutterMap>(find.byType(FlutterMap)).options.onTap,
        isNotNull,
      );
      expect(pilot.sourceKnown, isFalse);
      await unmount(tester);
    },
  );

  for (final width in [320.0, 1200.0]) {
    testWidgets('range controls fit viewport $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      pilot.fix = const RangeFix(1000000, 3.5001, 98.5001, 19.9).toJson();
      await mount(tester);
      await tester.scrollUntilVisible(find.text('Mulai Pengamatan'), 300);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }
}
