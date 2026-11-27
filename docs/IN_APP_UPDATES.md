# IQ Tunnel In-App Update System

## Client implementation

The Flutter client includes:
- Manual update check from Settings. Release builds also perform one signed update check after the first frame at startup; Debug and test builds do not contact the production update service automatically unless the test override explicitly enables it.
- HTTPS-only manifest and APK URLs. Redirects are followed manually and only while the destination remains HTTPS; requests are abortable on header or body timeout, and rejected response bodies are cancelled.
- Ed25519 signature verification of the manifest using a pinned public key.
- Version and Android build-number comparison; the manifest `build_number` must be a non-negative JSON integer (fractional, negative, string, and boolean values are rejected).
- APK download with progress display and a 500 MiB upper bound.
- SHA-256 verification before opening the downloaded APK.
- Android package-installer handoff through the platform APK-opening flow.

Android still requires the user to approve installation. The app cannot silently replace itself on an ordinary consumer device. Android may also ask the user to allow IQ Tunnel as an install source.

## Manifest format

The manifest is JSON with these fields:

```json
{
  "version": "0.1.2",
  "build_number": 3,
  "download_url": "https://mahmoudaljuorany.store/updates/iq-tunnel/iq-tunnel-0.1.2-3.apk",
  "sha256": "64-character-lowercase-hex-digest",
  "notes": "Bug fixes and improvements",
  "signature": "base64-encoded-Ed25519-signature"
}
```

The Ed25519 signature covers the UTF-8 bytes of compact JSON containing exactly these fields in this order: `version`, `build_number`, `download_url`, `sha256`, `notes`. The `signature` field is excluded from the signed payload.

The app pins the public key in `lib/main.dart`. The release workflow verifies that the configured private key matches that public key before publishing.

## Build and release workflows

- Build orchestration and workflows are maintained in the intentionally public `loudply0-eng/IQ-Tunnel-Builder` repository. Its routine CI validates the mirrored source and builds a Debug APK; production workflows check out an exact selected commit from this private repository, verify that it belongs to private `main` history, copy that source into the isolated build workspace, and run the fail-closed vault gate before compiling.
The production workflow is manual-only, restricted to Builder `main`, requires explicit confirmation and the `iq-tunnel-production` Environment, signs with the permanent Android keystore, verifies the final APK identity/signature/Release manifest policy, validates the published APK and Xray source archive over HTTPS, then publishes the signed update manifest last.

See [RELEASE_SETUP.md](RELEASE_SETUP.md) for exact secret names, key handling, Oracle destination requirements, and first-install instructions.

## Production acceptance test

The system is not considered production-ready until:
1. A permanent Android signing keystore is configured and backed up securely.
2. The Ed25519 private key matching the app's pinned public key is configured as a GitHub Actions secret.
3. Oracle SSH deployment is configured with verified host-key pinning and correct web-root permissions.
4. A signed production APK is built and published successfully.
5. The public manifest and APK URLs are verified over HTTPS.
6. A physical Android device installs the first signed release and successfully updates to a higher build number from inside the app.
7. The test confirms Android installer handoff, cancellation/failure handling, signature continuity, and app-data preservation.

Debug builds are signed differently from production builds. The first signed production release must be installed once as the baseline; uninstall the debug build first if its signing certificate differs. All later releases must keep the same application ID and Android signing certificate.


## Android install permission

On Android 8.0 and newer, the first in-app update may open the system
"Install unknown apps" page for IQ Tunnel. The updater checks the permission
before downloading and resumes only after the user grants it. Android's
package installer still displays its own final confirmation. This is expected;
the app cannot silently install an APK.
