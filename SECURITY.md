# IQ Tunnel Security Policy

## Supported repositories and visibility

- `loudply0-eng/IQ-Tunnel` is the private source repository.
- `loudply0-eng/IQ-Tunnel-Builder` is intentionally public so GitHub Actions can build from the free public builder workflow.
- The public builder currently contains the Flutter application source used for the build. **Anyone can read, clone, copy, or fork that code.** Keeping the separate source repository private does not make the public copy confidential.
- Do not place confidential implementation details, server inventories, user profiles, credentials, private links, or internal operational notes in the public builder.
- Do not change the builder repository to private as a casual hardening step; doing so changes the intended free-build arrangement.

## Reporting a vulnerability

Do not publish working exploits, credentials, router passwords, subscription links, private keys, or personal data in public issues or pull requests.

Use GitHub's private vulnerability reporting facility from the repository Security tab when it is available. Otherwise contact the repository owner through the owner's GitHub profile and share only the minimum reproducible information. Give the maintainer a reasonable opportunity to investigate and release a fix before public disclosure.

## Secrets and release credentials

- Never commit Android keystores, keystore passwords, Ed25519 update-signing private keys, SSH private keys, access tokens, panel passwords, or real user data.
- Keep production values in GitHub Actions Environment secrets, not source files, workflow literals, build arguments, artifacts, or logs.
- The Android signing key and Ed25519 update private key are different credentials. Keep the approved Android signing certificate stable across releases; do not rotate it unless a planned migration is required.
- The embedded Ed25519 public key is not secret. Its corresponding private key must never be bundled in the app or public repository.
- If a secret may have appeared in a commit, log, artifact, or screenshot, rotate the affected credential. Deleting the visible file in a later commit does not remove it from Git history.
- Never print secret environment variables or turn on shell tracing around commands that process them.

## GitHub Actions release isolation

- Routine Android CI has read-only repository permissions and must not receive production secrets.
- Signed artifacts and production publishing run only from builder `main`; building the signed artifact requires `confirm_build=true`, and publishing requires `confirm_release=true`. The private-source dispatcher is disabled by default and runs only when the private repository variable `IQT_AUTO_RELEASE_ENABLED` is explicitly set to `true`.
- Production workflows use the `iq-tunnel-production` GitHub Environment. Configure it to allow deployments from `main` only and require approval from a trusted reviewer before enabling automatic dispatch. Do not set `IQT_AUTO_RELEASE_ENABLED=true` while the Environment has no required reviewer. The dispatcher has no access to production secrets; those remain behind the builder Environment.
- Production workflows intentionally use Environment-only secret names, not the legacy repository-secret names. Add these exact names under **Settings → Environments → iq-tunnel-production → Environment secrets**:
  - `IQT_PROD_SOURCE_DEPLOY_KEY` — private half of a dedicated SSH deploy key; register its matching public key as a read-only deploy key on `loudply0-eng/IQ-Tunnel`. Do not use an account-wide token.
  - `IQT_PROD_ANDROID_KEYSTORE_BASE64`, `IQT_PROD_ANDROID_KEYSTORE_PASSWORD`, `IQT_PROD_ANDROID_KEY_ALIAS`, `IQT_PROD_ANDROID_KEY_PASSWORD`
  - `IQT_PROD_ORACLE_SSH_KEY`, `IQT_PROD_ORACLE_HOST`, `IQT_PROD_ORACLE_USER`, `IQT_PROD_ORACLE_KNOWN_HOSTS` — `IQT_PROD_ORACLE_USER` must be `iqt-deploy`, forced to internal SFTP with no shell, sudo, or forwarding. Its `ChrootDirectory` is `/var/www/ota-jail/iqt-jail`; its forced initial SFTP directory is `/incoming`, mapping to host-side `/var/www/ota-jail/iqt-jail/incoming`. Workflow upload paths must stay relative to that initial directory (`PUBLISH_DIR="."`). The Nginx `/updates/iq-tunnel/` route must explicitly alias `/var/www/ota-jail/iqt-jail/incoming/` read-only. Verify the directory permissions and public HTTPS mapping before production use.
  - `IQT_PROD_UPDATE_PRIVATE_KEY_BASE64`
