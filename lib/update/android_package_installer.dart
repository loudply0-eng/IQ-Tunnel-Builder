import 'package:flutter/services.dart';

/// Requests the Android per-app permission required to install a downloaded
/// APK. The actual installation remains delegated to Android's package
/// installer and always requires the user's confirmation.
class AndroidPackageInstaller {
  AndroidPackageInstaller._();

  static const MethodChannel _channel = MethodChannel('iq_tunnel/libxray');

  static Future<void> ensureCanInstall() async {
    final canInstall =
        await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    if (canInstall) return;

    final granted = await _channel
            .invokeMethod<bool>('requestInstallPackagesPermission') ??
        false;
    if (!granted) {
      throw const InstallerPermissionDenied();
    }
  }
}

class InstallerPermissionDenied implements Exception {
  const InstallerPermissionDenied();

  @override
  String toString() => 'Android install permission was not granted.';
}
