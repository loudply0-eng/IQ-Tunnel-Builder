import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry, kReleaseMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';
import 'openwrt/openwrt_page.dart';
import 'security/encrypted_profile_store.dart';
import 'vpn/libxray_vpn_engine.dart';
import 'vpn/vpn_engine.dart';
import 'update/android_package_installer.dart';
import 'security/encrypted_vault.dart';

const updateManifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL', defaultValue: 'https://mahmoudaljuorany.store/updates/iq-tunnel/manifest.json');
const updatePublicKeyBase64 = String.fromEnvironment('UPDATE_PUBLIC_KEY', defaultValue: '4eOsYpXniRBp1ZTJjq5c3HbDW8tCvWbv1fr5PLVl+sk=');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const <String>['XTLS/libXray'],
      await rootBundle.loadString('assets/licenses/libxray-MIT.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      const <String>['XTLS/Xray-core'],
      await rootBundle.loadString('assets/licenses/xray-core-MPL-2.0.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      const <String>['IQ Tunnel third-party notices'],
      await rootBundle.loadString('assets/licenses/THIRD_PARTY_NOTICES.txt'),
    );
  });
  runApp(const IqTunnelApp());
}

class IqTunnelApp extends StatefulWidget {
  const IqTunnelApp({super.key, this.vpnEngine, this.updateServiceFactory});

  final VpnEngine? vpnEngine;
  final UpdateService Function()? updateServiceFactory;

  @override
  State<IqTunnelApp> createState() => _IqTunnelAppState();
}

