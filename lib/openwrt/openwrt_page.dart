import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'openwrt_client.dart';

class OpenWrtPage extends StatefulWidget {
  const OpenWrtPage({super.key});

  @override
  State<OpenWrtPage> createState() => _OpenWrtPageState();
}

class _OpenWrtPageState extends State<OpenWrtPage> {
  static const _savedAddressKey = 'iqt_openwrt_address_v1';
  static const _savedUsernameKey = 'iqt_openwrt_username_v1';
  static const _savedPasswordKey = 'iqt_openwrt_password_v1';

  final _storage = const FlutterSecureStorage();
  final _addressController = TextEditingController(text: 'http://192.168.1.1');
  final _usernameController = TextEditingController(text: 'root');
  final _passwordController = TextEditingController();
  final _client = OpenWrtClient();

  bool _remember = false;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;
  OpenWrtRouterSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    _loadSavedConnection();
  }

  @override
  void dispose() {
    _addressController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _loadSavedConnection() async {
    try {
      final address = await _storage.read(key: _savedAddressKey);
      final username = await _storage.read(key: _savedUsernameKey);
      final password = await _storage.read(key: _savedPasswordKey);
      if (!mounted || address == null || username == null || password == null) {
        return;
      }
      setState(() {
        _addressController.text = address;
        _usernameController.text = username;
        _passwordController.text = password;
        _remember = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'تعذر قراءة بيانات الراوتر المحفوظة من التخزين الآمن.');
      }
    }
  }

  Future<void> _connect({bool refresh = false}) async {
    if (_busy) return;
    final address = _addressController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (address.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = 'أدخل عنوان الراوتر واسم المستخدم وكلمة المرور.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await _client.inspect(
        address: address,
        username: username,
        password: password,
      );
      if (_remember) {
        await _storage.write(key: _savedAddressKey, value: address);
        await _storage.write(key: _savedUsernameKey, value: username);
        await _storage.write(key: _savedPasswordKey, value: password);
      } else {
        await _forgetSavedConnection();
      }
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(refresh
              ? 'تم تحديث معلومات الراوتر.'
              : 'تم الاتصال بالراوتر وقراءة معلوماته بنجاح.'),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetSavedConnection() async {
    await _storage.delete(key: _savedAddressKey);
    await _storage.delete(key: _savedUsernameKey);
    await _storage.delete(key: _savedPasswordKey);
  }

  Future<void> _forgetAndClear() async {
    try {
      await _forgetSavedConnection();
      if (!mounted) return;
      setState(() {
        _remember = false;
        _passwordController.clear();
        _snapshot = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف بيانات الراوتر المحفوظة.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'تعذر حذف بيانات الراوتر من التخزين الآمن.');
      }
    }
  }

  String _formatUptime(int seconds) {
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (days > 0) return '$days يوم • $hours ساعة';
    if (hours > 0) return '$hours ساعة • $minutes دقيقة';
    return '$minutes دقيقة';
  }

  String _formatMemory(Object? bytes) {
    if (bytes is! num || bytes < 0) return '—';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _interfaceAddresses(Map<String, dynamic> iface) {
    final values = iface['ipv4-address'];
    if (values is! List) return '';
    return values
        .whereType<Map>()
        .map((item) => item['address']?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .join('، ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('إدارة OpenWrt'),
        centerTitle: true,
        actions: [
          if (snapshot != null)
            IconButton(
              tooltip: 'تحديث معلومات الراوتر',
              onPressed: _busy ? null : () => _connect(refresh: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.router_rounded,
                            size: 32, color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'اربط IQ Tunnel براوترك',
                            style: TextStyle(
                                fontSize: 19, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'اتصل بواجهة ubus في OpenWrt لقراءة معلومات الجهاز وحالة الشبكة. هذه المرحلة للقراءة فقط ولا تغيّر إعدادات الراوتر.',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _addressController,
                      keyboardType: TextInputType.url,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'عنوان الراوتر',
                        hintText: 'http://192.168.1.1',
                        prefixIcon: Icon(Icons.link_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _usernameController,
                      textDirection: TextDirection.ltr,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: 'كلمة مرور الراوتر',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                          icon: Icon(_obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: _remember,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('حفظ بيانات الدخول على هذا الهاتف'),
                      subtitle: const Text(
                          'تُحفظ في Android Keystore عبر التخزين الآمن.'),
                      onChanged: (value) =>
                          setState(() => _remember = value ?? false),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _connect(),
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.router_outlined),
                        label: Text(_busy
                            ? 'جارٍ الاتصال وقراءة المعلومات...'
                            : 'اتصال بالراوتر'),
                      ),
                    ),
                    if (_remember)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: _busy ? null : _forgetAndClear,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('حذف بيانات الدخول المحفوظة'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline,
                          color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (snapshot != null) ...[
              const SizedBox(height: 18),
              Text('معلومات الراوتر',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.router_rounded),
                      title: Text(snapshot.model),
                      subtitle: Text(snapshot.hostname),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('إصدار OpenWrt'),
                      subtitle: Text(snapshot.version),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('مدة التشغيل'),
                      subtitle: Text(_formatUptime(snapshot.uptimeSeconds)),
                    ),
                    if (snapshot.loadAverages.isNotEmpty) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.speed_rounded),
                        title: const Text('حمل المعالج'),
                        subtitle: Text(snapshot.loadAverages
                            .map((value) =>
                                (value / 65536).toStringAsFixed(2))
                            .join(' • ')),
                      ),
                    ],
                    if (snapshot.memory.isNotEmpty) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.memory_rounded),
                        title: const Text('الذاكرة'),
                        subtitle: Text(
                          'المجموع: ${_formatMemory(snapshot.memory['total'])} • المتاح: ${_formatMemory(snapshot.memory['free'])}',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text('واجهات الشبكة',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (snapshot.interfaces.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('لم يرجع الراوتر قائمة واجهات الشبكة.'),
                  ),
                )
              else
                ...snapshot.interfaces.map((iface) {
                  final name = iface['interface']?.toString() ?? 'واجهة';
                  final protocol = iface['proto']?.toString() ?? '—';
                  final up = iface['up'] == true;
                  final addresses = _interfaceAddresses(iface);
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        up ? Icons.check_circle_outline : Icons.pause_circle_outline,
                        color: up ? Colors.green : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(name),
                      subtitle: Text([
                        'البروتوكول: $protocol',
                        if (addresses.isNotEmpty) 'IP: $addresses',
                        if (iface['device'] != null)
                          'الجهاز: ${iface['device']}',
                      ].join('\n')),
                      trailing: Text(
                        up ? 'فعّالة' : 'متوقفة',
                        style: TextStyle(
                          color: up ? Colors.green : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }),
            ],
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.shield_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'الأمان: لا ترسل كلمة المرور عبر HTTP إلى عنوان عام. استخدم هذه الميزة على شبكة الراوتر المحلية الموثوقة، أو اضبط HTTPS بشهادة موثوقة. لا نعطّل التحقق من الشهادات.',
                        style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'التحكم بتثبيت VPN وتغيير التوجيه والجدار الناري على الراوتر مرحلة لاحقة؛ هذا الإصدار لا يكتب أي إعداد في OpenWrt.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
