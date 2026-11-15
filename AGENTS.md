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
| Adaptive component | Chat Shortcuts, Quick Phrases, Keyboard Shortcuts, Menu Commands | Peer components, independently addable; share the same item renderer |
| Plain text | Text | Per-app text entries; adaptive region, optional background with 4-point content inset |
| Lyrics | Lyrics | Centered current line from system Now Playing and cached online LRC; shares text rendering and adaptive sizing |
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
- Menu Commands is an independent per-app component (`menu`), also available in
  Enhanced Bar. Reuse `KeyboardButton`, `KeyboardButtonsConfiguration`,
  `KeyboardButtonsComponent` and `ShortcutCategoryEditor.Kind.menu`; only the
  backend and command-specific inputs differ. Persist its list in `menuButtons`,
  never mix it with keyboard buttons or automatically insert it into saved bars.
  Optional `menuCommand` keeps old keyboard records compatible. Button title and
  exact localized command title are independent. Optional parent path uses →;
  an alternate exact title supports mutually exclusive Show/Hide commands.
  `MenuCommands.swift` reads only menu accessibility trees on explicit selection
  or tap, with depth/node/IPC/time bounds; no polling, app activation, key events
  or clipboard writes. Match exact titles and full paths, reject ambiguous,
  disabled, incomplete or unavailable results and recheck the same foreground
  bundle ID/PID immediately before AXPress. Never retry a possibly executed press.
  Choose Menu Command reads a running app without executing actions; Enhanced
  Bar first lets the user choose an app to read, while execution still targets
  the foreground app. Errors use existing nonactivating action feedback.
  Menu buttons inherit ordinary plain-label typography, display overrides,
  per-entry colors, Fill widths, 8-point item and 12-point component gaps.
  `check-menu-commands.sh` uses injected menu/action effects; signed hardware
  checks read real menus but never execute user commands. Include both native
  insertion orders and stable-ID row reordering in the existing regression checks.
- All list components (Chat Shortcuts, Quick Phrases, Keyboard Shortcuts, Text and Lyrics)
  use `ComponentPresentation` and `ShortcutScroller`. Scrolling mode supports
  left/center/right alignment of the whole list; overflow scrolls naturally. Fill
  mode uses per-item Relative / Fixed / Hug width policies, with 8-point gaps,
  no outer inset, and truncated labels when needed. Missing policies default to
  Relative 12, preserving equal widths. Invalidate the scrubber layout
  when the viewport width or mode changes. Keep its manually positioned content
  out of canonical Auto Layout minimum-width measurement.
- `SettingsStore.componentPresentations` stores layout/alignment per app and
  component, separately from content and icon/text mode. Missing preferences use
  Scrolling/Left (Lyrics defaults to Center), except legacy Keyboard Shortcuts configurations retain their
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
  action data. Fill allocation follows each item's width policy; Hug and scrolling
  buttons use the new fitting width. Restore text when recycling a view back to Icon + Text.
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
- `ComponentItemWidth` is the shared per-entry Fill width policy for chats,
  phrases, keyboard buttons and Text. Relative values are proportional weights,
  default 12: 6/6/12 is 1:1:2, with no twelve-column limit. Fixed is in points;
  Hug uses the same content/display-aware natural measurement as Scrolling.
  Reserve Fixed/Hug widths and unchanged 8-point gaps, then split the remaining
  width among Relative entries. If no Relative entries exist, leave trailing
  space. If widths overflow, preserve Fixed/Hug and allow native scrolling;
  Relative entries retain a 1-point minimum. Component boundaries stay 12 points.
  Width controls appear only in Fill; Scrolling ignores but retains saved values.
  Persist optional `fillWidth` with the stable item ID, preserving it during all
  other edits and row reordering. Reject nonfinite/nonpositive values and values
  above 1,000,000 without saving. Cache allocation per viewport and invalidate on
  content, display mode, layout, or native measurement-context changes. Do not
  expose these policies on fixed controls without a Fill layout.

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
  entries apply. Use natural text widths for Scrolling and shared width policies
  for Fill; Text Hug must measure in its actual presentation context.
