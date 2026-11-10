# TouchBarEnhancer

English · [简体中文](README.zh-CN.md)

A native macOS menu bar app for building per-app Touch Bars with reusable components. Built with Swift and AppKit, without BetterTouchTool or a full Xcode installation.

**Status:** early development, currently version 0.1.0. Requires macOS 14 or later and a MacBook Pro with a Touch Bar for hardware use. The app interface is in English.

## Features

- Per-app layouts using Apple's native **Customize Touch Bar…** drag-and-drop panel.
- **Keyboard Shortcuts**, **Quick Phrases**, and **Text** components for any app, plus dedicated controls for supported ChatGPT/Codex variants.
- **Scrolling** lists with left, center, or right alignment, or **Fill** layouts with equal-width buttons. Multiple adaptive components share the remaining space equally.
- Per-component and per-button **Icon Only** / **Icon + Text** settings. Button titles use plain native text and truncate with an ellipsis when space is limited.
- Live editing, draggable list ordering, and separate app configurations. No Save buttons.
- Selection and exclusion policies, explicit per-app overrides, global pause, and silent launch enabled by default.
- Preserves the system Control Strip and replaces the modal bar's leftmost close slot with the first component.

## Build and run

### Download

Download the Apple Silicon (`arm64`) ZIP from [GitHub Releases](https://github.com/in4pira10n/TouchBarEnhancer/releases/latest), extract it, and move `TouchBarEnhancer.app` to a stable location before granting Accessibility access. The current binary requires macOS 14+ and is locally signed, **not notarized**; Gatekeeper may block it. See the release notes before installing. Intel binaries are not included in this release.

### Requirements

- macOS 14+.
- Xcode Command Line Tools with Swift 6.0 or later; development has used Swift 6.0.3. Full Xcode is optional.
- A stable code-signing certificate and its private key in your login keychain, trusted for code signing on your Mac.

Check the toolchain:

```sh
xcode-select --install # Only if Command Line Tools are not installed.
swift --version
xcrun --show-sdk-path
```

Clone the repository and compile:

```sh
git clone https://github.com/in4pira10n/TouchBarEnhancer.git
cd TouchBarEnhancer
swift build -c release
```

To package a runnable app, select a signing identity from `security find-identity -v -p codesigning`. Use an existing development certificate, or create a local Code Signing certificate with Keychain Access's Certificate Assistant and configure its trust on your Mac. The packaging script does not create certificates.

```sh
export TOUCHBAR_SIGNING_IDENTITY="YOUR_CODE_SIGNING_IDENTITY"
bash scripts/build-app.sh
open -g dist/TouchBarEnhancer.app
```

Alternatively, put the identity's name or fingerprint on the first line of `.signing-identity.local` in the project root. This file is ignored by Git. Never commit certificates or private keys.

The build script fails if the identity is missing or unavailable; it never falls back to ad-hoc signing. Keep the same signing certificate, bundle ID, and installation path across updates to help retain Accessibility authorization. Quit the running app before rebuilding its bundle, then relaunch the same `dist/TouchBarEnhancer.app`.

## Set up your bar

1. Open **TB → Settings…** from the menu bar. Silent launch keeps this window closed at startup.
2. In **Applications**, choose **Exclusion Mode** (checked apps retain their native bar) or **Selection Mode** (only checked apps use the custom bar).
3. In **Apps**, select an app and configure its components. In Selection Mode, this list mirrors Applications, including unchecked entries.
4. Click **Customize Touch Bar…**, then drag components onto the bar and arrange them. Settings temporarily previews the selected app's layout; leaving the preview restores normal policy.
5. Grant **System Settings → Privacy & Security → Accessibility** access when using actions that send keyboard input or control app menus.

`Auto` follows the selection/exclusion policy. Explicit `Enabled` and `Native` overrides take precedence; global pause takes precedence over both. Removing a rule restores policy-based Auto behavior. Use **Hide and Restore System Bar** to dismiss the current custom bar, or **Show Touch Bar** to reapply policy.

Pause other Touch Bar replacement tools while using this app to avoid competing presentations.

## Components

| Component | Behavior |
| --- | --- |
| Keyboard Shortcuts | Per-app buttons with an icon, title, optional background, shortcut, and description. Record combinations directly in Settings. Clearing a background restores the standard gray. |
| Quick Phrases | Per-app phrases pasted into the focused input with Command+V. Does not press Return; the inserted phrase remains on the clipboard. |
| Text | Per-app text entries with font, size, weight, color, tracking, baseline, alignment, decoration, overflow, and optional background. Each property has its own Default action. Defaults to pure white on a clear background; adding a background enables 4 pt of horizontal padding per side. |
| Chat Shortcuts | User-defined chat labels, symbols/images, colors, and Control+1–9 slots. Available with the dedicated ChatGPT layout. |
| Sidebar / Terminal | Dedicated ChatGPT controls using matching menu actions when exposed by the target app. Terminal requires a compatible bottom-panel command. |
| Space | Native flexible space, placed explicitly in the customization panel. |

All list components support Scrolling and Fill. Fill divides the component's width equally between entries, with 8 pt gaps; separate components have 12 pt gaps. Text formatting applies only to the Text component. Standard action buttons retain native plain-text labels.

The ChatGPT adapter uses locally available menus and user-configured shortcuts. It **does not retrieve or synchronize pinned chats**, read conversations, or use an API key. Menu availability and Control+number behavior depend on the target app/version; configure slots to match its shortcuts. Music and Safari currently use generic components rather than dedicated integrations.

## Permissions, data, and limitations

- Configuration is stored locally using UserDefaults and AppKit's saved customization layouts. Embedded user images are stored with configuration, not in this repository.
- Keyboard Shortcuts, Quick Phrases, and app menu control require Accessibility access. Passive presentation and Text do not require it. Quick Phrases changes the clipboard when tapped.
- No network API, account sign-in, or API key is required by TouchBarEnhancer.
- Cross-app presentation uses **private system-modal Touch Bar APIs**, isolated in `Sources/TouchBarBridge`. Compatibility may change with macOS updates; selector availability alone does not prove working hardware.
- A system slide-in transition can still occur when returning from a native bar to the custom bar. It remains unresolved.
- Launch at login, notarization, and automatic updates are not implemented. Published binaries are signed locally.
- The app hides its bar before sleep. Use **Show Touch Bar** after waking if needed. Recovery after crashes, forced termination, or conflicts with other tools needs hardware testing.

## Development and verification

Project conventions and adapter design rules are in [AGENTS.md](AGENTS.md).

```sh
bash scripts/check-settings.sh
bash scripts/check-settings-ui.sh
bash scripts/check-component-layouts.sh
bash scripts/check-text-component.sh
bash scripts/check-native-customization.sh
swift build -c release
```

Additional scripts cover per-app phrases, display overrides, keyboard buttons, list ordering, and silent launch. Tests use isolated preferences and offscreen views where possible. Review older fixtures before running them: some present interactive UI.

For hardware layout verification, after packaging the signed app:

```sh
bash scripts/check-component-bar.sh
bash scripts/capture-touchbar.sh
```

Hardware checks temporarily replace the executable inside the same signed app, then restore and relaunch production. Capture runs externally. Generated files stay in `.build/` or `dist/`; screenshots verify rendering, not physical touch response.

```text
Sources/TouchBarEnhancer/  App lifecycle, settings, components, and adapters
Sources/TouchBarBridge/    Objective-C bridge for private presentation APIs
Resources/                Bundle metadata and bundled artwork
Tests/                    Native regression fixtures
scripts/                  Build, signing, verification, and capture helpers
```
