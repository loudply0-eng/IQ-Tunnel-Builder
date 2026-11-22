# IQ Tunnel automatic private-source releases

## 1. Public builder Environment

In `loudply0-eng/IQ-Tunnel-Builder`, open **Settings → Environments → iq-tunnel-production**.

Keep deployment branches restricted to `main`. Add this additional Environment secret:

| Name | Value and scope |
|---|---|
| `IQT_PROD_SOURCE_READ_TOKEN` | Fine-grained PAT restricted to the private repository `loudply0-eng/IQ-Tunnel` only, with Repository permissions → Contents: Read-only |

Do not grant this token write access. It is separate from Android signing, Ed25519 update signing and Oracle SSH credentials.

If the Environment has required reviewers, an automatic release waits for approval before it can use production secrets. For fully unattended release, the owner must intentionally decide whether to remove required reviewers while retaining the main-only deployment branch restriction. The workflow does not bypass Environment approvals.

## 2. Private source dispatcher

In `loudply0-eng/IQ-Tunnel`, open **Settings → Secrets and variables → Actions → Repository secrets** and add:

| Name | Value and scope |
|---|---|
| `IQT_BUILDER_DISPATCH_TOKEN` | Separate fine-grained PAT restricted to `loudply0-eng/IQ-Tunnel-Builder` only, with Actions: Read and write. Do not grant Contents: Write. |

This token is used only to start the public builder workflow. The private source dispatcher does not receive Android signing, OTA signing, or Oracle credentials.

## 3. Automatic release behavior

When an app-related change lands on private source `main`:

1. The private source dispatcher starts the public builder release workflow.
2. The builder checks out the exact private source commit SHA.
3. It builds the pinned libXray Android bridge, runs analysis/tests, signs the APK and verifies the permanent Android signing certificate.
4. It signs the update manifest with the dedicated Ed25519 private key.
5. It publishes the APK first and the signed manifest last.
6. The installed app checks the signed HTTPS manifest on launch and also exposes a manual update check in Settings.

The app verifies the Ed25519 metadata and SHA-256 APK digest before handing the APK to Android's installer. Android still requires the user to approve installation.

## 4. Manual recovery

The builder workflow remains available for manual recovery. Run **Actions → IQ Tunnel Public Builder — Signed Release** on builder branch `main`, set `confirm_release=true`, and set `source_ref` to `main` or an exact 40-character private source SHA.

## 5. Separation and security

- The source-read token is read-only and scoped only to IQ Tunnel's private repository.
- The dispatch token is scoped only to the IQ Tunnel public builder and has Actions write, not Contents write.
- Never re-use SODFA, Iraq Network Monitor, or another project's keys, tokens, or server paths.
- Keep Android signing, manifest signing and Oracle deployment credentials in the public builder's `iq-tunnel-production` Environment.
- The public builder's current source mirror and historical Git commits remain public. This workflow makes release builds use the private source revision; it does not erase old public copies or rewrite Git history.
