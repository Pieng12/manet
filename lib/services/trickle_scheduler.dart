import 'dart:math';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/trickle_state.dart';
import 'package:sqflite/sqflite.dart';

class TrickleScheduler {
  TrickleScheduler({
    required DatabaseExecutor database,
    Random? random,
    Duration imin = MeshConfig.trickleImin,
    Duration imax = MeshConfig.trickleImax,
    int redundancyConstant = MeshConfig.trickleRedundancyConstant,
  }) : _db = database,
       _random = random ?? Random(),
       _iminMs = imin.inMilliseconds,
       _imaxMs = imax.inMilliseconds,
       _redundancyConstant = redundancyConstant;

  final DatabaseExecutor _db;
  final Random _random;
  final int _iminMs;
  final int _imaxMs;
  final int _redundancyConstant;

  int get iminMs => _iminMs;
  int get imaxMs => _imaxMs;
  int get redundancyConstant => _redundancyConstant;

  Future<TrickleState> reset({
    required String messageId,
    required int nowMs,
    required String reason,
  }) {
    final state = _newInterval(
      messageId: messageId,
      intervalMs: _iminMs,
      nowMs: nowMs,
      resetReason: reason,
    );
    return _upsert(state);
  }

  Future<TrickleState?> stateFor(String messageId) async {
    final rows = await _db.query(
      'trickle_states',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TrickleState.fromDbMap(rows.first);
  }

  Future<TrickleState> ensureState({
    required String messageId,
    required int nowMs,
    String reason = 'recover',
  }) async {
    final existing = await stateFor(messageId);
    if (existing != null) return existing;
    return reset(messageId: messageId, nowMs: nowMs, reason: reason);
  }

  Future<bool> recordConsistentObservation({
    required String messageId,
    required String observerKey,
    required int nowMs,
  }) async {
    final state = await ensureState(
      messageId: messageId,
      nowMs: nowMs,
      reason: 'consistent_recovery',
    );
    final inserted = await _db.insert('trickle_observations', {
      'message_id': messageId,
      'interval_started_at': state.intervalStartedAt,
      'observer_key': observerKey,
      'first_seen_at': nowMs,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (inserted == 0) return false;

    await _db.update(
      'trickle_states',
      {'consistency_count': state.consistencyCount + 1, 'updated_at': nowMs},
      where: 'message_id = ? AND interval_started_at = ?',
      whereArgs: [messageId, state.intervalStartedAt],
    );
    return true;
  }

  Future<TrickleTransmitDecision> handleQueueEvent({
    required String messageId,
    required int nowMs,
  }) async {
    var state = await ensureState(
      messageId: messageId,
      nowMs: nowMs,
      reason: 'queue_recovered',
    );

    if (nowMs >= state.intervalEndAt) {
      state = await advanceInterval(messageId: messageId, nowMs: nowMs);
      return TrickleTransmitDecision(
        type: TrickleTransmitDecisionType.intervalAdvanced,
        state: state,
        nextEligibleAt: state.transmitAt,
      );
    }

    if (state.phase == TricklePhase.waitingTransmit &&
        nowMs >= state.transmitAt) {
      final nextState = state.copyWith(
        phase: TricklePhase.waitingIntervalEnd,
        updatedAt: nowMs,
      );
      await _upsert(nextState);
      return TrickleTransmitDecision(
        type: state.consistencyCount < _redundancyConstant
            ? TrickleTransmitDecisionType.allowTransmit
            : TrickleTransmitDecisionType.suppressTransmit,
        state: nextState,
        nextEligibleAt: state.intervalEndAt,
      );
    }

    return TrickleTransmitDecision(
      type: TrickleTransmitDecisionType.wait,
      state: state,
      nextEligibleAt: state.phase == TricklePhase.waitingTransmit
          ? state.transmitAt
          : state.intervalEndAt,
    );
  }

  Future<TrickleState> advanceInterval({
    required String messageId,
    required int nowMs,
  }) async {
    final current = await ensureState(
      messageId: messageId,
      nowMs: nowMs,
      reason: 'advance_recovery',
    );
    final doubled = current.intervalMs * 2;
    final nextInterval = doubled > _imaxMs ? _imaxMs : doubled;
    final state = _newInterval(
      messageId: messageId,
      intervalMs: nextInterval,
      nowMs: nowMs,
      resetReason: current.lastResetReason,
    );
    return _upsert(state);
  }

  Future<int> deleteState(String messageId) async {
    await _db.delete(
      'trickle_observations',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    return _db.delete(
      'trickle_states',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  TrickleState _newInterval({
    required String messageId,
    required int intervalMs,
    required int nowMs,
    required String? resetReason,
  }) {
    final half = intervalMs ~/ 2;
    final span = intervalMs - half;
    final offset = half + (span <= 1 ? 0 : _random.nextInt(span));
    return TrickleState(
      messageId: messageId,
      intervalMs: intervalMs,
      intervalStartedAt: nowMs,
      transmitAt: nowMs + offset,
      intervalEndAt: nowMs + intervalMs,
      consistencyCount: 0,
      phase: TricklePhase.waitingTransmit,
      lastResetReason: resetReason,
      updatedAt: nowMs,
    );
  }

  Future<TrickleState> _upsert(TrickleState state) async {
    await _db.insert(
      'trickle_states',
      state.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return state;
  }
}
