# TouchBarEnhancer: App adaptation and design rules

These are this project's conventions and lessons from the ChatGPT adapter, not
claims about official Apple HIG dimensions. Preserve user data and layouts.

## Environment and workflow

- Native AppKit menu bar app; English interface; macOS 14 minimum. Build with
  SwiftPM and Command Line Tools. Check `swift --version` before adopting newer
  language features; the current development toolchain is Swift 6.0.3.
- Keep UI and adapter state on the main actor. Prefer existing concrete shared
  components over another framework or an adapter-specific copy of the UI.
- Run `bash scripts/build-app.sh`. Update and relaunch only
  `dist/TouchBarEnhancer.app`; stop its exact running executable before replacing
  it. Never use `open -n` or leave competing app instances running.
- Preserve bundle ID, install path, and the certificate selected by
  `.signing-identity.local` / `TOUCHBAR_SIGNING_IDENTITY`. Use
  `scripts/sign-app.sh`; never fall back to ad-hoc signing or reset Accessibility
  permissions. A stable signing requirement keeps authorization across updates.
- **Launch silently is enabled by default**, including installations with no
  saved preference. Startup and debugging must not open or activate Settings.
  Explicit Settings menu actions may open it. Never change this preference just
  to make a test easier, or unexpectedly open test windows during debugging.
- Keep caches, binaries, probe files and screenshots in ignored `.build/` or
  `dist/` locations. Keep useful regression sources in `Tests/`. Do not assume
  this folder is a Git repository; preserve unrelated work.

## Component categories and reuse

| Category | Current examples | Contract |
| --- | --- | --- |
| Fixed action/toggle | Sidebar, Terminal | Independent native Touch Bar items; removable and reorderable |
| Adaptive component | Chat Shortcuts, Quick Phrases, Keyboard Shortcuts | Peer components, independently addable; share the same item renderer |
| Plain text | Text | Per-app text entries; adaptive region, optional background with 4-point content inset |
| Layout space | Native flexible Space | Optional user-controlled space; do not silently add/remove it |

- `ScrollingComponents.swift` is the source of truth: map adapter data to
  `ScrollingComponentItem`, configure `ShortcutScroller`, and handle `onSelect`.
  Keep its owner alive. Use `TouchBarComponentView` for component boundary spacing.
- Chat Shortcuts and Quick Phrases share item rendering and category editors.
  Categories in Settings are independently collapsible; this is not mutual
  exclusion. Quick Phrases is available to every app, even without a dedicated
  adapter or with ChatGPT controls disabled. Phrase lists are per app in
  `SettingsStore.quickPhrasesByApp`; each presentation owns its own views.
  On upgrade, copy the legacy shared list once to known apps (built-in, listed,
  layout, keyboard or display-configured apps). Retain the legacy key as a backup;
  never use it as a fallback after migration. New apps start empty, and an
  intentionally empty/deleted list must stay empty across relaunches.
- Keyboard Shortcuts is available to every app. Its button list and presentation
  settings are per app. Each button stores its own title, SF Symbol/embedded
  image, optional background, recorded shortcut and description. Empty background
  restores standard gray; never color the component container.
- All list components (Chat Shortcuts, Quick Phrases, Keyboard Shortcuts and Text)
  use `ComponentPresentation` and `ShortcutScroller`. Scrolling mode supports
  left/center/right alignment of the whole list; overflow scrolls naturally. Fill
  mode assigns equal item widths inside the available region, with 8-point gaps,
  no outer inset, and truncated labels when needed. Invalidate the scrubber layout
  when the viewport width or mode changes. Keep its manually positioned content
  out of canonical Auto Layout minimum-width measurement.
- `SettingsStore.componentPresentations` stores layout/alignment per app and
  component, separately from content and icon/text mode. Missing preferences use
  Scrolling/Left, except legacy Keyboard Shortcuts configurations retain their
  saved layout/alignment. `ComponentPresentationControls` supplies the same native
  Settings UI everywhere. Fill hides the whole-list alignment option without
  discarding it; changing back to Scrolling restores it. Fixed one-button
  controls and native Space retain their existing behavior.
- Each adaptive component has a per-app `Icon Only` / `Icon + Text` display
  preference, defaulting to Icon + Text for older/new preferences. Store these
  separately from item content. Apply changes to all existing and
  future presentation instances without recreating the bar or field editor.
  `ShortcutScroller.displayMode` owns rendering and measurement: Icon Only hides
  the title and its gap, centers the unchanged icon, and measures only the icon
  plus 16-point side padding. Retain full title, tooltip, accessibility label and
  action data. Fill buttons remain equal width; scrolling buttons use the new
  fitting width. Restore text when recycling a view back to Icon + Text.
