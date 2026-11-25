import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iq_tunnel/security/encrypted_profile_store.dart';
import 'package:iq_tunnel/security/encrypted_vault.dart';

class _MemoryKeyStore implements VaultKeyStore {
  String? value;

  @override
  Future<String?> readKey() async => value;

  @override
  Future<void> writeKey(String value) async {
    this.value = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('profiles are encrypted at rest and can be read back', () async {
    final keyStore = _MemoryKeyStore();
    final prefs = await SharedPreferences.getInstance();
    final store = EncryptedProfileStore(
      vault: EncryptedVault(keyStore: keyStore),
      preferences: prefs,
    );
    final profiles = <Map<String, dynamic>>[
      {
        'name': 'Test server',
        'type': 'vless',
        'server': 'example.invalid',
        'uuid': 'secret-profile-credential',
      },
    ];

    await store.writeAll(profiles);

    final stored = await store.debugStoredValue();
    expect(stored, isNotNull);
    expect(stored, isNot(contains('secret-profile-credential')));
    expect(stored, isNot(contains('"server"')));
    final encryptedBytes = base64Decode(stored!);
    expect(encryptedBytes.sublist(0, 5), <int>[0x49, 0x51, 0x54, 0x42, 1]);
    expect(await store.readAll(), profiles);
  });

  test('missing vault key preserves encrypted profiles without replacement', () async {
    final prefs = await SharedPreferences.getInstance();
    final originalKeys = _MemoryKeyStore();
    final originalStore = EncryptedProfileStore(
      vault: EncryptedVault(keyStore: originalKeys),
      preferences: prefs,
    );
    await originalStore.writeAll([
      {'name': 'Existing VPN', 'type': 'vless', 'uuid': 'private-credential'},
    ]);
    final encryptedBefore = await originalStore.debugStoredValue();

    final missingKeys = _MemoryKeyStore();
    final restoredStore = EncryptedProfileStore(
      vault: EncryptedVault(keyStore: missingKeys),
      preferences: prefs,
    );
    await expectLater(restoredStore.readAll(), throwsA(isA<StateError>()));

    expect(missingKeys.value, isNull);
    expect(await restoredStore.debugStoredValue(), encryptedBefore);
  });

  test('encrypted backup restores profiles with password', () async {
    final prefs = await SharedPreferences.getInstance();
    final keyStore = _MemoryKeyStore();
    final vault = EncryptedVault(keyStore: keyStore);
    final store = EncryptedProfileStore(vault: vault, preferences: prefs);
    final profiles = <Map<String, dynamic>>[
      {'name': 'Home', 'type': 'wireguard', 'privateKey': 'not-plaintext'},
    ];

    await store.writeAll(profiles);
    final backup = await store.exportBackup(password: 'correct horse battery');
    await store.clear();
    expect(await store.readAll(), isEmpty);

    await store.importBackup(backup, password: 'correct horse battery');
    expect(await store.readAll(), profiles);
    await expectLater(
      store.importBackup(backup, password: 'incorrect horse battery'),
      throwsA(isA<Exception>()),
    );
  });
}
