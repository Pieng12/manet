import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/trickle_state.dart';
import 'package:pkmproject/services/database_helper.dart';
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
          observationId: 'obs-1',
          observerKey: 'AA:BB',
          nowMs: now + 100,
        ),
        isTrue,
      );
      expect(
        await scheduler.recordConsistentObservation(
          messageId: state.messageId,
          observationId: 'obs-1',
          observerKey: 'AA:BB',
          nowMs: now + 200,
        ),
        isFalse,
      );

      final stored = await scheduler.stateFor(state.messageId);
      expect(stored!.consistencyCount, 1);
    },
  );

  test('different observation from same observer increments c again', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );

    for (final observation in ['obs-1', 'obs-2']) {
      expect(
        await scheduler.recordConsistentObservation(
          messageId: state.messageId,
          observationId: observation,
          observerKey: 'AA:BB',
          nowMs: now + 100,
        ),
        isTrue,
      );
    }

    final stored = await scheduler.stateFor(state.messageId);
    expect(stored!.consistencyCount, 2);
  });

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
        observationId: 'obs-$observer',
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

  test('24 hour sleep normalizes safely to Imax interval', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );
    final afterSleep = now + const Duration(hours: 24).inMilliseconds;

    final normalized = await scheduler.normalizeInterval(
      messageId: state.messageId,
      nowMs: afterSleep,
    );

    expect(normalized.intervalMs, 64000);
    expect(normalized.intervalStartedAt, lessThanOrEqualTo(afterSleep));
    expect(normalized.intervalEndAt, greaterThan(afterSleep));
    expect(normalized.intervalEndAt, normalized.intervalStartedAt + 64000);
    expect(
      normalized.transmitAt,
      inInclusiveRange(
        normalized.intervalStartedAt + normalized.intervalMs ~/ 2,
        normalized.intervalEndAt - 1,
      ),
    );
  });

  test(
    'transmit time stays in half-open range for odd intervals and Imax',
    () async {
      for (final intervalMs in [5, 7, 64000]) {
        for (var seed = 0; seed < 20; seed++) {
          final localScheduler = TrickleScheduler(
            database: db,
            random: Random(seed),
            imin: Duration(milliseconds: intervalMs),
            imax: Duration(milliseconds: intervalMs),
            redundancyConstant: 2,
          );
          final state = await localScheduler.reset(
            messageId: 'range-$intervalMs-$seed',
            nowMs: now + seed,
            reason: 'range_test',
          );

          expect(
            state.transmitAt,
            inInclusiveRange(
              state.intervalStartedAt + state.intervalMs ~/ 2,
              state.intervalEndAt - 1,
            ),
          );
          expect(state.transmitAt, isNot(state.intervalEndAt));
        }
      }
    },
  );

  test(
    'redundancy constant k controls allow versus suppress threshold',
    () async {
      Future<TrickleTransmitDecisionType> decisionFor({
        required int k,
        required int c,
      }) async {
        final localScheduler = TrickleScheduler(
          database: db,
          random: Random(k * 10 + c),
          imin: const Duration(seconds: 8),
          imax: const Duration(seconds: 8),
          redundancyConstant: k,
        );
        final state = await localScheduler.reset(
          messageId: 'k-$k-c-$c',
          nowMs: now,
          reason: 'k_test',
        );
        for (var i = 0; i < c; i++) {
          await localScheduler.recordConsistentObservation(
            messageId: state.messageId,
            observationId: 'obs-$i',
            observerKey: 'ble:$i',
            nowMs: now + i + 1,
          );
        }
        return (await localScheduler.handleQueueEvent(
          messageId: state.messageId,
          nowMs: state.transmitAt,
        )).type;
      }

      expect(
        await decisionFor(k: 1, c: 0),
        TrickleTransmitDecisionType.allowTransmit,
      );
      expect(
        await decisionFor(k: 1, c: 1),
        TrickleTransmitDecisionType.suppressTransmit,
      );
      expect(
        await decisionFor(k: 2, c: 1),
        TrickleTransmitDecisionType.allowTransmit,
      );
      expect(
        await decisionFor(k: 2, c: 2),
        TrickleTransmitDecisionType.suppressTransmit,
      );
      expect(
        await decisionFor(k: 3, c: 2),
        TrickleTransmitDecisionType.allowTransmit,
      );
      expect(
        await decisionFor(k: 3, c: 3),
        TrickleTransmitDecisionType.suppressTransmit,
      );
    },
  );

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

  test('incoming inconsistency at Imin does not restart interval', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );

    final result = await scheduler.handleInconsistentInformation(
      messageId: state.messageId,
      nowMs: now + 1000,
      reason: 'incoming_inconsistent_state',
    );

    expect(result.resetPerformed, isFalse);
    expect(result.reason, 'already_at_imin');
    expect(result.state.intervalStartedAt, state.intervalStartedAt);
    expect(result.state.transmitAt, state.transmitAt);
  });

  test('incoming inconsistency above Imin resets to Imin', () async {
    var state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );
    state = await scheduler.advanceInterval(
      messageId: state.messageId,
      nowMs: state.intervalEndAt,
    );

    final result = await scheduler.handleInconsistentInformation(
      messageId: state.messageId,
      nowMs: state.intervalStartedAt + 1000,
      reason: 'incoming_inconsistent_state',
    );

    expect(result.resetPerformed, isTrue);
    expect(result.state.intervalMs, 8000);
    expect(result.state.intervalStartedAt, state.intervalStartedAt + 1000);
  });

  test(
    'late observation normalizes expired intervals before incrementing c',
    () async {
      final state = await scheduler.reset(
        messageId: 'sos-1',
        nowMs: now,
        reason: 'new_state',
      );
      final lateNow = now + const Duration(seconds: 30).inMilliseconds;

      expect(
        await scheduler.recordConsistentObservation(
          messageId: state.messageId,
          observationId: 'late-obs',
          observerKey: 'AA:BB',
          nowMs: lateNow,
        ),
        isTrue,
      );

      final stored = await scheduler.stateFor(state.messageId);
      expect(stored!.intervalStartedAt, greaterThan(state.intervalStartedAt));
      expect(stored.intervalEndAt, greaterThan(lateNow));
      expect(stored.intervalMs, lessThanOrEqualTo(64000));
      expect(stored.consistencyCount, 1);
    },
  );

  test(
    'old interval observations are pruned after interval advances',
    () async {
      final state = await scheduler.reset(
        messageId: 'sos-1',
        nowMs: now,
        reason: 'new_state',
      );
      await scheduler.recordConsistentObservation(
        messageId: state.messageId,
        observationId: 'old-obs',
        observerKey: 'AA:BB',
        nowMs: now + 100,
      );

      final lateNow = now + const Duration(seconds: 30).inMilliseconds;
      await scheduler.recordConsistentObservation(
        messageId: state.messageId,
        observationId: 'new-obs',
        observerKey: 'AA:BB',
        nowMs: lateNow,
      );

      final rows = await db.query(
        'trickle_observations',
        orderBy: 'observation_id ASC',
      );
      expect(rows.map((row) => row['observation_id']), ['new-obs']);
    },
  );

  test('delayed old observation does not increment current interval', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );
    final lateNow = now + const Duration(seconds: 30).inMilliseconds;
    await scheduler.recordConsistentObservation(
      messageId: state.messageId,
      observationId: 'current-obs',
      observerKey: 'AA:BB',
      nowMs: lateNow,
    );
    final advanced = await scheduler.stateFor(state.messageId);
    expect(advanced!.intervalStartedAt, greaterThan(state.intervalStartedAt));

    final recorded = await scheduler.recordConsistentObservation(
      messageId: state.messageId,
      observationId: 'old-delayed-obs',
      observerKey: 'AA:BB',
      nowMs: now + 100,
    );

    final stored = await scheduler.stateFor(state.messageId);
    final rows = await db.query('trickle_observations');
    expect(recorded, isFalse);
    expect(stored!.consistencyCount, 1);
    expect(
      rows.map((row) => row['observation_id']),
      isNot(contains('old-delayed-obs')),
    );
  });

  test('persisted trickle state survives scheduler reconstruction', () async {
    final state = await scheduler.reset(
      messageId: 'sos-1',
      nowMs: now,
      reason: 'new_state',
    );
    final restored = await TrickleScheduler(database: db).stateFor('sos-1');

    expect(restored!.messageId, state.messageId);
    expect(restored.transmitAt, state.transmitAt);
  });

  test(
    'legacy observer-key observation schema migrates non-destructively',
    () async {
      await db.execute('DROP TABLE trickle_observations');
      await db.execute('''
CREATE TABLE trickle_observations (
  message_id TEXT NOT NULL,
  interval_started_at INTEGER NOT NULL,
  observer_key TEXT NOT NULL,
  first_seen_at INTEGER NOT NULL,
  PRIMARY KEY(message_id, interval_started_at, observer_key)
)
''');
      await db.insert('trickle_observations', {
        'message_id': 'sos-legacy',
        'interval_started_at': now,
        'observer_key': 'ble:AA',
        'first_seen_at': now + 1,
      });

      await DatabaseHelper.ensureTrickleObservationSchema(db);

      final columns = await db.rawQuery(
        'PRAGMA table_info(trickle_observations)',
      );
      final columnNames = columns.map((row) => row['name']).toSet();
      expect(columnNames, contains('observation_id'));

      final rows = await db.query('trickle_observations');
      expect(rows, hasLength(1));
      expect(rows.single['observer_key'], 'ble:AA');
      expect(rows.single['observation_id'], 'sos-legacy:$now:ble:AA');
    },
  );
}
