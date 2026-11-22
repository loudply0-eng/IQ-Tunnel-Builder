# IQ Tunnel automatic private-source releases

## 1. Public builder Environment

In `loudply0-eng/IQ-Tunnel-Builder`, open **Settings → Environments → iq-tunnel-production**.

Keep deployment branches restricted to `main`. Add this Environment secret:

| Name | Value and scope |
|---|---|
| `IQT_PROD_SOURCE_READ_TOKEN` | Fine-grained PAT restricted to the private repository `loudply0-eng/IQ-Tunnel` only, with Repository permissions → Contents: Read-only |

Do not grant this token write access. It is separate from Android signing, Ed25519 update signing and Oracle SSH credentials.

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

- The source-read token is read-only and scoped only to IQ Tunnel's private repository.
- The dispatch token is scoped only to the IQ Tunnel public builder and has Actions write, not Contents write.
- The dispatcher is opt-in and has no production credentials.
- Never re-use SODFA, Iraq Network Monitor, or another project's keys, tokens, or server paths.
- Keep Android signing, manifest signing and Oracle deployment credentials in the public builder's `iq-tunnel-production` Environment.
- The public builder's current source mirror and historical Git commits remain public. This workflow makes release builds use the private source revision; it does not erase old public copies or rewrite Git history.
