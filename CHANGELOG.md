# Changelog

## 0.4.3 — 2026-10-22

- Fix switches briefly turning dark or bright when opening Settings by removing the whole-panel page transition.

## 0.4.2 — 2026-10-22

- Use the native popover material for connection cards, synchronize their appearance and smooth the dark-mode edges.
- Use consistent system text sizing and regular weight for settings labels and selected values.
- Replace nested picker menus with native popup controls containing only choices and selection marks; remove duplicate headings.

## 0.4.1 — 2026-10-22

- Combine the Settings footer into one row: app name and compact license, GitHub, diagnostics and Quit at the far right.
- Show Alipay QR codes for ¥5 / ¥10 / ¥20 / ¥50 and any amount, selected directly in the coffee support popover.

## 0.4.0 — 2026-10-22

- Provide a DMG installer that opens directly and supports dragging HeyBuds to Applications.
- Download and install updates in a native macOS window, with progress, cancellation and restart.
- Make Settings more compact, merge the version into the update action and move diagnostics to the bottom right.
- Use a small GitHub footer icon and a separate coffee support entry with Alipay amounts of ¥5 / ¥10 / ¥20 / ¥50, direct links and sharing to a phone.

## 0.3.4 — 2026-10-22

- Use circular glass back buttons across secondary pages.
- Move setting explanations into clickable information buttons beside their labels, with hover help and accessible descriptions. Keep help available when the model selector is disabled.

## 0.3.3 — 2026-10-22

- Add manual update checking, the GitHub project link and a text-only donation link to Diagnostics.
- Compare stable release versions numerically, show update-check failures clearly and open downloads only at the user's request.

## 0.3.2 — 2026-10-22

- Add OPPO Enco X4 (`06EC10`) and its Enco Bohr alias from EncoDeck, with the model's noise modes, EQ presets, ten-band custom EQ and existing sound/device controls.
- Recognize X4 parent/child noise reports and require a Hi-Res-off readback before enabling spatial audio. X4 adaptive noise uses the parent button; individual adaptive levels are not exposed.
- Remove Apple / Beats catalogs and passive advertisement support; macOS provides their native integration.
- Set the minimum deployment target to macOS 26 and update both READMEs, placing disconnected and connection pop-up previews first.
- Keep local agent instructions out of Git tracking and source releases. Preserve the X4 source excerpt and GPL notice.

### Thanks

Thanks to [EncoDeck](https://github.com/TIANLI0/EncoDeck) and its contributors for publishing the OPPO Enco X4 model configuration and protocol tests used for this adaptation.

## 0.3.1 — 2026-10-22

- Show the menu bar entry before background catalog loading; create the panel on first use.
- Index model names and aliases once and reuse the catalog during discovery.
- Reduce background discovery wakeups and omit the idle loading indicator.
- Strip release symbols, losslessly compress the icon, compact runtime catalogs, exclude reference-only data and keep developer preview/check code in debug builds.
- Simplify bilingual READMEs, consolidate compatibility/release notes and verify exact app/ZIP contents in CI.

## 0.3.0 — 2026-10-17

- Rename EncoBar to **HeyBuds**, including the app, Swift package and modules, resources, diagnostics and `heybuds-probe`.
- Use `local.heybuds.app` and migrate recognized legacy preferences once, without replacing existing HeyBuds settings.
- Preserve the native interface and the six brand backends from 0.2.0.
- Prepare a public source archive, bilingual documentation, contribution and release guides, issue templates and GitHub Actions.

## 0.2.0 — 2026-10-17

- Add vivo / iQOO, Huawei, Xiaomi / Redmi, Edifier and read-only Apple / Beats backends alongside OPPO / OnePlus / realme.
- Import 226 catalog records, including model IDs and family rules. Keep hardware-validation claims separate from catalog and simulated-protocol coverage.
- Validate 61 automated tests before the rename.