- Text also has a separate, per-app **component** Width setting: Auto preserves
  equal peer allocation; Fixed reserves points for the entire Text region; Hug
  fits the total natural text width, including 8-point entry gaps and any optional
  4-point background insets. This setting is available in both layouts and is
  independent of per-entry Fill policies. Store it in `ComponentPresentation.textWidth`;
  layout/alignment edits must preserve it. Compact Text can shrink below the
  normal 32-point viewport to a 1-point minimum. Its region and wrapper need high
  horizontal hugging (but low compression resistance) so AppKit does not retain
  a wide empty slot around a narrow view. Text and Lyrics set `requestedWidth`;
  button label typography, padding and natural measurement stay unchanged.
  Both canonical native customization and the modal host reserve compact Text
  first, then share remaining width among normal adaptive peers, preserving
  explicit Space and 12-point component gaps. Clamp oversized requests to the
  available area while retaining peers' minimum widths. Recompute Hug after
  text/style/background edits and native context changes; never reuse a modal
  allocation as the customizable item's intrinsic minimum.
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
- `TextStyleEditor` is the shared native style inspector for Text entries and
  Lyrics. Bind it to the latest model through read/write closures; do not copy
  typography controls into another component. Valid keystrokes save without
  reloading its field editor. Font-panel changes target only the visible current
  inspector, including while the floating font panel is key.
  `LyricsComponentConfiguration.style` is optional for legacy decoding and is
  independent per app (including Enhanced Bar). Missing style preserves centered,
  tail-truncated, white native text with no background. Each Default restores
  only its property; Lyrics alignment/overflow restore Center/Truncate Tail.
  Use the configured style on every lyric/status render, retain Fill/region width
  settings during edits, and let shared Text measurement recompute Hug. Styling
  must never restart media observation/search or persist live lyric content.
- Lyrics additionally applies EchoDiary-style Pangu spacing through native
  attributed glyph kerning: add 0.25 em at adjacent Han/kana and ASCII letter or
  digit boundaries, on top of configured tracking. Preserve every original
  character, explicit whitespace, URLs, cache data and accessibility text; do not
  insert literal spaces, load a web view or add GTK/Pango. `chineseSpacing` is
  presentation-only and enabled for Lyrics, never for ordinary Text or buttons.
  Shared native measurement and drawing must use the same attributes so Hug,
  Fill and truncation include those gaps. Cover overlapping mixed boundaries,
  supplementary Han, emoji, URLs, user tracking and reused views.
- Text alignment is within an entry's cell; component alignment positions the
  whole list in Scrolling mode. Keep these separate. The 30-point hardware height
  remains fixed; oversized typography can be clipped. Reject nonfinite/out-of-range
  numeric edits without saving, and do not steal focus from the field editor.
- Basic text styling stays compact; advanced typography is independently
  collapsible. Text content is edited in the native list and supports stable-ID
  reordering. Empty lists remain empty after relaunch.
