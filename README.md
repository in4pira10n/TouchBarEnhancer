# TouchBarEnhancer

English · [简体中文](README.zh-CN.md)
---

<img width="1004" height="30" alt="image" src="https://github.com/user-attachments/assets/bd93e3cc-dc58-490e-9507-49dd8db0da73" />
↑ Customized ChatGPT Bar.



<img width="1004" height="30" alt="image" src="https://github.com/user-attachments/assets/806bd62b-a930-468b-82c1-667b39ef7c76" />
↑ Lyrics.



<img width="1181" height="911" alt="image" src="https://github.com/user-attachments/assets/8eca2c08-bd99-4526-b7c2-280c8ea57c87" />
↑ The customization window.

---
A native macOS menu bar app for building per-app Touch Bars with reusable components. Built with Swift and AppKit, without BetterTouchTool or a full Xcode installation.

**Status:** early development, currently version 0.3.0. Requires macOS 14 or later and a MacBook Pro with a Touch Bar for hardware use. The app interface is in English.

## Features

- Per-app layouts using Apple's native **Customize Touch Bar…** drag-and-drop panel.
- **Keyboard Shortcuts**, **Quick Phrases**, and **Text** components for any app, plus dedicated controls for supported ChatGPT/Codex variants.
- **Scrolling** lists with left, center, or right alignment, or **Fill** layouts with per-item Relative, Fixed, or Hug widths. Multiple adaptive components share the remaining space equally.
- Per-component and per-button **Icon Only** / **Icon + Text** settings. Button titles use plain native text and truncate with an ellipsis when space is limited.
- Live editing, draggable list ordering, and separate app configurations. No Save buttons.
- Selection and exclusion policies, explicit per-app overrides, global pause, and silent launch enabled by default.
- Preserves the system Control Strip and replaces the modal bar's leftmost close slot with the first component.
- Configurable Control Strip button with an SF Symbol, tap/hold/modifier actions, and Bluetooth/system playback automation. Uses private registration APIs; placement is managed by macOS.
- A shared **Enhanced Bar**, toggled from a Control Strip interaction, with the same reusable components as app layouts. **Lyrics** shows the current timed line from NetEase, QQ Music or LRCLIB, with a local cache, native Pangu-style Chinese/Latin spacing, and per-app typography. Matching prefers exact title/artist, then the closest compatible duration. The search pane fills the current song and previews recommended results before you save a choice.

## Build and run

### Download

