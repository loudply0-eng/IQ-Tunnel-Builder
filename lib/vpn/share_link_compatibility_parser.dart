import 'dart:convert';
import 'dart:io';

import 'wireguard_config_parser.dart';

/// Parsed compatibility links and the remainder for the native converter.
class ShareLinkCompatibilityImport {
  const ShareLinkCompatibilityImport({
    required this.outbounds,
    required this.remaining,
  });

  final List<Map<String, dynamic>> outbounds;
  final String remaining;
}

/// Compatibility parser for legacy VMess QR JSON and WireGuard share URIs.
/// Modern share-link formats are passed to the official libXray converter.
class ShareLinkCompatibilityParser {
  const ShareLinkCompatibilityParser._();

  static ShareLinkCompatibilityImport extract(String payload) {
    var source = payload.trim();
    if (source.isEmpty) {
      return const ShareLinkCompatibilityImport(
        outbounds: <Map<String, dynamic>>[],
        remaining: '',
      );
    }

    // Accept a standard WireGuard client .conf file directly.
    if (RegExp(r'^\s*\[Interface\]\s*$', multiLine: true, caseSensitive: false).hasMatch(source)) {
      return ShareLinkCompatibilityImport(
        outbounds: <Map<String, dynamic>>[
          WireGuardConfigParser.parseToXrayOutbound(source),
        ],
        remaining: '',
      );
    }

    // Decode a Base64-wrapped subscription only when it contains known links.
    if (!source.contains('://')) {
      final decoded = _decodeBase64Text(source);
      if (decoded != null &&
          (RegExp(r'^\s*(?:wireguard|wg|vmess)://', multiLine: true, caseSensitive: false).hasMatch(decoded) ||
              RegExp(r'^\s*\[Interface\]\s*$', multiLine: true, caseSensitive: false).hasMatch(decoded))) {
        source = decoded.trim();
      }
    }

    final outbounds = <Map<String, dynamic>>[];
    final remaining = <String>[];
    for (final rawLine in source.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final wireGuardConfig = WireGuardConfigParser.decodeShareLink(line);
      if (wireGuardConfig != null) {
        outbounds.add(WireGuardConfigParser.parseToXrayOutbound(wireGuardConfig));
        continue;
      }

      final legacyVmess = parseLegacyVmessLink(line);
      if (legacyVmess != null) {
        outbounds.add(legacyVmess);
        continue;
      }

      remaining.add(line);
    }

    return ShareLinkCompatibilityImport(
      outbounds: List<Map<String, dynamic>>.unmodifiable(outbounds),
      remaining: remaining.join('\n').trim(),
    );
  }

