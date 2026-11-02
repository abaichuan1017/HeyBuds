# Releasing

Use Apple Silicon, Swift 6.4 and the macOS 27 SDK:

The resulting application targets macOS 15 or later; the build SDK requirement is separate from the runtime requirement.

The build script explicitly records the active SDK version when linking. Lowering the runtime target must not lower the linked SDK metadata and change the default interface behavior on macOS 26+.

```sh
python3 scripts/audit-source.py
swift test --no-parallel
bash scripts/build.sh
python3 scripts/audit-app.py
```

Keep `AppIdentity.version`, `CFBundleShortVersionString` in `scripts/build.sh` and the changelog aligned. Increase `CFBundleVersion` for every release. Forks must use their own update feed and signing key.

## Signed updates

The application uses Sparkle's standard native interface and downloads the same DMG used for direct installation. Update checks start when the user requests them. Automatic checks, automatic installation and system-profile reporting are disabled by default. The HTTPS feed and each archive require Ed25519 signatures, and archive verification happens before extraction.

Initialize the signing account once with Sparkle's `bin/generate_keys --account HeyBuds-updates` and embed only its public key in `scripts/build.sh`. Keep the private key in the login Keychain, outside Git and archives. Prepare concise, user-facing release notes, then run:

```sh
python3 scripts/prepare-update.py --notes-file release-notes.md
python3 scripts/package-source.py
```

`prepare-update.py` signs the already-built app archive and `docs/appcast.xml`. Do not rebuild or change the archive after signing it. Commit the signed feed with the version tag, then publish the matching archive at the URL in the feed. Future releases keep the same signing key and feed URL.

## Publication

For a GitHub prerelease, use a distinct version such as `0.6.1-beta.1` and increase `CFBundleVersion`. Keep `docs/appcast.xml` on the stable release: do not run `prepare-update.py` for a prerelease. Publish the matching tag and DMG with `gh release create --prerelease --latest=false`. Prerelease installations continue to use the stable update feed and receive a future stable release when its build number is higher.

Upload the DMG directly, without wrapping it in a ZIP. Upload only `dist/HeyBuds-arm64.dmg`. Use GitHub’s automatically generated “Source code (zip)” for the matching tag; do not upload a duplicate source ZIP. GitHub also provides a source tarball automatically. Source packages, manifests and checksums generated under `releases/` remain local verification outputs.

Release notes describe changes users can see. Keep test counts, build/signing/package-audit results, local paths and process details in private maintenance records. The workflow uploads the app and source archive but does not publish a release or access the signing key.

The source package includes pinned dependency metadata and required licenses. `AGENTS.md`, other local instructions, backups, captures, signing material and temporary previews are excluded. `audit-app.py` checks the bundled files, the pinned Sparkle framework, relative symlinks, catalog equivalence and disk-image contents.
