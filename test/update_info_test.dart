import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
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

class _TrackingResponseClient extends http.BaseClient {
  _TrackingResponseClient({
    required this.statusCode,
    this.contentLength,
  });

  final int statusCode;
  final int? contentLength;
  late StreamController<List<int>> _body;
  bool bodyCancelled = false;
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.AbortableRequest) {
      request.abortTrigger!.then((_) => aborted = true);
    }
    _body = StreamController<List<int>>(
      onCancel: () {
        bodyCancelled = true;
      },
    );
    return http.StreamedResponse(
      _body.stream,
      statusCode,
      request: request,
      contentLength: contentLength,
    );
  }
}

class _DownloadResponseClient extends http.BaseClient {
  _DownloadResponseClient({required this.chunks, required this.contentLength});

  final List<List<int>> chunks;
  final int contentLength;

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

Future<({UpdateInfo update, String publicKeyBase64})> _makeSignedUpdate() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final unsigned = UpdateInfo(
    version: '1.2.3',
    buildNumber: 42,
    downloadUrl: 'https://updates.example.com/iq-tunnel.apk',
    sha256: List<String>.filled(64, 'a').join(),
    notes: 'Signed test update',
    signature: '',
  );
  final signature = await algorithm.sign(
    utf8.encode(unsigned.signedPayload),
    keyPair: keyPair,
  );
  return (
    update: UpdateInfo(
      version: unsigned.version,
      buildNumber: unsigned.buildNumber,
      downloadUrl: unsigned.downloadUrl,
      sha256: unsigned.sha256,
      notes: unsigned.notes,
      signature: base64Encode(signature.bytes),
    ),
    publicKeyBase64: base64Encode(publicKey.bytes),
  );
}

UpdateInfo _downloadUpdate(String sha256) => UpdateInfo(
      version: '1.2.3',
      buildNumber: 42,
      downloadUrl: 'https://updates.example.com/iq-tunnel.apk',
      sha256: sha256,
      notes: '',
      signature: '',
    );

