import 'dart:convert';
import 'dart:io';

/// Converts a standard WireGuard client .conf file into an Xray WireGuard
/// outbound. No source text, private key or peer credential is logged.
class WireGuardConfigParser {
  const WireGuardConfigParser._();

  /// Decodes Base64 wireguard:// and wg:// client configuration links.
  static String? decodeShareLink(String source) {
    final trimmed = source.trim();
    final match = RegExp(
      r'^(?:wireguard|wg)://([^#]+)(?:#.*)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match == null) return null;
    var encoded = match.group(1)!.trim();
    if (encoded.isEmpty || encoded.contains('?')) {
      throw const FormatException('WireGuard share link must contain Base64 configuration.');
    }
    try {
      encoded = Uri.decodeComponent(encoded).replaceAll('-', '+').replaceAll('_', '/');
      final remainder = encoded.length % 4;
      if (remainder != 0) {
        encoded += List<String>.filled(4 - remainder, '=').join();
      }
      final decoded = utf8.decode(base64.decode(encoded), allowMalformed: false).trim();
      final hasInterface = RegExp(r'^\s*\[Interface\]\s*$', multiLine: true, caseSensitive: false).hasMatch(decoded);
      final hasPeer = RegExp(r'^\s*\[Peer\]\s*$', multiLine: true, caseSensitive: false).hasMatch(decoded);
      if (!hasInterface || !hasPeer) {
        throw const FormatException('WireGuard link does not contain a standard client config.');
      }
      return decoded;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('WireGuard share link has invalid Base64 data.');
    }
  }
  static Map<String, dynamic> parseToXrayOutbound(
    String source, {
    String tag = 'wireguard-import',
  }) {
    if (source.trim().isEmpty) {
      throw const FormatException('WireGuard configuration is empty.');
    }
    if (tag.trim().isEmpty) {
      throw const FormatException('WireGuard outbound tag cannot be empty.');
    }

    final interfaceValues = <String, String>{};
    final peers = <Map<String, String>>[];
    Map<String, String>? currentPeer;
    var inInterface = false;
    var sawInterface = false;
    var lineNumber = 0;

    for (final rawLine in const LineSplitter().convert(source)) {
      lineNumber++;
      final line = rawLine.split('#').first.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('[') && line.endsWith(']')) {
        final section = line.substring(1, line.length - 1).trim().toLowerCase();
        if (section == 'interface') {
          if (sawInterface) {
            throw FormatException('Only one [Interface] section is supported (line ' + lineNumber.toString() + ').');
          }
          sawInterface = true;
          inInterface = true;
          currentPeer = null;
        } else if (section == 'peer') {
          if (!sawInterface) {
            throw FormatException('[Interface] must appear before [Peer] (line ' + lineNumber.toString() + ').');
          }
          inInterface = false;
          currentPeer = <String, String>{};
          peers.add(currentPeer);
        } else {
          throw FormatException('Unsupported WireGuard section at line ' + lineNumber.toString() + '.');
        }
        continue;
      }

      final separator = line.indexOf('=');
      if (separator <= 0) {
        throw FormatException('Invalid WireGuard setting at line ' + lineNumber.toString() + '.');
      }
      final key = line.substring(0, separator).trim().toLowerCase();
      final value = line.substring(separator + 1).trim();
      if (value.isEmpty) {
        throw FormatException('WireGuard setting "' + key + '" is empty at line ' + lineNumber.toString() + '.');
      }

      final target = inInterface ? interfaceValues : currentPeer;
      if (target == null) {
        throw FormatException('WireGuard setting is outside a section at line ' + lineNumber.toString() + '.');
      }

      const interfaceKeys = <String>{
        'privatekey',
        'address',
        'dns',
        'mtu',
        'reserved',
      };
      const peerKeys = <String>{
        'publickey',
        'presharedkey',
        'endpoint',
        'allowedips',
        'persistentkeepalive',
      };
      final supported = inInterface ? interfaceKeys : peerKeys;
      if (!supported.contains(key)) {
        // Ignore OS-specific directives such as PostUp, Table and SaveConfig.
        // They are not part of the Xray client outbound model.
        continue;
      }
      if (target.containsKey(key)) {
        throw FormatException('Duplicate WireGuard setting "' + key + '" at line ' + lineNumber.toString() + '.');
      }
      target[key] = value;
    }

    if (!sawInterface || !interfaceValues.containsKey('privatekey')) {
      throw const FormatException('WireGuard [Interface] must contain PrivateKey.');
    }
    if (peers.isEmpty) {
      throw const FormatException('WireGuard configuration must contain at least one [Peer].');
    }

    final secretKey = _validateKey(interfaceValues['privatekey']!, 'PrivateKey');
    final addresses = _splitList(interfaceValues['address'], 'Address');
    if (addresses.isEmpty) {
      throw const FormatException('WireGuard [Interface] must contain Address.');
    }
    for (final address in addresses) {
      _validateCidr(address, 'Address');
    }

    final dns = _splitList(interfaceValues['dns'], 'DNS');
    for (final server in dns) {
      if (InternetAddress.tryParse(server) == null) {
        throw const FormatException('WireGuard DNS entries must be IP addresses.');
      }
    }

    final mtu = int.tryParse(interfaceValues['mtu'] ?? '1420');
    if (mtu == null || mtu < 576 || mtu > 9000) {
      throw const FormatException('WireGuard MTU must be between 576 and 9000.');
    }

    final reserved = _parseReserved(interfaceValues['reserved']);
    final xrayPeers = <Map<String, dynamic>>[];
    for (var index = 0; index < peers.length; index++) {
      final peer = peers[index];
      final peerLabel = 'WireGuard peer ' + (index + 1).toString();
      final publicKeyRaw = peer['publickey'];
      if (publicKeyRaw == null) {
        throw FormatException(peerLabel + ' is missing PublicKey.');
      }
      final publicKey = _validateKey(publicKeyRaw, 'Peer PublicKey');
      final endpoint = peer['endpoint'];
      if (endpoint == null) {
        throw FormatException(peerLabel + ' is missing Endpoint.');
      }
      _validateEndpoint(endpoint);

      final xrayPeer = <String, dynamic>{
        'publicKey': publicKey,
        'endpoint': endpoint,
      };
      final psk = peer['presharedkey'];
      if (psk != null) {
        xrayPeer['preSharedKey'] = _validateKey(psk, 'Peer PresharedKey');
      }

      final allowedIps = _splitList(peer['allowedips'], 'AllowedIPs');
      for (final cidr in allowedIps) {
        _validateCidr(cidr, 'AllowedIPs');
      }
      if (allowedIps.isNotEmpty) {
        xrayPeer['allowedIPs'] = allowedIps;
      }

      final keepAlive = peer['persistentkeepalive'];
      if (keepAlive != null) {
        final seconds = int.tryParse(keepAlive);
        if (seconds == null || seconds < 0 || seconds > 65535) {
          throw FormatException(peerLabel + ' has an invalid PersistentKeepalive.');
        }
        if (seconds > 0) xrayPeer['keepAlive'] = seconds;
      }
      xrayPeers.add(xrayPeer);
    }

    final settings = <String, dynamic>{
      'isClient': true,
      'noKernelTun': true,
      'secretKey': secretKey,
      'address': addresses,
      'peers': xrayPeers,
      'mtu': mtu,
    };
    if (dns.isNotEmpty) settings['remoteDNS'] = dns;
    if (reserved != null) settings['reserved'] = base64Encode(reserved);

    return <String, dynamic>{
      'tag': tag,
      'protocol': 'wireguard',
      'settings': settings,
    };
  }

