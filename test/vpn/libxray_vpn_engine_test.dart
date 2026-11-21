import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/vpn/libxray_vpn_engine.dart';

void main() {
  group('ShareLinkCompatibilityParser', () {
    test('parses legacy VMess QR JSON into a native Xray outbound', () {
      final encoded = base64Encode(utf8.encode(jsonEncode(<String, dynamic>{
        'v': '2',
        'ps': 'Legacy VMess',
        'add': 'vmess.example.com',
        'port': '443',
        'id': '12345678-abcd-abcd-abcd-123456789abc',
        'aid': '0',
        'scy': 'auto',
        'net': 'ws',
        'host': 'cdn.example.com',
        'path': '/connect',
        'tls': 'tls',
        'sni': 'vmess.example.com',
        'alpn': 'h2,http/1.1',
      })));

      final outbound = ShareLinkCompatibilityParser.parseLegacyVmessLink(
        'vmess://' + encoded + '#Legacy',
      );
      expect(outbound, isNotNull);
      expect(outbound!['protocol'], 'vmess');
      expect(outbound['tag'], 'Legacy VMess');
      final settings = outbound['settings'] as Map<String, dynamic>;
      final vnext = settings['vnext'] as List<dynamic>;
      expect(vnext.single['address'], 'vmess.example.com');
      final stream = outbound['streamSettings'] as Map<String, dynamic>;
      expect(stream['network'], 'ws');
      expect(stream['security'], 'tls');
      expect(stream['wsSettings']['path'], '/connect');
      expect(stream['wsSettings']['host'], 'cdn.example.com');
      expect(stream['tlsSettings']['serverName'], 'vmess.example.com');
      expect(stream['tlsSettings']['alpn'], <String>['h2', 'http/1.1']);
    });

    test('keeps modern VMess AEAD links for the official libXray converter', () {
      expect(
        ShareLinkCompatibilityParser.parseLegacyVmessLink(
          'vmess://12345678-abcd-abcd-abcd-123456789abc@vmess.example.com:443?encryption=auto',
        ),
        isNull,
      );
    });

    test('extracts legacy VMess and WireGuard URI nodes from mixed subscriptions', () {
      const wireGuardConfig = '''
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32

[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
Endpoint = wg.example.com:51820
''';
      final wireGuardEncoded = base64Url.encode(utf8.encode(wireGuardConfig)).replaceAll('=', '');
      final wireGuardLink = 'wireguard://' + wireGuardEncoded + '#WG';
      final vmessJson = jsonEncode(<String, dynamic>{
        'ps': 'Old VMess',
        'add': 'vmess.example.com',
        'port': '443',
        'id': '12345678-abcd-abcd-abcd-123456789abc',
        'net': 'tcp',
        'type': 'none',
      });
      final vmessLink = 'vmess://' + base64Encode(utf8.encode(vmessJson));
      final result = ShareLinkCompatibilityParser.extract(
        wireGuardLink + '\n' + vmessLink + '\nvless://server.example:443',
      );

      expect(result.outbounds, hasLength(2));
      expect(result.outbounds[0]['protocol'], 'wireguard');
      expect(result.outbounds[1]['protocol'], 'vmess');
      expect(result.remaining, contains('vless://server.example:443'));
    });
  });

  group('XrayClientConfigBuilder', () {
    test('adds safe default direct and block outbounds', () {
      final json = XrayClientConfigBuilder.fromOutbounds(<Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'node-1',
          'protocol': 'vless',
          'settings': <String, dynamic>{},
        },
      ]);

      expect(json, contains('"protocol": "vless"'));
      expect(json, contains('"tag": "iqt-direct"'));
      expect(json, contains('"tag": "iqt-block"'));
      expect(json, contains('"rules": []'));
      expect(json, isNot(contains('geoip:')));
      expect(json, contains('"stats": {}'));
      expect(json, contains('"statsInboundUplink": true'));
      expect(json, contains('"statsInboundDownlink": true'));
      expect(json, isNot(contains('"inboundUplink": true')));
      expect(json, isNot(contains('"inboundDownlink": true')));
      expect(json, contains('"system": {'));
    });

    test('preserves unique outbound tags and makes duplicate tags unique', () {
      final json = XrayClientConfigBuilder.fromOutbounds(<Map<String, dynamic>>[
        <String, dynamic>{'tag': 'node', 'protocol': 'vless'},
        <String, dynamic>{'tag': 'node', 'protocol': 'trojan'},
      ]);

      expect(json, contains('"tag": "node"'));
      expect(json, contains('"tag": "node-1"'));
    });


    test('reserves fallback tags without colliding with imported nodes', () {
      final json = XrayClientConfigBuilder.fromOutbounds(<Map<String, dynamic>>[
        <String, dynamic>{'tag': 'iqt-direct', 'protocol': 'vless'},
        <String, dynamic>{'tag': 'iqt-block', 'protocol': 'trojan'},
      ]);

      expect(json, contains('"tag": "iqt-direct-1"'));
      expect(json, contains('"tag": "iqt-block-1"'));
    });

    test('refuses an empty outbound set', () {
      expect(
        () => XrayClientConfigBuilder.fromOutbounds(<Map<String, dynamic>>[]),
        throwsFormatException,
      );
    });
  });
}
