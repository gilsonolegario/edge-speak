# EdgeSpeak — interface contract

State: 2026-10-15. A PDF/text reader with aloud reading in
**streaming**: each synthesized slice plays as soon as it is ready.
Two engines: edge-tts online (Microsoft neural voices, returns
per-word timings) and Piper offline (one WAV per sentence, no word
timings). No automated test suite: it was removed by owner decision on
2026-10-15 (backup kept outside the repo). Verification is `swift build`
plus the live app — the green/red state of behavior is asserted by live
runs, recorded in BACKLOG.md, not here.

UI: **toolbar at the top** (Open, Voice,
Options) + content + **floating control bar at the bottom, always
visible**.

- Language: Swift / SwiftUI, platform macOS 14+. SwiftPM package
  (Swift 6 tools, language mode v5), target `EdgeSpeak`, sources in
  `Sources/EdgeSpeak/` (24 files). No `Tests/` directory exists.
- **Architecture decision:** the engines stay internal
  (`StreamingPlayer` + `EdgeTTS`/`PiperTTS`). `edge-playback`/mpv
  was discarded because it returns neither per-word timings nor
  per-sentence skip — it would lose the word-by-word highlighting,
  the on-disk cache and the offline voice.
- Process: the orchestrator defines the boundary contracts between
  files; implementation runs in subagents with disjoint scopes;
  integration is verified with `swift build` and a
  relaunch of the app.
- Research context: the survey notes, OSS map and audit findings were
  removed with `docs/` on 2026-10-15. What was incorporated into the code
  stays described in the sections below; the removed notes are not
  recoverable from this document.

---

## 1) UI map

### `EdgeSpeakApp.swift` — app, delegate, scenes

`WindowGroup("EdgeSpeak") { ContentView() }` with an `AppDelegate`
(opens PDFs and text by double-click or drag onto the app icon, posts
`.edgeSpeakOpenFile`) plus the `Settings` scene (`SettingsView()`,
⌘,). `ContentView` also accepts a command-line argument and a drop
onto the window (`.onDrop`). The `Info.plist` written by
`build-app.sh` registers the app as an alternate handler for PDF,
plain text and Markdown.

**Root decision — why the window is a `Container` of fixed type:**
applying `.toolbar` directly to content that changes shape (empty →
editor → PDF → panel) recreates the view root and the toolbar is lost
in the transition — measured: without a PDF the toolbar appeared (7
buttons in the accessibility tree), and opening a PDF made it
disappear. The `Container` (a private struct whose type never
changes) gives the window a stable identity anchor; the toolbar
survives.

### `ContentView.swift` — layout B2, no NavigationSplitView

```
Toolbar (Open | Voice picker | Options menu)
content (PDFDocumentView when a PDF is open, else the editor or the clickable text panel)
PlayerBar  ← floating, always visible
```

- Toolbar: **Open** (import panel, disabled during synthesis),
  **Voice** picker (menu style, sections: Offline / English /
  Portuguese, disabled during synthesis; a saved voice that no longer
  exists falls back to the default, or the Picker loses its
  selection and synthesis fails), **Options** menu.
- Options menu: *Follow reading* toggle (always present — the
  text-only mode also auto-scrolls and the user needs to stop it),
  font size −2/+2 (⌘−/⌘+) and default (⌘0, limits 12–42), *Generate
  new reading* (discards the transcription and replays; disabled
  without a transcription), *Sleep timer* submenu (Off/5/15/30/60 min:
  arms `sleepMinutes`/`sleepDeadline`, `@State`, never persisted; a
  cancellable `task(id:)` countdown stops playback and zeroes the menu,
  with a status confirmation), *Settings…* (`SettingsLink`). Rate, text
  mode and footnotes live in the Settings window, not in this menu.
- Keyboard, monitored with `NSEvent.keyDown` (the PDFView is AppKit
  and swallows SwiftUI shortcuts): **Enter** = play/pause always;
  **Space** = play/pause only outside the editor and the PDF, and
  **never during `isBusy`** (during synthesis Space is ignored —
  before, it cancelled and restarted the synthesis, following the
  disabled-button rule); **⌥← / ⌥→** = ±15 s. Modifiers
  `.capsLock`/`.numericPad`/`.function` are cleared before the
  comparison.
- File loading by generation (`loadGeneration`): PDF extraction runs
  on `Task.detached` (the Python process waits with `Thread.sleep`
  for up to 180 s — on the main actor the UI froze), with a
  security-scoped resource guard (`startAccessingSecurityScopedResource`)
  and disposal of a late result when another file came in front.
  Before switching, `cancelSynthesis` + `stopPlayback` —
  `stopPlayback` alone leaves the synthesis task alive and it would
  enqueue audio from the old document again.
- `.onChange(of: integralMode)` → `handleIntegralModeChange()`:
  discards the current transcription (`discardTranscription`) and, if
  a reading was in course, restarts with the new list; with no
  reading, only discards (the next play already uses the new mode).
  No loop: neither the discard nor the play changes `integralMode`.
- Panel highlight **by global sentence index** (not by text search):
  repeated sentences would otherwise highlight the wrong occurrence.
  The `AttributedString` uses **AppKit-scoped attributes on purpose**
  (`appKit.foregroundColor`/`appKit.backgroundColor`): attributes in
  SwiftUI scope have no counterpart in `NSAttributedString` — the
  panel dropped them and nothing was highlighted. Base color
  `labelColor` (light/dark).
- Word-by-word karaoke in the panel: match by text with a sequential
  cursor (the spoken text expands years and abbreviations — a direct
  index would land on the wrong word); a matched word gets bold +
  yellow background (α 0.75) + dark text — the PDF's yellow, not the
  system blue: one karaoke color across both views (an audit finding;
  dark on yellow reads well in both themes).
- Attributed-string cache by (sentence, word): the view is re-evaluated
  on every progress tick; rebuilding 45k letters from scratch each
  time saturated the main thread. Outside a reading it computes
  directly; during a reading it writes the cache asynchronously and
  returns the value.
- `currentWordRect` (PDF karaoke): only with a PDF, only with an
  online voice (`!PiperTTS.isOfflineVoice(controller.voiceInUse)`),
  valid indices and a matched box via `WordAligner` (by normalized
  text, never by index) — a word that is not found becomes an absence
  of highlight, never a wrong highlight.
- `statusBanner`: a transient strip (fades in 4 s), permanent during
  synthesis (it is live progress), with the synthesis percentage, a
  "no highlighting" badge (audio without segments) and an offline-voice
  badge.
- `clickToPlay`: the reveal token takes the PDF to the clicked
  passage at once; with no audio and no synthesis in course, it
  synthesizes **from the clicked sentence** (`Array(lista[pos...])`)
  and tries the jump (the controller keeps it pending and retries
  with each arriving slice).
- The `wordAligner` state is `@State` to survive view re-evaluation
  cycles — the yellow highlight cannot restart from zero on every
  tick.

### `PlayerBar.swift` — transport only

Knows nothing about the phrase list or the voice:

```swift
struct PlayerBar: View {
    @ObservedObject var controller: SpeechController
    let textLength: Int
    let canPlay: Bool
    let onTogglePlay: () -> Void
    let onTransport: () -> Void      // scrubber dragged or ±15 s (takes the PDF to the passage)
}
```

- Center button always `play.fill`/`pause.fill` (never `hourglass`):
  during synthesis it is disabled (a second click would cancel and
  restart) but still shows play, instead of looking stuck.
  `.disabled(!canPause && (!canPlay || controller.isBusy))`.
- Left button is **cancel synthesis** (⌘.) during `isBusy`, **stop**
  the reading when audio exists.
- Scrubber: `dragValue` suspends the pointer during the drag and is
  **returned to nil on release** (`DragGesture.onEnded`) — without
  this the local value stayed stuck, `scrubPosition` (which prefers
  the pointer over the player) froze the time, and the scrubber for
  the rest of the session.
- Volume 0…1 (applied to the current player and the following ones,
  without touching the system volume); export only with audio and no
  synthesis in flight.

### `PDFDocumentView.swift` — `NSViewRepresentable` over PDFKit

```swift
var document: PDFDocument
var page: Int? = nil          // page of the sentence; nil clears
var rects: [CGRect] = []      // line boxes of the sentence
var wordRect: CGRect? = nil   // box of the word being read; nil clears
var follow: Bool = true
var scrollHold: Bool = false  // transient brake: manual scroll holds only for the moment
var revealToken: Int = 0
var onUserScroll: (() -> Void)? = nil  // user scroll → the owner sets scrollHold
var onPageClick: ((Int, CGPoint) -> Void)?
```