class _IqTunnelAppState extends State<IqTunnelApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  Color _accentColor = appThemePalettes.first.color;

  @override
  void initState() {
    super.initState();
    _loadAppearance();
  }

  Future<void> _loadAppearance() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString('app_theme_mode');
    final mode = ThemeMode.values.firstWhere(
      (item) => item.name == savedMode,
      orElse: () => ThemeMode.dark,
    );
    final savedColor = prefs.getInt('app_theme_accent');
    final palette = appThemePalettes.firstWhere(
      (item) => item.color.value == savedColor,
      orElse: () => appThemePalettes.first,
    );
    if (!mounted) return;
    setState(() {
      _themeMode = mode;
      _accentColor = palette.color;
    });
  }

  Future<void> _setThemeMode(ThemeMode value) async {
    setState(() => _themeMode = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme_mode', value.name);
  }

  Future<void> _setAccentColor(Color value) async {
    setState(() => _accentColor = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_theme_accent', value.value);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'IQ Tunnel',
        debugShowCheckedModeBanner: false,
        theme: buildIqTunnelTheme(Brightness.light, _accentColor),
        darkTheme: buildIqTunnelTheme(Brightness.dark, _accentColor),
        themeMode: _themeMode,
        home: HomePage(
          themeMode: _themeMode,
          accentColor: _accentColor,
          onThemeModeChanged: _setThemeMode,
          onAccentColorChanged: _setAccentColor,
          vpnEngine: widget.vpnEngine,
          updateServiceFactory: widget.updateServiceFactory,
        ),
      );
}


const Map<String, Map<String, String>> _translations = {
  'ar': {'checking':'جارٍ الفحص...','settings':'الإعدادات','language':'لغة التطبيق','updates':'تحديثات التطبيق','checkUpdates':'فحص تحديثات التطبيق','serviceUnavailable':'خدمة التحديثات غير متاحة حالياً. حاول لاحقاً.','networkError':'تعذر الاتصال بخدمة التحديثات. تحقق من الإنترنت.','invalidUpdate':'بيانات التحديث غير صالحة أو تعذر التحقق منها.','tagline':'اتصل بلا حدود','connectionDev':'محرك الاتصال قيد التطوير','version':'الإصدار','about':'حول التطبيق','automatic':'يمكن تغيير اللغة في أي وقت.','latest':'أنت تستخدم أحدث إصدار من IQ Tunnel.','newUpdate':'تحديث جديد متوفر','later':'لاحقاً','downloadInstall':'تنزيل وتثبيت'},
  'en': {'checking':'Checking...','settings':'Settings','language':'App language','updates':'App updates','checkUpdates':'Check for app updates','serviceUnavailable':'The update service is not available yet. Please try again later.','networkError':'Could not connect to the update service. Check your internet.','invalidUpdate':'Update information is invalid or could not be verified.','tagline':'CONNECT WITHOUT LIMITS','connectionDev':'Connection engine is under development','version':'Version','about':'About','automatic':'You can change the language at any time.','latest':'You are using the latest version of IQ Tunnel.','newUpdate':'New update available','later':'Later','downloadInstall':'Download and install'},
  'ku': {'settings':'ڕێکخستنەکان','language':'زمانی ئەپەکە','updates':'نوێکردنەوەی ئەپەکە','checkUpdates':'پشکنینی نوێکردنەوە','serviceUnavailable':'خزمەتگوزاری نوێکردنەوە ئێستا بەردەست نییە.','networkError':'نەتوانرا پەیوەندی بە خزمەتگوزاری نوێکردنەوەوە بکرێت.','invalidUpdate':'زانیاری نوێکردنەوە نادروستە.','tagline':'بێ سنوور پەیوەندی بکە','connectionDev':'موتۆری پەیوەندی لەژێر گەشەپێداندایە','version':'وەشان','about':'دەربارەی ئەپەکە','automatic':'دەتوانیت هەر کاتێک زمان بگۆڕیت.','latest':'نوێترین وەشانی IQ Tunnel بەکاردەهێنیت.','newUpdate':'نوێکردنەوەی نوێ بەردەستە','later':'دواتر','downloadInstall':'داگرتن و دامەزراندن'},
  'kmr': {'settings':'Mîheng','language':'Zimanê sepanê','updates':'Nûkirinên sepanê','checkUpdates':'Nûkirinan kontrol bike','serviceUnavailable':'Xizmeta nûkirinê niha ne berdest e.','networkError':'Girêdan bi xizmeta nûkirinê re pêk nehat.','invalidUpdate':'Agahiyên nûkirinê ne derbasdar in.','tagline':'BÊ SÎNOR GIRÊ BIDE','connectionDev':'Motora girêdanê di pêşveçûnê de ye','version':'Guherto','about':'Derbarê sepanê','automatic':'Tu dikarî zimanê biguherînî.','latest':'Tu guhertoya herî nû ya IQ Tunnel bi kar tînî.','newUpdate':'Nûkirineke nû heye','later':'Paşê','downloadInstall':'Daxîne û saz bike'},
  'tr': {'settings':'Ayarlar','language':'Uygulama dili','updates':'Uygulama güncellemeleri','checkUpdates':'Güncellemeleri kontrol et','serviceUnavailable':'Güncelleme hizmeti şu anda kullanılamıyor.','networkError':'Güncelleme hizmetine bağlanılamadı.','invalidUpdate':'Güncelleme bilgileri geçersiz.','tagline':'SINIRLAR OLMADAN BAĞLAN','connectionDev':'Bağlantı motoru geliştirme aşamasında','version':'Sürüm','about':'Hakkında','automatic':'Dili istediğiniz zaman değiştirebilirsiniz.','latest':'En son IQ Tunnel sürümünü kullanıyorsunuz.','newUpdate':'Yeni güncelleme mevcut','later':'Daha sonra','downloadInstall':'İndir ve yükle'},
  'fa': {'settings':'تنظیمات','language':'زبان برنامه','updates':'به‌روزرسانی برنامه','checkUpdates':'بررسی به‌روزرسانی','serviceUnavailable':'سرویس به‌روزرسانی موقتاً در دسترس نیست.','networkError':'اتصال به سرویس به‌روزرسانی ممکن نشد.','invalidUpdate':'اطلاعات به‌روزرسانی معتبر نیست.','tagline':'بدون محدودیت متصل شوید','connectionDev':'موتور اتصال در حال توسعه است','version':'نسخه','about':'درباره برنامه','automatic':'هر زمان می‌توانید زبان را تغییر دهید.','latest':'از آخرین نسخه IQ Tunnel استفاده می‌کنید.','newUpdate':'به‌روزرسانی جدید موجود است','later':'بعداً','downloadInstall':'دانلود و نصب'},
  'fr': {'settings':'Paramètres','language':'Langue de l’application','updates':'Mises à jour','checkUpdates':'Rechercher des mises à jour','serviceUnavailable':'Le service de mise à jour est temporairement indisponible.','networkError':'Impossible de joindre le service de mise à jour.','invalidUpdate':'Les informations de mise à jour sont invalides.','tagline':'CONNECTEZ-VOUS SANS LIMITES','connectionDev':'Le moteur de connexion est en développement','version':'Version','about':'À propos','automatic':'Vous pouvez changer la langue à tout moment.','latest':'Vous utilisez la dernière version de IQ Tunnel.','newUpdate':'Nouvelle mise à jour disponible','later':'Plus tard','downloadInstall':'Télécharger et installer'},
  'es': {'settings':'Ajustes','language':'Idioma de la aplicación','updates':'Actualizaciones','checkUpdates':'Buscar actualizaciones','serviceUnavailable':'El servicio de actualizaciones no está disponible temporalmente.','networkError':'No se pudo conectar al servicio de actualizaciones.','invalidUpdate':'La información de actualización no es válida.','tagline':'CONECTA SIN LÍMITES','connectionDev':'El motor de conexión está en desarrollo','version':'Versión','about':'Acerca de','automatic':'Puedes cambiar el idioma en cualquier momento.','latest':'Usas la última versión de IQ Tunnel.','newUpdate':'Nueva actualización disponible','later':'Más tarde','downloadInstall':'Descargar e instalar'},
  'de': {'settings':'Einstellungen','language':'App-Sprache','updates':'App-Updates','checkUpdates':'Nach Updates suchen','serviceUnavailable':'Der Update-Dienst ist derzeit nicht verfügbar.','networkError':'Verbindung zum Update-Dienst fehlgeschlagen.','invalidUpdate':'Update-Informationen sind ungültig.','tagline':'VERBINDE DICH OHNE GRENZEN','connectionDev':'Verbindungsmodul wird entwickelt','version':'Version','about':'Über','automatic':'Du kannst die Sprache jederzeit ändern.','latest':'Du verwendest die neueste Version von IQ Tunnel.','newUpdate':'Neues Update verfügbar','later':'Später','downloadInstall':'Herunterladen und installieren'},
  'ru': {'settings':'Настройки','language':'Язык приложения','updates':'Обновления приложения','checkUpdates':'Проверить обновления','serviceUnavailable':'Служба обновлений временно недоступна.','networkError':'Не удалось подключиться к службе обновлений.','invalidUpdate':'Данные обновления недействительны.','tagline':'ПОДКЛЮЧАЙСЯ БЕЗ ГРАНИЦ','connectionDev':'Модуль подключения находится в разработке','version':'Версия','about':'О приложении','automatic':'Вы можете изменить язык в любое время.','latest':'Вы используете последнюю версию IQ Tunnel.','newUpdate':'Доступно новое обновление','later':'Позже','downloadInstall':'Скачать и установить'},
  'zh': {'settings':'设置','language':'应用语言','updates':'应用更新','checkUpdates':'检查应用更新','serviceUnavailable':'更新服务暂时不可用。','networkError':'无法连接更新服务。','invalidUpdate':'更新信息无效。','tagline':'畅享无限连接','connectionDev':'连接引擎正在开发中','version':'版本','about':'关于','automatic':'您可以随时更改语言。','latest':'您正在使用最新版本的 IQ Tunnel。','newUpdate':'有新更新可用','later':'稍后','downloadInstall':'下载并安装'},
};

class UpdateUnavailableException implements Exception {
  const UpdateUnavailableException();
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.sha256,
    required this.notes,
    required this.signature,
  });

  final String version;
  final int buildNumber;
  final String downloadUrl;
  final String sha256;
  final String notes;
  final String signature;

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        version: json['version'] as String,
        buildNumber: (json['build_number'] as num).toInt(),
        downloadUrl: json['download_url'] as String,
        sha256: (json['sha256'] as String).toLowerCase(),
        notes: json['notes'] as String? ?? '',
        signature: json['signature'] as String,
      );

  String get signedPayload => jsonEncode(<String, dynamic>{
        'version': version,
        'build_number': buildNumber,
        'download_url': downloadUrl,
        'sha256': sha256,
        'notes': notes,
      });
}