- Every chat, phrase and keyboard item has an optional `displayModeOverride`.
  `nil` follows the component; forced Icon Only / Icon + Text takes precedence
  for rendering and natural-width measurement. Optional decoding preserves old
  records. The shared item editor exposes Follow Component / Always Icon Only /
  Always Icon + Text. Keep the override with its stable item through editing,
  reordering and persistence. Fill allocation and inter-item gaps do not change.
- Give each component a distinct stable item identifier. Give each app's layout
  its own customization identifier. Keep the generic and dedicated ChatGPT
  layouts separate; preserve existing identifiers and saved component order.
- A view has only one superview. Never move the same NSView between a palette,
  Settings preview, and modal presentation. Share configuration/models, not
  presentation views. Keep ownership scoped to the actual Touch Bar context.

## Plain text and system typography

- `TextComponent.swift` owns the text model, per-app list editor and native font
  handling. Text uses the shared region/scroller and participates in equal peer
  allocation and native customization with the stable `text` item identifier.
  Do not insert it into existing user layouts automatically.
- Plain text defaults to no background, icon, or 16-point button content padding.
  An optional per-entry background color enables 4-point horizontal content padding
  on each side; clearing/resetting that background restores zero padding. These
  are internal insets, never changes to the 8/12-point item/component gaps.
  Only the 12-point external component gap and 8-point gap between separate text
  entries apply. Use natural text widths for Scrolling and equal cells for Fill.
- `TextComponentStyle` stores optional font face, size, weight, italic, text color,
  opacity, tracking, baseline, underline, strikethrough, text alignment, overflow
  and background color.
  Nil means the corresponding AppKit label/paragraph default, except the user's
  chosen project defaults: text foreground is pure white and background is clear.
  Resetting foreground returns white, and resetting background removes its inset.
  Never serialize
  guessed system font names, sizes, colors or zero tracking as the default.
- Each property has its own Default action; reset only that property and update
  all presentations immediately. Font selection uses NSFontManager/NSFontPanel;
  color uses NSColorWell; text drawing uses NSTextField/NSAttributedString and
  paragraph attributes. Font-panel changes must still target the current editor.
  Retain face traits selected in the font panel unless explicitly overridden.
- Text alignment is within an entry's cell; component alignment positions the
  whole list in Scrolling mode. Keep these separate. The 30-point hardware height
  remains fixed; oversized typography can be clipped. Reject nonfinite/out-of-range
  numeric edits without saving, and do not steal focus from the field editor.
- Basic text styling stays compact; advanced typography is independently
  collapsible. Text content is edited in the native list and supports stable-ID
  reordering. Empty lists remain empty after relaunch.

## Dimensions and appearance (points, not screenshot pixels)

| Property | Value / behavior |
| --- | --- |
| Visible component height | 30 |
| Text and scrolling SF Symbol size | 15, system font / regular weight, default tracking |
| Icon–title gap inside an item | 6 |
| Horizontal content padding inside each item | 16 per side |
| Gap between items inside one scroller | 8 |
| Gap between separate components | 12 (AppKit's 8 plus wrapper's 4) |
| Extra inset around a scrolling region | 0, especially when it is the leading component |
| Minimum scrolling viewport | 32, plus any component boundary spacing |
| Item corner radius | 6 |
| Standard background | #363636; pressed background #808080; white foreground |
| ChatGPT Sidebar symbol | 19, using SF Symbol rendering |
| Current ChatGPT side button width | 75 each; project-specific, not a universal AppKit size |
| Terminal artwork | Embedded original image, fills height 30; intentional exception to normal symbol sizing |
| Separation from system Control Strip | Preserve the observed system gap of 16 |

- Keep icon and title together in one vertically centered stack. Title width is
  natural/fitting width; do not split icon and title across a full-width row or
  center the entire chat list in the available bar. Measure and draw using the
  same font, image dimensions, padding and gap constants.
