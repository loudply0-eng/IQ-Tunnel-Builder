import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Read-only JSON-RPC client for the OpenWrt ubus HTTP endpoint.
///
/// No UCI writes, shell commands, package installation, reboots or firmware
/// upgrades are exposed in this first integration phase.
class OpenWrtClient {
  OpenWrtClient({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const String _anonymousSession =
      '00000000000000000000000000000000';
  static const int _maxResponseBytes = 1024 * 1024;

  final http.Client _client;
  final bool _ownsClient;
  int _requestId = 0;

  Future<OpenWrtRouterSnapshot> inspect({
    required String address,
    required String username,
    required String password,
    bool allowInsecureHttp = false,
  }) async {
    final endpoint = _endpoint(
      address,
      allowInsecureHttp: allowInsecureHttp,
    );
    final cleanUsername = username.trim();
    if (cleanUsername.isEmpty || cleanUsername.length > 128) {
      throw const OpenWrtException('اسم مستخدم الراوتر غير صالح.');
    }
    if (password.isEmpty || password.length > 512) {
      throw const OpenWrtException('كلمة مرور الراوتر غير صالحة.');
    }

    String? sessionId;
    try {
      sessionId = await _login(endpoint, cleanUsername, password);
      final values = await Future.wait<Map<String, dynamic>>([
        _call(endpoint, sessionId, 'system', 'board', const {}),
        _call(endpoint, sessionId, 'system', 'info', const {}),
        _call(endpoint, sessionId, 'network.interface', 'dump', const {}),
      ]);

      final interfacesValue = values[2]['interface'];
      final interfaces = interfacesValue is List
          ? interfacesValue
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(growable: false)
          : const <Map<String, dynamic>>[];

      return OpenWrtRouterSnapshot(
        board: values[0],
        system: values[1],
        interfaces: interfaces,
      );
    } finally {
      if (sessionId != null) {
        try {
          await _call(endpoint, sessionId, 'session', 'destroy', const {});
        } catch (_) {
          // The router also expires this short-lived session automatically.
        }
      }
    }
  }

  Future<String> _login(Uri endpoint, String username, String password) async {
    final response = await _rpc(
      endpoint,
      _anonymousSession,
      'session',
      'login',
      <String, dynamic>{
        'username': username,
        'password': password,
        'timeout': 120,
      },
    );
    final id = response['ubus_rpc_session'];
    if (id is! String ||
        id.length != 32 ||
        !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(id)) {
      throw const OpenWrtException(
        'رفض الراوتر تسجيل الدخول أو لم يُرجع جلسة صالحة.',
      );
    }
    return id;
  }

  Future<Map<String, dynamic>> _call(
    Uri endpoint,
    String sessionId,
    String object,
    String method,
    Map<String, dynamic> arguments,
  ) =>
      _rpc(endpoint, sessionId, object, method, arguments);

  Future<Map<String, dynamic>> _rpc(
    Uri endpoint,
    String sessionId,
    String object,
    String method,
    Map<String, dynamic> arguments,
  ) async {
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/json'
      ..body = jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': ++_requestId,
        'method': 'call',
        'params': <dynamic>[sessionId, object, method, arguments],
      });

    late http.StreamedResponse streamed;
    try {
      streamed = await _client.send(request).timeout(
            const Duration(seconds: 12),
          );
    } on SocketException {
      throw const OpenWrtException(
        'تعذر الوصول للراوتر. تأكد أن الهاتف متصل بشبكته وأن العنوان صحيح.',
      );
    } on HandshakeException {
      throw const OpenWrtException(
        'فشل التحقق من شهادة HTTPS للراوتر. استخدم شهادة موثوقة أو اتصال LAN آمن.',
      );
    } on HttpException {
      throw const OpenWrtException('تعذر إكمال اتصال HTTP مع الراوتر.');
    } on Exception {
      throw const OpenWrtException(
        'انتهت مهلة الاتصال بالراوتر أو تعذر إنشاء الطلب.',
      );
    }

    final declaredLength = int.tryParse(
      streamed.headers['content-length'] ?? '',
    );
    if (declaredLength != null && declaredLength > _maxResponseBytes) {
      throw const OpenWrtException(
        'استجابة الراوتر أكبر من الحد المسموح به.',
      );
    }
    if (streamed.isRedirect) {
      throw const OpenWrtException(
        'الراوتر أعاد توجيه الطلب؛ استخدم عنوان الإدارة الصحيح مباشرة.',
      );
    }
    if (streamed.statusCode != 200) {
      if (streamed.statusCode == 401 || streamed.statusCode == 403) {
        throw const OpenWrtException(
          'الراوتر رفض الوصول إلى واجهة ubus. تحقق من صلاحيات rpcd واسم المستخدم.',
        );
      }
      if (streamed.statusCode == 404) {
        throw const OpenWrtException(
          'واجهة /ubus غير موجودة. تأكد من تثبيت rpcd وتهيئة واجهة ubus في OpenWrt.',
        );
      }
      throw OpenWrtException(
        'الراوتر ردّ برمز HTTP ${streamed.statusCode}.',
      );
    }
    final responseBytes = BytesBuilder(copy: false);
    var receivedBytes = 0;
    try {
      await for (final chunk in streamed.stream.timeout(
        const Duration(seconds: 12),
      )) {
        receivedBytes += chunk.length;
        if (receivedBytes > _maxResponseBytes) {
          throw const OpenWrtException(
            'استجابة الراوتر أكبر من الحد المسموح به.',
          );
        }
        responseBytes.add(chunk);
      }
    } on OpenWrtException {
      rethrow;
    } on Exception {
      throw const OpenWrtException(
        'انقطع الاتصال أثناء قراءة استجابة الراوتر.',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(responseBytes.takeBytes()));
    } on FormatException {
      throw const OpenWrtException(
        'استجابة الراوتر ليست JSON صالحاً؛ قد لا تكون واجهة ubus مفعّلة.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const OpenWrtException('صيغة استجابة ubus غير متوقعة.');
    }
    if (decoded['error'] != null) {
      throw const OpenWrtException('الراوتر رفض طلب ubus.');
    }

    final result = decoded['result'];
    if (result is! List || result.isEmpty || result.first is! num) {
      throw const OpenWrtException('الراوتر أرجع نتيجة ubus غير مكتملة.');
    }
    final code = (result.first as num).toInt();
    if (code != 0) {
      if (code == 6) {
        throw const OpenWrtException(
          'صلاحيات حساب الراوتر لا تسمح بقراءة هذه المعلومات.',
        );
      }
      throw OpenWrtException('فشل طلب ubus (الرمز $code).');
    }
    if (result.length < 2 || result[1] is! Map) {
      return <String, dynamic>{};
    }
    return Map<String, dynamic>.from(result[1] as Map);
  }

  Uri _endpoint(
    String input, {
    required bool allowInsecureHttp,
  }) {
    var value = input.trim();
    if (value.isEmpty || value.length > 253) {
      throw const OpenWrtException('عنوان الراوتر غير صالح.');
    }
    if (!value.contains('://')) value = 'http://$value';

    final parsed = Uri.tryParse(value);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        (parsed.path.isNotEmpty && parsed.path != '/') ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw const OpenWrtException(
        'اكتب عنوان الراوتر مثل http://192.168.1.1 أو https://router.example.',
      );
    }

    if (parsed.scheme == 'http') {
      if (!_isPrivateOrLocalHost(parsed.host)) {
        throw const OpenWrtException(
          'الاتصال غير المشفر مرفوض للعناوين العامة. استخدم HTTPS للوصول الخارجي.',
        );
      }
      if (!allowInsecureHttp) {
        throw const OpenWrtException(
          'هذا الراوتر يستخدم HTTP غير مشفر. يجب تأكيد المخاطر صراحةً قبل إرسال بيانات الدخول.',
        );
      }
    }
    return parsed.replace(path: '/ubus', query: null, fragment: null);
  }

