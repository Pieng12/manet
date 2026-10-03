import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TimingLogger extends ExperimentLogger {
  _TimingLogger(this.clock);

  final FixedExperimentClock clock;
  final recorded = <Map<String, Object?>>[];
  final reached = Completer<void>();
  final release = Completer<void>();
  final requestRecorded = Completer<void>();
  final secondWakeScheduled = Completer<void>();
  int scheduledWakes = 0;
  String? blockEvent;
  String? failEvent;
  int loggingCostMs = 0;

  @override
  Future<void> logEvent({
    required String eventType,
    required String deviceId,
    String? messageId,
    int? senderCrc,
    int? hopCount,
    int? hopIn,
    int? hopOut,
    int? rssi,
    String? payloadHash,
    int? eventTimestampMs,
    int? elapsedRealtimeMs,
    int? protocolTimestampMs,
    String? packetType,
    String? status,
    Map<String, dynamic>? detail,
    String? eventKey,
    String? messageKey,
    String? stateIdentity,
    String? observationId,
    String? burstId,
  }) async {
    recorded.add({
      'type': eventType,
      'wall': eventTimestampMs,
      'monotonic': elapsedRealtimeMs,
      'detail': detail,
    });
    if (eventType == ExperimentEventTypes.advertiseBurstRequested &&
        !requestRecorded.isCompleted) {
      requestRecorded.complete();
    }
    if (eventType == ExperimentEventTypes.queueWakeScheduled &&
        ++scheduledWakes == 2) {
      secondWakeScheduled.complete();
    }
    if (eventType == blockEvent && !reached.isCompleted) {
      clock.monotonicMs += loggingCostMs;
      clock.wallMs += loggingCostMs;
      reached.complete();
      await release.future;
    }
    if (eventType == failEvent) throw StateError('diagnostic storage failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  const channel = MethodChannel('id.ac.usu.resqmesh/mesh');
  const start = 287532;
  const transmit = 295522;
  const end = 295532;
  late Database db;
  late FixedExperimentClock clock;
  late _TimingLogger logger;
  late RelayQueueService queue;
  late BleAdvertiserService advertiser;
  late SOSMessage message;
  late Completer<int> nativeStarted;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    for (final sql in [
      createSosMessagesTableSql,
      createRelayQueueTableSql,
      createAckTombstonesTableSql,
      createTrickleStatesTableSql,
      createTrickleObservationsTableSql,
      createExperimentSessionsTableSql,
      createExperimentTrialsTableSql,
      createExperimentEventsTableSql,
    ]) {
      await db.execute(sql);
    }
    clock = FixedExperimentClock(wallMs: 1791057171347, monotonicMs: start);
    logger = _TimingLogger(clock);
    nativeStarted = Completer<int>();
    message = SOSMessage(
      id: 'research-boundary',
      senderId: 'source',
      senderCrc: 123,
      content: 'SOS',
      latitude: 3.5,
      longitude: 98.6,
      createdAt: clock.wallMs,
      updatedAt: clock.wallMs,
      hopCount: 1,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startNativeBleAdvertising') {
            if (!nativeStarted.isCompleted) {
              nativeStarted.complete(clock.monotonicMs);
            }
            return true;
          }
          return switch (call.method) {
            'isNativeBleAdvertising' => true,
            'stopNativeBleAdvertising' => true,
            'getNativeBleAdvertisingStatus' => {'active': true},
            _ => null,
          };
        });
  });

  tearDown(() async {
    if (!logger.release.isCompleted) logger.release.complete();
    advertiser.releaseSchedulerOwnership();
    await advertiser.stopAdvertising();
    advertiser.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
  });

  Future<void> prepare(ForwardingMode mode) async {
    queue = RelayQueueService(
      database: db,
      clock: clock,
      mode: mode,
      random: Random(1),
    );
    await queue.storeAndQueueSos(message: message, nextEligibleAt: start);
    if (mode.usesTrickle) {
      await db.update('trickle_states', {'transmit_at': transmit});
      await db.update('relay_queue', {'next_eligible_at': transmit});
    }
    advertiser = BleAdvertiserService.forTesting(
      relayQueue: queue,
      experimentLogger: logger,
      clock: clock,
      readMessage: (id) async => message,
    );
    advertiser.claimSchedulerOwnership();
    clock.monotonicMs = transmit;
    clock.wallMs += transmit - start;
  }

  for (final mode in [
    ForwardingMode.trickle,
    ForwardingMode.trickleNoSuppression,
  ]) {
    test(
      '$mode slow selection diagnostics cannot consume the final 10 ms',
      () async {
        await prepare(mode);
        logger.blockEvent = ExperimentEventTypes.schedulerPacketSelected;
        logger.loggingCostMs = 55;
        final tick = advertiser.advertiseLatestOrStop(
          continueScheduling: false,
        );
        await logger.reached.future.timeout(const Duration(seconds: 5));
        expect(await nativeStarted.future, transmit);
        expect(clock.monotonicMs, greaterThan(end));
        final item = (await queue.getItem(message.id, 'sos'))!;
        expect(item.relayCount, 1);
        expect(item.lastRelayedAt, transmit);
        logger.release.complete();
        await tick;
        final allowed = logger.recorded.singleWhere(
          (e) => e['type'] == ExperimentEventTypes.trickleTxAllowed,
        );
        expect(allowed['monotonic'], transmit);
        final requested = logger.recorded.singleWhere(
          (e) => e['type'] == ExperimentEventTypes.advertiseBurstRequested,
        );
        expect(requested['monotonic'], transmit);
        expect(
          logger.recorded.where(
            (e) => e['type'] == ExperimentEventTypes.trickleTxSuppressed,
          ),
          isEmpty,
        );
      },
    );

    test(
      '$mode wake timer progresses while scheduled diagnostics are blocked',
      () async {
        await prepare(mode);
        clock.monotonicMs = transmit - 1;
        clock.wallMs--;
        logger.blockEvent = ExperimentEventTypes.waitingNextEligible;
        final tick = advertiser.advertiseLatestOrStop();
        await logger.reached.future.timeout(const Duration(seconds: 5));
        clock.monotonicMs = transmit;
        clock.wallMs++;
        expect(
          await nativeStarted.future.timeout(const Duration(seconds: 5)),
          transmit,
        );
        logger.release.complete();
        await tick;
        await logger.requestRecorded.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
        await advertiser.stopAdvertising();
      },
    );

    test(
      '$mode diagnostic failure cannot undo successful advertising',
      () async {
        await prepare(mode);
        logger.failEvent = ExperimentEventTypes.schedulerPacketSelected;
        await advertiser.advertiseLatestOrStop(continueScheduling: false);
        expect(await nativeStarted.future, transmit);
        expect((await queue.getItem(message.id, 'sos'))!.relayCount, 1);
        expect(advertiser.isAdvertising, isTrue);
      },
    );

    test(
      '$mode busy wake requests coalesce and get a fresh queue selection',
      () async {
        await prepare(mode);
        final reading = Completer<void>();
        final releaseRead = Completer<void>();
        advertiser.dispose();
        advertiser = BleAdvertiserService.forTesting(
          relayQueue: queue,
          experimentLogger: logger,
          clock: clock,
          readMessage: (id) async {
            reading.complete();
            await releaseRead.future;
            return message;
          },
        );
        advertiser.claimSchedulerOwnership();
        final firstTick = advertiser.advertiseLatestOrStop();
        await reading.future;
        clock.monotonicMs = end + 45;
        clock.wallMs += 55;
        await advertiser.advertiseLatestOrStop();
        await advertiser.advertiseLatestOrStop();
        releaseRead.complete();
        await firstTick;
        await logger.secondWakeScheduled.future.timeout(
          const Duration(seconds: 5),
        );
        await Future<void>.delayed(Duration.zero);
        expect(nativeStarted.isCompleted, isFalse);
        expect(logger.scheduledWakes, 2);
        expect((await queue.trickleStateFor(message.id))!.intervalMs, 16000);
        expect((await queue.getItem(message.id, 'sos'))!.relayCount, 0);
      },
    );

    test(
      '$mode genuinely late callback remains missed, never a late TX',
      () async {
        await prepare(mode);
        await ExperimentLogger(database: db).ensureSession(deviceId: 'source');
        clock.monotonicMs = end + 45;
        clock.wallMs += 55;
        await advertiser.advertiseLatestOrStop(continueScheduling: false);
        expect(nativeStarted.isCompleted, isFalse);
        final missed = await db.query(
          'experiment_events',
          where: 'event_type = ?',
          whereArgs: [ExperimentEventTypes.trickleTxMissed],
        );
        expect(missed, hasLength(1));
        expect(missed.single['elapsed_realtime_ms'], end + 45);
        expect((await queue.trickleStateFor(message.id))!.intervalMs, 16000);
        final advanced = logger.recorded.singleWhere(
          (e) => e['type'] == ExperimentEventTypes.trickleIntervalStarted,
        );
        expect(advanced['monotonic'], end + 45);
        expect(advanced['wall'], clock.wallMs);
      },
    );

    test('$mode still uses c and suppression flag at the deadline', () async {
      await prepare(mode);
      await db.update('trickle_states', {'consistency_count': 1});
      await advertiser.advertiseLatestOrStop(continueScheduling: false);
      expect(nativeStarted.isCompleted, !mode.suppressionEnabled);
      expect(
        logger.recorded.any(
          (e) => e['type'] == ExperimentEventTypes.trickleTxSuppressed,
        ),
        mode.suppressionEnabled,
      );
      expect(
        (await queue.getItem(message.id, 'sos'))!.relayCount,
        mode.suppressionEnabled ? 0 : 1,
      );
    });
  }

  test('Basic keeps selection diagnostics before native advertising', () async {
    await prepare(ForwardingMode.basicFlooding);
    logger.blockEvent = ExperimentEventTypes.schedulerPacketSelected;
    logger.loggingCostMs = 55;
    final tick = advertiser.advertiseLatestOrStop(continueScheduling: false);
    await logger.reached.future.timeout(const Duration(seconds: 5));
    expect(nativeStarted.isCompleted, isFalse);
    logger.release.complete();
    await tick;
    expect(await nativeStarted.future, transmit + 55);
    expect(
      logger.recorded.where(
        (e) => (e['type'] as String).startsWith('TRICKLE_'),
      ),
      isEmpty,
    );
  });
}
