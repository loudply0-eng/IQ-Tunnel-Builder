# IQ Tunnel automatic private-source releases

## 1. Public builder Environment

In `loudply0-eng/IQ-Tunnel-Builder`, open **Settings → Environments → iq-tunnel-production**.

Keep deployment branches restricted to `main`. Production secrets used by the manually confirmed release workflow belong only in this Environment. Configure at least one trusted required reviewer before any production run is approved. Keep the environment restricted to `main`.

Add the dedicated read-only private-source deploy key as an Environment secret:

| Name | Value and scope |
|---|---|
| `IQT_PROD_SOURCE_DEPLOY_KEY` | SSH private key for read-only checkout of `loudply0-eng/IQ-Tunnel`. Register its public half as a read-only deploy key on the private repository. It must not have write access. |

The same Environment secret is required by both signed Builder workflows because both now build from a commit verified against private `main`. Never paste the key into repository files, workflow inputs, PR comments, or logs.

**Current state:** Manual release is available only through the Builder's signed-release workflow with `confirm_release=true` and the Environment approval gate. Automatic private-source dispatch is currently hard-disabled; do not enable unattended publishing.

## 2. Private source dispatcher (held / not active)

The private repository's `.github/workflows/dispatch-public-builder.yml` is a disabled placeholder:
- It has only a manual `workflow_dispatch` trigger; it does not listen to `push` events.
- Its job condition is hard-coded as `${{ false }}`.
- It does not read an Actions variable, dispatch token, or any production credentials.

Therefore, **do not create `IQT_BUILDER_DISPATCH_TOKEN` or set `IQT_AUTO_RELEASE_ENABLED` expecting automatic releases to work**. Those names appeared in an earlier proposed design, but they are not active configuration in the current workflow. Re-enabling dispatch requires a separately reviewed code change, a narrowly scoped token, a trusted Builder Environment reviewer, available Actions budget, and explicit owner approval.

## 3. Automatic release behavior (not enabled)

There is no active automatic release behavior at present. Source changes on private `main` do not automatically request a public Builder production release. The hard-disabled dispatcher is intentionally retained as a placeholder while production validation is incomplete.

Any future automatic-release implementation must dispatch an exact private source commit SHA, verify that it is an ancestor of private `main`, keep the production Environment approval gate, and pass the same vault, backup, signing, SFTP, HTTPS and real-device acceptance gates as a manual release. Do not weaken the manual confirmation or Environment protection to enable automation.

## 4. Manual release and signed artifact

The Builder workflows are available for controlled manual use:
- **Actions → IQ Tunnel Public Builder — Signed Release** on Builder branch `main`: set `confirm_release=true` and `source_ref` to `main` or an exact 40-character private source SHA.
- **Actions → IQ Tunnel Signed Release APK Artifact** on Builder branch `main`: set `confirm_build=true` and select the same kind of private `source_ref`.

Both workflows use the read-only private-source deploy key, verify that the selected commit belongs to private `main` history, and build from the copied private source. Neither accepts an arbitrary public Builder mirror as the release source. The signed-artifact workflow creates a signed APK artifact only; the primary signed-release workflow is the one that deploys the OTA APK and manifest to Oracle. Both remain protected by the `iq-tunnel-production` Environment approval.

## 5. Separation and security

- The source deploy key is a dedicated read-only deploy key for IQ Tunnel's private repository.
- The dispatch token is scoped only to the IQ Tunnel public builder and has Actions write, not Contents write.
- The dispatcher is opt-in and has no production credentials.
- Never re-use SODFA, Iraq Network Monitor, or another project's keys, tokens, or server paths.
- Keep Android signing, manifest signing and Oracle deployment credentials in the public builder's `iq-tunnel-production` Environment.
- Oracle publishing must use the dedicated `iqt-deploy` account, restricted to SFTP with no shell, sudo, or forwarding. Configure `/incoming` as the account's `ChrootDirectory`, owned by `root` and not writable by the SFTP user (OpenSSH requires every `ChrootDirectory` component to be root-owned and not writable by group/others). Pre-create `/incoming/publish` as a child directory owned by `iqt-deploy` (or a dedicated writable group) with only the minimum required write/traverse permissions. From the SFTP client the jailed root is `/`, but uploads must go to `/publish/...`, never directly to `/`. The website must expose the host-side `/incoming/publish` directory read-only at `/updates/iq-tunnel/`. The workflow checks `pwd`, lists `/` and `/publish`, writes two probe files inside `/publish`, replaces one over the other using the supported `rename` command, and checks the OpenSSH verbose log for `posix-rename@openssh.com`. This client-side preflight does not prove the host-side mapping: verify the actual chroot ownership/modes, `/publish` ownership/write access, web-server mapping/read access, atomic replacement of an existing release file, and HTTPS checksum checks before enabling production dispatch.
- The public builder's current source mirror and historical Git commits remain public. This workflow makes release builds use the private source revision; it does not erase old public copies or rewrite Git history.

