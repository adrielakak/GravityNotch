# Contributing to GravityNotch

Thanks for taking the time to contribute! Code, translations, bug reports, docs and feature ideas are all welcome, and first-time open source contributors are explicitly welcome too.

## Table of Contents

- [Where to Start](#where-to-start)
- [Setting Up Your Environment](#setting-up-your-environment)
- [The One Xcode Quirk You Must Know](#the-one-xcode-quirk-you-must-know)
- [Making Changes](#making-changes)
- [Pull Requests](#pull-requests)
- [Translations](#translations)
- [Reporting Bugs](#reporting-bugs)
- [Feature Requests](#feature-requests)

## Where to Start

- Browse issues labeled [`good first issue`](https://github.com/adrielakak/GravityNotch/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22): they are scoped, and each one points to the files involved.
- Comment on the issue before you start so nobody else works on the same thing.
- For larger changes, open an issue first to discuss the approach.

## Setting Up Your Environment

Requirements: macOS 14 or later and Xcode 16+.

1. Fork the repository, then clone your fork:
   ```bash
   git clone https://github.com/{your-username}/GravityNotch.git
   cd GravityNotch
   ```
2. Create a branch from `main`:
   ```bash
   git checkout -b fix/short-description
   ```
3. Build without a signing identity:
   ```bash
   xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
     CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" build
   ```
   Or open `boringNotch.xcodeproj` in Xcode and run the `boringNotch` scheme.

The project has no test target yet, so verification means: it builds, and you ran the app and checked your change works.

## The One Xcode Quirk You Must Know

Only `boringNotch/private/` and `BoringNotchXPCHelper/` are file-system synchronized groups. In every other folder, a new `.swift` file is **not compiled** until it is added to the `boringNotch` target (in Xcode: drag the file into the project navigator and tick the `boringNotch` target, or add it via *File > Add Files*).

Also note:
- Most GravityNotch-specific features (Clips, Agents, Caffeine, OCR, lock screen panel, Caps Lock HUD) currently live in `boringNotch/helpers/AppIcons.swift`.
- `boringNotch/helpers/Clipboard+Content.swift` is **not** part of the target and contains outdated duplicates of some of those types. Edit the versions in `AppIcons.swift`, not that file.

Quick map of the codebase:

| Area | Where |
| --- | --- |
| App entry, windows per screen | `boringNotch/boringNotchApp.swift` |
| Root view (closed notch, live activities, tabs) | `boringNotch/ContentView.swift` |
| Tabs (`home`, `shelf`, `clipboard`, `agents`) | `boringNotch/enums/generic.swift`, `boringNotch/components/Tabs/` |
| Header buttons (OCR, Caffeine, audio output) | `boringNotch/components/Notch/BoringHeader.swift` |
| Settings keys | `boringNotch/models/Constants.swift` (`Defaults.Keys`) |
| Settings UI | `boringNotch/components/Settings/` |
| Music controllers | `boringNotch/MediaControllers/` |
| Volume / brightness key interception | `boringNotch/observers/MediaKeyInterceptor.swift` |
| Shelf | `boringNotch/components/Shelf/` |

## Making Changes

- Keep pull requests focused: one fix or feature per PR.
- Add user-facing strings to the string catalog (`boringNotch/Localizable.xcstrings`) instead of hardcoding them.
- Use [Conventional Commits](https://www.conventionalcommits.org/) when you can: `feat: ...`, `fix: ...`, `docs: ...`, `chore: ...`.
- Remove debug prints before submitting.

## Pull Requests

1. Push your branch to your fork and open a pull request against `main` of `adrielakak/GravityNotch`.
2. In the description, explain what changed and why, reference the issue (`Fixes #12`), and add a screenshot or short screen recording for any UI change.
3. Be ready for a round of feedback. Reviews usually happen within a few days.

## Translations

GravityNotch is fully translated in English and French. Fifteen other languages (Arabic, Chinese Simplified, Czech, German, Hungarian, Italian, Korean, Polish, Portuguese (Brazil), Russian, Spanish, Turkish, Ukrainian, British English) inherited the original Boring Notch translations, but every GravityNotch-specific feature (Clips, Agents, lock screen player, onboarding...) is still missing in them.

To complete or add a language:

1. Open `boringNotch/Localizable.xcstrings` in Xcode (it opens as a table).
2. Select your language in the sidebar (or add one with the **+** button), then filter on untranslated strings and fill them in.
3. Open a pull request. Partial translations are fine.

## Reporting Bugs

Open an issue with:

- Steps to reproduce, expected vs. actual behavior
- Your macOS version, Mac model (notch or not, Apple Silicon or Intel) and GravityNotch version
- Screenshots or a screen recording if possible

## Feature Requests

Open an issue describing the use case and why it would help. Check existing issues first to avoid duplicates.

---

GravityNotch is a fork of [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch). Bugs that also exist in the original app are worth reporting upstream too.