  bool _isPrivateOrLocalHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost') {
      return true;
    }
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      final a = bytes[0];
      final b = bytes[1];
      return a == 10 ||
          a == 127 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 169 && b == 254);
    }
    if (bytes.length == 16) {
      final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
      final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
      return address.isLoopback || uniqueLocal || linkLocal;
    }
    return false;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class OpenWrtException implements Exception {
  const OpenWrtException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OpenWrtRouterSnapshot {
  const OpenWrtRouterSnapshot({
    required this.board,
    required this.system,
    required this.interfaces,
  });

  final Map<String, dynamic> board;
  final Map<String, dynamic> system;
  final List<Map<String, dynamic>> interfaces;

  String get hostname => _string(board['hostname'], fallback: 'OpenWrt');
  String get model => _string(board['model'], fallback: 'راوتر OpenWrt');
  String get version {
    final release = board['release'];
    if (release is Map) {
      return _string(
        release['version'],
        fallback: _string(release['description'], fallback: 'غير معروف'),
      );
    }
    return 'غير معروف';
  }

  int get uptimeSeconds =>
      system['uptime'] is num ? (system['uptime'] as num).toInt() : 0;

  List<num> get loadAverages {
    final value = system['load'];
    if (value is! List) return const <num>[];
    return value.whereType<num>().take(3).toList(growable: false);
  }

  Map<String, dynamic> get memory {
    final value = system['memory'];
    return value is Map ? Map<String, dynamic>.from(value) : const {};
  }

  static String _string(Object? value, {required String fallback}) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? fallback : result;
  }
}