Download the Universal (`arm64` + `x86_64`) ZIP from [GitHub Releases](https://github.com/in4pira10n/TouchBarEnhancer/releases/latest), extract it, and move `TouchBarEnhancer.app` to a stable location before granting Accessibility access. The same app supports Apple Silicon and Intel Macs running macOS 14+. It is locally signed, **not notarized**; Gatekeeper may block it. See the release notes before installing.

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

For a Universal app containing both Apple Silicon and Intel binaries, use `bash scripts/build-app.sh --universal`. This builds each architecture with SwiftPM and combines them with `lipo` before signing. Without the flag, the script builds only the host architecture for local development.

## Set up your bar

1. Open **TB → Settings…** from the menu bar. Silent launch keeps this window closed at startup.
2. In **Applications**, choose **Exclusion Mode** (checked apps retain their native bar) or **Selection Mode** (only checked apps use the custom bar).
3. In **Apps**, select an app and configure its components. In Selection Mode, this list mirrors Applications, including unchecked entries.
4. Click **Customize Touch Bar…**, then drag components onto the bar and arrange them. Settings temporarily previews the selected app's layout; leaving the preview restores normal policy.
5. Grant **System Settings → Privacy & Security → Accessibility** access when using actions that send keyboard input or control app menus.

`Auto` follows the selection/exclusion policy. Explicit `Enabled` and `Native` overrides take precedence; global pause takes precedence over both. Removing a rule restores policy-based Auto behavior. Use **Hide and Restore System Bar** to dismiss the current custom bar, or **Show Touch Bar** to reapply policy.

Pause other Touch Bar replacement tools while using this app to avoid competing presentations.

**Settings → Control Strip** configures the system-tray entry (on by default). Set its SF Symbol and tap action: pause/resume enhancement (the default), paste the existing clipboard, paste specified text, copy text, send a recorded keyboard shortcut, run an Apple Shortcut, or open a URL. Changes save and apply immediately; Default resets just the symbol. Shortcut input can be None, Clipboard Text, or Specified Text. Shortcuts runs in the background through `/usr/bin/shortcuts` with literal arguments, without a shell. Paste Clipboard preserves the original pasteboard, including images/files; paste and keyboard actions target the foreground app and require Accessibility. Specified pasted text remains on the clipboard. Failures appear in the menu bar icon's tooltip and in this settings pane when open.

**Previous Media** and **Next Media** send system Now Playing transport commands without switching apps, sending keyboard input or changing the clipboard. They are available for every interaction. The active player determines whether it can skip and how Previous behaves; system acceptance alone does not confirm a track change.

Assign **Show Enhanced Touch Bar** to any interaction to show a shared bar to the left of the system Control Strip. Repeat the interaction to restore the current app's bar according to its rules. Configure it in **Settings → Enhanced Bar**, or use **Customize Enhanced Bar…** below the action selector. This layout is independent of per-app bars; its phrases and keyboard buttons act on the foreground app. While open, this explicit bar overrides app policy and Pause without changing either preference. It starts with Lyrics and closes on sleep or quit. Settings previews take priority while editing.

The **Configurations** list keeps Default and automation rules visible. Select Default to edit the fallback button, or use **Add Rule** to create a disabled rule based on Default. The right-hand editor separates the rule's name and enable switch, **When all match** conditions, and **Use this button** symbol and tap action. Choose **Bluetooth device is connected**, **Music / media is playing**, or both. For Bluetooth, use Refresh to select an already paired device, then enable the rule. The first matching enabled rule wins; drag rules or use ↑/↓ to change priority. Default stays fixed and is used when no rule matches. The header shows the configuration currently in use, independently of the selected editor. Conditions switch configuration only: actions still require a tap. Changes save immediately.

Each configuration, including Default, has its own **Show button** switch. Turning it off hides our extra Control Strip entry while that configuration is active, preserves its symbol/action, and keeps conditions monitored. A hidden matching rule still wins priority. For example, hide Default and show a Playing rule to display the button only during playback. The header's **Enable Control Strip button** is the master switch for both the entry and automation. Older configurations remain shown by default.

Media uses system Now Playing notifications: one initial state read, then playback/pause and playback-source changes update the rule without periodic media queries. This covers supported music, videos and browser media, not exclusively music, through availability-guarded private MediaRemote APIs. Paused or unavailable playback does not match. Bluetooth conditions alone check paired-device connection status about every two seconds while needed, without scanning or connecting; macOS may request Bluetooth permission. Monitoring continues while a configuration hides the button. No media app is launched and playback is never changed. With no enabled valid rules, monitoring stops; media-only rules do not access Bluetooth or start a polling timer.

Each configuration also has independent **Tap**, **Long Press**, **Option + Tap**, **Command + Tap**, and **Control + Tap** actions. Select an **Interaction**, then edit its action using the same fields. Existing Tap settings are preserved; additional interactions default to **No Action**. Under Long Press, **Hold for** sets the duration independently for each configuration (0.1–10 seconds, default 0.6); **Default** restores 0.6 seconds. Long Press fires once and suppresses the release tap. Modifier taps use the modifier held at press-down; Shift and multiple-modifier combinations have no assigned action. Modified holds remain modifier taps on release. Moving outside the button, hiding it, or changing configuration cancels a pending press. The hold deadline is a one-shot timer only while pressing; media monitoring remains event-driven.

The button has no app-style rounded bezel and uses the system's tray allocation. It requests AppKit's highest named visibility priority (High). This registers an additional item without changing Apple's saved button order or removing Play/Pause. Exact placement and availability depend on macOS; priority does not guarantee that system controls can never displace it. The button is removed when disabled or on normal quit. Pause/resume still respects your app rules.

On the tested Mac running macOS 14.8.9, this entry appears beside the expand chevron, before the system controls. Substituting its identifier for Play/Pause in the system's compact layout did not place it in the rightmost slot; that experiment was reverted. This feature adds an entry rather than replacing the system Play/Pause button. If ControlStrip is restarted separately, relaunch TouchBarEnhancer to restore its entry.

## Components

| Component | Behavior |
| --- | --- |
| Keyboard Shortcuts | Per-app buttons with an icon, title, optional background, shortcut, and description. Record combinations directly in Settings. Clearing a background restores the standard gray. |
| Menu Commands | The same button editor and layouts as Keyboard Shortcuts, with an exact menu command name instead of a key combination. Optional parent path (`View → Layout`) disambiguates duplicate names; an alternate name supports Show/Hide commands. Choose Menu Command reads a running app's menus. Commands execute through Accessibility only in the target foreground app; unavailable or ambiguous commands report an error. Also available in Enhanced Bar. |
| Quick Phrases | Per-app phrases pasted into the focused input with Command+V. Does not press Return; the inserted phrase remains on the clipboard. |
| Text | Per-app text entries with font, size, weight, color, tracking, baseline, alignment, decoration, overflow, and optional background. Each property has its own Default action. Defaults to pure white on a clear background; adding a background enables 4 pt of horizontal padding per side. The entire component supports Auto, Fixed, and Hug widths. |
| Lyrics | Current timed lyric line, centered by default with white text and no background. Shares Text's font, size, color and advanced typography editor, with individual defaults. Supports Scrolling/Fill, alignment, component Auto/Fixed/Hug width and Fill line Relative/Fixed/Hug width. Uses system Now Playing, online search and local cache. |
| Chat Shortcuts | User-defined chat labels, symbols/images, colors, and Control+1–9 slots. Available with the dedicated ChatGPT layout. |
| Sidebar / Terminal | Dedicated ChatGPT controls using matching menu actions when exposed by the target app. Terminal requires a compatible bottom-panel command. |
| Space | Native flexible space, placed explicitly in the customization panel. |

All list components support Scrolling and Fill. In Fill, the table's **Width** column sets each entry to **Relative** (default weight 12), **Fixed** (points), or **Hug** (natural content width). Relative weights divide the space remaining after Fixed/Hug entries and gaps; `6, 6, 12` gives a `1:1:2` ratio. Default entries still share width equally. Without Relative entries, unused space stays at the end; oversized Fixed/Hug content scrolls. Switching to Scrolling hides and ignores these settings while preserving them. Item gaps stay 8 pt and component gaps stay 12 pt. Text formatting applies only to the Text component. Standard action buttons retain native plain-text labels.

The ChatGPT adapter uses locally available menus and user-configured shortcuts. It **does not retrieve or synchronize pinned chats**, read conversations, or use an API key. Menu availability and Control+number behavior depend on the target app/version; configure slots to match its shortcuts. Music and Safari currently use generic components rather than dedicated integrations.

Text also has its own **Width** setting above the entry table, available in both layouts: **Auto** keeps the previous equal share, **Fixed** reserves a width in points, and **Hug** fits the whole text list. Compact Text can be narrower than 32 pt and releases space to other adaptive components. This is separate from individual entries' Fill widths; gaps and action-button text styles stay unchanged.

Lyrics follows the system's active Now Playing source, including compatible music and browser players. Add it through native customization or open Enhanced Bar. While visible, it searches NetEase, QQ Music and LRCLIB using the title and artist, checks available duration/album metadata, and caches matching timed lyrics locally for 30 days (confirmed misses for one hour). Playback notifications re-anchor a local timeline; a single deadline advances to the next line without polling the player. Pause retains the current line. Hiding the component stops observation and requests. Missing metadata, position, network access or matching timed lyrics produces an unavailable state; coverage and timing depend on the player and provider. The lightweight provider → LRC → current-line approach is inspired by [LyricsX](https://github.com/MxIris-LyricsX-Project/LyricsX) and [LyricsKit](https://github.com/MxIris-LyricsX-Project/LyricsKit), implemented independently without their UI or dependencies.

In **Settings → Lyrics**, drag sources to change priority. Exact title/artist matches are tried before fuzzy matching (enabled by default), which helps with artist aliases and title variations while retaining available duration/version checks. If a match is missing or incorrect, edit the title and optional artist, press **Search**, select a result to preview it, then choose **Use Lyrics**. The selection is cached for the song shown under **Save for**, even if playback changes during the search. Manual choices survive automatic cache expiry and source changes; **Restore Automatic** clears that song's selection. Manual searches contact the same sources only when requested.

Tap the Lyrics region to open **Settings → Lyrics**. Swipe right to advance 5 seconds or left to rewind 5 seconds. Requests clamp to the available duration and preserve pause. Repeated swipes accumulate while the player reports an unchanged pre-seek position, with one reconciliation read after three seconds. New player positions take precedence. The active player must support seeking; no keyboard shortcut, track skip, or media polling is used.

## Permissions, data, and limitations

- Configuration is stored locally using UserDefaults and AppKit's saved customization layouts. Embedded user images are stored with configuration, not in this repository.
- Keyboard Shortcuts, Quick Phrases, and app menu control require Accessibility access. Passive presentation and Text do not require it. Quick Phrases changes the clipboard when tapped.
- No account sign-in or API key is required. Visible Lyrics sends song/artist metadata to NetEase, QQ Music and LRCLIB over HTTPS; lyrics are cached in the app's local Caches folder. Other components do not require this network access.
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
bash scripts/check-component-widths.sh
bash scripts/check-text-component.sh
bash scripts/check-native-customization.sh
bash scripts/check-lyrics-backend.sh
bash scripts/check-lyrics-media.sh
swift build -c release
```

Additional scripts cover per-app phrases, display overrides, keyboard buttons, list ordering, and silent launch. Tests use isolated preferences and offscreen views where possible. Review older fixtures before running them: some present interactive UI.

For hardware layout verification, after packaging the signed app:

```sh
bash scripts/check-component-bar.sh
bash scripts/check-component-widths-bar.sh
bash scripts/check-text-region-width-bar.sh
bash scripts/check-control-strip.sh
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