class UpdateService {
  UpdateService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const int _maxManifestBytes = 64 * 1024;

  final http.Client _client;
  final bool _ownsClient;

  Future<http.StreamedResponse> _sendHttpsGet(
    Uri initialUri,
    Map<String, String> headers, {
    required Duration timeout,
  }) async {
    var uri = initialUri;
    for (var redirectCount = 0; redirectCount <= 5; redirectCount++) {
      if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        throw const FormatException(
          'Update requests and redirects must use HTTPS without embedded credentials.',
        );
      }

      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response = await _client.send(request).timeout(timeout);
      final location = response.headers['location'];
      final isRedirect = response.isRedirect ||
          (response.statusCode >= 300 &&
              response.statusCode < 400 &&
              location != null);
      if (!isRedirect) return response;

      await _cancelResponseBody(response);
      if (location == null || location.trim().isEmpty) {
        throw const FormatException('Update server returned a redirect without a Location.');
      }
      if (redirectCount == 5) {
        throw const FormatException('Too many redirects while retrieving an update.');
      }

      final nextUri = uri.resolve(location.trim());
      if (nextUri.scheme != 'https' ||
          nextUri.host.isEmpty ||
          nextUri.userInfo.isNotEmpty) {
        throw const FormatException(
          'Update redirects to non-HTTPS destinations are blocked.',
        );
      }
      uri = nextUri;
    }
    throw const FormatException('Too many redirects while retrieving an update.');
  }

  Future<void> _cancelResponseBody(http.StreamedResponse response) async {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
  }

  Future<UpdateInfo?> check() async {
    if (updateManifestUrl.isEmpty || updatePublicKeyBase64.isEmpty) {
      throw const FormatException(
        'خدمة التحديثات غير مهيأة بعد. يلزم ضبط رابط manifest ومفتاح التحقق.',
      );
    }
    final manifestUri = Uri.tryParse(updateManifestUrl);
    if (manifestUri == null || manifestUri.scheme != 'https') {
      throw const FormatException('رابط التحديثات يجب أن يستخدم HTTPS.');
    }
    final response = await _sendHttpsGet(
      manifestUri,
      {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache, no-store, max-age=0',
        'Pragma': 'no-cache',
        'User-Agent': 'IQ-Tunnel-Updater',
      },
      timeout: const Duration(seconds: 20),
    );
    if (response.statusCode == 404 || response.statusCode == 503) {
      throw const UpdateUnavailableException();
    }
    if (response.statusCode != 200) {
      throw HttpException(
        'Update server returned HTTP ${response.statusCode}',
        uri: manifestUri,
      );
    }

    // Enforce the manifest limit while streaming; checking bodyBytes after a
    // normal GET would allocate the entire response before rejecting it.
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > _maxManifestBytes) {
      await _cancelResponseBody(response);
      throw const FormatException('Update manifest is larger than 64 KiB.');
    }
    final manifestBytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (manifestBytes.length + chunk.length > _maxManifestBytes) {
        throw const FormatException('Update manifest is larger than 64 KiB.');
      }
      manifestBytes.addAll(chunk);
    }
    final json = jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    final update = UpdateInfo.fromJson(json);
    await _verifyManifest(update);
    final package = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(package.buildNumber) ?? 0;
    // Android accepts an in-place APK update only when versionCode/buildNumber increases.
    // A newer display version with an equal or lower build number would be rejected by Package Installer.
    return update.buildNumber > currentBuild ? update : null;
  }

  Future<void> _verifyManifest(UpdateInfo update) async {
    final keyBytes = base64Decode(updatePublicKeyBase64);
    final signatureBytes = base64Decode(update.signature);
    if (keyBytes.length != 32 || signatureBytes.length != 64) {
      throw const FormatException('توقيع التحديث أو مفتاحه غير صالح.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(update.sha256)) {
      throw const FormatException('بصمة SHA-256 غير صالحة.');
    }
    final uri = Uri.tryParse(update.downloadUrl);
    if (uri == null || uri.scheme != 'https') {
      throw const FormatException('ملف التحديث يجب أن يكون عبر HTTPS.');
    }
    final algorithm = Ed25519();
    final publicKey = SimplePublicKey(keyBytes, type: KeyPairType.ed25519);
    final signature = Signature(signatureBytes, publicKey: publicKey);
    final valid = await algorithm.verify(
      utf8.encode(update.signedPayload),
      signature: signature,
    );
    if (!valid) throw const FormatException('تعذر التحقق من توقيع التحديث.');
  }

  Future<File> download(
    UpdateInfo update, {
    required void Function(int received, int total) onProgress,
  }) async {
    final uri = Uri.parse(update.downloadUrl);
    final response = await _sendHttpsGet(
      uri,
      {
        'Accept': 'application/vnd.android.package-archive, application/octet-stream',
        'Cache-Control': 'no-cache',
        'User-Agent': 'IQ-Tunnel-Updater',
      },
      timeout: const Duration(seconds: 30),
    );
    if (response.statusCode != 200) {
      throw Exception('فشل تنزيل التحديث (${response.statusCode}).');
    }
    final total = response.contentLength ?? 0;
    if (total <= 0 || total > 500 * 1024 * 1024) {
      throw const FormatException('حجم ملف التحديث غير معروف أو أكبر من الحد.');
    }
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/iq-tunnel-update.apk');
    if (await file.exists()) await file.delete();
    final sink = file.openWrite();

    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
        onTimeout: (sink) => sink.addError(
          TimeoutException('APK download stalled for 30 seconds.'),
        ),
      )) {
        received += chunk.length;
        if (received > total || received > 500 * 1024 * 1024) {
          throw const FormatException('حجم التنزيل تجاوز الحجم المتوقع.');
        }
        sink.add(chunk);
        onProgress(received, total);
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
    await sink.close();
    if (received != total) {
      await file.delete();
      throw const FormatException('التنزيل غير مكتمل.');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    if (digest != update.sha256) {
      await file.delete();
      throw const FormatException('فشل التحقق من سلامة ملف التحديث (SHA-256).');
    }
    return file;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }

}

