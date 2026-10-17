# HeyBuds validation

Checked on 2026-10-17, Asia/Shanghai. This public summary excludes local historical logs, captures, preferences and recovery files.

## Executed locally

| Check | Result and boundary |
| --- | --- |
| Renamed project | Swift package, four source modules, three test targets, resource bundle, app metadata and CLI use HeyBuds / heybuds-probe |
| Automated tests | **64 passed**: 23 protocol, 34 session and 7 presentation / preference-migration tests |
| Isolated source archive | Extracted to a fresh temporary directory with no sibling references or build cache; all **64 tests passed again** |
| Release build | Apple Silicon arm64, Swift 6.4, macOS 27 SDK; HeyBuds 0.3.0 application packaged successfully |
| Signature and ZIP | Strict local ad-hoc signature validation passed; application ZIP CRC and every bundled file matched |
| Icon | Renamed application icon is byte-identical to the approved prior icon |
| Runtime identity | Actual app and menu bar show HeyBuds; settings show HeyBuds 0.3.0 |
| Preference migration | Migration marker confirmed; all four recognized preferences explicitly saved by the legacy installation were preserved; existing HeyBuds settings are protected by unit tests |
| Current device | Air5 Pro battery, wear and noise state displayed after launch; no earbud-setting writes were performed for the rename |
| Source audit | Explicit public-file allowlist, valid JSON, catalog/resource hashes, relative Markdown links, home-path / raw-address / private-key-block checks passed |
| GitHub preparation | Local main branch initialized; source, documentation, license, issue templates and workflow prepared. YAML parsed locally; hosted Actions has not run |
| Reference protection | Original 235-file reference manifest rechecked locally; no reference file changed |

Local environment was rechecked as Apple Silicon, macOS 27.2 and Apple Swift 6.4. Command Line Tools report existing missing search-directory linker warnings; linking, tests and packaging succeeded without changing the system toolchain.

The migration tests cover the preference allowlist, exclusion of unrelated data, preservation of current settings, one-time execution and invalid legacy values. The existing protocol and session suite remains unchanged in scope. Runtime inspection confirms current app identity and state display, not a complete hardware acceptance run.

## Not claimed

- No new-brand physical-device validation was performed in this rename.
- Imported model records and mock tests are not hardware certification.
- The app is not notarized or Developer ID signed by this local preparation.
- The original local preparation did not create a remote repository, tag or release. Public repository creation and release publication are a separate operation; hosted CI requires its own observed result.

See [compatibility](COMPATIBILITY.md), [brand scope](ALL_BRANDS.md) and [release preparation](RELEASING.md). Local recovery copies are kept outside the public package under ignored `backups/`.

## GitHub publication

The public repository [abaichuan1017/HeyBuds](https://github.com/abaichuan1017/HeyBuds) was created on 2026-10-17. Version v0.3.0 is being published from the audited source and matching local release assets. Hosted CI is tracked separately and is not assumed to pass.
