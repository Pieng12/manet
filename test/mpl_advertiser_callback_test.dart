import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/mpl_scheduler.dart';
import 'package:pkmproject/services/neighbor_runtime.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'mpl_scheduler_test.dart' show ZeroRandom;

class CallbackLogger extends ExperimentLogger {
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
  var nativeRequests = 0;
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
    ]) {
      await db.execute(sql);
    }
    clock = FixedExperimentClock(wallMs: 1791057171347, monotonicMs: 1000);
    message = SOSMessage(
      id: 'mpl-sos',
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
    nativeRequests = 0;
    withMessage = false;
    await runtime.configure({
      'transport_profile': NeighborRuntime.profile,
      'node_id': 'android-source',
      'mode': 'trickle_mpl',
      'allowed_transmitters': [3],
      'scheduler_semantics': MplScheduler.semantics,
    });
    await runtime.startTrial('mpl-callback');
    runtime.mpl = MplScheduler(scope: runtime.scope, random: ZeroRandom())
      ..discover(1000);
    runtime.controller = runtime.mpl!.neighbors;
    queue = RelayQueueService(
      database: db,
      clock: clock,
      mode: ForwardingMode.trickleMpl,
    );
    advertiser = BleAdvertiserService.forTesting(
      relayQueue: queue,
      experimentLogger: CallbackLogger(),
      clock: clock,
      readMessage: (_) async => message,
      readNeighborInventory: () async =>
          withMessage ? [message.stateIdentity] : [],
    );
    advertiser.claimSchedulerOwnership();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startNativeBleAdvertising') {
            nativeRequests++;
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

  test(
    'S1 activation renews exhausted repair without clearing durable state',
    () async {
      final first = await runtime.statusFrame();
      final a = MplScheduler(scope: runtime.scope, random: ZeroRandom())
        ..discover(0);
      a.sync([message.stateIdentity], 0);
      a.receive(first, 100, 100);
      final t = a.data[message.stateIdentity.value]!;
      expect(a.dataDue(t.key, 4000), true);
      a.dataResult(t.key, t.generation, 4000, true);
      a.tick(8100);
      expect(a.dataDue(t.key, t.transmit), true);
      a.dataResult(t.key, t.generation, t.transmit, true);
      expect(a.repairProtected(t.key, 13000), false);
      final unchanged = await runtime.statusFrame();
      a.receive(unchanged, 30000, 30000);
      expect(a.repairProtected(t.key, 30000), false);

      final retained = StateIdentity(
        messageKey: MessageKey(
          senderCrc: 456,
          protocolTimestampMs:
              message.stateIdentity.messageKey.protocolTimestampMs,
        ),
        statusIndex: 1,
        isAck: false,
        fromServer: false,
      );
      runtime.mpl!.sync([retained], 30000);
      await runtime.participationActivated(30100, reactivated: true);
      expect(runtime.mpl!.buffer.containsKey(retained.value), true);
      final activated = await runtime.frame(inventory: [retained]);
      expect(activated.boot, first.boot + 1);
      expect(activated.sequence, 1);
      expect(
        (await SharedPreferences.getInstance()).getInt('neighbor_incarnation'),
        activated.boot,
      );
      a.receive(activated, 30100, 30100);
      t.consistent(30200, 30200);
      expect(t.c, 1);
      expect(a.repairProtected(t.key, 30200), true);
      expect(a.dataDue(t.key, t.transmit), true);
      expect(a.receive(unchanged, 30300, 30300), false);
    },
  );

  test(
    'repeated confirmed ON does not change boot, sequence or discovery',
    () async {
      final first = await runtime.frame();
      final generation = runtime.mpl!.control.generation;
      await runtime.participationActivated(30000, reactivated: false);
      final second = await runtime.frame();
      expect(second.boot, first.boot);
      expect(second.sequence, first.sequence + 1);
      expect(runtime.mpl!.control.generation, generation);
    },
  );

  test(
    'activation incarnation overflow fails closed without wrap or discovery',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('neighbor_incarnation', 0xffffffff);
      final generation = runtime.mpl!.control.generation;
      await expectLater(
        runtime.participationActivated(30000, reactivated: true),
        throwsStateError,
      );
      expect(prefs.getInt('neighbor_incarnation'), 0xffffffff);
      expect(runtime.mpl!.control.generation, generation);
      await expectLater(runtime.frame(), throwsStateError);
    },
  );
  for (final success in [false, true]) {
    test(
      'MPL CONTROL $success consumes bootstrap only after real native success',
      () async {
        clock.monotonicMs = 3000;
        final work = advertiser.advertiseLatestOrStop(
          continueScheduling: false,
        );
        await requested.future.timeout(const Duration(seconds: 5));
        expect(runtime.mpl!.bootstrap, 2);
        expect(advertiser.isAdvertising, false);
        callback.complete(success);
        await work;
        expect(runtime.mpl!.bootstrap, success ? 1 : 2);
        expect(runtime.mpl!.control.pending, !success);
        expect(nativeRequests, 1);
      },
    );
    test('MPL DATA $success durable relay metrics follow callback', () async {
      withMessage = true;
      await queue.storeAndQueueSos(message: message, nextEligibleAt: 1000);
      await runtime.synchronizeStatus(
        1000,
        readInventory: () async => [message.stateIdentity],
      );
      clock.monotonicMs = 5000;
      final work = advertiser.advertiseLatestOrStop(continueScheduling: false);
      await requested.future.timeout(const Duration(seconds: 5));
      expect((await queue.getAllItems()).single.relayCount, 0);
      callback.complete(success);
      await work;
      expect((await queue.getAllItems()).single.relayCount, success ? 1 : 0);
      expect(runtime.mpl!.data[message.stateIdentity.value]!.pending, !success);
      expect(await queue.queueSize(), 1);
      expect(nativeRequests, 1); // due DATA did not also start CONTROL
      if (!success) {
        expect((await queue.getAllItems()).single.nextEligibleAt, 6000);
      }
    });
  }
  test(
    'older CONTROL callback cannot consume newer inventory announcement',
    () async {
      clock.monotonicMs = 3000;
      final work = advertiser.advertiseLatestOrStop(continueScheduling: false);
      await requested.future.timeout(const Duration(seconds: 5));
      runtime.mpl!.sync([message.stateIdentity], 3001);
      callback.complete(true);
      await work;
      expect(runtime.mpl!.bootstrap, 2);
      expect(runtime.mpl!.buffer, contains(message.stateIdentity.value));
    },
  );
  test('UI isolate does not start a second advertising owner', () async {
    advertiser.releaseSchedulerOwnership();
    clock.monotonicMs = 3000;
    await advertiser.advertiseLatestOrStop(continueScheduling: false);
    expect(nativeRequests, 0);
  });
}
