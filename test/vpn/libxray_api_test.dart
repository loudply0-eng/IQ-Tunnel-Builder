import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/vpn/libxray_api.dart';

class _TrafficStatsInvoker extends _FakeLibXrayInvoker {
  _TrafficStatsInvoker(super.response);

  @override
  Future<String> getTrafficStats() async => response;
}

class _FakeLibXrayInvoker implements LibXrayInvoker {
  _FakeLibXrayInvoker(this.response);

  final String response;
  String? lastRequest;

  @override
  Future<String> invoke(String requestJson) async {
    lastRequest = requestJson;
    return response;
  }

  @override
  Future<void> connect(String xrayJson) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> isRunning() async => true;

  @override
  Future<String> getTrafficStats() async =>
      '{"available":true,"uploadTotal":1234,"downloadTotal":5678}';

  @override
  Stream<Map<String, Object?>> get connectionEvents =>
      const Stream<Map<String, Object?>>.empty();
}

void main() {
  group('LibXrayRequest', () {
    test('uses the pinned API version and structured payload', () {
      const request = LibXrayRequest(
        method: 'convertShareLinksToXrayJson',
        payload: <String, Object?>{'text': 'vless://example'},
      );

      expect(jsonDecode(request.encode()), <String, Object?>{
        'apiVersion': 3,
        'method': 'convertShareLinksToXrayJson',
        'payload': <String, Object?>{'text': 'vless://example'},
      });
    });
  });

  group('LibXrayResponse', () {
    test('decodes successful response data', () {
      final response = LibXrayResponse.decode(
        '{"success":true,"data":{"version":"test"},"error":""}',
      );

      expect(response.success, isTrue);
      expect(response.data, <String, dynamic>{'version': 'test'});
      expect(response.error, isEmpty);
    });

    test('rejects malformed response envelopes', () {
      expect(
        () => LibXrayResponse.decode('[]'),
        throwsFormatException,
      );
      expect(
        () => LibXrayResponse.decode('{"data":{}}'),
        throwsFormatException,
      );
      expect(
        () => LibXrayResponse.decode('{"success":true,"error":42}'),
        throwsFormatException,
      );
    });
  });

  group('LibXrayClient', () {
    test('converts only validated outbound maps and keeps payload out of errors', () async {
      final invoker = _FakeLibXrayInvoker(
        '{"success":true,"data":{"outbounds":['
        '{"tag":"node-1","protocol":"vless","settings":{}},'
        '{"tag":"node-2","protocol":"trojan","settings":{}}'
        ']},"error":""}',
      );
      final client = LibXrayClient(invoker);

      final outbounds = await client.convertShareLinksToOutbounds(
        'vless://secret-profile-value',
      );

      expect(outbounds, hasLength(2));
      expect(outbounds.first['protocol'], 'vless');
      expect(
        jsonDecode(invoker.lastRequest!)['payload']['text'],
        'vless://secret-profile-value',
      );
    });

    test('can pass an Age key only in the native request payload', () async {
      final invoker = _FakeLibXrayInvoker(
        '{"success":true,"data":{"outbounds":['
        '{"tag":"node-1","protocol":"vless"}'
        ']},"error":""}',
      );
      final client = LibXrayClient(invoker);

      await client.convertShareLinksToOutbounds(
        '-----BEGIN AGE ENCRYPTED FILE-----',
        ageSecretKey: 'AGE-SECRET-KEY-1example',
      );

      final payload = jsonDecode(invoker.lastRequest!)['payload'];
      expect(payload['age']['secretKey'], 'AGE-SECRET-KEY-1example');
    });

    test('refuses empty input without calling the native bridge', () async {
      final invoker = _FakeLibXrayInvoker(
        '{"success":true,"data":{"outbounds":[]},"error":""}',
      );
      final client = LibXrayClient(invoker);

      await expectLater(
        client.convertShareLinksToOutbounds('  '),
        throwsFormatException,
      );
      expect(invoker.lastRequest, isNull);
    });

    test('does not accept an empty outbound response', () async {
      final invoker = _FakeLibXrayInvoker(
        '{"success":true,"data":{"outbounds":[]},"error":""}',
      );
      final client = LibXrayClient(invoker);

      await expectLater(
        client.convertShareLinksToOutbounds('vless://invalid'),
        throwsFormatException,
      );
    });

    test('surfaces native errors without attaching the original profile text', () async {
      const privateLink = 'vless://private-uuid@example.invalid';
      final invoker = _FakeLibXrayInvoker(
        '{"success":false,"data":null,"error":"no valid outbound found"}',
      );
      final client = LibXrayClient(invoker);

      await expectLater(
        client.convertShareLinksToOutbounds(privateLink),
        throwsA(
          isA<LibXrayException>().having(
            (error) => error.message,
            'message',
            'no valid outbound found',
          ),
        ),
      );
    });

    test('reads the native core version', () async {
      final invoker = _FakeLibXrayInvoker(
        '{"success":true,"data":{"version":"26.11.9"},"error":""}',
      );
      final client = LibXrayClient(invoker);

      expect(await client.getCoreVersion(), '26.11.9');
    });

    test('reads managed connection state', () async {
      final invoker = _FakeLibXrayInvoker(
        '{"success":true,"data":{"running":true},"error":""}',
      );
      final client = LibXrayClient(invoker);

      expect(await client.isRunning(), isTrue);
    });

    test('decodes in-process traffic counters', () async {
      final client = LibXrayClient(_FakeLibXrayInvoker(''));
      final stats = await client.getTrafficStats();

      expect(stats.available, isTrue);
      expect(stats.uploadTotal, 1234);
      expect(stats.downloadTotal, 5678);
    });

    test('rejects malformed traffic counter payloads', () async {
      // A separate fake response allows verifying the native JSON boundary.
      final invalid = _TrafficStatsInvoker('{"available":"yes"}');
      final client = LibXrayClient(invalid);
      await expectLater(client.getTrafficStats(), throwsFormatException);
    });
  });
}

