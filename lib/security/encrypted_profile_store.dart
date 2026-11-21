import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'encrypted_vault.dart';

/// Persists VPN profiles only as authenticated ciphertext in app-private
/// preferences. The actual profile UI and engine consume this repository.
class EncryptedProfileStore {
  EncryptedProfileStore({
    required EncryptedVault vault,
    SharedPreferences? preferences,
  })  : _vault = vault,
        _preferences = preferences;

  static const String _storageKey = 'iq_tunnel_profiles_encrypted_v1';

  final EncryptedVault _vault;
  final SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ?? SharedPreferences.getInstance();

  Future<List<Map<String, dynamic>>> readAll() async {
    final encoded = (await _prefs).getString(_storageKey);
    if (encoded == null || encoded.isEmpty) return <Map<String, dynamic>>[];

    final encrypted = base64Decode(encoded);
    final clear = await _vault.decryptLocal(encrypted);
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! List) {
      throw const FormatException('Encrypted profile store has an invalid shape.');
    }
    return decoded.map((item) {
      if (item is! Map) {
        throw const FormatException('A stored profile is not an object.');
      }
      return Map<String, dynamic>.from(item);
    }).toList(growable: false);
  }

  Future<void> writeAll(List<Map<String, dynamic>> profiles) async {
    final clear = utf8.encode(jsonEncode(profiles));
    final encrypted = await _vault.encryptLocal(clear);
    final saved = await (await _prefs).setString(
      _storageKey,
      base64Encode(encrypted),
    );
    if (!saved) {
      throw StateError('Could not persist encrypted VPN profiles.');
    }
  }

  Future<Uint8List> exportBackup({required String password}) async {
    final profiles = await readAll();
    return _vault.encryptBackup(
      utf8.encode(jsonEncode(profiles)),
      password: password,
    );
  }

  Future<void> importBackup(
    List<int> backup, {
    required String password,
  }) async {
    final clear = await _vault.decryptBackup(backup, password: password);
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! List || decoded.any((item) => item is! Map)) {
      throw const FormatException('Backup does not contain a valid profile list.');
    }
    await writeAll(
      decoded.map((item) => Map<String, dynamic>.from(item as Map)).toList(),
    );
  }

  Future<void> clear() async {
    await (await _prefs).remove(_storageKey);
  }

  /// Useful for security tests: confirms that preferences never contain
  /// readable profile JSON.
  @visibleForTesting
  Future<String?> debugStoredValue() async =>
      (await _prefs).getString(_storageKey);
}
