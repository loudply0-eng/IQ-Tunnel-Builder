import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/main.dart';

void main() {
  testWidgets('home screen exposes VPN link entry and settings updates', (tester) async {
    await tester.pumpWidget(const IqTunnelApp());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('IQ Tunnel'), findsWidgets);
    expect(find.text('إضافة رابط أو اشتراك VPN'), findsOneWidget);

    await tester.tap(find.byTooltip('الإعدادات'));
    await tester.pumpAndSettle();
    expect(find.text('فحص تحديثات التطبيق'), findsOneWidget);
  });

  testWidgets('about page describes verified updates without a license subpage', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AboutAppPage(version: '1.0.9+10')),
    );

    expect(find.text('حول IQ Tunnel'), findsOneWidget);
    expect(find.text('تحديثات موثّقة'), findsOneWidget);
    expect(find.text('التراخيص مفتوحة المصدر'), findsNothing);
  });
}
