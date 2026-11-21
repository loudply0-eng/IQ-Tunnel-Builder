import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/main.dart';

void main() {
  test('update signature payload is deterministic and excludes signature', () {
    final update = UpdateInfo(
      version: '1.2.3',
      buildNumber: 42,
      downloadUrl: 'https://updates.example.com/iq-tunnel.apk',
      sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      notes: 'إصلاحات وتحسينات',
      signature: 'not-part-of-the-payload',
    );

    expect(
      update.signedPayload,
      '{"version":"1.2.3","build_number":42,"download_url":"https://updates.example.com/iq-tunnel.apk","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","notes":"إصلاحات وتحسينات"}',
    );
    expect(update.signedPayload, isNot(contains('not-part-of-the-payload')));
  });

  test('manifest parser reads required update metadata', () {
    final update = UpdateInfo.fromJson({
      'version': '1.2.3',
      'build_number': 42,
      'download_url': 'https://updates.example.com/iq-tunnel.apk',
      'sha256': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'notes': 'Security fixes',
      'signature': 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    });

    expect(update.version, '1.2.3');
    expect(update.buildNumber, 42);
    expect(update.notes, 'Security fixes');
  });
}