- **Sentence highlight (blue)**: one `PDFAnnotation` `.highlight` per
  box (translucent accent color, α 0.28), added to the sentence's
  page — geometric, never a text search (the filtered text is never
  identical to the PDF's); drawn per page, they scroll with the PDF.
  Deduplicated by its own key (`key(page:rects:)`, page + boxes),
  **separate from the word highlight**: changing the word only moves
  the yellow annotation, and the 10 Hz ticks recreate nothing
  (recreating on every word made the whole paragraph blink). Removed
  when the sentence changes or on clear (never an orphaned
  annotation — the app never saves the document). Changing the
  document resets all coordinator state.
- **Word highlight (yellow)**: `PDFAnnotation` (`.highlight`,
  `systemYellow` α 0.55) with its own state in the `Coordinator`
  (`wordAnnotation`/`wordPage`), **reused** when page and box are
  the same (avoids blinking when only the token changed); replaced
  only when the box or the page changes; removed when the word
  changes or on clear.
- **Word scrolling**: `shouldScrollToWord` scrolls only when follow
  is on **and** the word is outside the visible area — scrolling on
  every word chokes the speech.
- **User scrolling**: the `Coordinator` observes the bounds of the
  `NSClipView` inside the `PDFView` (found in depth — PDFKit does
  not expose it in this SDK version) and notifies `onUserScroll` only
  when follow is on, outside a 0.5 s silence window after a
  programmatic `go(to:)` (`markProgrammaticScroll`), the origin
  changed (>0.5 pt) and neither the size nor the scale changed (zoom
  and resizing change size/scale, never only the origin — a pure
  `isUserScroll` decision, tested). The owner (`ContentView`) sets a
  transient brake (`scrollHold`, `@State`, not persisted) on the
  notification instead of turning the persisted master
  (`followReading`) off: manual scrolling wins only for the moment,
  and any highlight advance, click, or **Go to the passage** releases
  the brake and the view resumes following. The button appears with
  the master on + brake, during the reading.
- **Clicking the PDF (`ClickablePDFView`)**: stores the point in
  `mouseDown` and reports only on `mouseUp` with a movement < 4 pt —
  distinguishing a click from a drag/selection; the rest follows
  PDFKit. `onPageClick` returns (0-based page index, point in page
  coordinates).

### `ClickableTextView.swift` — `NSViewRepresentable` over `NSTextView`

- **Why `NSTextView` and not SwiftUI `Text`**: `Text` renders the
  `AttributedString` but returns only "the text was clicked", not
  **where**; jumping the reading to the sentence needs the character
  index under the cursor, and only TextKit provides that reliably
  (`glyphIndex(for:in:)` → `characterIndexForGlyph(at:)`, with
  window-to-container coordinate conversion, and the container has
  its own inset).
- **Why an `NSScrollView` around it**: `NSTextView` has no intrinsic
  size; giving it the height of the whole text makes the panel
  swallow the window and hide the PDF (a measured defect). With inner
  scrolling the panel has a bounded height (140…300 pt).
- `pointSize` is `CGFloat` (not `Font`): `Font` is an opaque wrapper
  and `NSTextView` needs the point value.
- **Click, not drag (`ClickReportingTextView`)**: `mouseDown` stores
  the window point and the character (window→view conversion,
  independent of scrolling); `mouseUp` reports only with a movement
  < 4 pt (`hypot`) — without the guard, dragging to select triggered
  a jump at the press point (an audit finding; the PDF already
  filtered the same threshold in `ClickablePDFView`).
- **Teleprompter**: `scrollTo` (UTF-16, as TextKit counts) scrolls to
  the sentence being read when it changes — not on every word, to
  avoid trembling; with `follow` off it never touches the user's
  scrolling.

### `SettingsView.swift` — Settings scene (⌘,)

Three tabs: **Reading** (voice, rate, follow, language), **Text**
(font size, *Full text*, *Read footnotes*) and **Advanced** (on-disk
cache size and a *Clear cache* button, via
`DiskCache.totalBytes()`/`clearAll(preserving:)` with an
`.edgeSpeakClearCache` alert; the measurement runs off the main
actor) plus a copyable diagnostic report (`Diagnostics.text()` with a
`DiagStatus` snapshot outside the `@MainActor`, versions/environment/
venv/ffmpeg/cache/language/last-status, no document data; user-initiated
copy button + selectable text). Every control writes through `@AppStorage` to the keys of
`AppSetting` — the same keys `ContentView` uses. Honest note: the
Settings scene cannot see the main window's controller, so there is
no way to disable the controls during synthesis (the cadence applies
to the next synthesis anyway).

---

## 2) Feature → code map

Symbol names here are verified against
the source tree and are the stable reference. The feature→code map
that lived in `docs/` was removed on 2026-10-15; no test names appear
below — the suite was removed the same day.

1. **Yellow per word, never jumping back** — implementation:
   `StreamingPlayer` (0.1 s timer + `updateHighlight`,
   `currentWordIndex`); mirrored in `SpeechController`
   (`highlightWordIndex`); view: `ContentView` (online karaoke,
   bold + strong background); alignment: `WordAligner`
   (Needleman–Wunsch, the current phrase never moves back).
   Formerly locked by `WordAlignerTests` (suite removed 2026-10-15).
   **Gap:** visual regression is manual.
2. **Blue per sentence** — implementation: `PDFDocumentView` (one
   `.highlight` annotation per box); text: `ContentView`
   (`highlightIndex` → range, accent color α 0.35); emitted by
   `StreamingPlayer` (`currentSegmentText`/`Index`/`Page`).
   **Gap:** no automated color test — manual only.
3. **Manual scrolling holds (transient brake) + Go to the passage** — implementation:
   `PDFDocumentView` (`onUserScroll`, `isUserScroll`, `scrollHold`);
   `ContentView` (`followReading` master persisted, `scrollHold` brake set on
   `onUserScroll`, released on highlight advance/click/`goToPassage`; the button
   appears with master on + brake, `revealToken` jumps to the passage);
    catalog: `L10n` (`ui.goToPassage`). Formerly `PDFFollowTests`
    covered the pure `isUserScroll` decision (suite removed 2026-10-15),
    not the flag.
4. **Click plays from the sentence (even with no audio)** —
   implementation: text panel `ContentView` (`onTap` charIndex →
   entry; `clickToPlay`: `revealToken` + `jumpToSegment`, or play
   from the sentence); PDF: `ContentView` via
   `PhraseLocator.phraseIndex` and `clickToPlay`; locator:
   `PhraseLocator`; pending jump: `SpeechController`
   (`pendingJumpIndex`, `jumpToSegment`, `retryPendingJump`);
   player: `StreamingPlayer` (`seek(toSegment:)`, `jumpToSegment`).
    Formerly `PdfClickLocatorTests` + `StreamingProofTests`
    (suites removed 2026-10-15).
5. **Direct jump to the slice** — implementation:
   `StreamingPlayer` (`seek(toSegment:)`: the chunk containing the
   sentence + local `seg.start`; global `seek` for the bar; shared
   `gotoChunk`); controller: `SpeechController` (`seek(toSegmentAt:)`,
   `seek(to:)`). Formerly `StreamingProofTests`
    (suite removed 2026-10-15).
6. **Discard transcription + Generate new reading** —
   implementation: `SpeechController` (`hasTranscription`,
   `discardTranscription`: clears key/audio/segments/highlights +
   `DiskCache.remove`, `cancelSynthesis`); UI: `ContentView`
   (discard, `handleIntegralModeChange`); catalog: `L10n`
   (`status.transcriptionDiscarded`, `ui.newReading`). Formerly
    `TranscriptionResetTests` (suite removed 2026-10-15).
7. **Persisted voice, Settings, PT/EN translation** — implementation:
   keys in `AppSettings` (`voiceKey`, `rateKey`, `followKey`,
   `integralKey`, `footnoteKey`, `fontKey`); UI: `ContentView`
   (`@AppStorage` for voice/rate/language); Settings:
   `SettingsView` (offline voices, rate choices, footnotes toggle);
   catalog: `L10n` (`resolve` + fallback, pt/en tables). Formerly
    `L10nResolverTests` + `L10nCompletenessTests` (suites removed
    2026-10-15).
8. **Formulas spelled out with pauses** — implementation:
   `ReadAloudFilter` (`forSpeech`, `expandLogic`, `resolveHorseshoe`,
   `expandSetBuilder`, `expandAbbreviations`, `spellOutYears`,
   `numeroPorExtenso`, the formula-line rule). Formerly
    `ReadAloudFilterTests` (suite removed 2026-10-15). **Gap:** no
    measured formula PDF — how extraction delivers a symbol (entity,
    LaTeX, image) is unknown.
9. **Footnotes (marker + body + option)** — implementation: linking
   in `TextImport` (`resolveFootnotes`, `marcaAnterior`, use in
   `makePhrases`); announcement in `ReadAloudFilter`
   (`expandFootnoteMarkers` via `forSpeech`) with the mold in `L10n`
   (`speech.footnote`); option: `AppSettings` (`footnoteKey`,
   default true), `ContentView`, `SettingsView`. Formerly
    `FootnoteTests` (suite removed 2026-10-15).
10. **Online/offline engines, cache, venv** — online: `EdgeTTS`
    (`buildChunks` — first slice short, cut retreats to paragraph
    end; `mapSegments`; streaming in order via `OrderedPublisher`;
    `join`); offline: `PiperTTS` (own venv, `venvPython` →
    `BundledEnv`, `ensureVenv` + voice, `runStreaming` one sentence
    at a time); cache: `DiskCache` (`key`, `lookup`, `store`,
    `remove`); venv: `BundledEnv` (`readyPython`, `ensure`,
    `pickPython`); scripts: `Tools/synth_timing.py`,
    `Tools/synth_timing.py`,
    `Tools/piper_synth.py`, `Tools/pdf_extract.py`. Formerly
    `BundledEnvTests` + `EdgeTTSChunkTests` + `EngineProtectionTests`
    (suites removed 2026-10-15). **Gap:** no end-to-end verification
    of the cache join/eviction or of Piper offline.

---

## 3) Layer contracts

### `EdgeTTS.swift` — online engine in stream

`enum EdgeTTS`, stateless.

```swift
static let edgeTTSPath: String   // ~/.local/bin, /opt/homebrew/bin, /usr/local/bin; else "edge-tts"
static let ffmpegPath: String?   // concatenation; nil → append bytes

static var pythonPath: String                    // support venv (BundledEnv) when ready; else legacy probe
static func pythonForSynthesis(progress:) throws -> String  // prepares the bundled venv; legacy only in dev

static func timeout(forChars: Int) -> TimeInterval   // chars/10, clamped 60…600 (a bad network does not freeze the UI)
static let maxConcurrentChunks = 3                   // above this the service throttles the first slice
static let maxAttemptsPerChunk  = 3                  // retry per slice (a 403 does not retry: it is a block, not an instability)

static func buildChunks(_ phrases: [TextImport.Phrase], maxChars: Int, firstChars: Int = 450) -> [[TextImport.Phrase]]
static func mapSegments(_ script: [Segment], _ phrases: [TextImport.Phrase]) -> [Segment]
static func synthesizeStreaming(...) -> AsyncThrowingStream<ChunkDelivery, Error>
static func killRunningProcesses()
static func purgeStaleDirectories(keeping: URL)
```

`Segment` (a spoken sentence) and `Word` (a word) — Codable,
Sendable:

```swift
struct Segment: Codable, Sendable, Identifiable {
    struct Word: Codable, Sendable { let start: Double; let duration: Double; let text: String }
    let start: Double      // instant inside the final audio
    let duration: Double
    let text: String
    var words: [Word] = []      // empty without word timings (Piper)
    var index: Int = -1         // global index of the sentence in the active list
    var page: Int?              // page of origin (nil without a PDF)
    var rects: [CGRect] = []    // line boxes of the sentence of origin
    var id: Int { index >= 0 ? index : Int(start * 1000) }
}
enum ChunkDelivery: Sendable { case chunk(index: Int, url: URL, segments: [Segment]); case final(Result) }
```

Verified rules and decisions:

- **Why `AsyncStream` and not a fixed-window `TaskGroup`:** with the
  group, the consumer is resumed only when a task returns — measured:
  slice 0 ready at 38 s was delivered only at 100 s. The stream
  delivers at the instant. The slices are synthesized in parallel (3
  in flight, the pipe full from t=0 — before, the queue emptied at
  ~30 s) but **delivered in order** by `OrderedPublisher` (a class
  with an `NSLock`: the emitter runs inside the consumer's group and
  the index needs an atomic read; internal so the headless harness
  covers the order).
- **Why the first slice is short (~450 chars):** audio enters in
  about 1 s; the rest follows in index order.
- The slice text is built with `ReadAloudFilter.forSpeech` per
  phrase joined by `" "` — and **`"\n"` at the paragraph boundary**
  (`phrase.paragraphEnd`): the breath of the pause between
  paragraphs. **Never duplicate terminal punctuation** ("Frase.."):
  the script's `_split_sentences` (in the mode without
  `--lines-file`) derives sentences from the input text and would
  match the leftover punctuation as an extra sentence, breaking the
  1:1 pairing with `mapSegments`. `"\n"` does not match the
  terminator regex.
