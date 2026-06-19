# AllinAI Quota Menu

Lightweight macOS menu bar app for viewing AllinAI subscription quota.

Current version: `0.1.0`

Platform: **macOS**.

The Windows version is available at [qx0657/allinai-quota-tray-windows](https://github.com/qx0657/allinai-quota-tray-windows).

The app lives in the macOS menu bar, shows quota state with a circular progress icon, stores credentials locally, and periodically refreshes subscription usage from the AllinAI service API.

## Features

- Menu bar progress icon for quota usage.
- Login dialog with credentials stored in macOS Keychain.
- Access/refresh token cache under Application Support.
- Configurable refresh interval.
- Logout and manual refresh menu actions.
- Optional current-user startup entry from the menu.
- Version metadata in the app bundle and menu for future upgrades.
- DMG packaging script for sharing the app.

## Project Layout

```text
.
├── Sources/AllinAIQuotaMenu.swift  # App source, menu UI, API client, storage helpers
├── Assets/logo.png                 # Source icon image
├── Assets/AllinAIQuota.icns        # Generated app icon
├── build.sh                        # Build and install to /Applications
├── make_icon.sh                    # Regenerate .icns from logo.png
├── package_dmg.sh                  # Build dist/AllinAI-Quota.dmg
├── README.md                       # User/developer documentation
├── AGENTS.md                       # Notes for future AI/code agents
├── dist/                           # DMG output
└── research/                       # Captured web/API research artifacts
```

## Requirements

- macOS with Swift command line tools.
- `swiftc`, `sips`, `iconutil`, `plutil`, and `hdiutil` available on PATH.
- Network access to `https://allincode.top`.

## Build And Install

```bash
./build.sh
open "/Applications/AllinAI Quota.app"
```

The installed app path is:

```text
/Applications/AllinAI Quota.app
```

## Package DMG

```bash
./package_dmg.sh
```

The DMG is written to:

```text
dist/AllinAI-Quota.dmg
```

## Local Data

The app stores local data here:

```text
~/Library/Application Support/AllinAIQuotaMenu/
```

Files:

```text
config.json
tokens.json
```

Passwords are stored in macOS Keychain under service:

```text
local.allinai.quota.menu
```

Startup toggle LaunchAgent:

```text
~/Library/LaunchAgents/local.allinai.quota.menu.plist
```

Legacy config from `AllinCodeQuotaMenu` is migrated automatically when the new app starts.

## App Behavior

- On launch, the app creates an `NSStatusItem` and runs as a menu-bar-only app.
- If credentials exist, it refreshes quota immediately and then on the configured interval.
- Menu entries are rebuilt on open so status, version, startup state, and quota details stay current.
- The startup toggle writes or removes a per-user LaunchAgent and does not require administrator privileges.
- The app uses `LSUIElement` in `Info.plist`, so it does not appear as a normal Dock app.

## Service API

Base API:

```text
https://allincode.top/api/v1
```

Used endpoints:

```text
POST /auth/login
POST /auth/refresh
GET  /subscriptions?timezone=<local-timezone>
GET  /user/profile
```

Subscription page:

```text
https://allincode.top/subscriptions
```

Do not rename the API host unless the backend endpoint has actually changed.

## Versioning

Version metadata lives in:

```text
build.sh
package_dmg.sh
```

Update these together for a release:

```bash
APP_VERSION="0.1.0"
APP_BUILD="1"
```

Those values are written to the generated app bundle:

```text
CFBundleShortVersionString
CFBundleVersion
```

After building, verify:

```bash
plutil -p "/Applications/AllinAI Quota.app/Contents/Info.plist" | grep CFBundle
```

## Credits

The macOS implementation was created and maintained as the native menu-bar version of AllinAI Quota.

The Windows counterpart was generated with assistance from OpenAI Codex and is linked above. Future changes in either platform should preserve the shared product behavior where practical while using each platform's native APIs.

## Notes

- The user-facing app name is `AllinAI Quota`.
- The service endpoint remains `https://allincode.top/api/v1`; do not rename the real API host unless the service itself changes.
- The app is an unsigned local build. When sharing the DMG, recipients may need to allow the app in macOS Privacy & Security.
- Startup is per-user and does not require administrator privileges.
