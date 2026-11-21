import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'libxray_api.dart';
import 'vpn_engine.dart';
import 'share_link_compatibility_parser.dart';

export 'share_link_compatibility_parser.dart' show ShareLinkCompatibilityImport, ShareLinkCompatibilityParser;

/// Builds the client-side Xray config. The Android VpnService plugin adds
/// the TUN inbound and FD at runtime, so no platform file descriptor is
/// ever persisted in an encrypted user profile.
class XrayClientConfigBuilder {
  const XrayClientConfigBuilder._();

  static String fromOutbounds(List<Map<String, dynamic>> source) {
    if (source.isEmpty) {
      throw const FormatException('No valid VPN outbound is available.');
    }

    final outbounds = <Map<String, dynamic>>[];
    final usedTags = <String>{};
    var index = 0;
    for (final sourceOutbound in source) {
      final outbound = Map<String, dynamic>.from(sourceOutbound);
      var tag = outbound['tag']?.toString().trim() ?? '';
      if (tag.isEmpty) tag = 'iqt-node-' + index.toString();
      var uniqueTag = tag;
      var duplicateIndex = 1;
      while (usedTags.contains(uniqueTag)) {
        uniqueTag = tag + '-' + duplicateIndex.toString();
        duplicateIndex++;
      }
      usedTags.add(uniqueTag);
      outbound['tag'] = uniqueTag;
      outbounds.add(outbound);
      index++;
    }

    String reserveTag(String base) {
      var candidate = base;
      var suffix = 1;
      while (usedTags.contains(candidate)) {
        candidate = base + '-' + suffix.toString();
        suffix++;
      }
      usedTags.add(candidate);
      return candidate;
    }

    final directTag = reserveTag('iqt-direct');
    final blockTag = reserveTag('iqt-block');
    outbounds.add(<String, dynamic>{
      'tag': directTag,
      'protocol': 'freedom',
      'settings': <String, dynamic>{},
    });
    outbounds.add(<String, dynamic>{
      'tag': blockTag,
      'protocol': 'blackhole',
      'settings': <String, dynamic>{},
    });

    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{
        'servers': <String>['1.1.1.1', '8.8.8.8'],
      },
      'outbounds': outbounds,
      'stats': <String, dynamic>{},
      'policy': <String, dynamic>{
        'system': <String, dynamic>{
          'statsInboundUplink': true,
          'statsInboundDownlink': true,
        },
      },
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': <Map<String, dynamic>>[],
      },
    };
    return const JsonEncoder.withIndent('  ').convert(config);
  }
}

/// Production candidate using the official libXray bridge. The Android
/// bridge reports connected only after the managed Xray instance starts.
class LibXrayVpnEngineAdapter implements VpnEngine {
  LibXrayVpnEngineAdapter({LibXrayClient? client})
      : _client = client ?? LibXrayClient(const MethodChannelLibXrayInvoker());

  final LibXrayClient _client;
  final StreamController<VpnEngineState> _states =
      StreamController<VpnEngineState>.broadcast();

  StreamSubscription<Map<String, Object?>>? _eventSubscription;
  VpnEngineStatus _status = VpnEngineStatus.disconnected;
  String? _lastError;

  @override
  VpnEngineStatus get status => _status;

  @override
  Stream<VpnEngineState> watchConnectionState() => _states.stream;

  @override
  Stream<VpnTrafficStats> watchConnectionStats() async* {
    int? previousUpload;
    int? previousDownload;
    Duration? previousAt;
    final stopwatch = Stopwatch()..start();
    var unavailableReported = false;

    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_status != VpnEngineStatus.connected) {
        previousUpload = null;
        previousDownload = null;
        previousAt = null;
        if (!unavailableReported) {
          unavailableReported = true;
          yield const VpnTrafficStats(available: false);
        }
        continue;
      }