- **1:1 boundary with the script by construction:** besides the slice
  text (`chunk-%04d.txt`), each slice writes `chunk-%04d.lines.txt`
  with ONE spoken phrase per line (the same `forSpeech` text, in
  order) and passes `--lines-file`. The script treats each line as a
  passage — 1 segment per line, in order — without deriving
  sentences with its own regex (before, two different regexes, one in
  Swift and one in Python, could misalign the timings). The old
  regex mode remains available without `--lines-file`, for
  compatibility only.
- `mapSegments` pairs by order: the published text is the sentence's
  (active list); from the script come only the timings. Extra events
  are ignored; phrases without an event inherit the previous end —
  time is never invented, only index, page and boxes.
- **Why read the duration from the file (`AVURLAsset.load(.duration)`)
  instead of summing the phrase timings:** there is silence at the end
  of each slice, and that silence must count so the highlighting of
  the following slices is neither ahead nor behind.
- Retry with progressive wait (0.8 s × attempt); a `403` on stderr
  breaks the loop (a service block — retrying does not help).
- **Why `stderr` goes to a temp file:** a full pipe would deadlock a
  long process. The timeout terminates (SIGTERM, 2 s of grace, then
  SIGKILL).
- Concatenation: ffmpeg when available (`-f concat -c copy`), else
  byte appending. A failure at any step deletes the synthesis
  directory.
- `loadSegments` degrades silently: an unreadable timings JSON
  returns `[]` — no highlighting, but the audio stays valid.
- `purgeStaleDirectories(keeping:)` removes `EdgeSpeak-*` from the
  temp folder **except** the current reading and the one registered
  in `protectedDir` (the MP3 stays on disk because `AVAudioPlayer`
  needs it while playing; without this protection, the next synthesis
  would delete the audio in playback and `restart` would fall into
  the silent guard with `hasAudio` true).
- `killRunningProcesses` terminates the registered processes (only
  those whose first argument ends in `synth_timing.py`) and does
  `pkill -f synth_timing.py` — **never** a bare "python", so as not
  to hit other people's processes.
- Python paths: `pythonPath` prefers the support venv
  (`BundledEnv.readyPython()`); the legacy path probes pipx,
  `~/.local/share/edge-tts-venv`, homebrew and `/usr/bin/python3`,
  **accepting only what imports `edge_tts`** (probe `-c "import
  edge_tts"`), with caching. `pythonForSynthesis` prepares the
  bundled environment; if preparation fails AND the legacy one
  imports, the legacy is valid (dev); otherwise the legible
  preparation error is what the UI shows.
- `synthTimingScript`: bundle first (`Bundle.main`), else the
  repository's `Tools/` (dev).

### `PiperTTS.swift` — offline engine (one WAV per sentence)

`enum PiperTTS`, stateless. Five voices (`offlineVoices`):
faber/edresson/cadu/jeff pt-BR and lessac en-US; `isOfflineVoice(_:)`
and `label(for:)` guide the UI; `voiceFileBase(for:)` and
`voiceRemotePath(for:)` are pure (testable).

- **Own environment:** `piper-venv` and `voices/` in
  `~/Library/Application Support/EdgeSpeak/`; `ensureVenv()` creates
  the legacy venv with `/usr/bin/python3` and installs the wheel by
  URL (architecture via `utsname`: `macosx_11_0_arm64` or
  `macosx_10_9_x86_64`, release v1.8.0 of OHF-Voice/piper1-gpl).
  `venvPython` prefers the bundled support venv (`BundledEnv`) and
  falls back to the legacy one.
- **Choosing the .onnx (`pickOnnx`, pure):** existing support beats
  the bundle; without support, the bundle; with neither, the support
  (the download target). A cached voice counts only with
  `cachedVoiceValid`: sizes above the floors (`onnxMinBytes` 1 MB,
  `jsonMinBytes` 512 B — a planning hypothesis that rejects grossly
  truncated files) **and** a `.onnx.json` parseable as JSON.
