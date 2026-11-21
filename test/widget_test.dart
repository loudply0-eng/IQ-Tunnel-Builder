import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/main.dart';
import 'package:iq_tunnel/vpn/vpn_engine.dart';

class _TestVpnEngine implements VpnEngine {
  @override
  VpnEngineStatus get status => VpnEngineStatus.disconnected;

  @override
  Stream<VpnEngineState> watchConnectionState() => const Stream<VpnEngineState>.empty();

  @override
  Stream<VpnTrafficStats> watchConnectionStats() => const Stream<VpnTrafficStats>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> validateProfile(String payload) async {}

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<void> requestNotificationPermission() async {}

  @override
  Future<void> connect(String payload, {Duration timeout = const Duration(seconds: 120)}) async {}

  @override
  Future<void> disconnect() async {}
}

void main() {
  testWidgets('shows IQ Tunnel VPN home screen', (tester) async {
    await tester.pumpWidget(const IqTunnelApp(vpnEngine: _TestVpnEngine()));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('IQ Tunnel'), findsWidgets);
    expect(find.text('فحص تحديثات التطبيق'), findsOneWidget);
    expect(find.text('استيراد ملف VPN'), findsOneWidget);
    expect(find.text('إضافة رابط أو اشتراك VPN'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('about page exposes the open-source licenses page', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AboutAppPage(version: '0.1.6+7')),
    );

    expect(find.text('حول IQ Tunnel'), findsOneWidget);
    for (var attempt = 0;
        attempt < 4 && find.text('التراخيص مفتوحة المصدر').evaluate().isEmpty;
        attempt++) {
      await tester.drag(find.byType(ListView), const Offset(0, -560));
      await tester.pumpAndSettle();
    }
    expect(find.text('التراخيص مفتوحة المصدر'), findsOneWidget);
  });
}

