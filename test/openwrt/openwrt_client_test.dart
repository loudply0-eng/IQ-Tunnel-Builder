import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iq_tunnel/openwrt/openwrt_client.dart';

void main() {
  group('OpenWrtClient', () {
    test('reads router details with a short-lived ubus session', () async {
      final calls = <Map<String, dynamic>>[];
      final client = OpenWrtClient(
        client: MockClient((request) async {
          expect(request.url.path, '/ubus');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final params = body['params'] as List<dynamic>;
          calls.add(body);
          final object = params[1] as String;
          final method = params[2] as String;

          if (object == 'session' && method == 'login') {
            return http.Response(
              jsonEncode({
                'result': [
                  0,
                  {'ubus_rpc_session': '0123456789abcdef0123456789abcdef'}
                ]
              }),
              200,
            );
          }
          if (object == 'system' && method == 'board') {
            return http.Response(
              jsonEncode({
                'result': [
                  0,
                  {
                    'hostname': 'OpenWrt',
                    'model': 'Test Router',
                    'release': {'version': '24.10.0'}
                  }
                ]
              }),
              200,
            );
          }
          if (object == 'system' && method == 'info') {
            return http.Response(
              jsonEncode({
                'result': [
                  0,
                  {
                    'uptime': 3600,
                    'load': [65536, 32768, 0],
                    'memory': {'total': 1024, 'free': 512}
                  }
                ]
              }),
              200,
            );
          }
          if (object == 'network.interface' && method == 'dump') {
            return http.Response(
              jsonEncode({
                'result': [
                  0,
                  {
                    'interface': [
                      {
                        'interface': 'wan',
                        'proto': 'dhcp',
                        'up': true,
                        'ipv4-address': [
                          {'address': '192.0.2.10'}
                        ]
                      }
                    ]
                  }
                ]
              }),
              200,
            );
          }
          if (object == 'session' && method == 'destroy') {
            return http.Response(jsonEncode({'result': [0, {}]}), 200);
          }
          return http.Response('unexpected ubus request', 500);
        }),
      );

      final snapshot = await client.inspect(
        address: 'http://192.168.1.1',
        username: 'root',
        password: 'not-logged',
        allowInsecureHttp: true,
      );
      expect(snapshot.hostname, 'OpenWrt');
      expect(snapshot.model, 'Test Router');
      expect(snapshot.version, '24.10.0');
      expect(snapshot.uptimeSeconds, 3600);
      expect(snapshot.interfaces.single['interface'], 'wan');
      expect(calls.length, 5);
      expect((calls.last['params'] as List<dynamic>)[2], 'destroy');
    });

    test('blocks plain HTTP to public addresses before sending credentials',
        () async {
      var sent = false;
      final client = OpenWrtClient(
        client: MockClient((request) async {
          sent = true;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        client.inspect(
          address: 'http://example.com',
          username: 'root',
          password: 'secret',
        ),
        throwsA(isA<OpenWrtException>()),
      );
      expect(sent, isFalse);
    });

    test('requires explicit opt-in before sending credentials over local HTTP',
        () async {
      var sent = false;
      final client = OpenWrtClient(
        client: MockClient((request) async {
          sent = true;
          return http.Response(jsonEncode({'result': [6]}), 200);
        }),
      );

      await expectLater(
        client.inspect(
          address: 'http://192.168.1.1',
          username: 'root',
          password: 'secret',
        ),
        throwsA(
          isA<OpenWrtException>().having(
            (error) => error.message,
            'message',
            contains('تأكيد'),
          ),
        ),
      );
      expect(sent, isFalse);

      await expectLater(
        client.inspect(
          address: 'http://192.168.1.1',
          username: 'root',
          password: 'secret',
          allowInsecureHttp: true,
        ),
        throwsA(isA<OpenWrtException>()),
      );
      expect(sent, isTrue);
    });

    test('does not trust local-looking DNS suffixes for plain HTTP', () async {
      var sent = false;
      final client = OpenWrtClient(
        client: MockClient((request) async {
          sent = true;
          return http.Response('{}', 200);
        }),
      );

      for (final address in [
        'http://router.lan',
        'http://router.local',
        'http://router.home.arpa',
      ]) {
        await expectLater(
          client.inspect(
            address: address,
            username: 'root',
            password: 'secret',
          ),
          throwsA(isA<OpenWrtException>()),
        );
      }
      expect(sent, isFalse);
    });

    test('rejects URL-embedded credentials and unexpected paths', () async {
      final client = OpenWrtClient(
        client: MockClient((request) async => http.Response('{}', 200)),
      );

      await expectLater(
        client.inspect(
          address: 'http://root:secret@192.168.1.1',
          username: 'root',
          password: 'secret',
        ),
        throwsA(isA<OpenWrtException>()),
      );
      await expectLater(
        client.inspect(
          address: 'http://192.168.1.1/cgi-bin/luci',
          username: 'root',
          password: 'secret',
        ),
        throwsA(isA<OpenWrtException>()),
      );
    });

    test('maps ubus permission denied to a safe message', () async {
      final client = OpenWrtClient(
        client: MockClient((request) async => http.Response(
              jsonEncode({'result': [6]}),
              200,
            )),
      );

      await expectLater(
        client.inspect(
          address: 'http://192.168.1.1',
          username: 'root',
          password: 'wrong',
          allowInsecureHttp: true,
        ),
        throwsA(
          isA<OpenWrtException>().having(
            (error) => error.message,
            'message',
            contains('صلاحيات'),
          ),
        ),
      );
    });
  });
}