- Lyrics reuses `TextComponent` and the same shared presentation controls: default
  Scrolling/Center, clear background and white native text. Region Auto/Fixed/Hug
  works in both layouts; line Relative/Fixed/Hug works only in Fill. Keep its
  stable `lyrics` identifier and independent per-app preferences. Do not insert
  Lyrics into existing app layouts automatically. `LyricsBackend.swift` owns
  independent NetEase, QQ Music and LRCLIB searches, LRC parsing, matching, cache
  and current-line timing. No LyricsX UI or LyricsKit dependency is imported.
  Search uses song/artist, checks available duration/album and rejects mismatches;
  no account, cookie or API key. Ephemeral HTTPS requests send song metadata only
  while Lyrics is in the actually presented app/shared bar or active Settings
  preview. Hide/removal, sleep and quit cancel requests, observers and deadlines.
  Never search merely for a customization palette or offscreen view.
  Cache matching timed results for 30 days and confirmed misses for one hour in
  the app's Caches/Lyrics-v1 folder, at most 200 entries. Outages are not misses.
  Bound/validate cache content and preserve unrelated files during pruning.
  `LyricsSettings.swift` owns Settings → Lyrics. Source rows support native
  stable-identity drag reordering; priority and the default-on fuzzy preference
  persist in `SettingsStore.lyricsSearch` and reload visible lyrics immediately.
  Try normalized exact title AND artist matches across the ordered sources before a fuzzy pass.
  Fuzzy matching permits artist aliases, title annotations and small title edits,
  while retaining available duration and live/remix/instrumental version checks.
  Retry title-only queries to avoid provider-specific artist aliases. Rank fuzzy
  candidates across sources by known compatible duration first, then smallest
  duration difference, metadata score and stable source order. An absent artist
  is allowed when title and duration agree; a duration alone never establishes
  a match. Without duration, retain title/artist checks. Version mismatches still
  fail, even with identical duration. Version automatic matching caches when the
  algorithm changes, without expiring or deleting manual selections.
  Changes invalidate automatic cache by configuration, never manual choices.
  Explicit search allows an edited title and optional artist, returns candidates
  with provider identity, and loads a timed preview only after selection. Use
  Lyrics saves the chosen timeline for the target song captured when Search was
  pressed; subsequent player changes must not move this target. Show that target
  next to the apply action. Store manual choices in Lyrics-v1/Selections, outside
  automatic expiry/pruning; Restore Automatic removes only the target selection
  and automatic entry. Never let an older automatic request overwrite a manual
  choice. Typing and source reordering do not themselves run manual searches.
  Observe metadata only while the Lyrics pane is visible, without polling or
  changing playback. Cancel search/preview work on replacement and pane close;
  ignore late callbacks, retain the native field editor and preview selection.
  Opening the pane automatically fills the current title/artist; unedited inputs
  follow metadata updates, while edits (including cleared fields) survive further
  notifications. Reopening fills the then-current song. Do not add a redundant
  Use Current Song button. Search recommends and previews a safe exact/duration
  match, but only explicit Use Lyrics writes a manual selection. Restore Automatic
  appears only for a saved selection. Preserve the captured apply target while
  songs change, with no automatic search on typing or autofill.
  MediaRemote reads normalized metadata/elapsed/timestamp/rate from the bridge
  on start and metadata/seek/playing/source notifications, never via polling.
  Locally extrapolate playback time and schedule one one-shot deadline for the
  next lyric line. Pause cancels it; seek/resume re-anchor. Retain a known song's
  missing optional metadata/position in incomplete snapshots, but never carry
  an anchor across different tracks/sources. Explicit playing/pause event values
  override a stale read for that event. Reject cancelled/late reads and searches.
  Keep local line changes out of UserDefaults and bar reconstruction. Instrumental,
  unavailable lyrics/position, search and idle states use honest English labels.
- Lyrics has its own full-region `LyricsInteractionView` above the shared text
  scroller; it must not add an intrinsic minimum or change Text/button rendering.
  Direct touches are claimed on contact: release with at most 8 points of jitter
  opens Settings → Lyrics; a horizontal displacement of at least 20 points seeks
  once (+5 seconds right, −5 left). Swipes never open search, including a swipe
  that returns to its origin. Cancel multi-touch, vertical exits, detach/hide and
  track-detail changes; ordinary line updates retain the gesture. Keep local
  mouse fallback and accessibility press, with no global input monitor/timer.
  Search navigation shows Settings only after an explicit user tap. Seeking uses
  a fresh bounded Now Playing read and availability-guarded MediaRemote elapsed
  time dispatch, clamps to zero/known duration, and rejects stale/changed media.
  It never sends previous/next-track commands, resumes playback, or polls. The
  active player decides whether a dispatched seek is supported. Gesture/backend
  fixtures inject actions; never alter the user's media to test these features.

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
  tail with an ellipsis when space is insufficient. Only Text and the Lyrics
  text renderer use attributed strings. Explicitly reset font/color/alignment and disable wrapping when
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
- Control Strip's Show Enhanced Touch Bar action toggles a shared, independently
  customizable bar in the same persistent modal host, retaining the system Strip.
  `LayoutApp.enhancedBar` is a configuration namespace, never a real app or input
  target. Its layout identifier is independent of app layouts; its initial layout
  contains Lyrics. Settings → Enhanced Bar reuses the app component editors and
  native customization. Each presentation owns its own views. Shared phrases and
  keys resolve the actual foreground target at tap time, with the same PID and
  Accessibility checks as app components. The explicit bar stays open across app
  activation and temporarily overrides Auto/Native/Pause without changing their
  preferences. Repeating any assigned Show Enhanced Touch Bar interaction closes
  it and reapplies the current app policy; Hide, sleep and quit also dismiss it.
  Settings previews retain priority while their window is active. This manual
  visibility is session state and must not be restored on launch.
