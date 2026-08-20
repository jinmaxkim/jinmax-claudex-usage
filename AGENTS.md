# Repository Guidelines

## Project Structure

This is a small native macOS menu-bar app with no Xcode project or package manifest.

- `main.swift` contains the application, data readers, menu-bar UI, and preferences.
- `makeicon.swift` generates the app icon used during builds.
- `build.sh` compiles Swift sources and assembles `.build/ClaudexUsage.app`.
- `install.sh` rebuilds and installs the app; `package.sh` produces a distributable DMG in `dist/`.
- `README.md` is the user-facing setup and troubleshooting reference.

Keep generated `.build/` and `dist/` contents out of source changes unless intentionally releasing an artifact.

## Build, Test, and Development Commands

Work on macOS 13+ with the Xcode command-line tools installed.

```bash
./build.sh       # Compile with swiftc and create .build/ClaudexUsage.app
./install.sh     # Build, replace the local installed app, and stop a running copy
./package.sh     # Rebuild and create dist/ClaudexUsage-<version>.dmg
open .build/ClaudexUsage.app  # Launch the development bundle
```

There is no automated test suite yet. For changes, run `./build.sh`, launch the bundle, and manually verify menu-bar display, refresh behavior, preferences, and missing-data handling. Test both Claude history data and unavailable Codex/Claude sources where applicable.

## Coding Style and Naming

Use standard Swift style: four-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for functions, variables, and properties. Keep helpers narrowly scoped; use `private` for implementation details that do not need wider access. Prefer clear `guard` exits and Foundation/AppKit APIs already used by the app over new dependencies.

Keep shell scripts POSIX-friendly Bash with `set -e`, quoted paths, and concise comments. Do not hand-edit generated app bundles or icons.

## Commit and Pull Request Guidelines

Recent commits use short, imperative Korean summaries (for example, `메뉴 막대 항목 위치 저장`). Follow that convention and keep each commit focused. Before committing, rebuild successfully and review `git diff`; do not include local usage data or generated output.

Pull requests should explain the user-visible behavior, note manual verification performed, link any relevant issue, and include a menu-bar screenshot when UI output changes. Call out macOS-version or local-app assumptions explicitly.

## Security and Local Data

The app reads Claude usage history from the user Library and queries a local Codex executable. Preserve this local-only model: do not add telemetry, upload usage data, or commit machine-specific paths, credentials, or captured usage files.
