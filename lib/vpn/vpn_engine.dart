/// Engine-neutral VPN lifecycle contract.
///
/// The UI and encrypted profile store depend on this contract rather than on
/// a specific native VPN core. Engine implementations must not report
/// "connected" until their Android VpnService/datapath is actually active.
enum VpnEngineStatus {
  unknown,
  disconnected,
  connecting,
  connected,
  disconnecting,
}

class VpnEngineState {
  const VpnEngineState({required this.status, this.error});

  final VpnEngineStatus status;
  final String? error;
}

class VpnTrafficStats {
  const VpnTrafficStats({
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.available = true,
  });

  final int uploadSpeed;
  final int downloadSpeed;
  final int uploadTotal;
  final int downloadTotal;
  final bool available;
}

abstract interface class VpnEngine {
  VpnEngineStatus get status;
  Stream<VpnEngineState> watchConnectionState();
  Stream<VpnTrafficStats> watchConnectionStats();
  Future<void> initialize();
  Future<void> validateProfile(String payload);
  Future<bool> hasNotificationPermission();
  Future<void> requestNotificationPermission();
  Future<void> connect(
    String payload, {
    Duration timeout = const Duration(seconds: 120),
  });
  Future<void> disconnect();
}
