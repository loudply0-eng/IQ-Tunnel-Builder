import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iq_tunnel/update/android_package_installer.dart';

const _channel = MethodChannel('iq_tunnel/libxray');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('does not open Android settings when install permission already exists',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method == 'canInstallPackages') return true;
      fail('Unexpected method: ${call.method}');
    });

    await AndroidPackageInstaller.ensureCanInstall();

    expect(calls, <String>['canInstallPackages']);
  });

  test('opens settings and continues when the user grants install permission',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method == 'canInstallPackages') return false;
      if (call.method == 'requestInstallPackagesPermission') return true;
      fail('Unexpected method: ${call.method}');
    });

    await AndroidPackageInstaller.ensureCanInstall();

    expect(calls, <String>[
      'canInstallPackages',
      'requestInstallPackagesPermission',
    ]);
  });

  test('stops before APK installation when the user denies permission',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method == 'canInstallPackages') return false;
      if (call.method == 'requestInstallPackagesPermission') return false;
      fail('Unexpected method: ${call.method}');
    });

    await expectLater(
      AndroidPackageInstaller.ensureCanInstall(),
      throwsA(isA<InstallerPermissionDenied>()),
    );
    expect(calls, <String>[
      'canInstallPackages',
      'requestInstallPackagesPermission',
    ]);
  });
}
