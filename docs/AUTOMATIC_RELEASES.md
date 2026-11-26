# IQ Tunnel automatic private-source releases

## 1. Public builder Environment

In `loudply0-eng/IQ-Tunnel-Builder`, open **Settings → Environments → iq-tunnel-production**.

Keep deployment branches restricted to `main`. Add this Environment secret:

| Name | Value and scope |
|---|---|
| `IQT_PROD_SOURCE_DEPLOY_KEY` | Private half of a dedicated SSH deploy key. Register its matching public key on `loudply0-eng/IQ-Tunnel` as a read-only deploy key. No account-wide PAT or write permission |

Do not grant this deploy key write access. It is separate from Android signing, Ed25519 update signing and Oracle SSH credentials.

**Before enabling automatic releases, add at least one trusted required reviewer to this Environment.** The dispatcher deliberately has an opt-in switch and must remain disabled until the approval gate is configured. Do not enable unattended production publishing merely to make builds automatic.

## 2. Private source dispatcher

In `loudply0-eng/IQ-Tunnel`, open **Settings → Secrets and variables → Actions → Repository secrets** and add:

| Name | Value and scope |
|---|---|
| `IQT_BUILDER_DISPATCH_TOKEN` | Fine-grained PAT restricted to `loudply0-eng/IQ-Tunnel-Builder` only, with Actions: Read and write. Do not grant Contents: Write. |

Then add a repository Actions variable:

| Name | Initial value |
|---|---|
| `IQT_AUTO_RELEASE_ENABLED` | `false` or leave unset |

The token only requests a workflow dispatch. It cannot read or write source contents and it is not given any Android signing, OTA signing, or Oracle credentials.

## 3. Automatic release behavior

The private dispatcher listens for app-related changes on private `main`. It is **disabled by default**. It runs only when `IQT_AUTO_RELEASE_ENABLED=true`.

When enabled, it asks the public builder to release the exact source commit SHA. The public builder:
1. Checks out the private source commit and the complete private `main` history.
2. Rejects the selected commit unless it is an ancestor of private `main`.
3. Builds the pinned libXray Android bridge and runs analysis/tests.
4. Signs the APK with the permanent Android key and verifies its approved certificate fingerprint.
5. Signs the update manifest with the dedicated Ed25519 private key.
6. Publishes the APK first and the signed manifest last.

The builder Environment approval must remain active. Android installation still requires the user's approval; silent installation is not supported.

## 4. Manual recovery

The builder workflow remains available for manual recovery. Run **Actions → IQ Tunnel Public Builder — Signed Release** on builder branch `main`, set `confirm_release=true`, and set `source_ref` to `main` or an exact 40-character private source SHA. The workflow rejects a SHA that is not reachable from private `main`.

## 5. Separation and security

- The source deploy key is a dedicated read-only deploy key for IQ Tunnel's private repository.
- The dispatch token is scoped only to the IQ Tunnel public builder and has Actions write, not Contents write.
- The dispatcher is opt-in and has no production credentials.
- Never re-use SODFA, Iraq Network Monitor, or another project's keys, tokens, or server paths.
- Keep Android signing, manifest signing and Oracle deployment credentials in the public builder's `iq-tunnel-production` Environment.
- Oracle publishing must use the dedicated `iqt-deploy` account, restricted to SFTP with no shell, sudo, or forwarding. Configure `/incoming` as the account's `ChrootDirectory`; from the SFTP client that jailed directory is `/`, so the workflow uploads to paths such as `/manifest.json` (not `/incoming/manifest.json`). The website must expose the host-side `/incoming` directory read-only at `/updates/iq-tunnel/`. The workflow checks that the SFTP-visible working directory is `/` and that POSIX rename is advertised, but this does not prove the host-side mapping: verify the actual account configuration, write access, atomic replacement of an existing file, and HTTPS checksum checks before enabling production dispatch.
- The public builder's current source mirror and historical Git commits remain public. This workflow makes release builds use the private source revision; it does not erase old public copies or rewrite Git history.

## 6. Mandatory Android in-place upgrade acceptance

A successful CI build is not proof that an installed app can be upgraded without losing its Android Keystore-backed vault. Before approving a stable APK or merging a storage-major-version update, run this checklist on a real Android device using a non-production test profile where possible:

1. Record the installed app's package ID, version/build number, and signing-certificate SHA-256. Do not infer signer identity from the version string.
2. In the installed app, create at least one recognizable test profile and verify it can be opened/used. Create an encrypted password-protected export and store it outside the app's private storage as a recovery copy.
3. Build/install the candidate as an **in-place update** over the installed app. Do not uninstall, clear app data, reset the device, or change Android users between steps. Android must accept the update with the same package ID and signing certificate.
4. Launch the updated app. Verify the pre-existing profile is still present and decrypts correctly; verify the profile's non-secret settings are unchanged.
5. Create a second profile, force-stop and relaunch the app, then verify both profiles remain readable.
6. Verify encrypted export/import with the recovery copy on a separate test install or after the original profile checks have passed.
7. Record device model, Android version, source commit, candidate APK SHA-256, before/after app versions, signer fingerprint, and each observed result.

**Pass criteria:** Android accepts the APK as an update; the original Keystore-backed key remains usable; all pre-existing profiles decrypt; newly saved data survives relaunch; export/import succeeds. Any missing profile, authentication error, unexpected key regeneration, signature mismatch, or install-as-new prompt is a failure and blocks release.

Never use uninstall/reinstall as an upgrade test: uninstalling can remove app-private data and invalidate the test. Do not test a downgrade by installing an older version over the candidate. Keep the existing user installation untouched until its signing lineage and a successful in-place update are established.

This checklist is a manual device gate. Static tests, Flutter tests, and Debug APK CI cannot substitute for it.

## 7. Android backup and device-transfer policy

The generated Android manifest sets `android:allowBackup="false"`, points legacy devices to `@xml/backup_rules`, and points Android 12+ devices to `@xml/data_extraction_rules`. Both XML resources exclude all nine documented app-storage domains (`root`, `file`, `database`, `sharedpref`, `external`, `device_root`, `device_file`, `device_database`, and `device_sharedpref`) using `path="."`. The Android 12+ rules apply independently to both cloud backup and direct device-to-device transfer.

Some Android 12+ manufacturers may ignore `allowBackup=false` for direct device transfer. The explicit `device-transfer` exclusions are therefore mandatory; the release workflow also inspects the compiled APK with AAPT2 and retains the manifest/resource dump as CI evidence. This static gate does not replace a real device-to-device migration test on supported OEM devices.

IQ Tunnel has no supported iOS companion app, so no cross-platform iOS transfer section is configured. OS backup/device migration is not the supported way to move encrypted VPN profiles. Use the app's password-protected encrypted export/import flow and retain the export outside app-private storage. If restored ciphertext is ever present without its Android Keystore key, the vault must fail closed rather than create a replacement key or overwrite the ciphertext.
