# IQ Tunnel — Public Build Repository

This repository is the intentionally public build mirror for the IQ Tunnel Android application. The separate development/source repository, `loudply0-eng/IQ-Tunnel`, remains private, but the copy of the application source in this builder is public and can be viewed, cloned, copied, or forked.

## Build workflows

- **IQ Tunnel Android CI** runs on pushes and pull requests. It runs the native libXray build checks, dependency integrity checks, Flutter analysis, tests, and a debug APK build. Its job has read-only repository permissions and does not receive production secrets.
- **IQ Tunnel Signed Release APK Artifact** is manual-only and runs from `main`. It creates a permanent-key-signed release APK artifact; it does not publish to the Oracle update server.
- **IQ Tunnel Public Builder — Signed Release** remains manually gated. A private-source dispatcher can request a release after an app-related push to private `main`, but only after the owner explicitly enables `IQT_AUTO_RELEASE_ENABLED` and configures a trusted required reviewer on the production Environment. It checks out an exact private source commit and verifies that commit is an ancestor of private `main` before building, signing, and publishing.

The two signed workflows use the GitHub Actions Environment named `iq-tunnel-production`. Before relying on it as a security boundary, the repository owner must configure that Environment to allow deployments from `main` only, add required reviewers where possible, and add the exact `IQT_PROD_*` secrets listed in [SECURITY.md](SECURITY.md). Production workflows intentionally ignore the legacy repository-secret names and fail closed until those Environment secrets exist; remove the old repository-level copies after verifying the migration. Merely referencing an Environment in YAML does not enable its protection rules.

## Dependency integrity

The checked-in `pubspec.lock` pins the Dart/Flutter dependency graph. CI uses `flutter pub get --enforce-lockfile` so that a build fails rather than silently rewriting the lockfile. Dependabot checks GitHub Actions and Pub dependencies weekly.

GitHub's Dependency Graph, Dependabot alerts, and Dependency Review must be enabled in repository Security settings for dependency vulnerability alerts and PR dependency review to operate.

## Public-repository safety

- Do not add private credentials, Android keystores, keystore passwords, Ed25519 update private keys, SSH private keys, real user profiles, subscription links, router credentials, or private server configuration.
- Never print secrets in workflow logs or include them in artifacts.
- Keep production workflows manual-only and on `main`; never add production secrets to routine CI or pull-request jobs.
- This public builder is deliberately kept public to preserve the intended public-runner build arrangement. Making it private is not a routine hardening step and may change that arrangement.
- Public source visibility cannot be prevented: anyone can read and copy code placed in this repository.

See [SECURITY.md](SECURITY.md) for the security policy and the owner-only GitHub settings that must be completed.


## Automatic release from private source

New releases are built from the private `loudply0-eng/IQ-Tunnel` repository at an exact branch or commit SHA. The private source repository dispatches the public builder workflow when an app-related change lands on `main`. See [docs/AUTOMATIC_RELEASES.md](docs/AUTOMATIC_RELEASES.md) for the separate read-only source token and dispatch token setup.

The builder's existing public Git history and current source mirror are not erased by this workflow change. The release job uses the private source checkout for its actual build workspace.
