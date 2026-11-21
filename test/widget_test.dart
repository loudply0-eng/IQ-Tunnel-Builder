import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/main.dart';

void main() {
  testWidgets('shows IQ Tunnel VPN home screen', (tester) async {
    await tester.pumpWidget(const IqTunnelApp());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('IQ Tunnel'), findsWidgets);
    expect(find.text('فحص تحديثات التطبيق'), findsOneWidget);
    expect(find.text('استيراد ملف VPN'), findsOneWidget);
    expect(find.text('إضافة رابط أو اشتراك VPN'), findsOneWidget);
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