  static String _validateKey(String value, String label) {
    try {
      final decoded = base64Decode(value);
      if (decoded.length != 32) throw const FormatException();
      return base64Encode(decoded);
    } on FormatException {
      throw FormatException(label + ' must be a valid 32-byte base64 WireGuard key.');
    }
  }

  static List<String> _splitList(String? value, String label) {
    if (value == null || value.trim().isEmpty) return <String>[];
    final values = value.split(',').map((part) => part.trim()).toList();
    if (values.any((part) => part.isEmpty)) {
      throw FormatException(label + ' contains an empty entry.');
    }
    return values;
  }

  static void _validateCidr(String value, String label) {
    final parts = value.split('/');
    if (parts.length != 2) {
      throw FormatException(label + ' entry must include a CIDR prefix.');
    }
    final address = InternetAddress.tryParse(parts[0]);
    final prefix = int.tryParse(parts[1]);
    final maxPrefix = address?.type == InternetAddressType.IPv4 ? 32 : 128;
    if (address == null || prefix == null || prefix < 0 || prefix > maxPrefix) {
      throw FormatException(label + ' entry has an invalid IP address or CIDR prefix.');
    }
  }

  static void _validateEndpoint(String value) {
    String host;
    String portText;
    if (value.startsWith('[')) {
      final closing = value.indexOf(']');
      if (closing < 0 || closing + 1 >= value.length || value[closing + 1] != ':') {
        throw const FormatException('WireGuard Endpoint must include a host and port.');
      }
      host = value.substring(1, closing);
      portText = value.substring(closing + 2);
      final ip = InternetAddress.tryParse(host);
      if (ip == null || ip.type != InternetAddressType.IPv6) {
        throw const FormatException('WireGuard Endpoint has an invalid IPv6 host.');
      }
    } else {
      final separator = value.lastIndexOf(':');
      if (separator <= 0 || value.substring(0, separator).contains(':')) {
        throw const FormatException('IPv6 WireGuard endpoints must use brackets.');
      }
      host = value.substring(0, separator);
      portText = value.substring(separator + 1);
      final ip = InternetAddress.tryParse(host);
      final isDomain = RegExp(
        r'^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
      ).hasMatch(host);
      if (ip == null && !isDomain) {
        throw const FormatException('WireGuard Endpoint has an invalid host.');
      }
    }
    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('WireGuard Endpoint port must be between 1 and 65535.');
    }
  }

  static List<int>? _parseReserved(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split(',').map((part) => int.tryParse(part.trim())).toList();
    if (parts.length != 3 ||
        parts.any((part) => part == null || part < 0 || part > 255)) {
      throw const FormatException('WireGuard Reserved must contain exactly three byte values.');
    }
    return parts.cast<int>();
  }
}