- `ControlStripButton` is a separate, retained system-tray item with its own
  stable identifier, independent of AppBar/preview layouts. Its action toggles
  global pause by default and respects app policy on resume. The Control Strip
  settings tab controls visibility, symbol and tap action;
  startup remains silent. Private registration/presence functions are isolated
  and availability-guarded in TouchBarBridge; unregister on disable and clean exit.
  Do not rewrite system Control Strip preferences or remove Apple's buttons
  merely to register ours. System positioning must be verified on hardware;
  successful registration and programmatic `performClick` do not prove visibility
  or physical touches. Keep ordinary settings/silent-launch fixtures from
  registering the production identifier; run the signed hardware fixture alone.
  Set its `visibilityPriority` to AppKit's highest named priority (`.high`) before
  registration, retaining it across hide/show. On this macOS this also changes
  the item's underlying priority from 0 to 1000. This is a priority request, not
  proof that macOS will never displace a third-party tray item. The user confirmed
  that playback controls can still displace it. Private `priority` aliases the
  same property; it is not a second system-tray priority override. Do not fight
  system controls by polling/re-registering or changing system Strip preferences.
  LyricsX comparison (2026-11-15): its pinned TouchBarHelper revision
  `003d41193ac1c6ab9cc570a1923587298014bf1d` uses the same addSystemTrayItem /
  DFRElementSetControlStripPresenceForIdentifier registration, with no extra
  priority API. It associates modal presentation with its tray identifier and
  removes/restores its entry when LyricsX becomes/resigns active. On this Mac,
  the no-placement presentation overload forwards to placement 0. Signed A/B
  captures show that supplying an identifier alone does not prevent a later
  fixture tray entry from replacing the visible entry. This comparison used
  two fixture entries in one process, not simulated Apple media ownership.
  The user reported recovery after diagnostic relaunches, and a real capture
  showed our button during playback; no production anti-displacement change
  was made in this investigation. Do not claim a durable fix from that recovery.
  Check the active automation's showsButton before diagnosing displacement:
  a hidden Default with a shown Playing rule intentionally hides on pause.
- `ControlStripSettings.swift` owns the persisted configuration, live native
  editor and action runner. Older preferences default to the original pause
  action/symbol. Invalid symbol edits must retain the last valid persisted icon.
  Keep the tray button borderless (no app-style rounded bezel) and let macOS
  allocate the slot. Fill its square background using the shared standard
  #363636 and pressed #808080 colors, rather than the system tray's underlying
  background or a translucent overlay. Its native borderless cell otherwise dims the symbol in a
  background app and introduces vertical alignment overhang; keep zero alignment
  insets, native tracking, and full-opacity white symbol drawing. Actual fixture
  frames on this machine measured 55.5 × 30 points, with no vertical overhang;
  do not turn that observed width into a fixed constraint. Paste Clipboard sends Command+V without rewriting any
  pasteboard type; specified text and recorded keys reuse the shared foreground
  and Accessibility checks. Background Shortcuts uses literal Process arguments,
  optional private temporary text input and bounded stderr; do not interpolate
  names/text into a shell command or run an action merely by editing settings.
  Errors must not activate Settings or open alerts. Use the existing menu tooltip
  and pane feedback. `check-control-strip-settings.sh` checks dispatch with mock
  event/URL effects and a private pasteboard; never run the user's shortcuts or
  paste into their app during a fixture.