- Atomic download: writes to `<destination>.part` in the same volume,
  validates (`downloadComplete`: received ≥ floor and ≥ expected when
  the server reported it; JSON validated) and only then renames — a
  partial file is never accepted.
- `lengthScale(for:)` translates the cadence (`EdgeTTS.Rate`) into
  `1/(1+percent/100)`.
- **Persistent session (`PiperSession`):** the app launches
  `piper_synth.py` as a child (the voice loads ONCE), waits for the
  line `{"ready": true}` (300 s deadline) and speaks JSON-line over
  stdin: request `{"id", "text", "wav", "length_scale"}`, response
  `{"id", "duration"}` or `{"id", "error"}` — the `id` matches the
  request (a response for another request is ignored). An error in one
  sentence does not kill the process. `stop()` sets `closed` through its
  own lock (never waits for an in-flight `synth()`) and the synth loop
  re-checks it every iteration; then closes stdin, SIGTERM,
  2 s, SIGKILL. `stopActiveSession`/`killRunningProcesses`
  (`pkill -f piper_synth.py`) end orphaned sessions.
- `runStreaming(...)`: synthesizes ONE sentence at a time, **in
  order, without parallelism** (Piper is fast; parallelism buys
  nothing). The spoken text comes from `ReadAloudFilter.forSpeech`;
  when `phrase.paragraphEnd`, it **appends `\n`** (the model's
  pause; the gap enters the measured duration of the WAV and the
  accumulated offset stays correct — **never shift offsets by hand,
  never insert silence WAVs**).
- **Duration:** `effectiveDuration(measured:declared:)` — uses the
  measured WAV (`duration(of:)` reads the RIFF header:
  `(bytes−44)/(rate×channels×bits/8)`); it falls back to the declared
  one only when the measurement is missing or zero. The declared one
  accumulates drift in the highlighting of the following sentences.
- Immediate delivery: each sentence becomes a `.chunk` with a local
  segment (`start: 0`), so the first plays without waiting for the
  rest; the global segments of the `Result` carry the accumulated
  offset.
- `concatWavs`: ffmpeg when available; else a manual join (the header
  of the first + the PCM of all, with the size fields rewritten).

### `StreamingPlayer.swift` — streaming playback

`@MainActor final class StreamingPlayer: NSObject, ObservableObject,
AVAudioPlayerDelegate`. It is the **source of truth** for playback
state (the controller mirrors it).

```swift
@Published private(set) var isPlaying / isPaused / isFinished / isStarved
@Published private(set) var elapsed: TimeInterval
@Published private(set) var knownDuration: TimeInterval
@Published private(set) var currentSegmentText: String?   // of the active segment
@Published private(set) var currentSegmentIndex: Int = -1  // global sentence index
@Published private(set) var currentSegmentPage: Int?
@Published private(set) var currentWordIndex: Int = -1     // active word (binary search by time)
@Published var volume: Float

func start(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments: [[EdgeTTS.Segment]])
func enqueue(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments: [[EdgeTTS.Segment]])
func markSynthesisComplete()
func seek(to globalTime: TimeInterval)
func seek(toSegment index: Int) -> Bool
func jumpToSegment(_ index: Int) -> Bool
func pause() / resume() / stop() / play() / restart(audioURL:segments:)
```

Rules and decisions:

- `durations` (optional) are measured **off the main actor** by
  whoever synthesizes. Without them, the player probes each slice in
  the background (`Task.detached`, `AVAudioPlayer(contentsOf:)`) and
  fills the duration on arrival, with a triple guard: session
  generation (`stop()`/`restart` invalidate), the index still valid
  with the same URL and the duration still zero, and `pendingProbes`
  preventing a duplicate probe. The duration also completes in
  `playChunk` itself (read from the playing player, no extra I/O on
  the main actor).
- `pause()` invalidates the 10 Hz highlight tick; `resume()`
  reinstalls it. **Why 10 Hz:** the shortest word lasts ~300 ms and
  each tick rebuilds the highlight — 20 Hz with long text saturated
  the main actor.
- **Why publish only when the value changes:** without the guard, the
  four published fields (`currentSegmentText`/`Index`/`Page`/
  `WordIndex`) emitted on every tick and the view rebuilt the entire
  text (45k letters) 10×/s — the main actor saturated and the
  highlight looked frozen.
- The delegate (`audioPlayerDidFinishPlaying`) acts only when the
  player that finished is the current session's (`player === current`
  and `currentGeneration == playbackGeneration`) — a late callback
  from a dead session is ignored.
- **`isStarved`:** the queue emptied before synthesis finished.
  Without the flag, slices arriving later would never play again (the
  reading "paused" by itself at the end of the first slice).
  `enqueue` and `play()` resume when there is new audio.
- **The central decision — why a jump by sentence goes DIRECTLY to
  the chunk:** in streaming, durations arrive late (background probe)
  and `knownDuration`/offsets are wrong until measured. The old path
  converted sentence → global time with zero offsets and `seek(to:)`
  clamped at the end of the measured audio or fell into the wrong
  chunk: the click read ANOTHER part. `seek(toSegment:)` finds the
  chunk containing the sentence (by `seg.index`) and uses `seg.start`
  (a LOCAL time, always correct); repositioning within the chunk goes
  through the private `gotoChunk`; the highlighting uses the same
  local times. The displayed clock (`elapsed`) stays approximate until
  the probes arrive — only it. Returns `false` when the sentence has
  no audio yet.
- `restart(audioURL:segments:)` (replay of the complete MP3 or the
  cache): the timings are ALREADY global, so the whole list counts as
  a single "chunk" with zero offset.
- `playChunk` with a corrupt chunk skips to the NEXT one (before, it
  repeated the SAME url and burned `nextIndex` — a permanent stall
  with the following slices already on disk).
- Exposed for UI/tests: `currentChunkIndex`, `chunkStarts`,
  `currentGlobalTime`, `isQueueExhausted`, `pendingCount`.

### `SpeechController.swift` — orchestrator

`@MainActor final class SpeechController: ObservableObject`.

```swift
@Published var isBusy: Bool; status: String; isPlaying: Bool; isPaused: Bool
@Published private(set) var hasAudio: Bool
@Published private(set) var completedChunks / totalChunks: Int
@Published private(set) var segments: [EdgeTTS.Segment]   // timings + indices
@Published private(set) var phrases: [TextImport.Phrase]  // active list
@Published private(set) var voiceInUse: String
@Published private(set) var highlightText: String?; highlightIndex: Int; highlightPage: Int?
@Published private(set) var highlightWordIndex: Int       // moves the karaoke
@Published var volume: Float

func play(phrases: [TextImport.Phrase], voice: String, rate: EdgeTTS.Rate = .normal, readFootnotes: Bool = true)
func pause() / resume() / stopPlayback()
func cancelSynthesis()
var hasTranscription: Bool
func discardTranscription()
func skip(_ seconds: TimeInterval)
func jumpToSegment(_ index: Int) -> Bool      // pending without audio; retried with each slice
func seek(to time: TimeInterval)
func seek(toSegmentAt index: Int)
func exportMP3()          // NSSavePanel; WAV offline, MP3 online
func setStatus(_ message: String)            // raw, no key
func setStatusKey(_ key: String, args: [Any], locale: L.Idioma?)
func refreshLocale(_ locale: L.Idioma)       // re-resolves the stored status
nonisolated static func parseProgress(_ message: String) -> (done: Int, total: Int)?
nonisolated static func failureMessage(for: Error, locale:) -> String
```

Rules and decisions:

- **Mirroring the streamer (why it exists):** `currentSegmentText`
  lives in `StreamingPlayer`, and the `objectWillChange` sink only
  republishes the controller when `isPlaying`/`isPaused`/`status`
  change — the highlight would freeze on the first sentence. Here
  each streamer field has its own `sink` → the controller's
  `@Published`. `volume` is a `didSet` → `streamer.volume`.
- `fullText` (used as the **cache key** in `DiskCache` and in the
  duration estimate) joins the phrases with `" "`, with `"\n"` after
  `phrase.paragraphEnd`. This invalidates old audio (without a pause)
  **exactly once**; the published text of each phrase does not change.
- The engine is chosen by the voice: `PiperTTS.isOfflineVoice(voice)`
  → offline. The flow is the same (slice by slice, a single audio at
  the end).
- **Cancellation by generation:** each `play` increments
  `synthGeneration`; the task checks `gen == synthGeneration` on the
  main actor before every effect (streamer, `segments`, `status`,
  `isBusy`) and the old task — even one stuck in a blocking `run` —
  exits without writing anything. `cancelSynthesis` invalidates the
  generation, signals a `CancelFlag` (an instance per generation: the
  old task keeps reading `isCancelled == true` inside the blocking
  `run`) and terminates the processes of both engines.
