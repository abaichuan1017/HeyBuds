# Validation

## 0.3.4 — 2026-10-22

- 72 automated tests passed: 27 protocol, 34 session and 11 presentation/preferences/update checks.
- Update checks cover numeric version ordering, stable-release and project-URL validation, HTTP failures and the user-facing results.
- Native navigation and information-help components were rendered and inspected.
- Diagnostics includes manual update checking, the GitHub project and a text-only donation link. No payment image or QR code is bundled.
- The arm64 release build, strict signature verification, runtime-resource equivalence and exact ZIP-content checks passed.
- A live latest-release query succeeded. The source archive was independently extracted, audited and tested: all 72 tests passed.
- Detailed local maintenance records and temporary visual fixtures are excluded from public source.

## Hardware and platform limits

Enco Air5 Pro has historical read/write observations. X4 coverage uses public EncoDeck frames and simulated sessions; it has not completed HeyBuds/macOS hardware acceptance. This update adds no new hardware claim.

The deployment target is macOS 26.0. Checks ran on macOS 27.2 with Swift 6.4; macOS 26 runtime acceptance remains pending. Ad-hoc signing is not Developer ID signing or notarization.

Build commands are in [RELEASING.md](RELEASING.md); model and capability limits are in [COMPATIBILITY.md](COMPATIBILITY.md).