- Control Strip actions Previous Media / Next Media send the system Now Playing
  transport commands through availability-guarded MediaRemote functions in
  TouchBarBridge. Inject transport into the action runner; settings tests use a
  mock and hardware checks only inspect symbol availability. Never skip the
  user's media during automated verification. These actions need no foreground
  app, keyboard input, clipboard edits or media polling. Report command rejection
  without claiming an accepted command proves the player changed track; the
  active player decides previous/next behavior and availability.
- Control Strip automations persist as an ordered list separate from Default.
  Each profile independently configures Tap, Long Press, Option/Command/Control
  + Tap. Preserve legacy tap fields; store alternate `ControlStripActionBinding`
  values in `interactionActions`, defaulting to No Action. The same native action
  editor switches interaction without executing actions or recreating field editors.
  A binding's validation must not block a different interaction. Keep the symbol
  and visibility shared by the profile. Physical Touch Bar input uses a retained
  `ControlStripTouchRecognizer` accepting `.direct` touches; NSButtonCell mouse
  tracking alone does not cover this path. Claim the direct-touch stream on
  contact to prevent the native click recognizer from executing another action
  on release. Keep mouse tracking as a separate fallback. Both paths share one
  per-profile hold deadline in event-tracking/common modes, default 0.6 seconds;
  `longPressDuration` persists with each configuration, including Default. Missing
  or out-of-range saved durations use 0.6; the Long Press editor exposes Hold for
  (0.1–10 seconds) and Default, saves valid edits live, and retains the field
  editor. Changing duration cancels a pending press. Use no repeating gesture
  timer or global input monitor. Track the finger by NSTouch identity and
  snapshot modifiers on press-down. A plain long hold
  fires exactly once and suppresses release tap; modified holds remain modifier
  taps, and Shift/multiple-modifier combinations do nothing. Cancel pending
  gestures on drag outside, hiding, detachment or configuration changes. Guard
  stale deliveries after unregister. Test native mouse tracking with local queued
  events and direct-touch callbacks with immutable event doubles and mock action
  sinks. Inject an empty hardware-modifier snapshot for synthetic events so the
  user's typing cannot change the fixture's intended modifiers. These checks
  and screenshots cannot prove physical finger input.
  Each stable-ID rule owns its configuration and optional Bluetooth-connected
  and media-playing requirements; selected conditions combine with AND. First
  enabled match wins, and no match restores Default. New rules are disabled.
  Native live editors must distinguish the selected profile from the active
  profile and preserve field editors; editing never executes an action.
  The Control Strip pane uses a persistent native configuration list and a
  separate scrolling detail editor (minimum 820 × 560 points). Default is fixed
  at the top as fallback, not a higher-priority rule. Show rule order, enabled
  state and condition summaries in the list. Group the editor into identity /
  enable, When all match, and Use this button. The independent top header shows
  the actual active configuration even while another rule is being edited.
  Add Rule copies Default and starts disabled. Native table drag reordering
  uses stable IDs and a private pasteboard type, rejects foreign sources and
  drops above Default, and persists priority without executing actions. Refresh
  only visible row summaries during typing; never reload the detail field editor.
  Explicitly constrain separator thickness so a separator cannot consume the
  body or header area. Verify minimum-size viewports and light/dark rendering.
  Commit the displayed configuration and tap action together on the main actor.
  Each configuration (Default and every rule) owns `showsButton`; missing legacy
  values decode to true. The per-configuration Show button control hides only
  our extra tray entry, retains its symbol/action, and collapses the action form.
  The independent header master switch controls both registration and monitoring.
  Hidden matching rules still win priority; never skip them to show a later rule.
  Keep monitoring when a profile hides the entry, so a condition change can show
  it again, including a shown rule over a hidden Default. Hidden configurations
  cannot dispatch actions or require action validation. Header status reflects
  actual runtime visibility independently of the selected editor. Verify native
  unregister/re-register and stale tap suppression without user preference writes.
  Poll Bluetooth roughly every two seconds only when enabled valid Bluetooth
  conditions need it and the master is enabled. Media must never be polled:
  read once on initialization/configuration, then observe system MediaRemote
  playing/pause and source-change notifications. Apply the notification's bool
  immediately; query once only for source/unknown events. Bluetooth timer ticks
  must not query media. Cancel pending reads when a newer event arrives, and
  reject callbacks from cancelled observation generations. Remove subscriptions
  on disable/sleep/quit or when no media conditions need them; resample on wake.
  Media-only rules have no polling timer and must not query Bluetooth.
  Read paired devices by normalized address, never display name;
  no discovery, pairing or connection requests. Bluetooth permission is optional
  and has a purpose string. Preserve a saved unavailable device in the picker.
  System Now Playing includes supported nonmusic media. Its private MediaRemote
  query is availability-guarded in TouchBarBridge and injected into the monitor;
  unknown/paused never matches Playing. Do not launch Music/Spotify or change
  playback to discover state. Bound pending requests, time out to unknown, and
  discard stale callbacks after configuration changes/stop. Condition changes
  must not save preferences, rebuild bars or open Settings.
  `check-control-strip-settings.sh` tests simulated startup, disconnect, pause,
  AND, priority, inactive readers, unknown/stale state, per-rule live editing,
  reordering and persistence. `check-control-strip-media.sh` reads the actual
  system state without changing playback. Simulated transitions do not prove
  real AirPods events or physical touches. `check-control-strip-automation-bar.sh`
  uses the same signed bundle for a nonactivating real tray fixture with mock
  conditions and mock actions, then restores production silently. It checks
  frame stability and tap/configuration agreement. Inspect external captures
  separately: all-black frames do not verify the visible icon transitions.
