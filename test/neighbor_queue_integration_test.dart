import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/neighbor_runtime.dart';
import 'package:pkmproject/services/neighbor_transport.dart';
import 'package:pkmproject/services/relay_queue_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late RelayQueueService queue;
  final runtime = NeighborRuntime.instance;
  final message = SOSMessage(
    id: 'neighbor-sos',
    senderId: 'source',
    senderCrc: 123,
    content: 'SOS',
    latitude: 3.5,
    longitude: 98.6,
    createdAt: 1780272042000,
    updatedAt: 1780272042000,
    hopCount: 2,
  );
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
      createProcessedBleObservationsTableSql,
    ]) {
      await db.execute(sql);
    }
    await runtime.configure({
      'transport_profile': NeighborRuntime.profile,
      'node_id': 'android-source',
      'mode': 'trickle_neighbor_status',
      'allowed_transmitters': [3, 4],
    });
    await runtime.startTrial('trial-test');
    queue = RelayQueueService(
      database: db,
      mode: ForwardingMode.trickleNeighborStatus,
      random: Random(4),
    );
    message.relayCount = 0;
    message.lastRelayedAt = 0;
    await queue.storeAndQueueSos(message: message, nextEligibleAt: 1000);
  });
  tearDown(() async {
    await runtime.configure({});
    await db.close();
  });
  NeighborFrame have(int sequence) => NeighborFrame(
    type: NeighborFrameType.status,
    transmitter: 3,
    boot: 1,
    sequence: sequence,
    scope: runtime.scope,
    inventory: [message.stateIdentity],
  );

  test(
    'first forward bypasses HAVE, failed start retains state; later HAVE suppresses durable queue',
    () async {
      var state = (await queue.trickleStateFor(message.id))!;
      expect(state.transmitAt, inInclusiveRange(5000, 8999));
      runtime.controller!.observe(have(1), state.transmitAt, state.transmitAt);
      var item = (await queue.getAllItems()).single;
      expect(
        (await queue.handleTrickleQueueEvent(
          item: item,
          nowMs: state.transmitAt,
        )).shouldAdvertise,
        true,
      );
      await queue.markAdvertisingFailed(item, nowMs: state.transmitAt);
      expect((await queue.getAllItems()).single.relayCount, 0);
      expect((await db.query('sos_messages')).single['relay_count'], 0);
      await queue.handleTrickleQueueEvent(
        item: item,
        nowMs: state.intervalEndAt,
      );
      state = (await queue.trickleStateFor(message.id))!;
      runtime.controller!.observe(have(2), state.transmitAt, state.transmitAt);
      item = (await queue.getAllItems()).single;
      expect(
        (await queue.handleTrickleQueueEvent(
          item: item,
          nowMs: state.transmitAt,
        )).shouldAdvertise,
        true,
      );
      await queue.markAdvertisingSucceeded(
        item,
        nowMs: state.transmitAt,
        nextEligibleAtOverride: state.intervalEndAt,
      );
      expect((await queue.getAllItems()).single.relayCount, 1);
      await queue.handleTrickleQueueEvent(
        item: item,
        nowMs: state.intervalEndAt,
      );
      state = (await queue.trickleStateFor(message.id))!;
      runtime.controller!.observe(have(3), state.transmitAt, state.transmitAt);
      item = (await queue.getAllItems()).single;
      expect(
        (await queue.handleTrickleQueueEvent(
          item: item,
          nowMs: state.transmitAt,
        )).shouldAdvertise,
        false,
      );
      expect(queue.neighborDecisionReason(message.id), 'ALL_OBSERVED_HAVE');
      expect(await queue.queueSize(), 1);
      expect(await db.query('sos_messages'), hasLength(1));
      expect(runtime.statusEnabled, true);
    },
  );
  test(
    'forbidden edges and old trial scope cannot become neighbor evidence',
    () {
      final frame = have(1);
      expect(runtime.allows(frame), true);
      expect(
        runtime.allows(
          NeighborFrame(
            type: frame.type,
            transmitter: 5,
            boot: 1,
            sequence: 1,
            scope: runtime.scope,
          ),
        ),
        false,
      );
      expect(
        runtime.allows(
          NeighborFrame(
            type: frame.type,
            transmitter: 3,
            boot: 1,
            sequence: 1,
            scope: runtime.scope + 1,
          ),
        ),
        false,
      );
      expect(runtime.controller!.peers(1000), isEmpty);
    },
  );
  test(
    'new incarnation survives runtime reload and sequence is never reused',
    () async {
      final old = await runtime.frame();
      await runtime.configure({
        'transport_profile': NeighborRuntime.profile,
        'node_id': 'android-source',
        'mode': 'trickle_neighbor_status',
        'allowed_transmitters': [3],
      });
      await runtime.startTrial('trial-test');
      final fresh = await runtime.frame();
      expect(fresh.boot, greaterThan(old.boot));
      expect(fresh.burstIdentity, isNot(old.burstIdentity));
    },
  );
}
