import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import AppKit

struct ContentView: View {
    @StateObject private var controller = SpeechController()

    @State private var text: String = ""
    @State private var pdfDocument: PDFDocument?
    /// Stable identity of the open document (file URL): anchors the
    /// saved position. Nil in text-only mode (no file, no resume).
    @State private var currentDocumentID: String?
    @State private var sentences: [TextImport.Phrase] = []
    @State private var filteredSentences: [TextImport.Phrase] = []
    @AppStorage(AppSetting.integralKey) private var integralMode: Bool = AppSetting.integralDefault
    @State private var showTextPanel: Bool = false
    @AppStorage(AppSetting.voiceKey) private var voice: String = AppSetting.voiceDefault
    /// Reading cadence, chosen by the user; persists the `percent: Int`
    /// and applies to the next synthesis.
    @AppStorage(AppSetting.rateKey) private var ratePercent: Int = AppSetting.rateDefault
    private var rate: EdgeTTS.Rate { EdgeTTS.Rate(percent: ratePercent) }
    @State private var showingImporter = false
    /// Follows the read sentence in the PDF; turning off freezes the scroll.
    @AppStorage(AppSetting.followKey) private var followReading: Bool = AppSetting.followDefault
    /// Transient follow brake: manual scrolling beats the highlight ONLY
    /// for the moment — any highlight advance releases it and the view
    /// resumes following (before, a scroll turned off the persisted
    /// `followReading` forever and the highlight never crossed the page
    /// again). Not persisted; the Settings switch (`followReading`) still applies.
    @State private var scrollHold = false
    /// Reads footnote bodies (default on); when off, markers
    /// become pauses and bodies leave the reading list.
    @AppStorage(AppSetting.footnoteKey) private var readFootnotes: Bool = AppSetting.footnoteDefault
    /// Each increment forces the PDF back to the read passage.
    @State private var revealToken: Int = 0
    /// Generation of the ongoing load: the PDF reading runs in the background, and if the
    /// user opens another file midway, the late result is
    /// discarded instead of overwriting the new document.
    @State private var loadGeneration = 0

    /// Stop timer: minutes chosen in the menu (0 = off).
    /// Not persisted — a timer must not survive relaunch.
    @State private var sleepMinutes: Int = 0
    /// Moment when the reading stops; `nil` when the timer is off.
    /// Changes on every choice and fires the countdown (`task id:sleepDeadline`).
    @State private var sleepDeadline: Date?

    /// Text font size, in points.
    ///
    /// Persisted because it is a reading preference: whoever needs a large
    /// font does not want to reconfigure it at every opening.
    @AppStorage(AppSetting.fontKey) private var fontSize: Double = AppSetting.fontDefault

    /// Interface language (EN default); all sentences below come from the
    /// `L` catalog in this language.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var language: L.Language { L.Language(rawValue: appLanguageRaw) ?? .en }

    private var textFont: Font { .system(size: fontSize) }

    private func adjustFont(by delta: Double) {
        fontSize = min(
            AppSetting.maxFontSize,
            max(AppSetting.minFontSize, fontSize + delta))
    }