- On this Mac running macOS 14.8.9, external captures confirm the tray item
  appears immediately after the expand chevron, before Apple's compact controls.
  A reversible experiment replacing only Play/Pause in `MiniCustomized` with our
  identifier removed Play/Pause but did not move our tray item to that slot.
  The original array was restored. Do not describe tray registration or editing
  that array as a working rightmost-button replacement. Restarting ControlStrip
  during diagnostics also required relaunching the app to register the item again.

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
  Enforce that minimum with required content-view width/height constraints;
  AppKit ignores `contentMinSize` for Auto Layout windows. Replace the outgoing
  minimum constraints before resizing to a smaller pane. Regression checks must
  verify the settled native fitting size and actual bounds, including undersized
  frame requests and last-pane restoration, not only the `contentMinSize` value.
  Keep the window's top edge when switching panes and remember its resized size
  per pane for the current session. App details scroll vertically and component
  tables scroll horizontally when column minimums no longer fit.
  Remember the last selected pane without triggering bar/configuration updates.
  Control Strip offers a contextual Customize Enhanced Bar… link only for the
  corresponding action; it navigates within the existing settings window.
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

- `check-lyrics-backend.sh` uses isolated cache and injected network/player/time
  to cover LRC variants, matching, invalid cache, outages, pause/seek/rate,
  incomplete snapshots and stale requests. `--live` searches known public tracks.
  `check-lyrics-media.sh --live` reads the actual system player and resolves its
  current line without activating an app or changing playback. Notification
  cancellation is tested alongside the existing Control Strip observer.
  `check-lyrics-bar.sh` uses the same signed bundle, isolated layouts/preferences
  and synthetic lyrics for external captures/live sizing checks; it restores
  production silently. Real provider/metadata tests and synthetic geometry checks
  are separate evidence; neither simulates a physical touch.
  `check-lyrics-settings.sh` covers actual native source drop callbacks, immediate
  preference reload, manual query/preview/application, fixed target during song
  changes, cancelled/out-of-order work and an automatic/manual selection race.
  It renders offscreen light/dark panes and never opens a window or changes media.
  `check-lyrics-typography.sh` covers legacy style decoding, shared editor live
  validation and field retention, individual defaults, per-app persistence,
  style retention across lines and independent presentations, and Hug/inset
  updates. `check-text-component.sh` protects the existing Text inspector after
  shared-editor changes. Native drop fixtures include long, styled lyric lines.
  `check-lyrics-interactions.sh` exercises real direct-touch recognizer callbacks,
  swipe/tap exclusion, cancellation, mouse fallback, full-region hit area and
  offscreen Lyrics pane routing. Backend seek cases cover fresh position, bounds,
  pending swipe accumulation, unavailable transport, timeout and stale media.
  Position reads can repeat the pre-seek snapshot. After accepted dispatch,
  retain a local target for at most three seconds so repeated/opposite swipes
  accumulate against it. Use it only for the exact unchanged elapsed/timestamp
  snapshot of the same source/song. New position anchors win immediately; pause
  freezes the target. Reconcile once after the final swipe, never poll. Cancel on
  disable or track/source change. Dispatch acceptance is not player acknowledgement.
  Hardware logs also show same-song/source snapshots with unavailable elapsed
  position after the first seek, even while every later touch is recognized.
  Display and seek must share `resolvingPlayback`: fill missing/negative/nonfinite
  positions from the same media's known extrapolated timeline and retain its
  missing album/duration. Partial reads do not cancel pending reconciliation;
  complete changed positions remain authoritative. Never invent a position when
  none is known, or borrow one across song/player changes. Keep this distinct
  from the three-second workaround for a valid but unchanged old snapshot.
  Bridge seeking sends the absolute-position command and propagates its Boolean
  result; the void elapsed-time wrapper loses this result. Relative skip commands
  are disabled by Music on this machine. Tests cover delayed/unchanged metadata,
  rejection, external seeks, playing/paused bursts and bounded reconciliation.
  Missing-position regression cases cover repeated seeks after nil/negative/NaN
  snapshots, retained duration bounds, rejected dispatches and source/song isolation.
  These mock effects do not prove physical finger input or player seek support.
