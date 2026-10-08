import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/neighbor_status_controller.dart';
import 'package:pkmproject/services/neighbor_status_schedule.dart';
import 'package:pkmproject/services/neighbor_transport.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Isolate-local evidence; durable protocol state remains in the existing queue.
class NeighborRuntime {
  NeighborRuntime._();
  static final instance = NeighborRuntime._();
  static const profile = 'neighbor_graph_v1';
  static const _key = 'neighbor_transport_profile_v1';
  final _rng = Random();
  String? _loaded;
  Map<String, dynamic>? configuration;
  NeighborStatusController? controller;
  int _boot = 0, _sequence = 0;
  int _nextStatusAt = 0;
  NeighborStatusSchedule? statusSchedule;
  List<StateIdentity> _inventory = [];
  int get nextStatusAt => statusSchedule?.nextAt ?? _nextStatusAt;
  set nextStatusAt(int value) {
    if (statusSchedule != null) {
      statusSchedule!.nextAt = value;
    } else {
      _nextStatusAt = value;
    }
  }

  int _jitter() => _rng.nextInt(controller!.parameters.discoveryJitterMs + 1);
  bool get enabled => configuration != null && configuration!['scope'] != null;
  bool get statusEnabled =>
      enabled && configuration!['mode'] == 'trickle_neighbor_status';
  int get transmitter => crc32(configuration!['node_id'] as String);
  int get scope => configuration!['scope'] as int;
  String get nodeId => configuration!['node_id'] as String;
  bool allows(NeighborFrame f) =>
      enabled &&
      f.scope == scope &&
      (configuration!['allowed_transmitters'] as List).contains(
        f.transmitter,
      ) &&
      f.transmitter != transmitter;

  Future<void> configure(Map<String, dynamic> args) async {
    final prefs = await SharedPreferences.getInstance();
    if (args['transport_profile'] != profile) {
      await prefs.remove(_key);
    } else {
      final rawAllowed = args['allowed_transmitters'];
      final allowed = rawAllowed is List
          ? rawAllowed.map((v) => int.tryParse(v.toString())).toList()
          : null;
      if (allowed == null ||
          allowed.isEmpty ||
          allowed.length > 5 ||
          allowed.toSet().length != allowed.length ||
          args['node_id'] is! String ||
          (args['node_id'] as String).isEmpty ||
          allowed.contains(crc32(args['node_id'] as String)) ||
          allowed.any((v) => v == null || v <= 0 || v > 0xffffffff)) {
        throw ArgumentError('Invalid stable transmitter adjacency');
      }
      final parameters = NeighborParameters.fromMap(args)..validate();
      await prefs.setString(
        _key,
        jsonEncode({
          'node_id': args['node_id'],
          'mode': args['mode'],
          'allowed_transmitters': allowed,
          'scope': null,
          ...parameters.toMap(),
        }),
      );
    }
    _loaded = null;
    await load();
  }

  Future<void> startTrial(String trialId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final cfg = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    cfg['scope'] = crc32(trialId);
    await prefs.setString(_key, jsonEncode(cfg));
    await load();
  }

