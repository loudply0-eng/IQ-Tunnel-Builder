import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the random local-vault key using Android Keystore-backed storage.
abstract interface class VaultKeyStore {
  Future<String?> readKey();
  Future<void> writeKey(String value);
}

class PlatformVaultKeyStore implements VaultKeyStore {
  PlatformVaultKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _keyName = 'iq_tunnel_vault_key_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readKey() => _storage.read(key: _keyName);

  @override
  Future<void> writeKey(String value) =>
      _storage.write(key: _keyName, value: value);
}

/// Authenticated encryption for local profile data and password-protected exports.
///
/// Export format: "IQTB" | version | 16-byte salt | 12-byte nonce | ciphertext | 16-byte GCM tag.
/// PBKDF2-HMAC-SHA256 derives a unique AES-256 key from the export password.
class EncryptedVault {
  EncryptedVault({VaultKeyStore? keyStore})
      : _keyStore = keyStore ?? PlatformVaultKeyStore();

  static const int _formatVersion = 1;
  static const int _maxBackupBytes = 10 * 1024 * 1024;
  static const List<int> _magic = [0x49, 0x51, 0x54, 0x42]; // IQTB
  static const List<int> _localAad = [0x49, 0x51, 0x54, 0x4c, 0x01]; // IQTL v1
  static const List<int> _backupAad = [0x49, 0x51, 0x54, 0x42, 0x01]; // IQTB v1

  final VaultKeyStore _keyStore;
  final AesGcm _aes = AesGcm.with256bits();

  Future<SecretKey> _localKey() async {
    final stored = await _keyStore.readKey();
    if (stored != null) {
      final bytes = base64Decode(stored);
      if (bytes.length != 32) {
        throw const FormatException('The local vault key is invalid.');
      }
      return SecretKey(bytes);
    }
    final bytes = _secureRandomBytes(32);
    await _keyStore.writeKey(base64Encode(bytes));
    return SecretKey(bytes);
  }

  /// Encrypts profile/configuration JSON for storage in the app's private files.
  Future<Uint8List> encryptLocal(List<int> cleartext) async {
    final box = await _aes.encrypt(
      cleartext,
      secretKey: await _localKey(),
      aad: _localAad,
    );
    return _pack(box.nonce, box.cipherText, box.mac.bytes);
  }

  /// Decrypts local data. Authentication failures are intentionally propagated.
  Future<Uint8List> decryptLocal(List<int> encrypted) async {
    final parts = _unpack(encrypted);
    final clear = await _aes.decrypt(
      SecretBox(parts.cipherText, nonce: parts.nonce, mac: Mac(parts.mac)),
      secretKey: await _localKey(),
      aad: _localAad,
    );
    return Uint8List.fromList(clear);
  }

  /// Creates a password-protected backup. Password must be at least 12 chars.
  Future<Uint8List> encryptBackup(
    List<int> cleartext, {
    required String password,
  }) async {
    _validatePassword(password);
    if (cleartext.length > _maxBackupBytes) {
      throw const FormatException('Backup is larger than the 10 MiB limit.');
    }
    final salt = _secureRandomBytes(16);
    final nonce = _secureRandomBytes(12);
    final key = await _deriveBackupKey(password, salt);
    final box = await _aes.encrypt(
      cleartext,
      secretKey: key,
      nonce: nonce,
      aad: _backupAad,
    );
    return Uint8List.fromList([
      ..._magic,
      _formatVersion,
      ...salt,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Opens a password-protected backup. Wrong passwords and tampering fail closed.
  Future<Uint8List> decryptBackup(
    List<int> encrypted, {
    required String password,
  }) async {
    _validatePassword(password);
    if (encrypted.length < 49 || encrypted.length > _maxBackupBytes + 49) {
      throw const FormatException('Encrypted backup size is invalid.');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (encrypted[i] != _magic[i]) {
        throw const FormatException('Unknown backup file format.');
      }
    }
    if (encrypted[4] != _formatVersion) {
      throw const FormatException('Unsupported backup file version.');
    }
    final salt = encrypted.sublist(5, 21);
    final nonce = encrypted.sublist(21, 33);
    final mac = encrypted.sublist(encrypted.length - 16);
    final cipherText = encrypted.sublist(33, encrypted.length - 16);
    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: await _deriveBackupKey(password, salt),
      aad: _backupAad,
    );
    return Uint8List.fromList(clear);
  }

  Future<SecretKey> _deriveBackupKey(String password, List<int> salt) =>
      Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 310000,
        bits: 256,
      ).deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );

  void _validatePassword(String password) {
    if (password.length < 12) {
      throw const FormatException(
        'Use an export password of at least 12 characters.',
      );
    }
  }

  Uint8List _pack(List<int> nonce, List<int> cipherText, List<int> mac) =>
      Uint8List.fromList([..._magic, _formatVersion, ...nonce, ...cipherText, ...mac]);

  ({List<int> nonce, List<int> cipherText, List<int> mac}) _unpack(
    List<int> data,
  ) {
    if (data.length < 33 || data[0] != _magic[0] ||
        data[1] != _magic[1] || data[2] != _magic[2] ||
        data[3] != _magic[3] || data[4] != _formatVersion) {
      throw const FormatException('Invalid encrypted local data.');
    }
    return (
      nonce: data.sublist(5, 17),
      cipherText: data.sublist(17, data.length - 16),
      mac: data.sublist(data.length - 16),
    );
  }

  List<int> _secureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
