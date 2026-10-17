# Preparing a HeyBuds release

## Local checks

On Apple Silicon with Swift 6.4 and the macOS 27 SDK:

```sh
python3 scripts/audit-source.py
swift test
bash scripts/build.sh
python3 scripts/package-source.py
```

Check `dist/HeyBuds.app`, `dist/HeyBuds-arm64.zip` and `releases/HeyBuds-v0.3.0-source.zip`. The source script also generates a SHA-256 manifest and `SHA256SUMS`. The app is ad-hoc signed by default; this is neither Developer ID distribution nor notarization.

Version fields in `AppIdentity.swift`, `PanelView.swift`, `AppModel.swift` and `scripts/build.sh` must agree. The source auditor checks those fields. Preserve the license and third-party notices in both source and app bundles.

## GitHub repository

The prepared source archive unpacks into `HeyBuds/` and includes dotfiles, workflows, tests and all runtime catalogs. A normal build needs no sibling reference repositories.

Create a repository named `HeyBuds`, then upload the extracted source or push the prepared local repository's `main` branch to the repository URL you own. This local preparation does not create a remote repository or publish a release. Use GPL-3.0-or-later, preserve the existing LICENSE text and attribution, and use the README to describe the actual compatibility boundaries.

The build workflow uses GitHub's `xcode-27` Apple Silicon runner. Its available label and macOS 27 environment were checked on 2026-10-17 against the [official runner table](https://github.com/actions/runner-images/blob/main/README.md) and [image contents](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md). Availability is controlled by GitHub; inspect the environment gate and the first hosted run before treating CI as passed.

The workflow runs tests, audits and local signing, then uploads build artifacts. It has read-only repository permissions and does not publish releases or import signing credentials. Hardware tests are excluded from CI.

## Release assets

Attach the application ZIP, the matching source ZIP and `SHA256SUMS` to the corresponding version tag. Include the compatibility and signing limitations in release notes. Record new hardware results only with a device, operation and observed outcome; do not promote a successful build or parsed catalog into a hardware claim.

Local `backups/`, `dist/backups/`, raw hardware observations, build caches and user preferences are excluded from public source archives and Git tracking.
