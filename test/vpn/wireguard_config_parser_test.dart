import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/vpn/wireguard_config_parser.dart';

void main() {
  const privateKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  const peerKey = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';

  group('WireGuardConfigParser', () {
    test('converts a valid client profile into an Xray WireGuard outbound', () {
      final outbound = WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.66.0.2/32, fd00:1234::2/128
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1380
Reserved = 1, 2, 255

[Peer]
PublicKey = $peerKey
PresharedKey = $privateKey
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''');

      expect(outbound['protocol'], 'wireguard');
      expect(outbound['tag'], 'wireguard-import');
      final settings = outbound['settings'] as Map<String, dynamic>;
      expect(settings['isClient'], isTrue);
      expect(settings['noKernelTun'], isTrue);
      expect(settings['secretKey'], privateKey);
      expect(settings['address'], <String>['10.66.0.2/32', 'fd00:1234::2/128']);
      expect(settings['mtu'], 1380);
      expect(settings['remoteDNS'], <String>['1.1.1.1', '2606:4700:4700::1111']);
      expect(settings['reserved'], 'AQL/');
      final peers = settings['peers'] as List<dynamic>;
      expect(peers, hasLength(1));
      expect(peers.single['publicKey'], peerKey);
      expect(peers.single['preSharedKey'], privateKey);
      expect(peers.single['endpoint'], 'vpn.example.com:51820');
      expect(peers.single['allowedIPs'], <String>['0.0.0.0/0', '::/0']);
      expect(peers.single['keepAlive'], 25);
    });

    test('decodes standard Base64 and URL-safe WireGuard share links', () {
      const config = '''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/32

[Peer]
PublicKey = $peerKey
Endpoint = vpn.example.com:51820
''';
      final encoded = base64Url.encode(utf8.encode(config)).replaceAll('=', '');
      expect(
        WireGuardConfigParser.decodeShareLink('wireguard://' + encoded + '#Test%20Node'),
        config.trim(),
      );
      expect(
        WireGuardConfigParser.decodeShareLink('wg://' + encoded),
        config.trim(),
      );
    });

    test('rejects WireGuard share links without a valid encoded client config', () {
      expect(
        () => WireGuardConfigParser.decodeShareLink('wireguard://not-a-config'),
        throwsFormatException,
      );
    });

    test('supports bracketed IPv6 peer endpoints and multiple peers', () {
      final outbound = WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/32

[Peer]
PublicKey = $peerKey
Endpoint = [2001:db8::1]:51820

[Peer]
PublicKey = $privateKey
Endpoint = 192.0.2.10:53
''');

      final settings = outbound['settings'] as Map<String, dynamic>;
      final peers = settings['peers'] as List<dynamic>;
      expect(peers, hasLength(2));
      expect(peers.first['endpoint'], '[2001:db8::1]:51820');
      expect(peers.first.containsKey('allowedIPs'), isFalse);
    });

    test('ignores platform-specific commands but does not pass them to Xray', () {
      final outbound = WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/32
PostUp = iptables -A OUTPUT -j ACCEPT
SaveConfig = true

[Peer]
PublicKey = $peerKey
Endpoint = vpn.example.com:51820
''');

      final serialized = outbound.toString();
      expect(serialized, isNot(contains('iptables')));
      expect(serialized, isNot(contains('SaveConfig')));
    });

    test('rejects invalid private keys without exposing key contents', () {
      const invalidSecret = 'definitely-not-a-wireguard-key';
      expect(
        () => WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $invalidSecret
Address = 10.0.0.2/32

[Peer]
PublicKey = $peerKey
Endpoint = vpn.example.com:51820
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            isNot(contains(invalidSecret)),
          ),
        ),
      );
    });

    test('rejects missing peers, invalid endpoint ports and malformed CIDRs', () {
      expect(
        () => WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/32
'''),
        throwsFormatException,
      );
      expect(
        () => WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/32
[Peer]
PublicKey = $peerKey
Endpoint = vpn.example.com:70000
'''),
        throwsFormatException,
      );
      expect(
        () => WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/40
[Peer]
PublicKey = $peerKey
Endpoint = vpn.example.com:51820
'''),
        throwsFormatException,
      );
    });

    test('rejects duplicate interface sections and invalid Reserved bytes', () {
      expect(
        () => WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/32
[Interface]
PrivateKey = $privateKey
[Peer]
PublicKey = $peerKey
Endpoint = vpn.example.com:51820
'''),
        throwsFormatException,
      );
      expect(
        () => WireGuardConfigParser.parseToXrayOutbound('''
[Interface]
PrivateKey = $privateKey
Address = 10.0.0.2/32
Reserved = 1,2
[Peer]
PublicKey = $peerKey
Endpoint = vpn.example.com:51820
'''),
        throwsFormatException,
      );
    });
  });
}
