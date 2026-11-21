import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/app_theme.dart';

void main() {
  test('offers a broad set of distinct accent colors', () {
    expect(appThemePalettes.length, greaterThanOrEqualTo(12));
    expect(
      appThemePalettes.map((palette) => palette.color.value).toSet().length,
      appThemePalettes.length,
    );
  });

  test('builds matching light and dark themes for the selected accent', () {
    const accent = Color(0xFF2196F3);
    final light = buildIqTunnelTheme(Brightness.light, accent);
    final dark = buildIqTunnelTheme(Brightness.dark, accent);

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.colorScheme.brightness, Brightness.light);
    expect(dark.colorScheme.brightness, Brightness.dark);
  });
}