  /// Parses legacy vmess://Base64(JSON) QR links. Modern vmess://UUID@host
  /// links are deliberately passed to the official converter.
  static Map<String, dynamic>? parseLegacyVmessLink(String source) {
    final trimmed = source.trim();
    if (!trimmed.toLowerCase().startsWith('vmess://')) return null;

    final encoded = trimmed.substring('vmess://'.length).split('#').first.trim();
    if (encoded.isEmpty || encoded.contains('@')) return null;

    final decoded = _decodeBase64Text(encoded);
    if (decoded == null || !decoded.trimLeft().startsWith('{')) return null;

    final Object? document;
    try {
      document = jsonDecode(decoded);
    } catch (_) {
      return null;
    }
    if (document is! Map) return null;
    final values = Map<String, dynamic>.from(document);

    final address = values['add']?.toString().trim() ?? '';
    final id = values['id']?.toString().trim() ?? '';
    final port = int.tryParse(values['port']?.toString() ?? '');
    final hostPattern = RegExp(
      r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$',
    );
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    if (address.isEmpty ||
        (InternetAddress.tryParse(address) == null && !hostPattern.hasMatch(address)) ||
        !uuidPattern.hasMatch(id) ||
        port == null ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('رابط VMess القديم يحتوي عنواناً أو UUID أو منفذاً غير صالح.');
    }

    final alterId = int.tryParse(values['aid']?.toString() ?? '0') ?? -1;
    if (alterId < 0 || alterId > 65535) {
      throw const FormatException('قيمة VMess alterId غير صالحة.');
    }

    final cipher = (values['scy'] ?? values['security'] ?? 'auto')
        .toString()
        .toLowerCase();
    const supportedCiphers = <String>{
      'auto',
      'aes-128-gcm',
      'chacha20-poly1305',
      'none',
    };
    if (!supportedCiphers.contains(cipher)) {
      throw const FormatException('تشفير رابط VMess القديم غير مدعوم.');
    }

    final network = (values['net'] ?? 'tcp').toString().toLowerCase();
    final transportType = (values['type'] ?? '').toString().toLowerCase();
    final path = (values['path'] ?? '').toString();
    final host = (values['host'] ?? '').toString();
    final streamSettings = <String, dynamic>{
      'network': network == 'tcp' ? 'raw' : network,
      'security': 'none',
    };

    switch (network) {
      case 'tcp':
        if (transportType == 'http') {
          final paths = path.isEmpty ? <String>['/'] : path.split(',');
          final hosts = host.isEmpty ? <String>[] : host.split(',');
          final headers = <String, dynamic>{};
          if (hosts.isNotEmpty) headers['Host'] = hosts;
          final request = <String, dynamic>{'path': paths};
          if (headers.isNotEmpty) request['headers'] = headers;
          streamSettings['rawSettings'] = <String, dynamic>{
            'header': <String, dynamic>{
              'type': 'http',
              'request': request,
            },
          };
        } else if (transportType.isNotEmpty && transportType != 'none') {
          throw const FormatException('نوع TCP header في رابط VMess القديم غير مدعوم.');
        }
        break;
      case 'ws':
        streamSettings['wsSettings'] = <String, dynamic>{
          if (path.isNotEmpty) 'path': path,
          if (host.isNotEmpty) 'host': host,
        };
        break;
      case 'grpc':
        final mode = (values['mode'] ?? transportType).toString().toLowerCase();
        if (mode.isNotEmpty && mode != 'gun' && mode != 'multi') {
          throw const FormatException('وضع gRPC في رابط VMess القديم غير مدعوم.');
        }
        streamSettings['grpcSettings'] = <String, dynamic>{
          if (path.isNotEmpty) 'serviceName': path,
          if (host.isNotEmpty) 'authority': host,
          'multiMode': mode == 'multi',
        };
        break;
      default:
        throw FormatException('نقل VMess القديم من نوع $network غير مدعوم حالياً.');
    }

    final tls = (values['tls'] ?? '').toString().toLowerCase();
    if (tls == 'tls' || tls == 'true' || tls == '1') {
      streamSettings['security'] = 'tls';
      final serverName = (values['sni'] ?? address).toString();
      final alpnValue = values['alpn'];
      final alpn = alpnValue is List
          ? alpnValue.map((item) => item.toString()).toList()
          : (alpnValue?.toString() ?? '')
              .split(',')
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toList();
      final tlsSettings = <String, dynamic>{'serverName': serverName};
      if (alpn.isNotEmpty) tlsSettings['alpn'] = alpn;
      final fingerprint = values['fp']?.toString();
      if (fingerprint != null && fingerprint.isNotEmpty) {
        tlsSettings['fingerprint'] = fingerprint;
      }
      if (values['allowInsecure']?.toString().toLowerCase() == 'true') {
        tlsSettings['allowInsecure'] = true;
      }
      streamSettings['tlsSettings'] = tlsSettings;
    } else if (tls.isNotEmpty && tls != 'none' && tls != 'false' && tls != '0') {
      throw const FormatException('نوع TLS في رابط VMess القديم غير مدعوم.');
    }

    final name = (values['ps'] ?? '').toString().trim();
    return <String, dynamic>{
      'tag': name.isEmpty ? 'legacy-vmess' : name,
      'protocol': 'vmess',
      'settings': <String, dynamic>{
        'vnext': <Map<String, dynamic>>[
          <String, dynamic>{
            'address': address,
            'port': port,
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': id,
                'alterId': alterId,
                'security': cipher,
              },
            ],
          },
        ],
      },
      'streamSettings': streamSettings,
    };
  }

  static String? _decodeBase64Text(String value) {
    try {
      var normalized = Uri.decodeComponent(value.trim());
      normalized = normalized.replaceAll('-', '+').replaceAll('_', '/');
      if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(normalized)) {
        return null;
      }
      final remainder = normalized.length % 4;
      if (remainder != 0) {
        normalized += List<String>.filled(4 - remainder, '=').join();
      }
      return utf8.decode(base64.decode(normalized), allowMalformed: false);
    } catch (_) {
      return null;
    }
  }
}