- **`play`, in this order:** resumes a pause with the same key
  (`status.playing`); a pause with the synthesis of the same reading
  in flight (`synthKeyInFlight`) resumes the streamer and the rest
  engages on arrival — `status.playingWhileSynthesizing` or
  `status.generatingNext` (before, it fell into the no-op and Play
  looked dead; an audit finding); a repeated play of the same reading
  in flight does not start a second synthesis; a synthesis in course
  with ANOTHER text cancels first.
- **`pendingJumpIndex` (click before audio):** `jumpToSegment`
  without audio stores the index as pending instead of ignoring it;
  each arriving slice tries the jump (`retryPendingJump`), so the
  click "plays from there" as soon as the passage exists. The pending
  jump dies with the synthesis (cancel, end or error) — without this,
  an earlier click would fire by itself in a future reading.
- **A click with no audio at all starts synthesis FROM the clicked
  sentence** (`ContentView.clickToPlay`): `Array(lista[pos...])` —
  with the whole list, the beginning of the document played before
  the chunk of the clicked passage existed.
- `discardTranscription` exists because `play` reuses audio when the
  key does not change: without clearing audio, segments, phrases, the
  current key and the `DiskCache` entry (including the in-flight
  key, when different), switching text mode and pressing play would
  resume the old reading.
- **Resolvable status:** catalog messages store `statusKey` +
  `statusArgs`; on a language change, `refreshLocale` re-resolves.
  Raw motor progress (`reportProgress`) clears the key — a motor
  message stays in the source language, and the switch would not
  overwrite it.
- Duration estimate: `chars/700` (measured: 1391 chars/s in PT, 26k
  chars; the pessimistic estimate keeps the real wait from looking
  like a freeze).
- `exportMP3`: the final file is already at hand — it only copies
  with the right extension (WAV offline, MP3 online) via `NSSavePanel`.
- **The cache is saved off the main actor** (`Task.detached(.utility)`):
  copying the final MP3/WAV inside the `MainActor.run` block froze the
  UI at the end of synthesis (an audit finding).
- `StatusRelay` (`@unchecked Sendable`, weak) carries progress from
  the background thread to the main actor without extending the
  controller's lifetime.

### Import — `TextImport.swift`, `PdfWords.swift`, `PDFTextExtractor.swift`

`TextImport.Phrase` — `Hashable, Sendable`:

```swift
struct Phrase: Hashable, Sendable {
    struct WordBox: Hashable, Sendable { let text: String; let rect: CGRect }
    let index: Int           // stable global index in the active list
    let text: String
    let page: Int?           // 0-based; nil for text without a PDF
    let rects: [CGRect]      // boxes of the sentence's LINES (not the paragraph's)
    let words: [WordBox]     // words of the whole paragraph (karaoke matches by text)
    let paragraphEnd: Bool   // true only on the last sentence of each block/paragraph
    let noteNumber: Int?     // footnote body (nil in running text)
}
```

- **The PDF pipeline:** `PDFTextExtractor.extractSegments` (XY-cut,
  the section below) → bibliography cut + `ReadAloudFilter.clean` per
  passage (`filtered(_:isPDF:)`, preserving page/boxes/words) →
  `makePhrases` (splits by block and sentence, assigns boxes) →
  `resolveFootnotes` (links bodies to markers). Full and filtered
  derive from the SAME extraction (`sentences`/`filteredSentences`).
- **`resolveFootnotes` — indices as a property:** a loose 1–2 digit
  number with a page (a label without a body, like the "1".."15" of
  the test article) is **discarded** (read, it would become "one");
  a body (1–2 starting digits + space + ≥12 characters) is moved to
  right after the marker's sentence — the marker is searched on the
  same page (in order) and, failing that, backwards through the
  document (covers endnotes); without a marker, the body stays intact
  (it could be a date or an enumeration: touching it would be
  corruption). The body loses its number and gains `noteNumber`.
  **The indices of the sentences that remain do NOT change** (they
  are property, not position) — highlighting and jumping by index
  keep working after resolution. The move runs backwards so positions
  still to be processed are not shifted.
- `makePhrases` splits each segment into sentences **by block** (a
  block is separated by a newline) and marks `paragraphEnd` on the
  last sentence of each block.
- `rects` are the sentence's **line boxes**: the sentence's tokens
  are matched in order against the paragraph's words (a monotonic
  cursor in `boxesForSentence`; a token not found is skipped without
  shifting the cursor) and the matched boxes are grouped by line
  (`groupByLine`: vertical overlap above half the smallest height;
  minX/minY/maxX/maxY per line, ordered). With no match at all, the
  sentence inherits the paragraph's boxes (`seg.rects`). A sentence
  crossing a page break is split into one passage per page (each with
  its page and boxes); without a break, a single passage. `words`
  keeps the whole paragraph's words — karaoke matches by text, not by
  index.
- `editorPhrases(_:integral:)`: typed/pasted text, the same single
  flag (full or `clean`).
