# Release checks

Use Apple Silicon, Swift 6.4 and the macOS 27 SDK:

```sh
python3 scripts/audit-source.py
swift test
bash scripts/build.sh
python3 scripts/audit-app.py
python3 scripts/package-source.py
```

The application ZIP is `dist/HeyBuds-arm64.zip`. `releases/` contains the versioned source ZIP, source manifest and `SHA256SUMS`. Attach matching application and source ZIPs plus checksums to the version tag. Keep version fields in `AppIdentity.swift`, `PanelView.swift`, `AppModel.swift` and `scripts/build.sh` consistent; the source audit checks them.

Release builds select only the app product, strip local/debug symbols, compact runtime JSON and icon PNG streams without changing their values or pixels, exclude reference-only resources and omit Finder metadata from the ZIP. Debug builds retain diagnostic preview and hardware-check flags. License notices stay in both distributions. `audit-app.py` checks the exact bundled files, catalog equivalence, signature, architecture and ZIP contents.

Signing is ad-hoc unless `HEYBUDS_SIGN_IDENTITY` is supplied. Local signature validation does not mean Developer ID distribution or notarization. Record hardware results separately from protocol tests.

`AGENTS.md` and other local agent instructions are excluded from Git tracking and the source allowlist. The X4 importer uses only the committed source excerpt. Confirm that the final source ZIP contains no instructions, backups, captures or temporary previews.

The workflow checks its runner environment before building. It audits source, runs tests, packages and checks the app, then uploads artifacts; it does not publish a release. Confirm each hosted run in Actions. Source archives use an explicit allowlist and exclude Git history, build caches, backups, captures and preferences. Normal builds require no sibling reference repositories.
