# IQ Tunnel — Production Release Setup

This guide is the operator checklist for producing the permanent, signed Android Release and publishing an in-app update. It does not authorize a release by itself.

## 1. Release safety gates

Do not dispatch either production workflow until all of these are true:

- The private vault fail-closed change is merged into `loudply0-eng/IQ-Tunnel` `main`, and the selected private source commit is an ancestor of that branch.
- The Builder workflow changes are merged into `loudply0-eng/IQ-Tunnel-Builder` `main`.
- The production GitHub Environment `iq-tunnel-production` is configured to allow deployments from Builder `main` only and has a required human reviewer.
- The installed app's package ID and signing-certificate fingerprint have been read from the actual device. Do not infer the signer from the version string.
- The permanent Android keystore and the Ed25519 update-signing private key are available and have been backed up securely.
- The Oracle SFTP jail and read-only HTTPS mapping have been verified by the server operator.

A successful Debug CI run is not a signed Release. A signed-artifact workflow run is not a published OTA release. A published OTA release is not proof of an in-place upgrade on a real device.

## 2. Configure the GitHub Environment

In the Builder repository, open **Settings → Environments → iq-tunnel-production**.

Configure the Environment to permit deployments from `main` only and require approval from a trusted reviewer. Keep production credentials exclusively in this Environment; do not put them in repository-level secrets, workflow YAML, commits, or artifacts.

Add these exact Environment secrets:

| Secret | Purpose |
| --- | --- |
| `IQT_PROD_SOURCE_DEPLOY_KEY` | Read-only SSH deploy key for the private `IQ-Tunnel` source repository |
| `IQT_PROD_ANDROID_KEYSTORE_BASE64` | Base64 encoding of the existing permanent Android keystore |
| `IQT_PROD_ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `IQT_PROD_ANDROID_KEY_ALIAS` | Must be `iq-tunnel` |
| `IQT_PROD_ANDROID_KEY_PASSWORD` | Key password |
| `IQT_PROD_UPDATE_PRIVATE_KEY_BASE64` | Existing Ed25519 private key matching the public key pinned in the app |
| `IQT_PROD_ORACLE_SSH_KEY` | Dedicated SFTP-only private SSH key |
| `IQT_PROD_ORACLE_HOST` | Oracle hostname (not a URL) |
| `IQT_PROD_ORACLE_USER` | Must be `iqt-deploy` |
| `IQT_PROD_ORACLE_KNOWN_HOSTS` | Independently verified SSH host-key entry |

The workflow deliberately checks the Android signing certificate SHA-256 against:

```
cc96499ac23bf3a9101b2a7cc7d19feef852e61a5902860abe15218a8968b017
```

It also checks that the Ed25519 private key corresponds to the app's pinned public key:

```
4eOsYpXniRBp1ZTJjq5c3HbDW8tCvWbv1fr5PLVl+sk=
```

**Do not generate replacement keys to satisfy these checks.** A new Android keystore will have a different signer and Android will reject it as an update over an installation signed by the approved certificate. A new Ed25519 key will not match the public key embedded in already-installed apps. If either original private key is lost, stop and plan a deliberate key migration; never silently replace it.

The deploy key for the private source repository must be a dedicated read-only repository deploy key. The Oracle key must belong only to the SFTP-only `iqt-deploy` account.

## 3. Oracle SFTP and HTTPS layout

The production workflow expects:

- The SFTP account's chroot root to be the host-side `/incoming` directory. Inside SFTP, this appears as `/`.
- The chroot directory itself to be root-owned and not writable by `iqt-deploy`, as required by OpenSSH.
- A pre-created `/publish` child directory writable by `iqt-deploy`.
- The website to expose the host-side `/incoming/publish` directory read-only at:

  `https://mahmoudaljuorany.store/updates/iq-tunnel/`

