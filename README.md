# IQ Tunnel — Public Build Repository

This repository is a public build mirror for the IQ Tunnel Android application.

- Builds an **unsigned debug APK** with GitHub Actions.
- Uses GitHub-hosted standard Ubuntu runners.
- Does not contain production signing keys, deployment credentials, or the production release workflow.
- The original development repository remains separate and private.

## Build

Open **Actions → IQ Tunnel Android CI**. Builds run on pushes to `main`, pull requests targeting `main`, or by selecting **Run workflow**.

The generated APK is available as the `iq-tunnel-debug-apk` artifact for 14 days.

## Important

This repository is public, so source code placed here can be viewed and copied by anyone. Do not add private credentials, signing keys, real user profiles, or production server configuration. Debug APKs are not production-signed releases.
