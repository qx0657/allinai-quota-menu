# AllinAI Quota Menu

Lightweight macOS menu bar app for viewing AllinAI subscription quota.

The app lives in the macOS menu bar, shows quota state with a circular progress icon, stores credentials locally, and periodically refreshes subscription usage from the AllinAI service API.

## Features

- Menu bar progress icon for quota usage.
- Login dialog with credentials stored in macOS Keychain.
- Access/refresh token cache under Application Support.
- Configurable refresh interval.
- Logout and manual refresh menu actions.
- DMG packaging script for sharing the app.

## Project Layout

```text
.
├── Sources/AllinAIQuotaMenu.swift  # App source
├── Assets/logo.png                 # Source icon image
├── Assets/AllinAIQuota.icns        # Generated app icon
├── build.sh                        # Build and install to /Applications
├── make_icon.sh                    # Regenerate .icns from logo.png
├── package_dmg.sh                  # Build dist/AllinAI-Quota.dmg
├── dist/                           # DMG output
└── research/                       # Captured web/API research artifacts
```

## Requirements

- macOS with Swift command line tools.
- `swiftc`, `sips`, `iconutil`, and `hdiutil` available on PATH.
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

Passwords are stored in macOS Keychain under service:

```text
local.allinai.quota.menu
```

Legacy config from `AllinCodeQuotaMenu` is migrated automatically when the new app starts.

## Notes

- The user-facing app name is `AllinAI Quota`.
- The service endpoint remains `https://allincode.top/api/v1`; do not rename the real API host unless the service itself changes.
- The app is an unsigned local build. When sharing the DMG, recipients may need to allow the app in macOS Privacy & Security.