      try {
        final snapshot = await _client.getTrafficStats();
        if (!snapshot.available) {
          previousUpload = null;
          previousDownload = null;
          previousAt = null;
          if (!unavailableReported) {
            unavailableReported = true;
            yield const VpnTrafficStats(available: false);
          }
          continue;
        }

        final now = stopwatch.elapsed;
        final elapsedSeconds = previousAt == null
            ? 1.0
            : math.max(
                0.001,
                (now - previousAt).inMicroseconds / Duration.microsecondsPerSecond,
              );
        final uploadRate = previousUpload == null
            ? 0
            : math.max(
                0,
                ((snapshot.uploadTotal - previousUpload) / elapsedSeconds).round(),
              ).toInt();
        final downloadRate = previousDownload == null
            ? 0
            : math.max(
                0,
                ((snapshot.downloadTotal - previousDownload) / elapsedSeconds).round(),
              ).toInt();

        unavailableReported = false;
        yield VpnTrafficStats(
          available: true,
          uploadSpeed: uploadRate,
          downloadSpeed: downloadRate,
          uploadTotal: snapshot.uploadTotal,
          downloadTotal: snapshot.downloadTotal,
        );

        previousUpload = snapshot.uploadTotal;
        previousDownload = snapshot.downloadTotal;
        previousAt = now;
      } catch (_) {
        previousUpload = null;
        previousDownload = null;
        previousAt = null;
        if (!unavailableReported) {
          unavailableReported = true;
          yield const VpnTrafficStats(available: false);
        }
      }
    }
  }

  @override
  Future<void> initialize() async {
    await _eventSubscription?.cancel();
    _eventSubscription = _client.connectionEvents.listen(_handleNativeEvent);
    // Keep application startup independent from the native libXray bridge.
    // Some Android devices can terminate the process while loading/probing
    // native VPN code during the first Flutter frame. Probe native state only
    // when the user explicitly starts or stops a tunnel.
    _setStatus(VpnEngineStatus.disconnected);
  }

  @override
  Future<void> validateProfile(String payload) async {
    final outbounds = await _outboundsFor(payload);
    if (outbounds.isEmpty) {
      throw const FormatException('The profile contains no supported VPN outbound.');
    }
  }

  @override
  Future<void> connect(
    String payload, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final outbounds = await _outboundsFor(payload);
    final xrayJson = XrayClientConfigBuilder.fromOutbounds(outbounds);
    _lastError = null;
    _setStatus(VpnEngineStatus.connecting);
    try {
      await _client.connect(xrayJson).timeout(timeout);
      final running = await _client.isRunning();
      if (!running && _status != VpnEngineStatus.connected) {
        throw StateError('The native Xray core did not remain running.');
      }
      if (_status != VpnEngineStatus.connected) {
        _setStatus(VpnEngineStatus.connected);
      }
    } catch (_) {
      // Do not surface native config payloads, UUIDs, endpoints or credentials.
      _lastError = 'تعذر إنشاء نفق VPN. تحقق من الإذن وملف الاتصال والشبكة.';
      _setStatus(VpnEngineStatus.disconnected, error: _lastError);
      throw StateError(_lastError!);
    }
  }

  @override
  Future<void> disconnect() async {
    _lastError = null;
    _setStatus(VpnEngineStatus.disconnecting);
    try {
      await _client.disconnect();
      _setStatus(VpnEngineStatus.disconnected);
    } catch (_) {
      // If the native state probe also fails, prefer "possibly connected"
      // over falsely claiming that a tunnel has definitely stopped.
      var stillRunning = true;
      try {
        stillRunning = await _client.isRunning();
      } catch (_) {
        // Preserve the safe default.
      }
      _lastError = 'تعذر تأكيد فصل نفق VPN. أعد المحاولة وتحقق من حالة الاتصال.';
      _setStatus(
        stillRunning ? VpnEngineStatus.connected : VpnEngineStatus.disconnected,
        error: _lastError,
      );
      throw StateError(_lastError!);
    }
  }

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<void> requestNotificationPermission() async {
    // The native VpnService owns its persistent notification. Android may
    // hide it from the notification drawer if POST_NOTIFICATIONS is denied.
  }

  Future<List<Map<String, dynamic>>> _outboundsFor(String payload) async {
    final compatible = ShareLinkCompatibilityParser.extract(payload);
    if (compatible.remaining.isEmpty) {
      return compatible.outbounds;
    }

    final nativeOutbounds =
        await _client.convertShareLinksToOutbounds(compatible.remaining);
    return <Map<String, dynamic>>[
      ...compatible.outbounds,
      ...nativeOutbounds,
    ];
  }

  void _handleNativeEvent(Map<String, Object?> event) {
    final state = event['status']?.toString();
    switch (state) {
      case 'connecting':
        _setStatus(VpnEngineStatus.connecting);
        break;
      case 'connected':
        _lastError = null;
        _setStatus(VpnEngineStatus.connected);
        break;
      case 'disconnected':
        _setStatus(VpnEngineStatus.disconnected);
        break;
      case 'error':
        _lastError = event['message']?.toString() ?? 'Native Xray engine failed.';
        _setStatus(VpnEngineStatus.disconnected, error: _lastError);
        break;
    }
  }

  void _setStatus(VpnEngineStatus value, {String? error}) {
    _status = value;
    _states.add(VpnEngineState(status: value, error: error ?? _lastError));
  }
}
