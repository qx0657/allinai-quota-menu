# AGENTS.md

Guidance for Codex or other coding agents working in this project.

## Scope

This repository contains a small native macOS menu bar app written as a single Swift source file plus shell scripts for icon generation, installation, and DMG packaging.

## Important Paths

- Source: `Sources/AllinAIQuotaMenu.swift`
- Install script: `build.sh`
- DMG packaging script: `package_dmg.sh`
- Icon script: `make_icon.sh`
- DMG output: `dist/AllinAI-Quota.dmg`
- Installed app: `/Applications/AllinAI Quota.app`
- App data: `~/Library/Application Support/AllinAIQuotaMenu/`

## Development Rules

- Keep the app lightweight; avoid frequent polling beyond the configured timer.
- Preserve the service API host `https://allincode.top` unless the backend endpoint is confirmed to change.
- Keep credentials out of source. Passwords must stay in macOS Keychain.
- Prefer focused changes in `Sources/AllinAIQuotaMenu.swift`; avoid introducing a package manager unless there is a clear need.
- Keep generated DMGs under `dist/`.

## Validation

Run these checks after changing source or scripts:

```bash
swiftc -typecheck Sources/AllinAIQuotaMenu.swift
zsh -n build.sh
zsh -n make_icon.sh
zsh -n package_dmg.sh
```

For install verification:

```bash
./build.sh
open "/Applications/AllinAI Quota.app"
```

For DMG verification:

```bash
./package_dmg.sh
hdiutil imageinfo dist/AllinAI-Quota.dmg
```

## Naming

Use `AllinAI` for app-visible names, local app identifiers, icon resources, and documentation.

Known intentional exception:

- `https://allincode.top/api/v1`
- `https://allincode.top/subscriptions`

Those are real service URLs and should not be renamed as part of branding cleanup.