- Button titles use plain `stringValue`, stay on one line and truncate at the
  tail with an ellipsis when space is insufficient. Only Text uses attributed
  strings. Explicitly reset font/color/alignment and disable wrapping when
  recycling a Text entry into a button. Preserve the button label's original
  native cell metrics (usesSingleLineMode false, maximumNumberOfLines 0);
  truncation keeps it on one line. Use the same configuration for measurement
  and drawing. Measure Text with a hidden label in its actual Touch Bar context:
  AppKit adapts default typography after attachment, so an offscreen scratch
  label can underestimate its natural width and clip the final characters.
- Use SF Symbols for normal controls. Do not stretch them to 30 high or recolor
  only the icon for press feedback. Press feedback changes the background;
  toggles may additionally reflect the target app's observed state.
- Quick Phrases uses standard gray. Chat Shortcuts may use a named system color
  or hex color. A chat tap is a momentary action, not a persistent selection frame.
- NSScrubber uses free scrolling, non-continuous selection, no selection overlay
  or background. Reset selectedIndex after execution so the same item can be
  tapped again. Scrolling past an item must not execute it.

## Adaptive layout and native customization

- Read available width from the actual system-owned presentation area. 684 is a
  design reference; this machine's app area has also measured 685. Do not fix the
  entire bar to either number or constrain its root wider than the system window.
- Fixed controls retain their width. Scrolling components divide the remaining
  width equally after fixed controls and 12-point component gaps. Removing a side
  control lets the remaining regions expand. Handle either order, one region,
  multiple regions, narrow widths, and explicitly inserted Space.
- Round equal modal viewport allocations down to backing pixels. AppKit rounds
  each view frame independently; rounding three fractional widths upward can hide
  the last region even when their unrounded constants sum to the available area.
- Keep minimum, preferred and allocated widths distinct. A minimum-width
  constraint alone is insufficient: AppKit's customization measurement can treat
  an intrinsic preferred width as the minimum. Horizontal compression resistance
  for the scrolling region **and its wrapper must be below fitting-size priority
  50** (currently 1). Otherwise a nominal 32-point viewport is measured around
  510 points, and dragging another scroller replaces the first. Check AppKit's
  measured minimum, not just the Swift constant or programmatic layouts.
- Hard constraints for the modal host must stay with its separate views. Never
  leak its allocated width into canonical customizable/palette items.
- Canonical customizable components may need equal sibling width constraints as
  well as equal preferred sizes: AppKit can expand a populated region while an
  empty region stays at its preference. Install only relative equalities once
  the canonical views share a presentation ancestor; remove them on detachment.
  Keep these separate from the modal host's allocated-width constants. Native
  regression fixtures must settle the layout pass after attachment callbacks.
- Observe native item order changes and update boundary spacing and allocation.
  Leading components have no added 4-point boundary inset. Keep internal item
  gaps and item padding separate from component spacing.
- Preserve the system Control Strip. The persistent modal host replaces its
  leftmost close/escape slot with the first real component, avoiding an empty
  leading gap; normal window previews need no empty escape replacement.
- Keep the modal host alive between enhanced apps. Restore native bars for
  excluded/unselected apps. The native-to-modal slide-in is a known unresolved
  system transition; do not claim it fixed based on a selector existing or a
  single still screenshot. Do not change system-wide animation preferences.

## Adapter behavior, settings and permissions

- Prefer supported app APIs, then explicit menu actions through Accessibility,
  then documented/user-configured shortcuts. Check foreground app/PID again
  before sending input. Never execute actions in a different app during preview.
- ChatGPT exposes no integrated full pinned-chat list here. Users define titles,
  symbols/images, colors and Control+1–9 slots; do not imply automatic chat sync.
  Sidebar/Terminal actions match explicit menu titles and use AXPress when
  available. Keep permission and unavailable-command feedback accurate.
- Quick Phrases pastes into the existing first responder via clipboard and
  Command+V. Do not send Return, activate a different app, or require every web
  editor to expose AXFocusedUIElement/AXEditable. Check foreground PID before
  changing the clipboard. The pasted phrase remains on the clipboard.
- Keyboard Shortcuts records locally while its recorder has focus. Escape cancels;
  unmodified Delete clears the binding. Send paired key-down/key-up events to the
  current target PID, rechecking foreground identity immediately before posting.
  Do not activate the target or modify the clipboard. Description is tooltip
  metadata. A missing binding must produce accurate feedback.
- Valid settings edits save and update all active instances immediately without
  rebuilding the field editor on every keystroke. Keep standard Edit menu actions
  so selection, copy, paste, undo and text navigation continue to work.