- Input: `.pdf` (the PyMuPDF script, with a PDFKit reserve),
  `.md`/`.txt` (`normalizeMarkdown`: fences, links, line markup,
  inline). A PDF without a geometry layer falls back to raw text per
  page; with no text at all, an honest error ("PDF without a text
  layer").
- `splitSentences`: terminal punctuation followed by
  uppercase/digit/open-paren/quote (regex with lookbehind).
- `PdfWords.lines(pdfURL:pageCount:)` runs `pdf_extract.py` and
  returns per line `[(text, box, words: [(text, box)])]` in
  **PDFKit page coordinates** (origin at the bottom-left — the same
  coordinate system as the `rects`; the script converts
  `[x0, h-y1, x1, h-y0]`). Old JSON without `words` still decodes
  (optional field); a word with an invalid box is discarded. Deadline:
  `min(180, 15 + 3×pages)`. `pythonWithFitz` probes (with cache) the
  support venv, `EdgeTTS.pythonPath`, the Piper venv, homebrew and
  `/usr/bin/python3`, accepting only what imports `fitz`; with none,
  it returns nil and the caller uses the PDFKit path.
- `PDFTextExtractor.extractSegments` returns `[(text, page, rects,
  words)]`; the paragraph's `words` are the concatenation, in reading
  order, of the words of the lines that are on the sentence's page
  (`flush` filters by `page == currentPage`). The PDFKit path
  (reserve) has no words.

### `PDFTextExtractor.swift` — reading order (XY-cut)

- **Why it exists:** `PDFPage.string` returns text line by line in
  print order — on **two-column** pages it alternates left/right and
  scrambles the text. Here each line comes with its box and the order
  is rebuilt by **recursive cutting (XY-cut)**: it separates by the
  largest **vertical** gutter first (columns), then horizontal
  (bands), until no gutter remains. Choosing vertical first is what
  makes a two-column page read as one whole column from the left,
  then the right; a full-width title "stitches" the gutter and forces
  a horizontal cut first.
- A vertical cut requires a clean gutter (no line crosses it), a
  minimum of `max(12, leading)` and **≥3 lines on each side** — a
  weak heuristic does not cut a single-column page.
- Headers/footers: `repeatedKeys` (the same normalized text — digit
  blocks become `#` — on ≥3 lines of ≥3 pages) and `isMarginNoise`
  (bands at the top 14%/bottom 86% of the page: page number, date,
  URL, a label ≤12 characters).
- Paragraphs (`paragraphs`): median leading per page; a line continues
  while the previous one did NOT close a sentence, filled the column
  (≥82% of the column width, not the page — `colLeft`/`colRight` from
  the XY-cut), the gap is < 1.6×leading and the line is not indented
  (>0.8×leading); a title (box >1.18× the median height) closes a
  paragraph; a page break continues if the sentence did not close; at
  a column turn (a negative gap) it decides "full line + sentence
  end", which is the correct flow between columns. A line-end hyphen
  is consumed on the join.
- Input paths: **PyMuPDF first** (`PdfWords.lines`; the page count
  must match, else it falls back to PDFKit) — the text layer of some
  PDFs has no spaces between words and PyMuPDF segments into words
  with boxes; **PDFKit as the reserve** (without Python or PyMuPDF),
  ordering lines top→bottom by geometry.
- A superscript footnote index (`[⁰¹²³⁴⁵⁶⁷⁸⁹]+`) is stripped BEFORE
  everything: glued to the end of a line, it hides the punctuation and
  the footnote would be glued to the previous paragraph.

### `ReadAloudFilter.swift` — what the voice reads

The largest file (45k). Two paths that **never mix**: `clean`
(displayed/transcribed text) and `forSpeech` (motor text). The
contract is locked by a test (`falaNaoAlteraExibicao`): `forSpeech`
expands notation; `clean` never inserts a spoken word.

- `clean(_:isPDF:)`: NFKC → strip footnote superscript →
  `stripPDFArtifacts` (repeated headers/footers, pagination, split
  dates, hyphenation — **before** the reflow, because the line break
  is the evidence of hyphenation) → `reflow` (regroups broken lines)
  → `stripQuotedBlocks` (a quotation in quotes — the `.` does NOT
  cross a line break on purpose; the old version erased whole
  sections; the bibliography in the second half; loose asterisk
  notes) → apparatus rules in order (footnote calls, bracketed notes,
  "note N", pagination in parentheses BEFORE the loose one — else an
  orphan `)` remains, cross-references with a lone-word guard — "we
  will see" is not "see", section titles stay on purpose,
  `ibid.`/`et al.`, `§N`, "Page N of M", author-year citations with
  a 4-digit year, formula lines, whole formulas as
  operand-symbol-operand, `$…$`/`\(...\)`, URLs) → final cleanup
  (lines of punctuation only, double spaces, orphan punctuation).
- **Why the reflow judges by WIDTH (85% of the 75th percentile) and
  not by "starts lowercase":** in a justified sentence all lines
  arrive near the margin and only the last is short; joining by
  lowercase left every break before a proper name loose. The width
  saves page breaks (a short line in the middle of a paragraph) and
  "the previous one is full" saves the break before a proper name.
- `forSpeech(_:voice:readFootnotes:)` (what the motor receives):
  blackboard-bold **before NFKC** (`foldaveis`: NFKC fuses ℕ with N —
  the regex table would receive them dead) → `expandAbbreviations` →
  `spellOutYears` (PT only: years 1500–2100 spelled out; in English
  the motor reads them alone) → `expandLogic` → `expandFootnoteMarkers`
  (announces the glued marker, unless `readFootnotes == false`) → collapse
  of duplicate spaces/commas.
- **Verbalization decisions (survey notes removed 2026-10-15):**
  - Quantifiers with a variable and a prosodic comma ("para todo
    x,"), modals □ ◇, turnstiles ⊢ ⊨ with a short pause before and
    after, negations ⊬ ⊭, ASCII `|-` `|=` `->` `=>` `<->`.
  - Sets ∈ ∉ ⊆ ∪ ∩ ∖ ∅ ℘, set-builder `{x | φ}`/`{x : φ}`
    (`expandSetBuilder`: only enters what has a "such that" marker
    inside the braces; without it, `{…}` is grouping and becomes
    silence; the closing brace is SILENCE — an end-of-enumeration
    pause).
  - **Horseshoe ⊃ by context** (`resolveHorseshoe`, a 12-character
    window on both sides): near ∈/⊆/∪/∩/∅ it is a superset; near
    ¬/∧/∨/⊢ (and by default) it is a conditional. A heuristic by
    nature — in doubt, the historical default is "implies".
  - Greek by name (φ "fi", λ — whose dot becomes a PAUSE, never
    "dot" —, Γ…), iota ℩ ("the x such that"), blackboard-bold, Quine
    corners (silence with a mention pause), primes p′ ("p prime",
    only an isolated token — "it's" and "O'Brien" do not change),
    §2 ("section 2"), functors ("T of u, o" — only a lone CAPITAL),
    R_H ("R H").
  - **Deliberate silence** (never verbalized in ordinary prose):
    `[]`/`<>` as a modal (a bracket already becomes a pause in
    `clean`; `<>` is ASCII "not equal"), the `x` of "3 x 4" as times
    (only a proper × reads "times"), a lone bar outside a
    set-builder (between letters it reads "or", with a guard against
    "and/or"), a grouping brace, `^` between letters/digits (a
    superscript reads as a space), `~` vs `∼` (at the start or after
    `)`/`,` it is negation; between terms, similarity).
  - ⊥/⊤: "false"/"true" in PT (a Brazilian classroom); EN keeps
    bottom/top.
- `expandFootnoteMarkers`: the glued marker becomes "nota de rodapé
  N"/"footnote N" (catalog text `L`, a single source in both
  languages). **Why textual and not geometric:** `clean` already
  removes the Unicode superscript before splitting sentences, so what
  reaches `forSpeech` is the glued ASCII digit. Strong guards: only
  1–2 digits (never 4, so as not to bite the years 1500–2100 that
  `spellOutYears` handles), the following digit cannot be a
  letter/digit/dot (protects "3.14", "3,14", "4.2.1", "7z"), a
  dot/semicolon requires a letter or a closing mark before (protects
  "9 Oct", "Figure 7"); a short glued string ("mp3") is an acronym
  and stays as is. With `readFootnotes: false`, the marker becomes a comma
  (a pause), without an announcement.

### `WordAligner.swift` — word-by-word karaoke

`@MainActor final class WordAligner`. Aligns the sequence of words
**SPOKEN** with the sequence of words of the PDF and says which box
corresponds to each spoken word.

- **Why align and not search word by word:** the aloud reading NEVER
  has the same word sequence as the PDF. Where the PDF puts a symbol,
  the voice puts a phrase — "∃uT (u,o)" becomes "there exists u, such
  that, T of u" (11 words for 3 boxes). Searching word by word
  forced the expansion words to match some box, and since they are
  COMMON words ("and", "such", "there"), they stole the box of a
  prose word right after: that was the "yellow jumping side to side"
  the owner saw.
- **Why a global alignment (Needleman–Wunsch) and not a greedy
  one:** the greedy one solves the common case but breaks exactly
  where the sequence lengths differ by construction. The global one
  prefers to leave an expansion word **without a box** rather than
  distort the rest, because distorting costs more.
- Costs: matching equal = 0 **minus a context bonus** (±3 neighbors
  equal, up to 3 per side, only neighbors with a letter or a digit);
  skipping = 1; substituting (a different pair) = 3 — more expensive
  than skipping because substituting distorts the sequence. **Why ±3
  and not ±1:** the phrase is read against the words of the WHOLE
  paragraph and the next phrase can repeat the same bigram; with ±1
  the backtrace from the end preferred the late occurrence and the
  yellow went to the next phrase (a measured case in the test
  article: "the laboratory" in two phrases). The bonus only applies
  to an equal pair, so an expansion stays boxless.
- Backtrace tie-breaking: a tie goes to MATCH (keeps "the … the" at
  the right occurrence), then skip the spoken word (expansion), then
  skip the PDF box.
- `normalizada(_:)`: lowercase, letters and digits only (the same
  rule as the panel karaoke and the token matching).
- **Per-sentence cache** (`caixa(frase:alvo:faladas:pdf:)`): the
  alignment is O(n·m) and the highlight ticks at 10 Hz — it
  recomputes only when the sentence or the counts change; a repeated
  request returns the same box.
- `caixa(alinhado:alvo:pdf:)` returns the box of the target; a
  target outside the list returns nil (never an invented neighboring
  box).

### `PhraseLocator.swift` — click → sentence

Sentence navigation, implemented here from scratch. Containment
wins; otherwise the nearest rectangle up to `maxDistance = 40` pt;
phrases without `rects` are ignored; same page only; the margin
returns nil. Euclidean point→rectangle distance (0 when inside).

### `BundledEnv.swift` — embedded Python environment

`enum BundledEnv`. The app works on a virgin Mac (only macOS 14+
arm64 + network), without the system Python or the owner's venvs.

- `ensure(progress:)`: idempotent and **serialized** (`setupLock` —
  two calls together prepare once; re-checks after waiting). Steps:
  probe `importsOK` (`-c "import edge_tts, fitz, piper"`) → create a
  venv from the **embedded base** (`Resources/pythonbase` in the
  bundle; dev reserve: `Build/staging`, `Resources`) → `ensurepip`
  if the base comes without pip (completes INSIDE the venv, without
  touching the base) → `pip install --no-index --find-links <wheels>`
  (edge-tts, pymupdf, piper-tts — installation WITHOUT a network) →
  apply `patch_edge_tts.py` to site-packages → verify again. Errors
  in pt-BR for the UI (`NSError` with `NSLocalizedDescriptionKey`).
- `readyPython()`: a hot path without a probe — valid when `ensure`
  has already passed in this run (`readyCache` under `stateLock`)
  AND the binary is executable.
- `pickPython(support:supportValid:legacy:)`: pure (the probe order
  in one place, testable).
- `sitePackages(in:)`: pure on the filesystem (testable with a fake
  directory); discovers `lib/python*/site-packages`.
- `runSync`: a blocking process with a timeout (300/900/120 s per
  step), stderr to a temp file (no pipe-deadlock risk), terminated
  when the deadline passes.
- **Why `ContentView` preheats in `onAppear`**
  (`Task.detached(.background)`): when the user asks for a reading,
  `ensure` has already passed (or runs then, with progress in the
  status).

### `DiskCache.swift` — on-disk synthesis cache

`enum DiskCache`, stateless. Stores the final audio (MP3 online, WAV
offline — the extension follows the real file; `lookup` accepts
either) and the global segments, in `Caches/EdgeSpeak/<key>/`.

```swift
static func key(text: String, voice: String, rate: EdgeTTS.Rate, readFootnotes: Bool = true) -> String
static func lookup(key: String) -> Hit?          // audio + segments, or nil
static func store(key: String, audioURL: URL, segments: [EdgeTTS.Segment])
static func remove(key: String)                  // deletes the whole entry
```

- Key: SHA-256 of `"v3|<voice>|<percent>|[no-notes|]<text>"`. The
  `v3` prefix is the generation of the phrase splitter: the same
  material with a new splitter = new indices — without the generation
  in the key, an old cache would serve segments with indices from
  another numbering (before, `v2` invalidated the karaoke cache,
  whose segments have no `words`). `readFootnotes` enters the key (audio
  with and without notes is different); with the default, the raw
  material is identical to before — no old cache is invalidated.
- Automatic pruning at every `store` (at most 1×/min, in
  `Task.detached(.background)`): entries older than 30 days leave,
  and above 2 GB the oldest go first. **Never** touches the key in
  use or entries written less than 60 s ago (a margin that protects
  the current reading). It fails silently — a cache is an
  optimization and must not break a reading. A failed `store` deletes
  the folder it started writing.

### `L10n.swift` — PT/EN text catalog

`enum L`. Compiled tables (`pt`, `en`), without a new `Package.swift`
or a new dependency.

- `resolve(_:locale:args:tables:)`: a fallback chain — requested
  language → PT → the key itself (never empty). Positional
  interpolation (`{0}`, `{1}`…); a marker without an argument passes
  through; an extra argument does not break the sentence. `tables` is
  a parameter so tests cover the fallback without touching the
  catalog. Default locale is `.en`.
- **`AppSetting.languageKey` ("appLanguage") and `languageDefault`
  (`.en`) live HERE** (an extension of `AppSetting`, at the end of the
  file). It is the only preference key outside `AppSettings.swift` —
  whoever looks for all the keys in `AppSetting` must remember this one.
- Codebase translated to English (identifiers, comments, literals,
  tests, Tools); UI strings go through this catalog (PT/EN parity
  locked by `L10nCompletenessTests`); engine and user messages use keys
  (`error.*`, `warn.*`, `common.*`).
- The `SpeechController` stores `statusKey`+`statusArgs` and
  `refreshLocale` re-resolves on a language change (the language is
  `@AppStorage` read by `ContentView`, `PlayerBar`, `SettingsView`
  and by the controller itself via `UserDefaults`).
- Completeness locked by tests: the same keys in both languages, `{n}`
  markers with the same arity, no empty text, no `\(` Swift
  interpolation in the catalog.

### `AppSettings.swift` — preferences

`enum AppSetting` centralizes keys and defaults, read by `@AppStorage`
both in the Settings window and in `ContentView` — always the same key
and the same default, never a string repeated by hand (except
`languageKey`, see the L10n section).

```swift
static let voiceKey = "voice"                // default "en-US-AndrewNeural"
static let rateKey = "readingRatePercent"    // default 0 (the `percent` of EdgeTTS.Rate)
static let followKey = "followReading"       // default true
static let integralKey = "integralText"      // default false
static let footnoteKey = "readFootnotes"     // default true (notes linked)
static let fontKey = "fontSize"              // default 17; limits 12…42

static let englishVoices / portugueseVoices   // online catalog (verified 2026-10-10)
static let voiceLabels: [String: String]      // "Name (country, gender)"
func label(for voice: String) -> String  // offline via PiperTTS
func isKnown(_ voice: String) -> Bool    // does the saved voice still exist?
```

- Font limits documented: below 12 the text becomes illegible; above
  42 the minimum window no longer fits.
- Migration in `ContentView`: "pt-BR-ThalitaNeural" (only the
  multilingual one existed) is rewritten to
  "pt-BR-ThalitaMultilingualNeural"; an orphan voice falls back to
  the default — without this the Picker would have no selected item
  and the synthesis would fail.
- `ReadingPositionStore` (in this file): per-document, per-voice
  reading positions under the `readingPositions` UserDefaults key;
  positions below 3 s are not saved, and resume is only suggested
  when the saved position is within the measured duration.

### UI — `EdgeSpeakApp.swift`, `ContentView.swift`, `PlayerBar.swift`, `PDFDocumentView.swift`, `ClickableTextView.swift`, `SettingsView.swift`

See section 1) for the full UI map. The decisions that cut across
files: the fixed-type `Container` root (the toolbar survives shape
changes), generation-scoped file loading, the AppKit attribute scope
for panel colors, the sequential text cursor for panel karaoke, and
the 4 pt click-vs-drag threshold in both clickable views.