- Run `bash scripts/check-settings.sh` and a release build for relevant changes.
  For layout/customization changes, also run native customization regression
  checks. Cover actual AppKit insertion/drop handling in both orders, not only
  setting `defaultItemIdentifiers` to an already-combined list.
- `check-enhanced-bar-settings.sh` covers action bindings for every interaction,
  contextual navigation, remembered pane, Lyrics defaults, live layouts/widths
  and independent persistence with offscreen native editors. The signed
  `check-enhanced-bar-runtime.sh` uses isolated preferences and nonpersistent
  layouts to check real tray dispatch, shared/native/app restoration, policy
  re-evaluation, Pause/Hide/sleep, centered Lyrics and compact/equal peer geometry.
  It never types, pastes, activates another app or changes media. External captures
  verify appearance separately; programmatic taps do not prove physical touches.
- `bash scripts/check-component-widths.sh` covers all four list categories,
  legacy Relative defaults, ratios, mixed Fixed/Hug/Relative, Fill-only controls,
  live edits, validation, resize, overflow, unchanged gaps and per-app persistence.
  `bash scripts/check-component-widths-bar.sh` verifies actual hardware frames
  and externally captures mixed widths, peer regions and Scrolling behavior.
  Native customization fixtures include oversized Fixed and Hug content; row
  reorder fixtures verify that width policies follow their stable items.
  Text region tests also cover sub-32-point widths, Auto reset, layout changes,
  per-app persistence, both native insertion orders and unchanged button labels.
  `bash scripts/check-text-region-width-bar.sh` captures actual compact regions,
  live Hug resizing, overflow clamping and the system Control Strip externally.
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