The workflow tests SFTP access, the jail root, and OpenSSH POSIX rename support. It uploads the versioned APK and Xray source archive, downloads the public APK over HTTPS, verifies its positive Content-Length and SHA-256, verifies the published Xray archive against its sidecar, and only then atomically replaces `manifest.json`.

These client-side checks do not prove the host's actual filesystem ownership or web-server mapping. The server operator must verify those independently before production use. Never give the deployment account a shell, sudo, forwarding, or write access outside its intended publish directory.

## 4. Verify the currently installed app before upgrading

The expected Android application ID is:

```
com.iqtunnel.iq_tunnel
```

With the phone connected and USB debugging authorized, inspect the installed package:

```powershell
adb shell pm path com.iqtunnel.iq_tunnel
adb shell dumpsys package com.iqtunnel.iq_tunnel | findstr /i "versionName versionCode"
```

Pull the installed base APK using the path returned by `pm path`, then inspect its signer with Android Build Tools:

```powershell
adb pull <returned-base-apk-path> .\\iq-tunnel-installed.apk
apksigner verify --verbose --print-certs .\\iq-tunnel-installed.apk
```

Compare the installed APK's certificate SHA-256 with the approved fingerprint above. If the package is absent, or its signer differs, do not attempt an in-place update over it. Do not uninstall, clear app data, or reset the device as a substitute for this check.

## 5. Build a signed APK artifact without publishing

After the Builder workflow changes are on `main`, open **Actions → IQ Tunnel Signed Release APK Artifact → Run workflow**.

- Select Builder branch `main`.
- Set `confirm_build` to `true`.
- Select private `main` or an exact 40-character private commit SHA that is already an ancestor of private `main`.
- Complete the required Environment approval.

This workflow builds and verifies a signed APK artifact; it does not publish the APK or update manifest to Oracle. Verify the artifact's package ID, version/build number, signer fingerprint, and SHA-256 before considering a production publication.

## 6. Publish the signed Release and activate OTA

Only after all gates above pass, open **Actions → IQ Tunnel Public Builder — Signed Release → Run workflow**.

- Select Builder branch `main`.
- Set `confirm_release` to `true`.
- Select private `main` or an exact 40-character private commit SHA that is already an ancestor of private `main`.
- Complete the required Environment approval.

The workflow checks the selected private source history, runs the fail-closed vault gate, runs Flutter analysis and tests, builds the Release with the permanent Android keystore, checks the package/version/signer, publishes the APK, verifies the public APK bytes, and publishes the signed manifest last.

The app's Release build performs a signed update check after the first frame at startup. The user can also check manually in Settings. When a newer signed manifest is found, the app verifies the Ed25519 signature, downloads the APK, checks SHA-256, and hands the APK to Android's package installer. Android still requires the user to approve installation; this is not silent installation.

## 7. Mandatory real-device acceptance

Before declaring the app production-ready:

1. Install the first approved signed Release as the baseline only after confirming the installed package/signing situation.
2. Create a non-sensitive test profile and confirm it is readable.
3. Install a higher build number **over the existing app**, without uninstalling or clearing data.
4. Confirm Android accepts the update, the original profile still decrypts, and app settings remain.
5. Create a second test profile, force-stop and relaunch, and confirm both profiles remain readable.
6. Confirm the app detects a later published manifest, verifies it, downloads the APK, and opens Android's installer.
7. Record device model, Android version, before/after versions, signer fingerprint, source commit, APK SHA-256, and results.

The app currently has encrypted profile export/import primitives but no user-facing export/import UI. Do not describe profile migration or portable backup as available until that feature is implemented and tested.

## 8. Operational restrictions

- Never commit or print signing secrets, keystores, SSH private keys, or the Ed25519 private key.
- Never dispatch a production workflow merely to see whether secrets are configured.
- Do not enable automatic release dispatch. Keep production release manual and Environment-approved.
- Do not merge a PR, publish a Release, or deploy to Oracle without explicit approval.
- A CI pass does not replace signed-artifact verification, Oracle validation, or physical-device upgrade testing.