class _TunnelLogo extends StatelessWidget {
  const _TunnelLogo({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.22),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF202632), Color(0xFF080B11), Color(0xFF111722)],
            ),
            border: Border.all(
              color: const Color(0x88FFC247),
              width: size * 0.012,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33219CCB),
                blurRadius: 24,
                offset: Offset(5, 8),
              ),
            ],
          ),
          child: CustomPaint(painter: _IqTunnelPainter()),
        ),
      );
}

class _IqTunnelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 108;
    canvas.save();
    canvas.scale(scale);

    final shield = Path()
      ..moveTo(54, 8)
      ..cubicTo(68, 17, 81, 19, 94, 21)
      ..lineTo(91, 62)
      ..cubicTo(88, 80, 71, 94, 54, 101)
      ..cubicTo(37, 94, 20, 80, 17, 62)
      ..lineTo(14, 21)
      ..cubicTo(27, 19, 40, 17, 54, 8)
      ..close();
    final shieldPaint = Paint()
      ..color = const Color(0xFFFFC247)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(shield, shieldPaint);

    final tunnelPaint = Paint()
      ..color = const Color(0xFF00D9E8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final outerTunnel = Path()
      ..moveTo(34, 39)
      ..cubicTo(36, 25, 72, 25, 74, 39);
    final innerTunnel = Path()
      ..moveTo(43, 39)
      ..cubicTo(45, 31, 63, 31, 65, 39);
    canvas.drawPath(outerTunnel, tunnelPaint);
    canvas.drawPath(innerTunnel, tunnelPaint);

    final letters = TextPainter(
      text: const TextSpan(
        text: 'IQT',
        style: TextStyle(
          color: Color(0xFFFFD778),
          fontSize: 28,
          fontWeight: FontWeight.w900,
          letterSpacing: -1.4,
          shadows: [Shadow(color: Color(0x887C5A20), blurRadius: 5)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 82);
    letters.paint(canvas, Offset((108 - letters.width) / 2, 43));

    final roadPaint = Paint()
      ..color = const Color(0xFF00D9E8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final road = Path()
      ..moveTo(43, 79)
      ..cubicTo(48, 82, 60, 82, 65, 79);
    canvas.drawPath(road, roadPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class AboutAppPage extends StatelessWidget {
  const AboutAppPage({super.key, required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('حول IQ Tunnel')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(22),
              children: [
                const SizedBox(height: 12),
                const Center(child: _TunnelLogo(size: 124)),
                const SizedBox(height: 16),
                const Center(
                  child: Text(
                    'IQ Tunnel',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    'الإصدار $version',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'IQ Tunnel تطبيق VPN لنظام Android، يجمع إعدادات الاتصال وإدارة ملفات الخوادم في مكان واحد، مع الاهتمام بحماية بيانات الاتصال وسلامة التحديثات.',
                  textAlign: TextAlign.start,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 20),
                _AboutFeature(
                  icon: Icons.link_rounded,
                  title: 'إضافة روابط VPN',
                  description:
                      'إضافة روابط الخوادم والاشتراكات المتوافقة وحفظها ضمن قائمة السيرفرات.',
                ),
                _AboutFeature(
                  icon: Icons.shield_outlined,
                  title: 'اتصال عبر محرك Xray',
                  description:
                      'يستخدم التطبيق محرك Xray/libXray لتشغيل روابط الاتصال المدعومة.',
                ),
                _AboutFeature(
                  icon: Icons.lock_outline_rounded,
                  title: 'حماية ملفات الاتصال',
                  description:
                      'تُحفظ ملفات الاتصال محلياً بصيغة مشفّرة، وتُفحص بيانات التحديثات قبل تمرير ملف APK إلى مثبت Android.',
                ),
                _AboutFeature(
                  icon: Icons.system_update_alt_rounded,
                  title: 'تحديثات موثّقة',
                  description:
                      'يتحقق التطبيق من توقيع Ed25519 وبصمة SHA-256 قبل فتح مثبت Android. ويظل تأكيد التثبيت بيد المستخدم.',
                ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'ملاحظة: دعم البروتوكولات والميزات يعتمد على صيغة ملف الاتصال وإصدار المحرك والخادم. بعض الإمكانات المتقدمة قد لا تكون متاحة في كل إصدار.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    'IQ Tunnel • اتصال أوضح وتحكم أسهل',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutFeature extends StatelessWidget {
  const _AboutFeature({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: Icon(icon),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(description),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.language,
    required this.version,
    required this.themeMode,
    required this.accentColor,
    required this.onLanguageChanged,
    required this.onCheckUpdates,
    required this.onThemeModeChanged,
    required this.onAccentColorChanged,
    required this.onShowAbout,
  });

  final String language;
  final String version;
  final ThemeMode themeMode;
  final Color accentColor;
  final ValueChanged<String> onLanguageChanged;
  final VoidCallback onCheckUpdates;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<Color> onAccentColorChanged;
  final VoidCallback onShowAbout;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ThemeMode _themeMode;
  late Color _accentColor;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.themeMode;
    _accentColor = widget.accentColor;
  }

  String t(String key) =>
      _translations[widget.language]?[key] ?? _translations['en']![key]!;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isArabic = widget.language == 'ar';
    final text = isArabic
        ? const ['حسب الجهاز', 'فاتح', 'داكن']
        : const ['System', 'Light', 'Dark'];
    return Directionality(
      textDirection: const {'ar', 'ku', 'fa'}.contains(widget.language)
          ? TextDirection.rtl
          : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: Text(t('settings'))),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              t('language'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  _languageTile(context, 'ar', 'العربية'),
                  _languageTile(context, 'en', 'English'),
                  _languageTile(context, 'ku', 'کوردی (سۆرانی)'),
                  _languageTile(context, 'kmr', 'Kurdî (Kurmancî)'),
                  _languageTile(context, 'tr', 'Türkçe'),
                  _languageTile(context, 'fa', 'فارسی'),
                  _languageTile(context, 'fr', 'Français'),
                  _languageTile(context, 'es', 'Español'),
                  _languageTile(context, 'de', 'Deutsch'),
                  _languageTile(context, 'ru', 'Русский'),
                  _languageTile(context, 'zh', '中文'),
                ],
              ),
            ),
            const SizedBox(height: 26),
            Text(
              isArabic ? 'المظهر' : 'Appearance',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: true,
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: const Icon(Icons.settings_suggest_outlined),
                      label: Text(text[0]),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: const Icon(Icons.light_mode_outlined),
                      label: Text(text[1]),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: const Icon(Icons.dark_mode_outlined),
                      label: Text(text[2]),
                    ),
                  ],
                  selected: <ThemeMode>{_themeMode},
                  onSelectionChanged: (selection) {
                    final value = selection.first;
                    setState(() => _themeMode = value);
                    widget.onThemeModeChanged(value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isArabic ? 'ألوان التطبيق' : 'App colors',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              isArabic
                  ? 'اختار اللون الرئيسي الذي تفضله للواجهة والأزرار.'
                  : 'Choose the accent color used by the interface and buttons.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: appThemePalettes.map((palette) {
                    final selected = _accentColor.value == palette.color.value;
                    return ChoiceChip(
                      avatar: CircleAvatar(
                        radius: 9,
                        backgroundColor: palette.color,
                        child: selected
                            ? const Icon(Icons.check, size: 12, color: Colors.white)
                            : null,
                      ),
                      label: Text(isArabic ? palette.labelAr : palette.labelEn),
                      selected: selected,
                      onSelected: (_) {
                        setState(() => _accentColor = palette.color);
                        widget.onAccentColorChanged(palette.color);
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 26),
            Text(
              t('updates'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                leading: Icon(Icons.system_update_alt, color: colors.primary),
                title: Text(t('checkUpdates')),
                subtitle: Text(t('automatic')),
                trailing: const Icon(Icons.chevron_right),
                onTap: widget.onCheckUpdates,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: Icon(Icons.info_outline_rounded, color: colors.primary),
                title: Text(t('about')),
                subtitle: Text(
                  isArabic ? 'تعرف على التطبيق ومزاياه' : 'Learn about IQ Tunnel',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: widget.onShowAbout,
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: Text(
                'IQ Tunnel • ${t('version')} ${widget.version}',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _languageTile(BuildContext context, String code, String label) =>
      RadioListTile<String>(
        value: code,
        groupValue: widget.language,
        title: Text(label),
        onChanged: (value) {
          if (value != null) {
            widget.onLanguageChanged(value);
            Navigator.pop(context);
          }
        },
      );
}


class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.themeMode,
    required this.accentColor,
    required this.onThemeModeChanged,
    required this.onAccentColorChanged,
    this.vpnEngine,
    this.updateServiceFactory,
  });

  final VpnEngine? vpnEngine;
  final UpdateService Function()? updateServiceFactory;
  final ThemeMode themeMode;
  final Color accentColor;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<Color> onAccentColorChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool checking = false;
  String language = 'ar';
  bool downloading = false;
  double downloadProgress = 0;
  String status = 'جارٍ تهيئة محرك VPN...';
  String version = '...';
  final EncryptedProfileStore _profileStore = EncryptedProfileStore(vault: EncryptedVault());
  late final Future<void> _profilesLoadFuture;
  bool engineReady = false;
  bool tunnelBusy = false;
  VpnEngineStatus tunnelStatus = VpnEngineStatus.disconnected;
  late final VpnEngine _vpnEngine =
      widget.vpnEngine ?? LibXrayVpnEngineAdapter();
  String? tunnelError;
  List<Map<String, dynamic>> savedProfiles = <Map<String, dynamic>>[];
  String? activeProfileId;
  int uploadSpeed = 0, downloadSpeed = 0, uploadTotal = 0, downloadTotal = 0;
  bool trafficStatsAvailable = false;
  StreamSubscription<VpnEngineState>? _tunnelStateSubscription;
  StreamSubscription<VpnTrafficStats>? _tunnelStatsSubscription;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadLanguage();
    _profilesLoadFuture = _loadProfiles();
    _initializeVpnEngine();

    if (kReleaseMode) {
      // Check for a signed update after the first frame so the home screen is
      // ready before any update dialog is presented. Debug and test builds do
      // not contact the production update service automatically.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkUpdates(automatic: true);
      });
    }
  }

  @override
  void dispose() {
    _tunnelStateSubscription?.cancel();
    _tunnelStatsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('app_language') ?? 'ar';
    if (mounted) setState(() => language = saved);
  }

  Future<void> _setLanguage(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', value);
    if (mounted) setState(() => language = value);
  }

  String _t(String key) => _translations[language]?[key] ?? _translations['en']![key]!;

  Future<void> _openAbout() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AboutAppPage(version: version),
    ));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsPage(
        language: language,
        version: version,
        themeMode: widget.themeMode,
        accentColor: widget.accentColor,
        onLanguageChanged: _setLanguage,
        onCheckUpdates: () => _checkUpdates(),
        onThemeModeChanged: widget.onThemeModeChanged,
        onAccentColorChanged: widget.onAccentColorChanged,
        onShowAbout: _openAbout,
      ),
    ));
  }

  Future<void> _openOpenWrt() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const OpenWrtPage(),
    ));
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => version = '${info.version}+${info.buildNumber}');
    } catch (_) {
      if (mounted) setState(() => version = '0.1.0');
    }
  }

  Future<void> _initializeVpnEngine() async {
    try {
      await _vpnEngine.initialize();
      _tunnelStateSubscription = _vpnEngine.watchConnectionState().listen((state) {
        if (!mounted) return;
        setState(() {
          tunnelStatus = state.status;
          tunnelError = state.error;
          if (state.status == VpnEngineStatus.connected) {
            status = 'النفق متصل فعلياً';
          } else if (state.status == VpnEngineStatus.connecting) {
            status = 'جارٍ إنشاء اتصال النفق...';
          } else if (state.status == VpnEngineStatus.disconnecting) {
            status = 'جارٍ قطع اتصال النفق...';
          } else {
            status = state.error ?? 'النفق غير متصل';
          }
        });
      });
      _tunnelStatsSubscription = _vpnEngine.watchConnectionStats().listen((stats) {
        if (!mounted) return;
        setState(() {
          uploadSpeed = stats.uploadSpeed;
          downloadSpeed = stats.downloadSpeed;
          uploadTotal = stats.uploadTotal;
          downloadTotal = stats.downloadTotal;
          trafficStatsAvailable = stats.available;
        });
      });
      if (mounted) setState(() {
        engineReady = true;
        tunnelStatus = _vpnEngine.status;
        status = tunnelStatus == VpnEngineStatus.connected
            ? 'النفق متصل فعلياً' : 'محرك VPN جاهز';
      });
    } catch (error) {
      if (mounted) setState(() {
        engineReady = false;
        tunnelError = error.toString();
        status = 'تعذر تهيئة محرك VPN: $error';
      });
    }
  }

  Future<void> _loadProfiles() async {
    try {
      final profiles = await _profileStore.readAll();
      if (mounted) setState(() => savedProfiles = profiles);
    } catch (error) {
      if (mounted) _showMessage('تعذر قراءة ملفات الاتصال المشفّرة: $error');
    }
  }

  String? _profilePayload(Map<String, dynamic> profile) {
    final payload = profile['payload'];
    if (payload is String && payload.trim().isNotEmpty) return payload.trim();
    final config = profile['config'];
    if (config is Map) return jsonEncode(config);
    return null;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatRate(int bytesPerSecond) => '${_formatBytes(bytesPerSecond)}/s';

  void _validateShareLinkInput(String payload) {
    final value = payload.trim();
    if (value.isEmpty) throw const FormatException('الصق رابط اتصال أولاً.');
    final supported = RegExp(
      r'^(?:vless|vmess|trojan|ss|socks|socks5|http|https|wireguard|wg)://',
      caseSensitive: false,
    );
    final lines = value.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => line.isNotEmpty);
    final hasSupportedLink = lines.any((line) => supported.hasMatch(line));
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    final mayBeBase64Subscription = compact.length >= 16 &&
        RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(compact);
    if (!hasSupportedLink && !mayBeBase64Subscription) {
      throw const FormatException('الرابط غير معروف. استخدم رابط VLESS أو VMess أو Trojan أو اشتراكاً مدعوماً.');
    }
  }

  Future<void> _saveProfile({required String name, required String payload, required String format}) async {
    final cleanPayload = payload.trim();
    if (cleanPayload.isEmpty) throw const FormatException('بيانات الاتصال فارغة.');
    _validateShareLinkInput(cleanPayload);
    // Wait for the initial encrypted-vault read so key creation cannot race
    // between startup loading and an early profile save.
    await _profilesLoadFuture;
    final profiles = await _profileStore.readAll();
    profiles.add({
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'name': name.trim().isEmpty ? 'سيرفر جديد' : name.trim(),
      'format': format,
      'imported_at': DateTime.now().toUtc().toIso8601String(),
      'payload': cleanPayload,
    });
    await _profileStore.writeAll(profiles);
    if (mounted) {
      setState(() => savedProfiles = profiles);
      _showMessage('تم حفظ الرابط بشكل مشفّر. تقدر هسه تجرب الاتصال.');
    }
  }

  Future<void> _importShareLink() async {
    final nameController = TextEditingController();
    final payloadController = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إضافة رابط أو اشتراك VPN'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'اسم السيرفر')),
            const SizedBox(height: 12),
            TextField(
              controller: payloadController,
              minLines: 4,
              maxLines: 8,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'الصق رابط VPN أو رابط الاشتراك',
                hintText: 'vless://… أو vmess://… أو https://…',
                border: OutlineInputBorder(),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'name': nameController.text, 'payload': payloadController.text,
            }),
            child: const Text('حفظ الرابط'),
          ),
        ],
      ),
    );
    nameController.dispose();
    payloadController.dispose();
    if (result == null) return;
    try {
      await _saveProfile(
        name: result['name'] ?? '',
        payload: result['payload'] ?? '',
        format: 'share-link-or-subscription',
      );
    } catch (error) {
      if (mounted) _showMessage('تعذر حفظ رابط الاتصال: $error');
    }
  }

  Future<void> _connectProfile(Map<String, dynamic> profile) async {
    if (!engineReady || tunnelBusy) return;
    final payload = _profilePayload(profile);
    if (payload == null) { _showMessage('ملف الاتصال هذا غير صالح؛ أعد استيراده.'); return; }
    setState(() {
      tunnelBusy = true;
      activeProfileId = profile['id']?.toString();
      tunnelError = null;
      status = 'جارٍ الاتصال بخادم VPN...';
    });
    try {
      if (!await _vpnEngine.hasNotificationPermission()) {
        await _vpnEngine.requestNotificationPermission();
      }
      await _vpnEngine.connect(payload, timeout: const Duration(seconds: 120));
      if (mounted) _showMessage('تم إنشاء نفق VPN والاتصال بالخادم.');
    } catch (error) {
      if (mounted) {
        setState(() { tunnelError = error.toString(); status = 'فشل اتصال النفق: $error'; });
        _showMessage('تعذر الاتصال: $error');
      }
    } finally {
      if (mounted) setState(() => tunnelBusy = false);
    }
  }

  Future<void> _disconnectTunnel() async {
    if (!engineReady || tunnelBusy) return;
    setState(() { tunnelBusy = true; status = 'جارٍ قطع اتصال VPN...'; });
    try {
      await _vpnEngine.disconnect();
      if (mounted) _showMessage('تم قطع اتصال النفق.');
    } catch (error) {
      if (mounted) _showMessage('تعذر قطع الاتصال: $error');
    } finally {
      if (mounted) setState(() => tunnelBusy = false);
    }
  }

  Future<void> _deleteProfile(Map<String, dynamic> profile) async {
    final id = profile['id']?.toString();
    if (tunnelStatus == VpnEngineStatus.connected && activeProfileId == id) {
      _showMessage('اقطع الاتصال بهذا السيرفر قبل حذفه.');
      return;
    }
    final profiles = await _profileStore.readAll();
    profiles.removeWhere((item) => item['id']?.toString() == id);
    await _profileStore.writeAll(profiles);
    if (mounted) setState(() => savedProfiles = profiles);
  }

  Future<void> _checkUpdates({bool automatic = false}) async {
    if (checking || downloading) return;
    setState(() {
      checking = true;
      if (!automatic) status = _t('checking');
    });
    final service = widget.updateServiceFactory?.call() ?? UpdateService();
    try {
      final update = await service.check();
      if (!mounted) return;
      if (update == null) {
        if (!automatic) {
          setState(() => status = '${_t('latest')} ($version)');
          _showMessage(_t('latest'));
        }
      } else {
        if (!automatic) {
          setState(() => status = '${_t('newUpdate')} ${update.version}');
        }
        await _showUpdateDialog(update, service);
      }
    } catch (error) {
      if (mounted) {
        final isNetworkError = error is SocketException ||
            error is TimeoutException ||
            error is HandshakeException ||
            error is http.ClientException;
        final message = error is UpdateUnavailableException
            ? _t('serviceUnavailable')
            : error is HttpException
                ? 'خادم التحديثات ردّ برمز غير ناجح.'
                : isNetworkError
                    ? _t('networkError')
                    : _t('invalidUpdate');
        // Keep the visible status friendly, but include the underlying network
        // error in the manual check so DNS, TLS, timeout and client failures
        // can be distinguished instead of being hidden behind one generic label.
        final diagnostic = (isNetworkError || error is HttpException)
            ? '\n' + error.toString()
            : '';
        if (!automatic) {
          setState(() => status = message);
          _showMessage(message + diagnostic);
        }
      }
    } finally {
      service.dispose();
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> _showUpdateDialog(UpdateInfo update, UpdateService service) async {
    var waitingForInstallerPermission = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: !downloading,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('newUpdate')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('الإصدار ${update.version} (${update.buildNumber})'),
              if (update.notes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(update.notes),
              ],
              if (downloading) ...[
                const SizedBox(height: 18),
                if (waitingForInstallerPermission) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text('بانتظار إذن التثبيت من Android...'),
                ] else ...[
                  LinearProgressIndicator(value: downloadProgress),
                  const SizedBox(height: 8),
                  Text('${(downloadProgress * 100).toStringAsFixed(0)}%'),
                ],
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: downloading ? null : () => Navigator.pop(dialogContext),
              child: Text(_t('later')),
            ),
            FilledButton(
              onPressed: downloading
                  ? null
                  : () async {
                      setDialogState(() {
                        downloading = true;
                        waitingForInstallerPermission = true;
                        downloadProgress = 0;
                      });
                      try {
                        await AndroidPackageInstaller.ensureCanInstall();
                        if (dialogContext.mounted) {
                          setDialogState(() => waitingForInstallerPermission = false);
                        }
                        final file = await service.download(
                          update,
                          onProgress: (received, total) {
                            if (!mounted) return;
                            setState(() => downloadProgress = received / total);
                            setDialogState(() => downloadProgress = received / total);
                          },
                        );
                        if (!mounted) return;
                        setState(() {
                          downloading = false;
                          status = 'تم التحقق من التحديث؛ بانتظار التثبيت';
                        });
                        Navigator.pop(dialogContext);
                        final result = await OpenFilex.open(
                          file.path,
                          type: 'application/vnd.android.package-archive',
                        );
                        if (mounted && result.type != ResultType.done) {
                          _showMessage(
                            'تم تنزيل التحديث والتحقق منه، لكن أندرويد لم يفتح المثبّت: ${result.message}',
                          );
                        }
                      } catch (error) {
                        if (mounted) {
                          setState(() => downloading = false);
                          final message = error is InstallerPermissionDenied
                              ? 'فعّل السماح بتثبيت التطبيقات من IQ Tunnel ثم أعد محاولة التحديث.'
                              : 'تعذر تنزيل أو تثبيت التحديث: $error';
                          _showMessage(message);
                        }
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            downloading = false;
                            waitingForInstallerPermission = false;
                          });
                        }
                      }
                    },
              child: Text(_t('downloadInstall')),
            ),
          ],
        ),
      ),
    );
  }



  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: const {'ar', 'ku', 'fa'}.contains(language) ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('IQ Tunnel'),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: 'إدارة OpenWrt',
                onPressed: _openOpenWrt,
                icon: const Icon(Icons.router_rounded),
              ),
              IconButton(
                tooltip: _t('about'),
                onPressed: _openAbout,
                icon: const Icon(Icons.info_outline_rounded),
              ),
              IconButton(
                tooltip: _t('settings'),
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_rounded),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const _TunnelLogo(size: 112),
                      const SizedBox(height: 20),
                      const Text('IQ Tunnel', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_t('tagline'), style: TextStyle(letterSpacing: 2, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 36),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        child: Column(children: [
                          Icon(
                            tunnelStatus == VpnEngineStatus.connected
                                ? Icons.shield_rounded : Icons.power_settings_new,
                            size: 48,
                            color: tunnelStatus == VpnEngineStatus.connected
                                ? const Color(0xFF48D597) : Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            !engineReady ? 'تهيئة محرك الاتصال...'
                                : tunnelStatus == VpnEngineStatus.connected
                                    ? 'النفق متصل بالخادم' : 'محرك VPN جاهز',
                            style: const TextStyle(fontSize: 18),
                          ),
                          const SizedBox(height: 6),
                          Text(status, textAlign: TextAlign.center,
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          const SizedBox(height: 8),
                          if (trafficStatsAvailable) ...[
                            Text('↓ ${_formatRate(downloadSpeed)}   ↑ ${_formatRate(uploadSpeed)}',
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                            Text('تنزيل ${_formatBytes(downloadTotal)} • رفع ${_formatBytes(uploadTotal)}',
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                          ] else
                            Text('إحصائيات حركة المرور قيد الربط',
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                          if (tunnelError != null && tunnelStatus != VpnEngineStatus.connected)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(tunnelError!, textAlign: TextAlign.center,
                                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                            ),
                        ]),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: !engineReady || tunnelBusy ? null
                              : tunnelStatus == VpnEngineStatus.connected
                                  ? _disconnectTunnel
                                  : savedProfiles.isEmpty ? null : () => _connectProfile(savedProfiles.first),
                          icon: tunnelBusy
                              ? const SizedBox(width: 18, height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(tunnelStatus == VpnEngineStatus.connected
                                  ? Icons.stop_circle_rounded : Icons.power_rounded),
                          label: Text(tunnelBusy ? 'جارٍ تنفيذ الطلب...'
                              : tunnelStatus == VpnEngineStatus.connected
                                  ? 'إيقاف اتصال VPN'
                                  : savedProfiles.isEmpty ? 'أضف سيرفر حتى تتصل'
                                      : 'اتصال بأول سيرفر محفوظ'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: !engineReady || tunnelBusy ? null : _importShareLink,
                          icon: const Icon(Icons.link_rounded),
                          label: const Text('إضافة رابط أو اشتراك VPN'),
                        ),
                      ),
                      if (savedProfiles.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        const Align(
                          alignment: Alignment.centerRight,
                          child: Text('السيرفرات المحفوظة',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 8),
                        ...savedProfiles.map((profile) {
                          final id = profile['id']?.toString();
                          final active = activeProfileId == id &&
                              tunnelStatus == VpnEngineStatus.connected;
                          return Card(
                            child: ListTile(
                              title: Text(profile['name']?.toString() ?? 'VPN Server'),
                              subtitle: Text(profile['format']?.toString() ?? 'VPN'),
                              leading: Icon(active ? Icons.shield_rounded : Icons.dns_rounded,
                                  color: active ? const Color(0xFF48D597) : Theme.of(context).colorScheme.onSurfaceVariant),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                  tooltip: active ? 'قطع الاتصال' : 'اتصال',
                                  onPressed: tunnelBusy || !engineReady ? null
                                      : active ? _disconnectTunnel : () => _connectProfile(profile),
                                  icon: Icon(active ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                                ),
                                IconButton(
                                  tooltip: 'حذف',
                                  onPressed: tunnelBusy ? null : () => _deleteProfile(profile),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ]),
                            ),
                          );
                        }),
                      ],
                      const SizedBox(height: 24),
                      Text('${_t('version')} $version',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