### Tools (`Tools/`) — the 1:1 boundary with the Swift side

- **`pdf_extract.py`** (PyMuPDF, AGPL) — `--pdf`/`--out`; JSON
  `pages[].lines[]` with `text`, `box` and `words[]` (one entry per
  word, reading order, coordinates **converted to PDFKit:
  `[x0, h-y1, x1, h-y0]`**). Groups by (block, line) of PyMuPDF
  itself; the final reading order is the Swift XY-cut. Boundary:
  `PdfWords.lines` decodes exactly this JSON (the `words` field is
  optional for compatibility).
- **`synth_timing.py`** — returns the audio and the per-sentence
  timings. Preferred mode `--lines-file`: the app passes one spoken
  phrase per line and each line becomes EXACTLY one segment, in order
  (`_group_words_lines`; an empty line becomes a zero-duration
  passage, never discarded — discarding it would shift the following
  ones). Words fall into the phrase by **sequential search in the
  reconstructed text** (`"\n".join(lines)`), because the word events
  carry NO punctuation (measured: `world`, not `world.`). The phrase
  duration touches the start of the next phrase (like the
  `SentenceBoundary` of the old mode) — the 0.3–0.5 s silence gap
  between phrases (measured) enters the duration, else the highlight
  blinked between phrases. Without `--lines-file`, the old regex mode
  applies (`_split_sentences`/`_group_words`), for compatibility
  only — **restriction: input without duplicated terminal
  punctuation**. A single pass with `boundary="WordBoundary"` (the
  library emits only ONE boundary type per synthesis). Timings in
  seconds (the library's unit: 100 ns). Boundary: `EdgeTTS` writes
  `chunk-%04d.txt` + `chunk-%04d.lines.txt` and reads the JSON
  `{"segments": [...]}` with `loadSegments`.
- **`piper_synth.py`** — a persistent process: loads the voice ONCE,
  announces `{"ready": true}` and serves JSON-line requests over
  stdin (`{"id", "text", "wav", "length_scale"}`), answering
  `{"id", "duration"}` (read from the header of the generated WAV,
  16-bit mono) or `{"id", "error"}` — an error in one request does
  not kill the process. Boundary: `PiperTTS.PiperSession` speaks
  exactly this protocol (matching by `id`, 300 s deadlines).
- **`patch_edge_tts.py`** — a patch applied by `BundledEnv.ensure`
  to the bundled venv's site-packages (idempotent: a second pass
  exits 0 without changing a byte; tested with a fake directory):
  1. `constants.py`: `WSS_URL` points to the v2 endpoint
     (`wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1`
     with `Ocp-Apim-Subscription-Key`) — old versions used
     `speech.platform.bing.com`, which Microsoft now refuses (403).
  2. `drm.py`: `parse_rfc2616_date` uses
     `email.utils.parsedate_to_datetime` — `strptime` with `%a`/`%b`
     only understands English and breaks with the system in pt-BR.
  Errors in pt-BR on stderr, exit 1 (failure) or 2 (usage).

---

## 4) Cross-cutting rules

- **No SSML** (no evidence of service support); the pause between
  paragraphs is made with `"\n"` in the text joined for the motor.
- On-disk cache by (full text + voice + cadence + notes); the key
  changes when the text changes (which is why the paragraph mark in
  `fullText` invalidates once). `DiskCache.remove(key:)` deletes the
  entry (used when discarding a transcription).