  Future<void> endTrial() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final cfg = Map<String, dynamic>.from(jsonDecode(raw) as Map)
      ..['scope'] = null;
    await prefs.setString(_key, jsonEncode(cfg));
    await load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (_loaded == raw && (_loaded != null || configuration == null)) return;
    configuration = raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    controller = null;
    statusSchedule = null;
    _inventory = [];
    if (!enabled) {
      _loaded = raw;
      return;
    }
    final cfg = configuration!;
    final params = NeighborParameters.fromMap(cfg);
    controller = NeighborStatusController(scope: scope, parameters: params);
    _boot = ((prefs.getInt('neighbor_incarnation') ?? 0) + 1) & 0xffffffff;
    if (_boot == 0) {
      throw StateError(
        'Incarnation exhausted; change configured node identity',
      );
    }
    if (!await prefs.setInt('neighbor_incarnation', _boot)) {
      controller = null;
      _loaded = null;
      throw StateError('Incarnation persistence failed; TX disabled');
    }
    _loaded = raw;
    _sequence = 0;
    if (statusEnabled && params.adaptive) {
      statusSchedule = NeighborStatusSchedule(params)
        ..start(ExperimentClock.instance.monotonicTimeMs(), _jitter());
      return;
    }
    nextStatusAt =
        ExperimentClock.instance.monotonicTimeMs() +
        1000 +
        _rng.nextInt(params.discoveryJitterMs + 1);
  }

  Future<NeighborFrame> frame({
    Uint8List? inner,
    List<StateIdentity> inventory = const [],
    bool complete = true,
  }) async {
    if (++_sequence > 0xffffffff) {
      final prefs = await SharedPreferences.getInstance();
      _boot++;
      if (_boot > 0xffffffff) throw StateError('Incarnation exhausted');
      if (!await prefs.setInt('neighbor_incarnation', _boot)) {
        _loaded = null;
        throw StateError('Incarnation persistence failed; TX disabled');
      }
      _sequence = 1;
    }
    return NeighborFrame(
      type: inner == null ? NeighborFrameType.status : NeighborFrameType.data,
      transmitter: transmitter,
      boot: _boot,
      sequence: _sequence,
      scope: scope,
      inner: inner,
      inventory: inventory,
      complete: complete,
    );
  }

  Future<List<StateIdentity>> inventoryStates() async {
    final db = await DatabaseHelper().database;
    final rows = await db.query(
      'sos_messages',
      where: 'ack_received_at IS NULL AND local_state NOT IN (?, ?)',
      whereArgs: ['acked', 'synced'],
    );
    return rows.map((r) => SOSMessage.fromDbMap(r).stateIdentity).toList();
  }

  bool _allHave(int now) =>
      _inventory.isNotEmpty &&
      _inventory.every((state) {
        final values = controller!.snapshot(state, now).values;
        return values.isNotEmpty &&
            values.every((v) => v == NeighborKnowledge.have);
      });

  Future<void> synchronizeStatus(
    int now, {
    Future<List<StateIdentity>> Function()? readInventory,
  }) async {
    if (statusSchedule == null) return;
    _inventory = await (readInventory ?? inventoryStates)();
    statusSchedule!.syncInventory(
      _inventory.map((s) => s.value).toList(),
      now,
      _jitter(),
    );
    statusSchedule!.stable(now, _allHave(now), _jitter());
  }

  void peerChanged(int now) {
    statusSchedule?.peerChanged(now, _jitter());
  }

  void restartStatus(int now) {
    statusSchedule?.start(now, _jitter());
  }

  Future<void> dataStarted(StateIdentity state, int now) async {
    final coalesced =
        statusSchedule?.dataSucceeded(
          state.value,
          now,
          _allHave(now),
          _jitter(),
        ) ??
        false;
    if (coalesced) {
      await log(
        'STATUS_COALESCED_WITH_DATA',
        state: state,
        monotonic: now,
        reason: 'DATA_STARTED',
      );
    }
  }

  void statusStarted(List<String> inventory, int now) {
    statusSchedule?.statusSucceeded(inventory, now, _allHave(now), _jitter());
  }

  void statusFailed(int now) => statusSchedule?.failed(now, _jitter());

  Future<NeighborFrame> statusFrame() async {
    final states = statusSchedule == null
        ? await inventoryStates()
        : _inventory;
    return frame(
      inventory: states.take(NeighborFrame.capacity).toList(),
      complete: states.length <= NeighborFrame.capacity,
    );
  }

  void statusAttempted(int now) {
    if (statusSchedule != null) return;
    final p = controller!.parameters;
    nextStatusAt =
        now + p.statusPeriodMs + _rng.nextInt(p.discoveryJitterMs + 1);
  }

  Map<String, Object> fields(NeighborFrame f) => {
    'transmitter_id': f.transmitter,
    'boot_id': f.boot,
    'transmission_sequence': f.sequence,
    'scope': f.scope,
    'transport_burst_id': f.burstIdentity,
    'transport_profile': profile,
    'frame_type': f.type.name,
    'inventory_count': f.inventory.length,
    'snapshot_complete': f.complete,
  };
  Future<void> emitChanges(int nowMs) async {
    if (!statusEnabled) return;
    for (final change in controller!.takeChanges(nowMs)) {
      await log(change['event'] as String, monotonic: nowMs, detail: change);
    }
  }

  Future<void> log(
    String event, {
    NeighborFrame? frame,
    int? receivedAt,
    int? monotonic,
    StateIdentity? state,
    String? reason,
    String? observation,
    int? rssi,
    String clockDomain = 'owner_monotonic',
    Map<String, Object?> detail = const {},
  }) async {
    try {
      final packet = frame?.inner == null
          ? null
          : BlePacket.unpack(frame!.inner!);
      await ExperimentLogger().logEvent(
        eventType: event,
        deviceId: nodeId,
        packetType: frame?.type == NeighborFrameType.status ? 'status' : 'sos',
        eventTimestampMs: receivedAt,
        elapsedRealtimeMs: monotonic,
        messageKey: state?.messageKey.value,
        stateIdentity: state?.value,
        observationId: observation,
        burstId: frame?.burstIdentity,
        rssi: rssi,
        senderCrc: packet?.senderCrc,
        protocolTimestampMs: packet?.timestampMs,
        status: packet?.status.name,
        hopIn: event.contains('RECEIVED') ? packet?.hopCount : null,
        hopOut: event.contains('BURST') ? packet?.hopCount : null,
        eventKey: observation == null ? null : '$event|$observation',
        detail: {
          ...detail,
          if (enabled) 'scope': scope,
          if (frame != null) ...fields(frame),
          if (statusEnabled)
            'neighbor_status_policy': controller!.parameters.policy,
          if (statusSchedule != null) 'status_reason': statusSchedule!.reason,
          'reason': ?reason,
          'clock_domain': clockDomain,
        },
      );
    } catch (error) {
      // Research diagnostics must never turn a durable protocol success into failure.
      print('[NeighborRuntime] Diagnostic insert failed: $event: $error');
    }
  }
}
