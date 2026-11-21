import 'package:flutter/services.dart';

/// Native Android bridge for the pinned libXray AAR.
class IqTunnelXray {
  IqTunnelXray._();

  static const MethodChannel _methods = MethodChannel('iq_tunnel/libxray');
  static const EventChannel _events = EventChannel('iq_tunnel/xray_events');

  static Future<String> invoke(String requestJson) async {
    final response = await _methods.invokeMethod<String>('invoke', requestJson);
    if (response == null || response.isEmpty) {
      throw const FormatException('Native Xray returned an empty response.');
    }
    return response;
  }

  static Future<void> connect(String xrayJson) async {
    await _methods.invokeMethod<void>(
      'connect',
      <String, Object?>{'xrayJson': xrayJson},
    ).timeout(const Duration(seconds: 45));
  }

  static Future<void> disconnect() =>
      _methods.invokeMethod<void>('disconnect');

  static Future<bool> isRunning() async =>
      await _methods.invokeMethod<bool>('isRunning') ?? false;

  static Stream<Map<String, Object?>> get connectionEvents =>
      _events.receiveBroadcastStream().where((event) => event is Map).map(
            (event) => Map<String, Object?>.from(event as Map),
          );
}

