# AGENTS.md

Guidance for Codex or other AI/code agents working in this project.

<!-- agent-docs-sync:start -->

## Scope

A small native macOS menu bar app: one Swift file plus shell scripts. Keep changes focused; do not add a package manager or large dependency stack without a clear reason.

The Windows app stays in its own repository. Before changing quota rules, authentication, scheduling, reminders or updates, read `docs/NATIVE_PARITY.md` and check whether its native counterpart needs the same change. Do not introduce a cross-platform runtime to synchronize the repositories.

## Code Map

All production Swift types are in `Sources/AllinAIQuotaMenu.swift`:

- Models, `QuotaPolicy`, `Format`: API types, consumption mode, most constrained known cycle and formatting.
- `LocalStorage`, `Keychain`: config/token files, migration and credential storage.
- `AllinClient` actor: login, shared token renewal, API calls and error classification.
- `QuotaStore` (MainActor): independent resource snapshots, refresh scheduling, cooldown/backoff, cancellation and session epochs.
- `ReminderManager`: thresholds, quiet initial observation, deduplication and native notifications.
- `ReleaseVersion`, `ReleaseClient`, `UpdateChecker`: independent GitHub stable-release checks, daily scheduling and persisted cooldown.
- `SummaryContent`, `SummaryView`, `QuotaProgressView`, `ProgressIcon`: presentation and read-only native views; no disk or Keychain access while rendering.
- `AppDelegate`, `LoginPanelController`, `StartupManager`: status item/menu, asynchronous login and per-user LaunchAgent.
- `AppInfo.intervals`: supported refresh intervals. `ProgressIcon.make(_:)` renders `StatusSymbol` values.

Other entry points: `Tests/AllinAIQuotaTests.swift`, `Tests/run_tests.sh`, `build.sh`, `make_icon.sh`, `package_dmg.sh`. Product intent is in `PRODUCT.md`, native UI rules in `DESIGN.md`, and publishing in `docs/RELEASING.md`.

## Behavior

- Stay menu-bar-only; preserve `LSUIElement`. Login and long-description panels are temporary.
- Keep Chinese labels, `开机自启动`, and `版本：v<version>` near the menu bottom.
- Ring, progress bar and percentage mean remaining quota. Select the most constrained known cycle; missing data is not zero or unlimited.
- Expired subscriptions cannot obscure balance mode. Do not infer automatic balance billing when a valid subscription is exhausted.
- Preserve independent subscription/profile snapshots and last successful times on failure.
- Only authentication errors trigger session recovery. Share token renewal; late responses cannot restore a logged-out session.
- All refresh paths honor service cooldown. Pause during sleep and merge wake/network recovery.
- Reminders and daily automatic update checks default off. Keep initial reminders quiet and deduplicated.
- Preserve template icons, readable light/dark states and the optional menu bar number preference.

## Service and Storage

Preserve `https://allincode.top/api/v1` and `https://allincode.top/subscriptions`; these real service URLs are intentional exceptions to AllinAI branding.

Endpoints: POST `/auth/login`, POST `/auth/refresh`, GET `/subscriptions?timezone=<local-timezone>`, GET `/user/profile`, wrapped in `{ code, message, data }`.

- App data: `~/Library/Application Support/AllinAIQuotaMenu/`.
- `config.json`: email and refresh interval only. Other preferences use UserDefaults.
- Passwords: macOS Keychain service `local.allinai.quota.menu`. Never store passwords in source, JSON config, logs, README examples or fixtures.
- `tokens.json` contains sensitive local runtime data; never commit or log it.
- Preserve file permissions, atomic writes and legacy credential migration. Test with isolated temporary storage and generated fake credentials, not real account data.
- Startup: `~/Library/LaunchAgents/local.allinai.quota.menu.plist`, per-user with no administrator requirement.
- Update requests use this repository's latest published GitHub Release without AllinAI credentials. Stable tags are `v<major>.<minor>.<patch>`; keep opt-in daily scheduling and persisted GitHub cooldown.

## Build and Validation

Run after source or script changes on macOS:

```sh
swiftc -typecheck Sources/AllinAIQuotaMenu.swift
swiftc -swift-version 6 -typecheck Sources/AllinAIQuotaMenu.swift
zsh -n build.sh
zsh -n make_icon.sh
zsh -n package_dmg.sh
zsh -n Tests/run_tests.sh
./Tests/run_tests.sh
```

Build an isolated app with `./build.sh --output "$PWD/.build/AllinAI Quota.app"`. `./build.sh` without arguments replaces `/Applications/AllinAI Quota.app`; use it for an intended installation, after exiting the old app. Preserve failure-safe bundle replacement.

For release packaging:

```sh
./package_dmg.sh
hdiutil verify dist/AllinAI-Quota.dmg
hdiutil imageinfo dist/AllinAI-Quota.dmg
```

Packaging builds an isolated app and must not overwrite the installed app. The scripts share icon staging paths; execute them sequentially. Check bundle version, build number, `LSUIElement`, minimum OS and Mach-O architecture. Current deployment target is macOS 12.0 in both compiler target and generated plist; builds use the host architecture. The official 0.2.0 DMG is Apple Silicon, not universal. Intel and minimum-OS runtime behavior remain unverified.

Previews use simulated data and do not prove real menu, notification or VoiceOver behavior. Windows cannot fully validate Swift/AppKit or macOS packaging.

## Version and Publishing

Current version: 0.2.0, build 2. Keep `APP_VERSION` / `APP_BUILD` in `build.sh` and `package_dmg.sh` synchronized, plus the `AppInfo.version` fallback, README and CHANGELOG. Normal UI version comes from `CFBundleShortVersionString`.

Follow `docs/RELEASING.md`: publish a stable tag for the built commit with `AllinAI-Quota.dmg` and `SHA256SUMS.txt`, verify assets before publishing, then confirm the latest-release API. Source push alone is not a release. Publish when requested; current builds have no Developer ID signing or notarization.

Keep `.build/`, `Assets/*.iconset/`, DMGs, staging directories and checksum output ignored. Never commit runtime account data. Keep the marked guidance in AGENTS.md and CLAUDE.md mirrored; edit one source and synchronize the other.
<!-- agent-docs-sync:end -->
