import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/main.dart';
import 'package:iq_tunnel/vpn/vpn_engine.dart';

class _FakeUpdateService extends UpdateService {
  int checkCount = 0;

  @override
  Future<UpdateInfo?> check() async {
    checkCount++;
    return null;
  }

  @override
  void dispose() {}
}

class _FakeVpnEngine implements VpnEngine {
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
  testWidgets('home screen exposes VPN link entry and settings updates', (tester) async {
    final fakeUpdateService = _FakeUpdateService();
    await tester.pumpWidget(IqTunnelApp(
      vpnEngine: _FakeVpnEngine(),
      updateServiceFactory: () => fakeUpdateService,
      automaticUpdateCheckEnabled: true,
    ));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('IQ Tunnel'), findsWidgets);
    expect(find.text('إضافة رابط أو اشتراك VPN'), findsOneWidget);
    expect(fakeUpdateService.checkCount, 1);

    await tester.tap(find.byTooltip('الإعدادات'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('فحص تحديثات التطبيق'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('فحص تحديثات التطبيق'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('about page describes verified updates without a license subpage', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AboutAppPage(version: '1.0.9+10')),
    );

    expect(find.text('حول IQ Tunnel'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('تحديثات موثّقة'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('تحديثات موثّقة'), findsOneWidget);
    expect(find.text('التراخيص مفتوحة المصدر'), findsNothing);
  });
}
