import 'dart:convert';

import 'package:flutter/services.dart';

const int libXrayApiVersion = 3;
const MethodChannel _libXrayChannel = MethodChannel('iq_tunnel/libxray');

/// A structured request for the pinned libXray Invoke API.
class LibXrayRequest {
  const LibXrayRequest({
    required this.method,
    this.payload = const <String, Object?>{},
  });

  final String method;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
        'apiVersion': libXrayApiVersion,
        'method': method,
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());
}

/// Parsed response from libXray. Error text is returned to callers but must
/// never be written to logs together with profiles, links, or credentials.
class LibXrayResponse {
  const LibXrayResponse({
    required this.success,
    required this.data,
    required this.error,
  });

  final bool success;
  final Object? data;
  final String error;

  factory LibXrayResponse.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('libXray returned a non-object response.');
    }

    final success = decoded['success'];
    if (success is! bool) {
      throw const FormatException('libXray response is missing a boolean success field.');
    }

    final error = decoded['error'];
    if (error != null && error is! String) {
      throw const FormatException('libXray response has an invalid error field.');
    }

    return LibXrayResponse(
      success: success,
      data: decoded['data'],
      error: error as String? ?? '',
    );
  }
}

/// Narrow seam for testing and for the native Android binding.
abstract interface class LibXrayInvoker {
  Future<String> invoke(String requestJson);
  Future<void> connect(String xrayJson);
  Future<void> disconnect();
  Future<bool> isRunning();
  Future<String> getTrafficStats();
  Stream<Map<String, Object?>> get connectionEvents;
}

class MethodChannelLibXrayInvoker implements LibXrayInvoker {
  const MethodChannelLibXrayInvoker();

  @override
  Future<String> invoke(String requestJson) async {
    final response = await _libXrayChannel.invokeMethod<String>(
      'invoke',
      requestJson,
    );
    if (response == null || response.isEmpty) {
      throw const FormatException('The native Xray engine returned an empty response.');
    }
    return response;
  }

  @override
  Future<void> connect(String xrayJson) =>
      _libXrayChannel.invokeMethod<void>(
        'connect',
        <String, Object?>{'xrayJson': xrayJson},
      ).timeout(const Duration(seconds: 120));

  @override
  Future<void> disconnect() =>
      _libXrayChannel.invokeMethod<void>('disconnect');

  @override
  Future<bool> isRunning() async =>
      await _libXrayChannel.invokeMethod<bool>('isRunning') ?? false;

  @override
  Future<String> getTrafficStats() async =>
      await _libXrayChannel.invokeMethod<String>('getTrafficStats') ??
      '{"available":false,"uploadTotal":0,"downloadTotal":0}';

  @override
  Stream<Map<String, Object?>> get connectionEvents =>
      const EventChannel('iq_tunnel/xray_events')
          .receiveBroadcastStream()
          .where((event) => event is Map)
          .map((event) => Map<String, Object?>.from(event as Map));
}

/// High-level, credential-safe wrapper for the documented libXray API.
class LibXrayClient {
  LibXrayClient(this._invoker);

  final LibXrayInvoker _invoker;

  Stream<Map<String, Object?>> get connectionEvents => _invoker.connectionEvents;

  Future<void> connect(String xrayJson) => _invoker.connect(xrayJson);

  Future<void> disconnect() => _invoker.disconnect();

  Future<LibXrayResponse> _call(LibXrayRequest request) async {
    final raw = await _invoker.invoke(request.encode());
    final response = LibXrayResponse.decode(raw);
    if (!response.success) {
      // Do not add request payloads to this exception.
      throw LibXrayException(
        response.error.isEmpty ? 'The Xray operation failed.' : response.error,
      );
    }
    return response;
  }

  /// Converts VLESS/VMess-AEAD/Trojan/SS/SOCKS/Hysteria2 links or a supported
  /// subscription text into validated Xray outbounds.
  ///
  /// libXray omits individual invalid entries and fails when no valid outbound
  /// remains. Legacy VMess QR-code links and WireGuard URI links are not part
  /// of this converter's supported input contract.
  Future<List<Map<String, dynamic>>> convertShareLinksToOutbounds(
    String text, {
    String? ageSecretKey,
  }) async {
    if (text.trim().isEmpty) {
      throw const FormatException('Paste a VPN link or subscription first.');
    }

    final age = ageSecretKey;
    final payload = <String, Object?>{'text': text};
    if (age != null && age.isNotEmpty) {
      payload['age'] = <String, Object?>{'secretKey': age};
    }

    final response = await _call(LibXrayRequest(
      method: 'convertShareLinksToXrayJson',
      payload: payload,
    ));

    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Xray share conversion returned invalid data.');
    }
    final rawOutbounds = data['outbounds'];
    if (rawOutbounds is! List || rawOutbounds.isEmpty) {
      throw const FormatException('No supported VPN servers were found in this input.');
    }

    final outbounds = <Map<String, dynamic>>[];
    for (final item in rawOutbounds) {
      if (item is! Map) {
        throw const FormatException('Xray returned an invalid outbound entry.');
      }
      outbounds.add(Map<String, dynamic>.from(item));
    }
    if (outbounds.isEmpty) {
      throw const FormatException('No supported VPN servers were found in this input.');
    }
    return List<Map<String, dynamic>>.unmodifiable(outbounds);
  }

  /// Gets the Xray core version reported by the native artifact.
  Future<String> getCoreVersion() async {
    final response = await _call(const LibXrayRequest(method: 'xrayVersion'));
    final data = response.data;
    if (data is! Map<String, dynamic> || data['version'] is! String) {
      throw const FormatException('Xray version response is invalid.');
    }
    return data['version'] as String;
  }

  /// Checks the managed instance state.
  Future<bool> isRunning() => _invoker.isRunning();

  Future<LibXrayTrafficStats> getTrafficStats() async {
    final raw = await _invoker.getTrafficStats();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Xray traffic statistics have an invalid shape.');
    }
    final available = decoded['available'];
    final upload = decoded['uploadTotal'];
    final download = decoded['downloadTotal'];
    if (available is! bool || upload is! num || download is! num ||
        upload < 0 || download < 0) {
      throw const FormatException('Xray traffic statistics contain invalid values.');
    }
    return LibXrayTrafficStats(
      available: available,
      uploadTotal: upload.toInt(),
      downloadTotal: download.toInt(),
    );
  }
}

class LibXrayTrafficStats {
  const LibXrayTrafficStats({
    required this.available,
    required this.uploadTotal,
    required this.downloadTotal,
  });

  final bool available;
  final int uploadTotal;
  final int downloadTotal;
}

class LibXrayException implements Exception {
  const LibXrayException(this.message);

  final String message;

  @override
  String toString() => message;
}
