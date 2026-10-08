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
import 'package:pkmproject/services/neighbor_runtime.dart';
import 'package:pkmproject/services/neighbor_transport.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CallbackLogger extends ExperimentLogger {
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
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('id.ac.usu.resqmesh/mesh');
  final runtime = NeighborRuntime.instance;
  late Database db;
  late RelayQueueService queue;
  late BleAdvertiserService advertiser;
  late FixedExperimentClock clock;
  late SOSMessage message;
  late Completer<bool> callback;
  late Completer<void> requested;
  var withMessage = false;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
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
    clock = FixedExperimentClock(wallMs: 1791057171347, monotonicMs: 1000);
    message = SOSMessage(
      id: 'adaptive-sos',
      senderId: 'source',
      senderCrc: 123,
      content: 'SOS',
      latitude: 3.5,
      longitude: 98.6,
      createdAt: clock.wallMs,
      updatedAt: clock.wallMs,
      hopCount: 1,
    );
    callback = Completer<bool>();
    requested = Completer<void>();
    withMessage = false;
    await runtime.configure({
      'transport_profile': NeighborRuntime.profile,
      'node_id': 'android-source',
      'mode': 'trickle_neighbor_status',
      'allowed_transmitters': [3],
      'neighbor_status_policy': 'adaptive_v2',
      'discovery_jitter_ms': 0,
    });
    await runtime.startTrial('adaptive-callback');
    runtime.statusSchedule!.start(0, 0);
    queue = RelayQueueService(
      database: db,
      clock: clock,
      mode: ForwardingMode.trickleNeighborStatus,
      random: Random(1),
    );
    advertiser = BleAdvertiserService.forTesting(
      relayQueue: queue,
      experimentLogger: _CallbackLogger(),
      clock: clock,
      readMessage: (id) async => message,
      readNeighborInventory: () async =>
          withMessage ? [message.stateIdentity] : [],
    );
    advertiser.claimSchedulerOwnership();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startNativeBleAdvertising') {
            if (!requested.isCompleted) requested.complete();
            return callback.future;
          }
          return switch (call.method) {
            'isNativeBleAdvertising' => advertiser.isAdvertising,
            'stopNativeBleAdvertising' => true,
            'getNativeBleAdvertisingStatus' => {
              'active': advertiser.isAdvertising,
            },
            _ => null,
          };
        });
  });
  tearDown(() async {
    if (!callback.isCompleted) callback.complete(false);
    advertiser.releaseSchedulerOwnership();
    await advertiser.stopAdvertising();
    advertiser.dispose();
    await runtime.configure({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
  });

  for (final success in [false, true]) {
    test(
      'STATUS $success callback advances schedule only after native result',
      () async {
        final work = advertiser.advertiseLatestOrStop(
          continueScheduling: false,
        );
        await requested.future.timeout(const Duration(seconds: 5));
        expect(runtime.nextStatusAt, 1000);
        expect(advertiser.isAdvertising, isFalse);
        callback.complete(success);
        await work;
        expect(advertiser.isAdvertising, success);
        expect(runtime.nextStatusAt, success ? 5000 : 2000);
        expect(await queue.queueSize(), 0);
        if (!success) {
          runtime.statusStarted([], 2000);
          expect(runtime.nextStatusAt, 6000);
        }
      },
    );
    test(
      'DATA $success callback preserves durable SOS and only success coalesces STATUS',
      () async {
        withMessage = true;
        runtime.statusSchedule!.statusSucceeded([], 1000, false, 0);
        await queue.storeAndQueueSos(message: message, nextEligibleAt: 1000);
        final state = (await queue.trickleStateFor(message.id))!;
        clock.monotonicMs = state.transmitAt;
        await runtime.synchronizeStatus(
          1000,
          readInventory: () async => [message.stateIdentity],
        );
        final pending = runtime.nextStatusAt;
        expect(pending, 11000);
        final work = advertiser.advertiseLatestOrStop(
          continueScheduling: false,
        );
        await requested.future.timeout(const Duration(seconds: 5));
        expect(runtime.nextStatusAt, pending);
        expect((await queue.getAllItems()).single.relayCount, 0);
        callback.complete(success);
        await work;
        expect(runtime.statusSchedule!.firstForwardComplete, success);
        expect((await queue.getAllItems()).single.relayCount, success ? 1 : 0);
        expect(
          runtime.nextStatusAt,
          success ? clock.monotonicMs + 15000 : pending,
        );
        expect(await db.query('sos_messages'), hasLength(1));
        expect(
          runtime.controller!.snapshot(
            message.stateIdentity,
            clock.monotonicMs,
          ),
          isEmpty,
        );
      },
    );
  }
  test(
    'STATUS grace fallback still advertises when DATA has never succeeded',
    () async {
      withMessage = true;
      runtime.statusSchedule!.statusSucceeded([], 1000, false, 0);
      await runtime.synchronizeStatus(
        1000,
        readInventory: () async => [message.stateIdentity],
      );
      clock.monotonicMs = 11000;
      final work = advertiser.advertiseLatestOrStop(continueScheduling: false);
      await requested.future.timeout(const Duration(seconds: 5));
      callback.complete(true);
      await work;
      expect(runtime.nextStatusAt, 26000);
      expect(runtime.statusSchedule!.firstForwardComplete, isFalse);
    },
  );
  test(
    'scanner resume restarts discovery and partial STATUS is not whole inventory',
    () async {
      final states = List.generate(
        9,
        (i) => SOSMessage(
          id: 's$i',
          senderId: 's$i',
          senderCrc: i + 1,
          content: 'SOS',
          latitude: 0,
          longitude: 0,
          createdAt: clock.wallMs,
          updatedAt: clock.wallMs,
        ).stateIdentity,
      );
      await runtime.synchronizeStatus(1000, readInventory: () async => states);
      final frame = await runtime.statusFrame();
      expect(frame.inventory, hasLength(NeighborFrame.capacity));
      expect(frame.complete, isFalse);
      for (final state in states.take(8)) {
        await runtime.dataStarted(state, 2000);
      }
      expect(runtime.statusSchedule!.firstForwardComplete, isFalse);
      runtime.restartStatus(3000);
      await runtime.synchronizeStatus(3000, readInventory: () async => states);
      expect(runtime.nextStatusAt, 4000);
      expect(runtime.statusSchedule!.reason, 'DISCOVERY');
    },
  );
}