    private func load(url: URL) {
        // stopPlayback alone stops the audio but leaves the synthesis task
        // alive: it would enqueue audio and sentences of the old document
        // over the newly loaded one. Cancel first, so the old
        // session dies before the text and sentence swap.
        if isReading || controller.isBusy {
            controller.cancelSynthesis()
            controller.stopPlayback()
        }
        // PDF extraction waits for the Python process with a
        // Thread.sleep loop (up to 180 s on a large file): on the main the UI
        // froze. Runs in the background with a live status; the safety scope
        // lasts until the end of the reading, and the generation discards the late
        // result if another file gets ahead.
        loadGeneration += 1
        let generation = loadGeneration
        let speech = controller
        let loc = language
        let scoped = url.startAccessingSecurityScopedResource()
        controller.setStatusKey("status.readingPDF", locale: language)
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try TextImport.readDocument(url: url)
                await MainActor.run {
                    guard generation == loadGeneration else { return }
                    text = r.filtered
                    pdfDocument = r.pdf
                    sentences = r.sentences
                    filteredSentences = r.filteredSentences
                    // Anchors the saved position to the file (applies to PDF and text:
                    // the identity is the URL, not the type). Only here, on success —
                    // the stop above saved the previous document's position.
                    currentDocumentID = url.absoluteString
                    speech.documentIDForPosition = url.absoluteString
                    // Texto trocado: invalida o cache de atributos (M3).
                    attrGeneration += 1
                    speech.setStatusKey(
                        "status.fileLoaded",
                        args: [url.lastPathComponent, r.filtered.count],
                        locale: loc)
                }
            } catch {
                await MainActor.run {
                    guard generation == loadGeneration else { return }
                    speech.setStatusKey(
                        "status.openFailed",
                        args: [error.localizedDescription],
                        locale: loc)
                }
            }
        }
    }

    private var activePhrases: [TextImport.Phrase] {
        if pdfDocument != nil {
            return integralMode ? sentences : filteredSentences
        }
        return controller.phrases
    }

    /// Text of the active list, for counting and button state.
    private var activeText: String {
        if pdfDocument != nil {
            return activePhrases.map { $0.text }.joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEmpty: Bool {
        pdfDocument == nil && activeText.isEmpty && !isReading && !controller.isBusy
    }

    private func playList() -> [TextImport.Phrase] {
        if pdfDocument != nil {
            // Without notes, the bodies leave; the indices of the remaining ones do NOT change
            // (they are property, not position) — highlight and jump still hold.
            return readFootnotes ? activePhrases : activePhrases.filter { $0.noteNumber == nil }
        }
        return TextImport.editorPhrases(text, integral: integralMode)
    }

    private var canPlay: Bool {
        if pdfDocument != nil {
            return !activePhrases.isEmpty && (!isReading || controller.isPaused || controller.isBusy)
        }
        return !activeText.isEmpty && (!isReading || controller.isPaused || controller.isBusy)
    }

    /// Paused with ready audio: play resumes instead of restarting.
    private var canPause: Bool { controller.isPlaying && !controller.isPaused }
    /// True while there is audio playing or paused — including
    /// during streaming synthesis, when it is already playing but audio is still missing.
    private var isReading: Bool { controller.isPlaying || controller.isPaused }

    /// Fraction of the synthesis completed, for the progress bar.
    private var synthesisFraction: Double? {
        guard controller.isBusy, controller.totalChunks > 0 else { return nil }
        return Double(controller.completedChunks) / Double(controller.totalChunks)
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText]
        for ext in ["md", "markdown"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }

    private func displayModel() -> (text: String, ranges: [(range: Range<String.Index>, index: Int)]) {
        let list = activePhrases
        var joined = ""
        var ranges: [(range: Range<String.Index>, index: Int)] = []
        for phrase in list {
            if !joined.isEmpty { joined += "\n" }
            let start = joined.endIndex
            joined += phrase.text
            ranges.append((start..<joined.endIndex, phrase.index))
        }
        return (joined, ranges)
    }

    private var currentPhrase: TextImport.Phrase? {
        let target = controller.highlightIndex
        guard target >= 0 else { return nil }
        return activePhrases.first { $0.index == target }
    }

    /// Lowercase, letters and digits only: strips punctuation and hyphens for the
    /// spoken-word→box match in the PDF.
    private static func normalizedWord(_ s: String) -> String {
        WordAligner.normalized(s)
    }

    /// State of the word→box match: only moves forward within the
    /// sentence (see `WordAligner`). It is `@State` to survive the view's
    /// evaluation cycles — the yellow cannot restart from scratch on every tick.
    @State private var wordAligner = WordAligner()

    /// Box of the word being read in the PDF (geometric karaoke): only with PDF,
    /// only with the online voice (Piper emits no word times) and only with the
    /// box matched by text — never by index.
    private var currentWordRect: CGRect? {
        guard pdfDocument != nil,
              !PiperTTS.isOfflineVoice(controller.voiceInUse),
              controller.highlightWordIndex >= 0,
              let phrase = currentPhrase,
              !phrase.words.isEmpty,
              let seg = controller.segments.first(
                  where: { $0.index == controller.highlightIndex }),
              !seg.words.isEmpty,
              controller.highlightWordIndex < seg.words.count
        else { return nil }
        return wordAligner.box(
            sentence: controller.highlightIndex,
            target: controller.highlightWordIndex,
            spokenWords: seg.words.map(\.text),
            pdf: phrase.words)
    }

    private var clickablePhrases: some View {
        let model = displayModel()
        // Teleprompter: the read sentence becomes the scroll target (UTF-16, as
        // TextKit counts); the word stays highlighted within it.
        let scroll: NSRange? = {
            guard controller.highlightIndex >= 0,
                  let e = model.ranges.first(where: { $0.index == controller.highlightIndex })
            else { return nil }
            return NSRange(e.range, in: model.text)
        }()
        return ClickableTextView(
            attributed: attributedPhrases(model.text, ranges: model.ranges),
            pointSize: fontSize,
            onTap: { charIndex in
                // The index comes in UTF-16 (TextKit); converts to the range.
                let clamped = min(max(0, charIndex), model.text.utf16.count)
                let idx = String.Index(utf16Offset: clamped, in: model.text)
                for entry in model.ranges
                where entry.range.contains(idx)
                    || (idx == model.text.endIndex && idx == entry.range.upperBound) {
                    clickToPlay(index: entry.index)
                    return
                }
            },
            scrollTo: scroll,
            follow: followReading
        )
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 300, alignment: .leading)
    }

    /// Highlights by GLOBAL INDEX (not by text search): repeated sentences
    /// would highlight the wrong occurrence without it. With word-by-word
    /// karaoke in online mode (Text panel, with or without PDF): the active
    /// sentence gets a background and the active word gets bold + stronger background. No
    /// karaoke offline (Piper emits no word times).
    ///
    /// During reading the result is cached by (sentence, word): the view
    /// is re-evaluated on every progress tick, and rebuilding 45k letters
    /// from scratch on each one saturated the main thread. Outside reading it computes directly.
    @State private var attrKey = ""
    @State private var attrValue = AttributedString("")
    /// Identity of the displayed text (document + full/filtered mode). Enters
    /// the attribute-cache key: without it, switching files or modes with the
    /// SAME (sentence, word) pair returned the previous text's `AttributedString`
    /// (wrong text / highlight on the wrong ranges — finding M3).
    @State private var attrGeneration = 0
    private func attributedPhrases(
        _ full: String, ranges: [(range: Range<String.Index>, index: Int)]
    ) -> AttributedString {
        guard isReading || controller.isBusy else {
            return buildAttributedPhrases(full, ranges: ranges)
        }
        let key = "\(attrGeneration)#\(controller.highlightIndex)#"
            + "\(controller.highlightWordIndex)"
        if key == attrKey { return attrValue }
        let value = buildAttributedPhrases(full, ranges: ranges)
        DispatchQueue.main.async {
            if self.attrKey != key { self.attrKey = key; self.attrValue = value }
        }
        return value
    }

    private func buildAttributedPhrases(
        _ full: String, ranges: [(range: Range<String.Index>, index: Int)]
    ) -> AttributedString {
        var attributed = AttributedString(full)
        // AppKit scope on purpose: attributes in SwiftUI scope
        // (`.backgroundColor`, `.foregroundColor`) have no counterpart in
        // `NSAttributedString` — the panel discarded them and nothing highlighted.
        // Without this the base text came out fixed black, illegible in dark mode.
        attributed[attributed.startIndex..<attributed.endIndex].appKit.foregroundColor = NSColor.labelColor
        let target = controller.highlightIndex
        guard target >= 0 else { return attributed }
        guard let entry = ranges.first(where: { $0.index == target }),
              let range = Range(entry.range, in: attributed)
        else { return attributed }
        // System color: follows the light/dark theme.
        attributed[range].appKit.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.35)
        // Word-by-word karaoke in online mode (text or PDF: the Text
        // panel uses the same streamer segments); Piper does not emit
        // word times.
        guard !PiperTTS.isOfflineVoice(controller.voiceInUse),
              controller.highlightWordIndex >= 0,
              let seg = controller.segments.first(where: { $0.index == target }),
              !seg.words.isEmpty
        else { return attributed }
        // Aligns word→passage by TEXT MATCHING, not by index: the
        // spoken text expands years/abbreviations ("1998" becomes several
        // words), and direct indexing fell on the wrong word. Each word
        // is searched from the end of the previous one; a miss is skipped without
        // shifting the following ones.
        let phraseText = String(full[entry.range])
        var cursor = phraseText.startIndex
        var wordLocal: Range<String.Index>?
        for (i, w) in seg.words.enumerated() {
            guard i <= controller.highlightWordIndex else { break }
            let needle = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty,
                  let found = phraseText.range(
                      of: needle, options: .caseInsensitive,
                      range: cursor..<phraseText.endIndex) else { continue }
            if i == controller.highlightWordIndex { wordLocal = found }
            cursor = found.upperBound
        }
        guard let local = wordLocal else { return attributed }
        // Converts the sentence's passage to the full string's base.
        let distLow = phraseText.distance(from: phraseText.startIndex, to: local.lowerBound)
        let distHigh = phraseText.distance(from: phraseText.startIndex, to: local.upperBound)
        let baseLow = full.index(entry.range.lowerBound, offsetBy: distLow)
        let baseHigh = full.index(entry.range.lowerBound, offsetBy: distHigh)
        if let wordRange = Range(baseLow..<baseHigh, in: attributed) {
            attributed[wordRange].appKit.font = NSFont.boldSystemFont(ofSize: fontSize)
            // Word in its own color, distinct from the line: white text in
            // bold over a strong highlight background — legible in both themes
            // and unmistakable from the sentence's soft background.
            // Word in YELLOW like in the PDF (no longer the system blue): dark
            // text on yellow reads well in both themes and unifies the karaoke
            // across both views — that was the divergence the audit pointed out.
            attributed[wordRange].appKit.foregroundColor = NSColor.black
            attributed[wordRange].appKit.backgroundColor =
                NSColor.systemYellow.withAlphaComponent(0.75)
        }
        return attributed
    }

    var body: some View {
        // FIXED-type container (`Container`, never swapped) between the window and
        // the content that changes shape (empty → editor → PDF → panel). Without
        // this anchor, every content change recreates the view root and the toolbar
        // is lost in the transition — measured: without PDF the bar
        // appeared (7 buttons in the accessibility tree), opening a PDF
        // it vanished. The container type does not change, so the bar survives.
        Container { textArea }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.top, 16)
            // Reserves the bottom band so the floating bar does not cover the
            // last line of the text.
            .padding(.bottom, isEmpty ? 16 : 74)
            .frame(minWidth: 720, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            // Floating bar over the content, like IINA's OSC. Always
            // visible while there is content: no auto-hide, so as not to
            // hinder following the reading.
            .overlay(alignment: .bottom) {
                if !isEmpty {
                    PlayerBar(
                        controller: controller,
                        textLength: activeText.count,
                        canPlay: canPlay,
                        onTogglePlay: togglePlay,
                        onTransport: { if pdfDocument != nil { revealToken += 1 } }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
            .overlay(alignment: .top) { statusBanner }
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: Self.importTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    load(url: url)
                case .failure(let error):
                    controller.setStatusKey(
                        "status.openFailed",
                        args: [error.localizedDescription],
                        locale: language)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in load(url: url) }
                }
                return true
            }
            // Double-click in Finder ("Open with EdgeSpeak") and drag onto the icon
            // arrive via the AppDelegate; command-line argument covers
            // `open --args` and the direct binary.
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakOpenFile)) { note in
                guard let url = note.object as? URL else { return }
                load(url: url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakClearCache)) { _ in
                controller.clearCache()
            }
            .onAppear {
                // Migrates a voice that stopped existing in the catalog (only the
                // multilingual existed) and sanitizes an orphaned stored value: without a catalog the
                // Picker has no selected item and synthesis would fail.
                if voice == "pt-BR-ThalitaNeural" {
                    voice = "pt-BR-ThalitaMultilingualNeural"
                } else if !AppSetting.isKnown(voice) {
                    voice = AppSetting.voiceDefault
                }
                // Pre-warms the bundled environment in the background, without freezing the UI and
                // without touching the status: when the user asks for the reading, `ensure`
                // has already run (or it runs then, with progress in the status).
                Task.detached(priority: .background) {
                    _ = try? BundledEnv.ensure(progress: { _ in })
                }
                for arg in CommandLine.arguments.dropFirst() {
                    let url = URL(fileURLWithPath: arg)
                    let ext = url.pathExtension.lowercased()
                    if FileManager.default.fileExists(atPath: url.path),
                       ["pdf", "md", "markdown", "txt", "text"].contains(ext) {
                        load(url: url)
                        break
                    }
                }
                installEventMonitors()
            }
            .onDisappear { removeEventMonitors() }
            .onChange(of: controller.status) { _, _ in showStatusBriefly() }
            .onChange(of: controller.isBusy) { _, busy in
                if busy { revealStatus() } else { showStatusBriefly() }
            }
            .onChange(of: integralMode) { _, _ in handleIntegralModeChange() }
            // Any advance of the highlight releases the transitory brake and the view
            // resumes following.
            .onChange(of: controller.highlightIndex) { _, _ in scrollHold = false }
            .onChange(of: appLanguageRaw) { _, _ in controller.refreshLocale(language) }
            // Choice in the timer menu: 0 turns it off (deadline nil); N arms the
            // deadline in N minutes. The firing lives in the `task(id:)` below.
            .onChange(of: sleepMinutes) { _, newValue in
                if newValue > 0 {
                    sleepDeadline = Date().addingTimeInterval(Double(newValue) * 60)
                    controller.setStatusKey("status.sleepSet", args: [newValue], locale: language)
                } else {
                    sleepDeadline = nil
                }
            }
            // Cancelable countdown: the `id` restarts the task on each new deadline
            // and cancels the previous one, with no Timer and no reference leak. When the
            // deadline arrives, it stops the reading and resets the menu.
            .task(id: sleepDeadline) {
                guard let target = sleepDeadline else { return }
                let remaining = target.timeIntervalSinceNow
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                guard !Task.isCancelled, sleepDeadline == target else { return }
                sleepDeadline = nil
                sleepMinutes = 0
                controller.stopPlayback()
            }
    }

    // MARK: - Text area

    /// Empty with affordance: icon + instruction + action, not looking stuck.
    private var emptyPlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text(L.get("ui.emptyPlaceholder", locale: language))
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(L.get("ui.emptyPlaceholderHint", locale: language))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showingImporter = true
            } label: {
                Label(L.get("ui.openFile", locale: language), systemImage: "doc")
            }
            .buttonStyle(.borderedProminent)
            .help(L.get("help.importFile", locale: language))
            .accessibilityLabel(Text(L.get("ui.openFile", locale: language)))
            .accessibilityHint(Text(L.get("help.importFile", locale: language)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// PDF always as the main view; secondary "Text" view (panel) with
    /// the clickable text that jumps by index. No PDF: editor (still) or
    /// clickable text (reading). The text is read-only during reading:
    /// the highlight is rebuilt on every sentence, and editing midway would make
    /// the highlight inconsistent with the already-synthesized audio.
    private var textArea: some View {
        Group {
            if isEmpty {
                emptyPlaceholder
            } else if let doc = pdfDocument {
                VStack(spacing: 8) {
                    PDFDocumentView(
                        document: doc,
                        page: (isReading || controller.isBusy)
                            ? currentPhrase?.page : nil,
                        rects: (isReading || controller.isBusy)
                            ? (currentPhrase?.rects ?? []) : [],
                        wordRect: (isReading || controller.isBusy)
                            ? currentWordRect : nil,
                        follow: followReading,
                        scrollHold: scrollHold,
                        revealToken: revealToken,
                        onUserScroll: { scrollHold = true },
                        onPageClick: { page, point in
                            guard let idx = PhraseLocator.phraseIndex(
                                near: point, on: page, among: activePhrases)
                            else { return }
                            clickToPlay(index: idx)
                        },
                        documentTitle: currentDocumentID?.components(separatedBy: "/").last ?? "",
                        currentPageText: L.get("pdf.header.page", locale: language, args: ((currentPhrase?.page ?? 0) + 1)),
                        voiceText: voice
                    )
                    // Manual scroll sets the transient brake (PDFDocumentView reports
                    // via onUserScroll); the button appears with the master on
                    // + brake, during the reading, and releases the brake by jumping
                    // to the passage.
                    if (isReading || controller.isBusy) && followReading && scrollHold {
                        HStack {
                            Spacer()
                            Button {
                                scrollHold = false
                                revealToken += 1
                            } label: {
                                Label(L.get("ui.goToPassage", locale: language), systemImage: "location.fill")
                            }
                            .buttonStyle(.link)
                            .font(.footnote)
                        }
                    }
                    DisclosureGroup {
                        clickablePhrases
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.get("ui.textPanel", locale: language))
                                .font(.system(size: 13, weight: .medium))
                            Text(L.get("ui.textPanelHint", locale: language))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint(Text(L.get("ui.textPanelHint", locale: language)))
                    .accessibilityLabel(Text(L.get("ui.textPanel", locale: language) + " — " + L.get("ui.textPanelHint", locale: language)))
                }
            } else if isReading || controller.isBusy {
                clickablePhrases
            } else {
                TextEditor(text: $text)
                    .font(textFont)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(controller.isBusy)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(8)
        // A frame instead of a loose background: visually separates the text from the
        // actions and gives breathing room, with no heavy "box".
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    controller.isBusy || isReading
                        ? Color.accentColor.opacity(0.45)
                        : Color.primary.opacity(0.12),
                    lineWidth: 1)
        )
    }

    private func togglePlay() {
        if canPause {
            controller.pause()
            return
        }
        // (Re)starting the reading resumes following: without this, an old
        // shutdown (manual scroll, which persists) froze the view forever
        // and the highlight never crossed the page. Scrolling manually turns it
        // off again at the moment — the "Go to passage" button still works.
        followReading = true
        // Internal pause resume: the audio is already where it stopped — no seek.
        let wasPaused = controller.isPaused
        controller.play(phrases: playList(), voice: voice, rate: rate, readFootnotes: readFootnotes)
        guard !wasPaused else { return }
        resumeSavedPositionIfCovered()
    }

    /// Automatic resume: reopening and pressing play returns where it stopped, ONLY when the
    /// measured audio already covers the point — else it starts from scratch. The status says from
    /// where, reusing the bar's time format (no duplicated logic).
    private func resumeSavedPositionIfCovered() {
        guard let doc = currentDocumentID else { return }
        let saved = ReadingPositionStore.load(documentID: doc, voice: voice)
        guard ReadingPositionStore.shouldResume(saved: saved, knownDuration: controller.knownDuration),
              let ponto = saved else { return }
        controller.seek(to: ponto)
        controller.setStatusKey(
            "status.resumedFrom",
            args: [PlayerBar.formatTime(ponto)],
            locale: language)
    }

    /// Click that plays: jumps to the clicked sentence; with no audio and no synthesis
    /// in progress, it starts the reading and jumps when the slice arrives (the controller
    /// keeps the pending jump and tries on every slice; from cache, the immediate
    /// retry already succeeds).
    private func clickToPlay(index: Int) {
        // The reveal token brings the PDF to the clicked passage at once — without
        // it the jump only changed the audio and the view stayed still (follow
        // off never scrolls by itself). It also re-enables following, for the
        // same reason as togglePlay.
        revealToken += 1
        scrollHold = false
        followReading = true
        if controller.jumpToSegment(index) { return }
        // No `hasAudio` here on purpose: it stays true after Stop (the queue
        // empties but the flag does not drop — audit 2026-10-13) and would block play
        // forever, with no audio, no process and no error. Whoever covers the index
        // already returned via `jumpToSegment`; the rest needs synthesis — and
        // `play` already guards synthesis in progress for the same reading.
        guard !controller.isBusy else { return }
        // With no audio at all, it synthesizes FROM the clicked sentence. With the whole
        // list, the player already had the document's beginning playing before the
        // clicked passage's slice existed — that is what made play start
        // at the beginning instead of the click point.
        let list = playList()
        guard let position = list.firstIndex(where: { $0.index == index }) else { return }
        controller.play(phrases: Array(list[position...]), voice: voice, rate: rate, readFootnotes: readFootnotes)
        controller.jumpToSegment(index)
    }

    /// Mode switch (integral/filtered) discards the old transcription and, if
    /// a reading was in progress, restarts with the new list via the same path
    /// as the play button. Without a reading, it only discards: the next play already uses the
    /// new mode. There is no loop: neither the discard nor the play changes `integralMode`.
    private func handleIntegralModeChange() {
        let active = isReading || controller.isBusy
        // Active list changes (full↔filtered): invalidates the attribute cache
        // before playing, so the highlight does not land on the old mode's text.
        attrGeneration += 1
        controller.discardTranscription()
        if active {
            controller.play(phrases: playList(), voice: voice, rate: rate, readFootnotes: readFootnotes)
        }
    }

    // MARK: - Status band

    @State private var statusVisible = false
    @State private var statusHideWork: DispatchWorkItem?

    private func revealStatus() {
        statusHideWork?.cancel()
        statusHideWork = nil
        if !statusVisible { statusVisible = true }
    }

    /// Shows the message and vanishes by itself — except during synthesis, when the
    /// message is the live progress and must not flicker.
    private func showStatusBriefly() {
        guard !controller.status.isEmpty else { return }
        if controller.isBusy { revealStatus(); return }
        revealStatus()
        let work = DispatchWorkItem { statusVisible = false }
        statusHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if statusVisible, !controller.status.isEmpty {
            HStack(spacing: 8) {
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(controller.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if controller.segments.isEmpty && controller.hasAudio {
                    Text(L.get("ui.noHighlight", locale: language))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if let fraction = synthesisFraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if PiperTTS.isOfflineVoice(controller.voiceInUse) {
                    Text(L.get("ui.offlineVoiceBadge", locale: language))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showingImporter = true
            } label: {
                Label(L.get("ui.open", locale: language), systemImage: "folder")
            }
            .disabled(controller.isBusy)
            .help(L.get("help.importFile", locale: language))
        }
        ToolbarItem(placement: .principal) {
            voicePicker
        }
        ToolbarItem(placement: .primaryAction) {
            optionsMenu
        }
    }

    private var voicePicker: some View {
        Picker(L.get("ui.voiceLabel", locale: language), selection: $voice) {
            Section(L.get("section.offline", locale: language)) {
                ForEach(PiperTTS.offlineVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option, locale: language)).tag(option)
                }
            }
            Section(L.get("section.english", locale: language)) {
                ForEach(AppSetting.englishVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option, locale: language)).tag(option)
                }
            }
            Section(L.get("section.portuguese", locale: language)) {
                ForEach(AppSetting.portugueseVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option, locale: language)).tag(option)
                }
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 240)
        .disabled(controller.isBusy)
        .help(L.get("help.readingVoice", locale: language))
    }

    /// Only the moment's actions: cadence and text mode live in Settings (⌘,)
    /// "Follow reading" is here and there, but in both it points to the SAME
    /// key (`AppSetting.followKey`), so it never diverges.
    private var optionsMenu: some View {
        Menu {
            // Without `if pdfDocument`: in text-only mode the teleprompter also
            // scrolls by itself and the user needs to turn it off (found in the audit).
            Toggle(L.get("ui.followReading", locale: language), isOn: $followReading)
            Divider()

            Button {
                adjustFont(by: -2)
            } label: {
                Label(L.get("ui.decreaseFont", locale: language), systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(fontSize <= AppSetting.minFontSize)

            Button {
                adjustFont(by: 2)
            } label: {
                Label(L.get("ui.increaseFont", locale: language), systemImage: "textformat.size.larger")
            }
            .keyboardShortcut("+", modifiers: .command)
            .keyboardShortcut("=", modifiers: .command)
            .disabled(fontSize >= AppSetting.maxFontSize)

            Button {
                fontSize = AppSetting.fontDefault
            } label: {
                Label(L.get("ui.defaultSize", locale: language), systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
            Button {
                controller.discardTranscription()
                controller.play(phrases: playList(), voice: voice, rate: rate, readFootnotes: readFootnotes)
            } label: {
                Label(L.get("ui.newReading", locale: language), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!controller.hasTranscription)
            .help(L.get("help.redoSynthesis", locale: language))

            Divider()
            // Sleep timer: turns itself off at the deadline. Lives as a
            // submenu because the Options menu already gathers the moment's actions.
            Menu {
                Button(L.get("ui.sleepOff", locale: language)) { sleepMinutes = 0 }
                Divider()
                ForEach([5, 15, 30, 60], id: \.self) { minute in
                    Button(L.get("ui.sleepMinutes", locale: language, args: minute)) {
                        sleepMinutes = minute
                    }
                }
            } label: {
                Label(L.get("ui.sleepTimer", locale: language), systemImage: "moon.zzz")
            }

            Divider()
            // SettingsLink opens the `Settings` scene of EdgeSpeakApp; it is what
            // compiles cleanest here (no @Environment and no scene id).
            SettingsLink {
                Label(L.get("ui.settings", locale: language), systemImage: "gear")
            }
        } label: {
            Label(L.get("ui.options", locale: language), systemImage: "slider.horizontal.3")
        }
        .help(L.get("help.optionsMenu", locale: language))
    }

    // MARK: - Keyboard and mouse (local monitors)

    @State private var eventMonitors: [Any?] = []

    /// Local keyboard event monitor.
    ///
    /// The `PDFView` is AppKit and swallows SwiftUI shortcuts: without the monitor,
    /// space would not toggle play/pause outside typing, nor would ⌥←/⌥→
    /// skip 15 s with the PDF focused.
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyDown(event)
        }
        eventMonitors = [keys]
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        eventMonitors = []
    }

    /// Space toggles play/pause outside typing and outside PDF reading; ⌥←/⌥→
    /// skip 15 s outside typing. Outside those cases the event goes on normally.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window ?? NSApp.keyWindow else { return event }
        let responder = window.firstResponder
        let editingText = responder is NSTextView || responder is NSTextField
        let readingPDF = responder is PDFView
        // Arrow keys arrive with `.numericPad`/`.function`; caps lock would shift
        // the comparison. Removes the three before requiring pure `.option`.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // Space (keyCode 49). In the editor space must insert text; in the PDF,
        // scroll — in those cases the event passes.
        if event.keyCode == 49, mods.isEmpty {
            if editingText || readingPDF { return event }
            // During synthesis the play button is disabled: the identity
            // key (`currentKey`) is only written at the end, so a new play
            // would be treated as "another text" and would cancel and restart the
            // ongoing synthesis. Space follows the button's rule and ignores.
            if controller.isBusy { return nil }
            if canPlay || canPause { togglePlay() }
            return nil
        }

        // ⌥← / ⌥→ (keyCode 123 / 124): ±15 s. In the editor, ⌥← navigates by word,
        // so there the event passes. During synthesis the buttons are
        // disabled; the shortcut follows the same rule.
        if mods == .option, event.keyCode == 123 || event.keyCode == 124 {
            if editingText { return event }
            guard !controller.isBusy else { return event }
            controller.skip(event.keyCode == 123 ? -15 : 15)
            // Explicit navigation: brings the PDF to the passage even with "Follow
            // reading" off, like the track and the ±15 s buttons.
            if pdfDocument != nil { revealToken += 1 }
            return nil
        }

        return event
    }
}

/// Fixed-type container, just to give the window a root that does not change
/// identity when the content changes (empty → editor → PDF → panel).
///
/// Exists because of the toolbar: applied directly to the content that
/// changes shape, it was lost in the switch (proven: without PDF the bar
/// appeared, opening a PDF it vanished). Here the root is always the same.
private struct Container<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}
