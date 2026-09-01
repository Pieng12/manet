import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/trickle_state.dart';
import 'package:pkmproject/services/trickle_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late TrickleScheduler scheduler;
  late int now;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(createTrickleStatesTableSql);
    await db.execute(createTrickleObservationsTableSql);
    scheduler = TrickleScheduler(
      database: db,
      random: Random(7),
      imin: const Duration(seconds: 8),
      imax: const Duration(seconds: 64),
      redundancyConstant: 2,
    );
    now = DateTime.utc(2026, 9, 1, 12).millisecondsSinceEpoch;
  });

  tearDown(() async {
    await db.close();
  });

  test('reset starts Imin interval and chooses t in [I/2, I)', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );

    expect(state.intervalMs, 8000);
    expect(state.consistencyCount, 0);
    expect(state.phase, TricklePhase.waitingTransmit);
    expect(state.transmitAt, inInclusiveRange(now + 4000, now + 7999));
    expect(state.intervalEndAt, now + 8000);
  });

  test(
    'consistent observation increments c once per observer per interval',
    () async {
      final state = await scheduler.reset(
        messageId: 'sos-1',
        nowMs: now,
        reason: 'new_state',
      );

      expect(
        await scheduler.recordConsistentObservation(
          messageId: state.messageId,
          observerKey: 'AA:BB',
          nowMs: now + 100,
        ),
        isTrue,
      );
      expect(
        await scheduler.recordConsistentObservation(
          messageId: state.messageId,
          observerKey: 'AA:BB',
          nowMs: now + 200,
        ),
        isFalse,
      );

      final stored = await scheduler.stateFor(state.messageId);
      expect(stored!.consistencyCount, 1);
    },
  );

  test('transmission is allowed when c is below k', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );

    final decision = await scheduler.handleQueueEvent(
      messageId: state.messageId,
      nowMs: state.transmitAt,
    );

    expect(decision.type, TrickleTransmitDecisionType.allowTransmit);
    expect(decision.nextEligibleAt, state.intervalEndAt);
  });

  test('transmission is suppressed when c reaches k', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );
    for (final observer in ['n1', 'n2']) {
      await scheduler.recordConsistentObservation(
        messageId: state.messageId,
        observerKey: observer,
        nowMs: now + 100,
      );
    }

    final decision = await scheduler.handleQueueEvent(
      messageId: state.messageId,
      nowMs: state.transmitAt,
    );

    expect(decision.type, TrickleTransmitDecisionType.suppressTransmit);
    expect(decision.shouldAdvertise, isFalse);
    expect(decision.nextEligibleAt, state.intervalEndAt);
  });

  test('interval doubles at interval end and caps at Imax', () async {
    var state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );

    for (final expected in [16000, 32000, 64000, 64000]) {
      state = await scheduler.advanceInterval(
        messageId: state.messageId,
        nowMs: state.intervalEndAt,
      );
      expect(state.intervalMs, expected);
      expect(state.consistencyCount, 0);
      expect(
        state.transmitAt,
        inInclusiveRange(
          state.intervalStartedAt + expected ~/ 2,
          state.intervalStartedAt + expected - 1,
        ),
      );
    }
  });

  test('new inconsistent state resets interval to Imin', () async {
    var state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );
    state = await scheduler.advanceInterval(
      messageId: state.messageId,
      nowMs: state.intervalEndAt,
    );
    expect(state.intervalMs, 16000);

    final reset = await scheduler.reset(
      messageId: state.messageId,
      nowMs: state.intervalStartedAt + 1000,
      reason: 'better_hop',
    );
    expect(reset.intervalMs, 8000);
    expect(reset.lastResetReason, 'better_hop');
  });
}
