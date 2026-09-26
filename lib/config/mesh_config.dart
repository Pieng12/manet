enum ForwardingMode {
  basicFlooding('basic_flooding'),
  trickle('trickle');

  const ForwardingMode(this.logValue);

  final String logValue;
}

enum ResqMeshMode { offline, gateway }

class MeshConfig {
  static const String protocolVersion = 'resqmesh-ble17-v1';
  static const Duration defaultRxBurstGap = Duration(milliseconds: 1000);
  static const int protocolEpochSeconds = int.fromEnvironment(
    'RESQMESH_PROTOCOL_EPOCH_SECONDS',
    defaultValue: 1780272000, // 2026-06-01T00:00:00Z
  );
  static const String protocolEpochId = String.fromEnvironment(
    'RESQMESH_PROTOCOL_EPOCH_ID',
    defaultValue: 'resqmesh-2026-06-01',
  );
  static const String resqMeshModeName = String.fromEnvironment(
    'RESQMESH_MODE',
    defaultValue: 'offline',
  );
  static const ResqMeshMode resqMeshMode = resqMeshModeName == 'gateway'
      ? ResqMeshMode.gateway
      : ResqMeshMode.offline;

  static const String apiBaseUrl = String.fromEnvironment(
    'RESQMESH_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080/api',
  );

  static const String forwardingModeName = String.fromEnvironment(
    'RESQMESH_FORWARDING_MODE',
    defaultValue: 'trickle',
  );
  static const String buildId = String.fromEnvironment(
    'RESQMESH_BUILD_ID',
    defaultValue: 'unknown',
  );
  static const ForwardingMode forwardingMode =
      forwardingModeName == 'basic' || forwardingModeName == 'basic_flooding'
      ? ForwardingMode.basicFlooding
      : ForwardingMode.trickle;

  static const int protocolLength = 17;
  static const int manufacturerId = 0xFFFF;
  // Compatibility metadata only. Neither value is a forwarding cutoff.
  static const int legacyHopMetadata = 5;
  static const int legacyAckHopMetadata = 5;
  static const int maxProtocolHop = 63;
  static const int hopSaturation = maxProtocolHop;
  static const int relayCountMetricSample = 10;

  // Compatibility metadata only. Active SOS and ACK packets do not expire.
  static const Duration defaultMessageLifetime = Duration(hours: 6);
  static const Duration ackLifetime = Duration(minutes: 2);
  static const Duration ackAdvertiseDuration = Duration(seconds: 10);
  static const Duration relayCooldown = Duration(seconds: 10);
  static const Duration basicFloodingInterval = Duration(seconds: 2);
  static const Duration sosAdvertiseBurstDuration = Duration(seconds: 2);
  static const int trickleIminMs = 8000;
  static const Duration trickleImin = Duration(milliseconds: trickleIminMs);
  static const int trickleImaxDoublings = 5;
  static const int trickleRedundancyConstant = 1;
  static const int trickleImaxMs = trickleIminMs * (1 << trickleImaxDoublings);
  static const Duration trickleImax = Duration(milliseconds: trickleImaxMs);
  static const Duration relayJitterMin = Duration(milliseconds: 300);
  static const Duration relayJitterMax = Duration(milliseconds: 1500);
  static const Duration gatewayHealthTimeout = Duration(seconds: 5);
  static const Duration maxClockSkew = Duration(minutes: 5);
  static const int gatewayHealthMaxRetry = 2;
  static const int maxConsecutiveAckSlots = 3;

  static const bool scanAllAdvertisements = false;
  static const bool connectableAdvertising = false;
  static const bool scannableAdvertising = false;
}