## 6. Mandatory Android in-place upgrade acceptance

A successful CI build is not proof that an installed app can be upgraded without losing its Android Keystore-backed vault. Before approving a stable APK or merging a storage-major-version update, run this checklist on a real Android device using a non-production test profile where possible:

The production workflow runs `.github/scripts/verify_vault_fail_closed.py` **after copying the selected private source revision** and refuses to build unless decryption cannot create a replacement key and the missing-key/profile-preservation regression tests are present. This is intentional: Builder's mirrored source passing CI is not enough if the production build selects an older private `main` revision. At the time of this review, private `main` does not yet contain the fail-closed key fix; it exists in [Private PR #15](https://github.com/loudply0-eng/IQ-Tunnel/pull/15). The production release remains blocked until that fix is merged into private `main`, the source gate passes against the merged revision, and the real-device acceptance below is completed.

1. Record the installed app's package ID, version/build number, and signing-certificate SHA-256. Do not infer signer identity from the version string.
2. In the installed app, create at least one recognizable test profile and verify it can be opened/used. **Do not assume a user-accessible backup exists:** the current source has encrypted export/import methods in the profile-store layer, but the app UI does not call them or expose export/import controls. Record export/import as **NOT IMPLEMENTED** until the user-facing feature is shipped.
3. Build/install the candidate as an **in-place update** over the installed app. Do not uninstall, clear app data, reset the device, or change Android users between steps. Android must accept the update with the same package ID and signing certificate.
4. Launch the updated app. Verify the pre-existing profile is still present and decrypts correctly; verify the profile's non-secret settings are unchanged.
5. Create a second profile, force-stop and relaunch the app, then verify both profiles remain readable.
6. After a user-facing encrypted export/import feature is implemented, verify export to a file, import on a clean test install, profile equality, and failure on wrong password/tampered backup. Until then, this criterion is **BLOCKED / NOT IMPLEMENTED** and must not be reported as passed.
7. Record device model, Android version, source commit, candidate APK SHA-256, before/after app versions, signer fingerprint, and each observed result.

**Pass criteria:** Android accepts the APK as an update; the original Keystore-backed key remains usable; all pre-existing profiles decrypt; and newly saved data survives relaunch. Password-protected export/import is an additional release criterion once its user-facing UI exists. At present that feature is **not implemented in the app UI**, so the full data-recovery acceptance is not complete. Any missing profile, authentication error, unexpected key regeneration, signature mismatch, or install-as-new prompt is a failure and blocks release.

Never use uninstall/reinstall as an upgrade test: uninstalling can remove app-private data and invalidate the test. Do not test a downgrade by installing an older version over the candidate. Keep the existing user installation untouched until its signing lineage and a successful in-place update are established.

This checklist is a manual device gate. Static tests, Flutter tests, and Debug APK CI cannot substitute for it.

## 7. Android backup and device-transfer policy

The generated Android manifest sets `android:allowBackup="false"`, points legacy devices to `@xml/backup_rules`, and points Android 12+ devices to `@xml/data_extraction_rules`. Both XML resources exclude all nine documented app-storage domains (`root`, `file`, `database`, `sharedpref`, `external`, `device_root`, `device_file`, `device_database`, and `device_sharedpref`) using `path="."`. The Android 12+ rules apply independently to both cloud backup and direct device-to-device transfer.

The generated Android manifest also removes the broad `READ_EXTERNAL_STORAGE` and `READ_MEDIA_*` permissions contributed by `open_filex`. IQ Tunnel uses that plugin only to hand off its own APK from app-private temporary storage to Android's package installer; it does not read user media. The AAPT2 gate rejects those permissions if they reappear in the merged APK manifest.

Some Android 12+ manufacturers may ignore `allowBackup=false` for direct device transfer. The explicit `device-transfer` exclusions are therefore mandatory; the release workflow also inspects the compiled APK with AAPT2 and retains the manifest/resource dump as CI evidence. This static gate does not replace a real device-to-device migration test on supported OEM devices.

IQ Tunnel has no supported iOS companion app, so no cross-platform iOS transfer section is configured. OS backup/device migration is not a supported way to move encrypted VPN profiles. **Current recovery gap:** `EncryptedProfileStore` contains password-protected `exportBackup()` and `importBackup()` methods, but the production UI currently has no call sites or controls for either method. These are internal storage primitives, not an available user feature. Do not claim users can export/import profiles yet, and do not uninstall/clear app data or migrate the installed device expecting profile recovery. Implement and test user-accessible file export/import before making portable recovery part of the product. If ciphertext is ever restored without its Android Keystore key, the vault must fail closed rather than create a replacement key or overwrite the ciphertext.