class _NeverRespondingClient extends http.BaseClient {
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is! http.AbortableRequest) {
      throw StateError('Updater must send an AbortableRequest.');
    }
    request.abortTrigger!.then((_) => aborted = true);
    return Completer<http.StreamedResponse>().future;
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

  test('manifest parser rejects non-integer or negative build numbers', () {
    final base = <String, dynamic>{
      'version': '1.2.3',
      'download_url': 'https://updates.example.com/iq-tunnel.apk',
      'sha256': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'notes': 'Security fixes',
      'signature': 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    };

    for (final invalid in <Object?>[42.0, -1, true, '42', null]) {
      expect(
        () => UpdateInfo.fromJson(<String, dynamic>{
          ...base,
          'build_number': invalid,
        }),
        throwsA(isA<FormatException>()),
        reason: 'Rejected build_number value: $invalid',
      );
    }
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

  test('cancels a rejected manifest response before throwing', () async {
    final client = _TrackingResponseClient(statusCode: 503);
    final service = UpdateService(client: client);
    addTearDown(service.dispose);

    await expectLater(
      service.check(),
      throwsA(isA<UpdateUnavailableException>()),
    );
    expect(client.bodyCancelled, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, isTrue);
  });

  test('aborts a request whose response headers time out', () async {
    final client = _NeverRespondingClient();
    final service = UpdateService(
      client: client,
      requestTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.check(),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, isTrue);
  });

  test('aborts and cancels a manifest body that stalls after headers', () async {
    final client = _TrackingResponseClient(
      statusCode: 200,
      contentLength: 128,
    );
    final service = UpdateService(
      client: client,
      requestTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.check(),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, isTrue);
    expect(client.bodyCancelled, isTrue);
  });

  test('accepts a correctly signed Ed25519 update manifest', () async {
    final signed = await _makeSignedUpdate();
    final service = UpdateService(publicKeyBase64: signed.publicKeyBase64);
    addTearDown(service.dispose);

    await expectLater(service.verifyManifestForTesting(signed.update), completes);
  });

  test('rejects a tampered Ed25519 update signature', () async {
    final signed = await _makeSignedUpdate();
    final bytes = List<int>.of(base64Decode(signed.update.signature));
    bytes[0] ^= 0x01;
    final tampered = UpdateInfo(
      version: signed.update.version,
      buildNumber: signed.update.buildNumber,
      downloadUrl: signed.update.downloadUrl,
      sha256: signed.update.sha256,
      notes: signed.update.notes,
      signature: base64Encode(bytes),
    );
    final service = UpdateService(publicKeyBase64: signed.publicKeyBase64);
    addTearDown(service.dispose);

    await expectLater(
      service.verifyManifestForTesting(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects malformed Ed25519 key or signature lengths', () async {
    final signed = await _makeSignedUpdate();
    final service = UpdateService(publicKeyBase64: base64Encode(<int>[1, 2, 3]));
    addTearDown(service.dispose);

    await expectLater(
      service.verifyManifestForTesting(signed.update),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an APK HTTPS redirect to plain HTTP', () async {
    final client = _DowngradeRedirectClient();
    final service = UpdateService(client: client);
    addTearDown(service.dispose);

    await expectLater(
      service.download(_downloadUpdate(List<String>.filled(64, 'a').join()), onProgress: (_, __) {}),
      throwsA(isA<FormatException>()),
    );
    expect(client.requestCount, 1);
  });

  test('downloads an APK only when its SHA-256 matches', () async {
    final bytes = utf8.encode('verified APK fixture');
    final digest = crypto.sha256.convert(bytes).toString();
    final client = _DownloadResponseClient(chunks: <List<int>>[bytes], contentLength: bytes.length);
    final directory = await Directory.systemTemp.createTemp('iqt-update-valid-');
    final service = UpdateService(
      client: client,
      temporaryDirectoryProvider: () async => directory,
    );
    addTearDown(service.dispose);
    addTearDown(() => directory.delete(recursive: true));

    final file = await service.download(_downloadUpdate(digest), onProgress: (_, __) {});
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), bytes);
  });

  test('deletes an APK whose SHA-256 does not match', () async {
    final bytes = utf8.encode('tampered APK fixture');
    final client = _DownloadResponseClient(chunks: <List<int>>[bytes], contentLength: bytes.length);
    final directory = await Directory.systemTemp.createTemp('iqt-update-hash-');
    final service = UpdateService(
      client: client,
      temporaryDirectoryProvider: () async => directory,
    );
    addTearDown(service.dispose);
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      service.download(_downloadUpdate(List<String>.filled(64, 'a').join()), onProgress: (_, __) {}),
      throwsA(isA<FormatException>()),
    );
    expect(await File('${directory.path}/iq-tunnel-update.apk').exists(), isFalse);
  });

  test('deletes a truncated APK download', () async {
    final bytes = utf8.encode('short');
    final client = _DownloadResponseClient(chunks: <List<int>>[bytes], contentLength: bytes.length + 10);
    final directory = await Directory.systemTemp.createTemp('iqt-update-short-');
    final service = UpdateService(
      client: client,
      temporaryDirectoryProvider: () async => directory,
    );
    addTearDown(service.dispose);
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      service.download(_downloadUpdate(List<String>.filled(64, 'a').join()), onProgress: (_, __) {}),
      throwsA(isA<FormatException>()),
    );
    expect(await File('${directory.path}/iq-tunnel-update.apk').exists(), isFalse);
  });

  test('deletes an APK stream that exceeds its declared length', () async {
    final bytes = utf8.encode('oversized fixture');
    final client = _DownloadResponseClient(chunks: <List<int>>[bytes], contentLength: bytes.length - 1);
    final directory = await Directory.systemTemp.createTemp('iqt-update-large-');
    final service = UpdateService(
      client: client,
      temporaryDirectoryProvider: () async => directory,
    );
    addTearDown(service.dispose);
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      service.download(_downloadUpdate(List<String>.filled(64, 'a').join()), onProgress: (_, __) {}),
      throwsA(isA<FormatException>()),
    );
    expect(await File('${directory.path}/iq-tunnel-update.apk').exists(), isFalse);
  });

  test('cancels an APK response with an unknown Content-Length', () async {
    final client = _TrackingResponseClient(statusCode: 200);
    final service = UpdateService(client: client);
    addTearDown(service.dispose);
    final update = UpdateInfo(
      version: '1.2.3',
      buildNumber: 42,
      downloadUrl: 'https://updates.example.com/iq-tunnel.apk',
      sha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      notes: '',
      signature: '',
    );

    await expectLater(
      service.download(update, onProgress: (_, __) {}),
      throwsA(isA<FormatException>()),
    );
    expect(client.bodyCancelled, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, isTrue);
  });
}
