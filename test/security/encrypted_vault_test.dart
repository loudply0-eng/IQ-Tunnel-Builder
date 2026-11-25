import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/security/encrypted_vault.dart';

class MemoryKeyStore implements VaultKeyStore {
  String? value;

  @override
  Future<String?> readKey() async => value;

  @override
  Future<void> writeKey(String value) async => this.value = value;
}

void main() {
  group('EncryptedVault', () {
    test('local encryption round-trips and rejects tampering', () async {
      final keys = MemoryKeyStore();
      final vault = EncryptedVault(keyStore: keys);
      final clear = utf8.encode('private VPN profile');
      final encrypted = await vault.encryptLocal(clear);

      expect(encrypted, isNot(containsAll(clear)));
      expect(utf8.decode(await vault.decryptLocal(encrypted)), 'private VPN profile');

      encrypted[encrypted.length - 1] ^= 1;
      await expectLater(vault.decryptLocal(encrypted), throwsA(anything));
    });

    test('decrypting with a missing local key fails without creating a replacement', () async {
      final originalKeys = MemoryKeyStore();
      final originalVault = EncryptedVault(keyStore: originalKeys);
      final encrypted = await originalVault.encryptLocal(
        utf8.encode('existing private VPN profile'),
      );

      final missingKeys = MemoryKeyStore();
      final restoredVault = EncryptedVault(keyStore: missingKeys);
      await expectLater(
        restoredVault.decryptLocal(encrypted),
        throwsA(isA<StateError>()),
      );
      expect(missingKeys.value, isNull);
    });

    test('malformed local key is rejected and never overwritten', () async {
      final keys = MemoryKeyStore()..value = 'not-base64';
      final vault = EncryptedVault(keyStore: keys);
      final encrypted = await EncryptedVault(
        keyStore: MemoryKeyStore(),
      ).encryptLocal(utf8.encode('profile'));

      await expectLater(vault.decryptLocal(encrypted), throwsFormatException);
      expect(keys.value, 'not-base64');
    });

    test('backup round-trips with password and rejects wrong password', () async {
      final vault = EncryptedVault(keyStore: MemoryKeyStore());
      final clear = utf8.encode('backup profile data');
      final encrypted = await vault.encryptBackup(
        clear,
        password: 'a-long-unique-passphrase',
      );

      expect(utf8.decode(await vault.decryptBackup(
        encrypted,
        password: 'a-long-unique-passphrase',
      )), 'backup profile data');

      await expectLater(
        vault.decryptBackup(encrypted, password: 'another-long-password'),
        throwsA(anything),
      );
    });

    test('rejects weak export passwords', () async {
      final vault = EncryptedVault(keyStore: MemoryKeyStore());
      await expectLater(
        vault.encryptBackup(utf8.encode('data'), password: 'short'),
        throwsFormatException,
      );
    });
  });
}
