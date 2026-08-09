enum ForwardingMode {
  basicFlooding('basic_flooding'),
  controlledEpidemic('controlled_epidemic');

  const ForwardingMode(this.logValue);

  final String logValue;
}

enum ResqMeshMode { offline, gateway }

class MeshConfig {
  static const String resqMeshModeName = String.fromEnvironment(
    'RESQMESH_MODE',
    defaultValue: 'offline',
  );
  static const ResqMeshMode resqMeshMode = resqMeshModeName == 'gateway'
      ? ResqMeshMode.gateway
      : ResqMeshMode.offline;

  static const String apiBaseUrl = String.fromEnvironment(
    'RESQMESH_API_BASE_URL',
    defaultValue: 'https://resqmesh-backend-production.up.railway.app/api',
  );

  static const String forwardingModeName = String.fromEnvironment(
    'RESQMESH_FORWARDING_MODE',
    defaultValue: 'controlled_epidemic',
  );
  static const ForwardingMode forwardingMode =
      forwardingModeName == 'basic' || forwardingModeName == 'basic_flooding'
      ? ForwardingMode.basicFlooding
      : ForwardingMode.controlledEpidemic;

  static const int protocolLength = 17;
  static const int manufacturerId = 0xFFFF;
  static const int legacyHopMetadata = 5;
  static const int legacyAckHopMetadata = 5;
  static const int maxProtocolHop = 63;
  static const int relayCountMetricSample = 10;

  static const Duration defaultMessageLifetime = Duration(hours: 6);
  static const Duration ackLifetime = Duration(minutes: 2);
  static const Duration ackAdvertiseDuration = Duration(seconds: 10);
  static const Duration relayCooldown = Duration(seconds: 10);
  static const Duration basicFloodingInterval = Duration(seconds: 2);
  static const Duration basicFloodingSlotDuration = Duration(seconds: 2);
  static const Duration adaptiveBackoffBase = Duration(seconds: 10);
  static const Duration adaptiveBackoffMax = Duration(minutes: 5);
  static const Duration relaySlotDuration = Duration(seconds: 5);
  static const Duration relayJitterMin = Duration(milliseconds: 300);
  static const Duration relayJitterMax = Duration(milliseconds: 1500);
  static const Duration gatewayHealthTimeout = Duration(seconds: 5);
  static const Duration maxClockSkew = Duration(minutes: 5);
  static const int gatewayHealthMaxRetry = 2;
  static const int maxConsecutiveAckSlots = 3;

  static const bool scanAllAdvertisements = false;
  static const bool connectableAdvertising = false;
}
