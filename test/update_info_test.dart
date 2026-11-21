import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iq_tunnel/main.dart';

class _DowngradeRedirectClient extends http.BaseClient {
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      302,
      request: request,
      headers: const <String, String>{
        'location': 'http://updates.example.com/manifest.json',
      },
    );
  }
}

class _StreamingManifestClient extends http.BaseClient {
  _StreamingManifestClient({
    required this.chunks,
    this.contentLength,
  });

  final List<List<int>> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks),
      200,
      request: request,
      contentLength: contentLength,
    );
  }
}

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

  test('rejects an HTTPS manifest redirect to plain HTTP', () async {
    final client = _DowngradeRedirectClient();
    final service = UpdateService(client: client);
    addTearDown(service.dispose);

    await expectLater(
      service.check(),
      throwsA(isA<FormatException>()),
    );
    expect(client.requestCount, 1);
  });

  test('rejects an oversized manifest from the Content-Length header', () async {
    final client = _StreamingManifestClient(
      chunks: const <List<int>>[],
      contentLength: 64 * 1024 + 1,
    );
    final service = UpdateService(client: client);
    addTearDown(service.dispose);

    await expectLater(
      service.check(),
      throwsA(isA<FormatException>()),
    );
  });

  test('caps manifest bytes while streaming when Content-Length is absent',
      () async {
    final client = _StreamingManifestClient(
      chunks: <List<int>>[
        List<int>.filled(64 * 1024, 0),
        <int>[1],
      ],
    );
    final service = UpdateService(client: client);
    addTearDown(service.dispose);

    await expectLater(
      service.check(),
      throwsA(isA<FormatException>()),
    );
  });
}