- The EdgeTTS ↔ `synth_timing.py` boundary is 1:1 by construction
  (`--lines-file`): one line per phrase, one segment per line, in
  order.
- Word-by-word highlighting: online voices only.
- The source of truth for playback state: `StreamingPlayer`.
- **The sentence index is property, not position** — every
  reordering (footnotes, filters) preserves `Phrase.index`.
- Cancellation/session switch by **generation**, in all layers
  (`synthGeneration`, `playbackGeneration`+`currentGeneration`,
  `CancelFlag` per instance, `loadGeneration`).
- Child processes are terminated by **script name**, never by a bare
  "python".

## 5) Invariants — what another agent must not break

1. A sentence is never cut in the middle: `buildChunks` groups whole
   sentences; the 1:1 boundary with `--lines-file` depends on it.
2. The text sent to the motor never duplicates terminal punctuation
   ("Frase..") — the `_SENT_END` of the mode without `--lines-file`
   would create an extra sentence and misalign the pairing; a
   paragraph `"\n"` does not match the regex.
3. `Phrase.index` is property: `resolveFootnotes` and the filters
   move/remove sentences WITHOUT reindexing. Highlighting, jumping and
   karaoke match by global index.
4. `StreamingPlayer` is the only source of truth for
   `isPlaying`/`isPaused`/`isFinished`/`isStarved`/elapsed; the
   controller only mirrors. Never publish playback state only in the
   controller.
5. Every session-state write checks the generation first:
   `gen == synthGeneration` (synthesis), `currentGeneration ==
   playbackGeneration` (delegate), `loadGeneration` (import). A
   generation only increases; never zero it.
6. Durations are measured off the main actor and filled with a
   generation/URL/index guard; `playChunk` completes only its own
   index. Never measure a duration on the main actor.
7. A jump by sentence goes DIRECTLY to the chunk containing it, with
   the local `seg.start` point — never convert sentence → global time
   with offsets still unmeasured.
8. Karaoke by word only with an online voice; the match is by
   normalized text (`WordAligner` in the PDF, a sequential cursor in
   the panel) — never by index between sequences of different lengths.
9. A formula expansion word stays WITHOUT a box (global alignment,
   substitution cost 3 > skip cost 1). Never force "and"/"such"/
   "there" to match a prose box.
10. Annotations in the PDF are geometric (the extractor's boxes),
    never a text search; deduplicated by their own keys (sentence:
    page+boxes; word: page+box) and removed on change/clear — never
    leave an orphaned annotation (the app does not save).
11. Manual scrolling always wins: the detector only notifies with
    follow on, outside the 0.5 s window of a `go(to:)`, with a
    changed origin and equal size/scale. Zoom and resizing never turn
    follow off.
12. The window root is the fixed-type `Container`; `.toolbar` is
    never applied directly to content that changes shape (the toolbar
    disappears — a measured defect).
13. The cache key is SHA-256 of `"v3|<voice>|<percent>|[no-notes|]
    <text>"` with `"\n"` at the paragraph boundaries of `fullText`.
    Changing the prefix or the join formula invalidates the whole cache
    at once — only done in `v2` (karaoke) and `v3` (phrase-splitter
    generation); never again without a reason.
14. `DiskCache` fails silently and never touches the current key nor
    entries younger than 60 s; pruning at most 1×/min in the
    background.
15. Piper: never shift offsets by hand nor insert silence WAVs — the
    gap of a paragraph `"\n"` enters the measured duration of the WAV.
16. `BundledEnv.ensure` is idempotent and serialized; the venv is
    born only from the embedded base, and pip installs `--no-index`
    from the bundled wheels. Never touch the system Python.
17. Synthesis processes are terminated by script name
    (`synth_timing.py`, `piper_synth.py`), never by a bare "python".
18. `forSpeech` expands for speech; `clean`/the displayed text never
    changes (the contract locked by `falaNaoAlteraExibicao`).
19. Space and ⌥-arrows are ignored during `isBusy` (the disabled-button
    rule); Enter always toggles play/pause.
20. The controller's status stores key+args to re-resolve on a
    language change; raw motor progress (`reportProgress`) clears the
    key so the switch does not overwrite it.
21. Preferences only via constants (`AppSetting` + the extension in
    `L10n`) — never repeat the `@AppStorage` key string by hand in
    two files.
22. A click in the PDF/text with no audio synthesizes FROM the clicked
    sentence (`Array(lista[pos...])`), not from the beginning; the
    pending jump is retried with each slice and dies with the
    synthesis.
23. Switching full/filtered mode (and *Generate new reading*) discards
    the transcription (`discardTranscription`) before any replay —
    without it, play reuses old audio by key.
24. The panel highlight publishes only when the value changes
    (rebuilding 45k letters 10×/s saturates the main actor), and the
    attributed string is cached by (sentence, word) during a reading.

## 6) Automated tests — removed

No test suite exists. It was removed by owner decision on 2026-10-15
(179 tests in 27 suites at removal; backup kept outside the repo) together
with the `EdgeSpeakTests` target in `Package.swift`, so `swift test`
reports no tests. Behavior once locked here — pre-buffer release, jump
without replay, highlight timer reinstall, page-own word box, panel
context rebind, whole-word citation matching — is now verified only by
`swift build` plus live runs in the app, recorded in BACKLOG.md.

---

### Scaffold

- This repo: `Package.swift`, `build-app.sh`, `README.md`,
  `CREDITS.md`, this `INTERFACE.md`, `Tools/`, `Resources/` (the
  icon).
- Sources: the files listed above. The orchestrator defines the
  boundary contracts; each subagent touches disjoint files; the
  integration is re-verified independently.
- **Never committed** (`.gitignore`): `.build/`, `Build/` (staging:
  the Python base, wheels, voices — ~490 MB), `EdgeSpeak.app/`,
  `DerivedData/`, `.swiftpm/`, `.venv/`, `venv/`, `__pycache__/`,
  `*.pyc`, `.DS_Store`, `.scratch/`, `NOTAS_SESSAO.md`,
  `PROXIMA_SESSAO.md`, `*.log`, `*.xcuserstate`, `xcuserdata/`,
  `.idea/`, `.vscode/`.

## 7) Known limits and open items

- **The first seconds without a highlight in the PDF: RESOLVED** (was: the
  slice played before the highlight settled; cause not isolated). The real
  cause was the pre-buffer release: it was checked in `enqueue` *before* the
  duration probe ran, and the probe (`finishProbe`) never released a held
  start — so the first sound waited for the NEXT slice, or for the whole
  synthesis to close in a short document. The opening ran with no audio and,
  therefore, no highlight. Fixed by `releasePrebufferIfReady()` (called by
  `enqueue`, `finishProbe`, `markSynthesisComplete`); `playChunk` now also
  positions the highlight immediately instead of waiting the first 10 Hz tick.
   Former regression: `prebufferReleasesWhenProbeLands` (suite removed
   2026-10-15).
- **Repetition of the first sentence: RESOLVED.** A jump (click or
  resume-by-document) made during the pre-buffer was undone by the release,
  which played slice 0 from zero — the sentence was heard twice. `gotoChunk`
  now spends the hold (`startPending`/`isBuffering`) and reinstalls the
   Former regression: `clickDuringBufferKeepsOffsetOnRelease` (suite
   removed 2026-10-15).
- **Footnote bodies in PDFs whose text layer does not carry them**
  (like the test article): the marker↔body pipeline is ready and
   covered with synthetic lists (former `FootnoteTests`, suite removed
   2026-10-15),
  what the extractor finds; without a body in the PDF, only the
  marker is announced. Marker detection is two-layered: geometric
  `sup` from the extractor (span-level, MuPDF bit or small+elevated
  digit with suffix rule; `Phrase.WordBox.sup`, consumed for standalone
  tokens) plus the textual reserve (`expandFootnoteMarkers`, which does
  not distinguish "argument.7" from "mp3" beyond the regex guards).
  Known gap: `temSup` requires the token core to equal N, so glued
  tokens (`realist's.1`) fall through to the reserve; suffix matching
  is the recorded next step.
- Open item: PDF extraction
  can deliver logic symbols another way (entity, LaTeX, image);
  without a measured formula PDF this path is unverified.
- Improvement paths researched, without integration (notes removed
  2026-10-15): Montreal Forced Aligner (MIT) for
  offline karaoke with Piper; AVAudioPlayerNode (native) for gapless
  concatenation without a duration probe; pdfminer.six (MIT) as a
  fallback plan if the PyMuPDF AGPL becomes blocking when opening the
  app.
- The scrubber during streaming still pins to the measured audio (a
  known open item in the backlog).