- Settings is resizable, with a minimum content size appropriate to each pane.
  Keep the window's top edge when switching panes and remember its resized size
  per pane for the current session. App details scroll vertically and component
  tables scroll horizontally when column minimums no longer fit.
- Edit simple per-item properties (title, shortcut and display override) directly
  in native table columns. Keep image/symbol, background, description and multiline
  phrase content in the selected-row inspector instead of repeating table fields.
  Resolve inline edits by stable item ID, not a captured row number. Do not reload
  the active title cell on each keystroke: that detaches its field editor and
  breaks selection/paste. Inline edits and inspector edits must preserve each
  other's latest values and retain display overrides and recorded shortcuts.
- Do not add Save buttons to live editors. Show inline validation only when
  needed, collapse empty feedback, and align category forms to the same label
  and control columns. Move secondary usage instructions to tooltips.
- Chat/phrase/keyboard editor lists support native row drag reordering within each list.
  Resolve the dragged entry by stable ID; preserve its content and shortcut slot,
  keep it selected after moving, save immediately, and refresh active bar data.
- Selection Mode's Apps list mirrors Applications, including unchecked entries.
  Exclusion/Selection affects Auto; explicit Enabled/Native overrides remain
  authoritative. Removing a rule restores policy-based Auto behavior.
- Unselected Auto apps cause the modal bar to be dismissed. The system/app owns
  the native bar thereafter; the agent observes app activation to re-evaluate
  policy, and does not select or continuously control that app's native bar.

## Verification and previous pitfalls

- Run `bash scripts/check-settings.sh` and a release build for relevant changes.
  For layout/customization changes, also run native customization regression
  checks. Cover actual AppKit insertion/drop handling in both orders, not only
  setting `defaultItemIdentifiers` to an already-combined list.
- Keyboard component checks: `bash scripts/check-keyboard-buttons.sh` covers
  recording, per-app persistence, per-button/default colors, live edits, both
  modes and alignments. `bash scripts/check-keyboard-bar.sh` temporarily uses the
  same signed app for a nonactivating hardware layout fixture and captures from
  the external harness; it restores production silently. It does not prove
  physical touches or send configured shortcuts into the user's foreground app.
- `bash scripts/check-component-display.sh` verifies legacy defaults, per-app and
  per-component/item display preferences, forced override precedence and reset,
  live updates in separate bar contexts,
  content preservation, reused views, icon centering, scrolling and fill geometry.
- `bash scripts/check-per-app-phrases.sh` covers migration, legacy backup,
  independent app editing/add/delete/live views, intentional emptiness and new apps.
- `bash scripts/check-component-layouts.sh` covers all list categories, legacy
  layout fallback, native options, Scrolling/Fill, three alignments, equal fill
  cells and 8-point gaps. `bash scripts/check-text-component.sh` checks true native
  defaults, attributed typography, every property's reset, separate app lists,
  live independent views, inline editing and zero button inset. Use
  `bash scripts/check-component-bar.sh` for external hardware captures of text
  and mixed adaptive regions. Extend actual native drop tests for new components,
  including long styled text, instead of checking only the customization palette.
- Assert both regions survive insertion/removal/reordering and saved-layout
  reload; verify equal actual widths and 12-point external gaps. Cover component
  interactions and repeated taps as well as screenshots. Test long/non-Latin
  titles and small viewports when changing text measurement.
- Use isolated preference suites and `persistsLayout: false` / unique test
  customization identifiers. Setting customizationIdentifier to nil **after**
  initialization does not undo a previously loaded user layout. Never reset the
  user's saved layouts or replace their chats/phrases to obtain a clean test.
- Prefer offscreen native controllers and nonactivating fixtures. Do not open
  Settings, a test editor or the customization overlay without a task-specific
  reason. Restore the same signed app silently after any fixture replacement.
- Capture the Touch Bar externally with `scripts/capture-touchbar.sh` or shell
  `screencapture -b -x`. Never request screen capture from the product or a test
  binary installed inside its bundle; that triggers unwanted recording consent.
- Validate the actual system-rendered bar, Control Strip, unclipped rounded
  edges, dimensions and actions. All-black screenshots or “API call succeeded”
  are not evidence of working hardware. Screenshots cannot prove physical touch.
- `scripts/run-app-check.sh` requires an explicit passing marker because Launch
  Services may return success for a crashed/asserting test. Do not run older
  interactive fixtures blindly; check for activation, popup and in-app capture
  behavior first. Never reset TCC or disable SIP for testing.
