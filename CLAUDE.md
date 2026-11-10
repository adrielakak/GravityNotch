# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

GravityNotch: a fork of [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) (GPL-3.0) that turns the MacBook notch into a Dynamic Island style control center. Native macOS app in Swift/SwiftUI + AppKit, deployment target macOS 14, Swift 5.

Remotes: `origin` is upstream boring.notch, `github` is the fork (`adrielakak/GravityNotch`). Push fork work to `github`, not `origin`.

## Build

No test target, no linter configured. Verification = a successful build plus running the app.

```bash
# Build without signing (Debug)
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" build
```

Targets: `boringNotch` (app) and `BoringNotchXPCHelper` (XPC service embedded in the app). SPM dependencies: Defaults, KeyboardShortcuts, LaunchAtLogin, Sparkle, Lottie, Pow, SwiftUI-Introspect, SkyLightWindow, MacroVisionKit, AsyncXPCConnection, swift-collections.

## Adding files to the Xcode project (important)

Only `boringNotch/private/` and `BoringNotchXPCHelper/` are file-system synchronized groups. Every other folder is a classic `PBXGroup`: a new `.swift` file there is **not compiled** until it is registered in `boringNotch.xcodeproj/project.pbxproj` (PBXFileReference, PBXBuildFile, group child, and Sources build phase).

Consequence in the current tree: most fork features live in one huge file, `boringNotch/helpers/AppIcons.swift` (~3400 lines), precisely because it is already in the target. `helpers/Clipboard+Content.swift` is **not** in the target; it contains duplicate copies of some of those types (`CaffeineManager`, `DroppyClipboardManager`, `CapsLockHUDMonitor`, ...). Adding it to the target as-is would cause duplicate symbol errors. Edit the version in `AppIcons.swift`.

## Architecture

- **Entry / windows**: `boringNotchApp.swift` holds the `AppDelegate`. It creates one borderless `BoringNotchWindow` per screen (or only the selected screen), repositions them on screen config changes, installs drag detectors over the notch region, and on screen lock switches windows to SkyLight (`BoringNotchSkyLightWindow`, private `SkyLight` framework) so the notch and lock screen media panel render above the lock screen.
- **State**: `BoringViewCoordinator.shared` is the global UI state (current tab `NotchViews`, sneak peeks/HUD content `SneakContentType`, selected screen). `BoringViewModel` is per-window (open/closed `notchState`, sizes, `open()`/`close()`). `ContentView.swift` is the root view that switches between closed notch, live activities and the open tabs.
- **Tabs**: `enums/generic.swift` `NotchViews` = `home`, `shelf`, `clipboard` (Clips), `agents`. Tab buttons in `components/Tabs/`, home in `components/Notch/NotchHomeView.swift`, header buttons (OCR capture, Caffeine, audio output) in `components/Notch/BoringHeader.swift`.
- **Settings**: persisted via the `Defaults` library; all keys are declared in `extension Defaults.Keys` in `models/Constants.swift`. Settings UI in `components/Settings/`.
- **Managers**: singletons (`.shared`) in `managers/` (music, volume, brightness, battery, calendar, webcam, spaces). Fork-added managers (`PlayingNextManager`, `AntigravityAgentMonitor`, `DroppyClipboardManager`, `CaffeineManager`, `ScreenCaptureOCRService`, `DroppyLockScreenMediaPanelManager`, `CapsLockHUDMonitor`, `AudioOutputRoutingMenu`) are in `helpers/AppIcons.swift`.
- **Media**: `MusicManager` picks a controller implementing `MediaControllerProtocol` (`MediaControllers/`: NowPlaying, Apple Music, Spotify, YouTube Music). `NowPlayingController` relies on the bundled `mediaremote-adapter/` (Perl script + `MediaRemoteAdapter.framework`) since MediaRemote is restricted on recent macOS. Apple Music / Spotify use AppleScript (`helpers/AppleScriptHelper.swift`). Synced lyrics come from LRCLIB in `MusicManager`.
- **System HUDs**: `observers/MediaKeyInterceptor.swift` intercepts volume/brightness/backlight keys via CGEvent taps (`.cghidEventTap`, `.cgSessionEventTap`, `.cgAnnotatedSessionEventTap`) to suppress native HUDs and drive sneak peeks. Needs Accessibility permission.
- **XPC helper**: privileged-ish work (accessibility authorization checks, screen and keyboard brightness get/set) goes through `XPCHelperClient.shared` (`boringNotch/XPCHelperClient/`) to the `BoringNotchXPCHelper` service. The protocol file exists in both targets and must stay identical.
- **Shelf**: `components/Shelf/` is MVVM: `Models`, `Services` (drop, persistence, thumbnails, quick share, `ImageProcessingService` for OCR / background removal via Vision), `ViewModels`, `Views`.
- **Live activities / HUD views**: `components/Live activities/` (inline HUD, battery, download, marquee).

## Conventions

- Upstream contribution rules (CONTRIBUTING.md) say code PRs target the `dev` branch of boring.notch; this fork works on `main`.
- Translations are managed through Crowdin (`Localizable.xcstrings`, `crowdin.yml`); add new user-facing strings to the string catalog rather than hardcoding.
- Release updates are delivered via Sparkle (`updater/appcast.xml`); DMG packaging scripts in `Configuration/dmg/`.