- The legacy repository-level names are deliberately no longer read by release workflows. Keep production workflows failing closed until the Environment and new Environment secrets are configured. After validating the replacement credentials, remove obsolete `IQT_PROD_SOURCE_READ_TOKEN` and `IQT_PROD_ORACLE_DEPLOY_DIR` secrets, plus legacy repository-level copies.
- Keep third-party Actions pinned to immutable commit SHAs; keep checkout credentials disabled and token permissions read-only unless a narrowly scoped write is required.
- Protect `main`: require pull requests, require the `IQ Tunnel Android CI / android-debug` status check, require at least one approval where practical, dismiss stale approvals after new commits, require conversation resolution, and block force-pushes and branch deletion.
- Enable GitHub Dependency Graph and Dependabot alerts in the repository's Security settings. Dependency Review cannot run until Dependency Graph is enabled.
- CODEOWNERS only identifies reviewers. It does not enforce approval unless branch protection or a ruleset requires code-owner review.

## App data and cryptography

- Local VPN profile data is stored as authenticated AES-256-GCM ciphertext.
- The random local data key is held through `flutter_secure_storage` using Android Keystore-backed protection.
- Password-protected exports use a fresh salt and nonce, PBKDF2-HMAC-SHA256, and AES-256-GCM. Wrong passwords and modified ciphertext must fail closed.
- Android cloud backup is disabled, and the legacy plus Android 12+ cloud/device-transfer XML policies explicitly exclude all nine app-storage domains. Some OEMs may still behave differently for device-to-device migration, so real-device transfer validation remains mandatory. OS migration is not the supported profile-move path; use password-protected encrypted export/import. If ciphertext is restored without its Android Keystore key, the vault must fail closed without generating a replacement key.
- Do not log passwords, UUIDs, subscription URLs, private keys, VPN payloads, router credentials, ubus session identifiers, or raw RPC payloads.

## Updates

- Manifest and APK delivery must use HTTPS.
- Update metadata is authenticated with Ed25519 using the public key embedded in the app.
- APK bytes are checked against the signed SHA-256 digest before Android's package installer is opened.
- Preserve the Android application ID and approved signing certificate across releases.
- Android installation remains a user-approved platform operation; do not attempt silent installation.

## OpenWrt

- The initial integration is read-only. It must not add UCI writes, shell access, package installation, reboots, firewall changes, or firmware upgrades without a separately reviewed feature and threat model.
- Never expose the router's ubus endpoint to the public internet.
- HTTPS certificate validation must stay enabled. Do not add permissive certificate callbacks or accept all certificates.
- HTTP credentials are transmitted in clear text. The app must require a fresh, explicit user confirmation before each HTTP attempt and must restrict HTTP to literal private/local IP addresses or localhost. Public addresses and arbitrary local-looking DNS names must remain blocked.
- The generated Android manifest currently enables app-level clear-text compatibility to support local OpenWrt routers. This is broader than a host-specific Android network policy, so every other network client must enforce HTTPS itself. Do not add new clear-text endpoints or bypass the OpenWrt client's host and consent checks.
- The HTTP confirmation is a risk acknowledgement, not encryption. Users should only accept it on a trusted local network.

## Third-party components and testing

- Review dependency provenance, maintenance, Android support, native ABI support, and license obligations before bundling components.
- Keep required license notices in distributed builds.
- Pin native libXray and Xray-core source revisions. Verify generated API signatures and native artifact integrity.
- CI must run static analysis and tests before a release can be built.
- Physical-device tests are still required for VPN routing, DNS, IPv4/IPv6, reconnect behaviour, OpenWrt HTTP consent, and Android installation flows.
