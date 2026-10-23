import SwiftUI
import AppKit
import Combine

/// Clickable text that reports which passage was clicked.
///
/// Why not a SwiftUI `Text`: it renders the `AttributedString`, but
/// only reports "the text was clicked", without saying WHERE. To jump the reading
/// to the sentence, the character index under the cursor is needed, and only
/// TextKit provides that reliably.
///
/// Why an `NSScrollView` around it: `NSTextView` has no intrinsic size.
/// Giving it the full text height makes the panel swallow the window and
/// hide the PDF (measured defect); with internal scrolling the panel has a bounded
/// height and the text scrolls inside it.
struct ClickableTextView: NSViewRepresentable {
    let attributed: AttributedString
    /// Size in points. We pass the number instead of `Font` because `Font` is
    /// an opaque wrapper, and `NSTextView` needs the point value.
    let pointSize: CGFloat
    /// Receives the clicked character index within the text.
    let onTap: (Int) -> Void
    /// (UTF-16) range of the sentence being read, for the teleprompter to scroll to it.
    var scrollTo: NSRange? = nil
    /// Follow the reading; when off, manual scrolling is respected.
    var follow: Bool = true
    /// Live controller for the DIRECT-DRIVE word paint (yellow reimplementation):
    /// the coordinator observes `highlightWordIndex` and paints the word run
    /// straight into the text storage, with zero SwiftUI rebuilds per word.
    /// Sentence background keeps flowing through `attributed` as before.
    var controller: SpeechController? = nil
    /// Current sentence context (full text + its range) for locating the word.
    var sentenceContext: (() -> (full: String, entry: Range<String.Index>)?)? = nil
    /// Interface language: the accessibility strings come from the catalog like
    /// every other label. They used to be hardcoded English in this file, which
    /// left the panel announcing itself in English on a Portuguese UI.
    var language: L.Language = .en

    /// Plano item 20: vizinha de frase (−1/+1) — alimenta as ações
    /// customizadas (VoiceOver) do painel; mesma política dos botões da
    /// barra (`SentenceNeighborPolicy` + `clickToPlay`). Nil desliga as ações.
    var onSentenceJump: ((Int) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var lastScrolledLocation: Int = -1
        var lastScrolledLength: Int = -1
        /// Currently painted word run (protected from sentence repaints).
        var wordRange: NSRange?
        /// Attributes captured under `wordRange` before the word was painted:
        /// `clearWord` restores them exactly. Repainting the sentence style
        /// blindly left a blue residue once the sentence had moved on.
        var wordSavedRuns: [(range: NSRange, attrs: [NSAttributedString.Key: Any])]?
        var wordCancellable: AnyCancellable?
        weak var box: ClickReportingTextView?
        var controller: SpeechController?
        var context: (() -> (full: String, entry: Range<String.Index>)?)?
        var pointSize: CGFloat = 13

        /// Sentence background color (same as the SwiftUI path's).
        static var sentenceBG: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.35) }
        static var wordBG: NSColor { NSColor.systemYellow.withAlphaComponent(0.75) }

        func bind(controller: SpeechController, textView: ClickReportingTextView,
                  context: (() -> (full: String, entry: Range<String.Index>)?)?, pointSize: CGFloat) {
            // Rebind on every update: `makeNSView` runs once and captured the first
            // document's closure. Switching files kept the old text for locating
            // the word, so the panel yellow landed wrong from the 2nd sentence on.
            // Only the sink is created once.
            self.box = textView
            self.controller = controller
            self.context = context
            self.pointSize = pointSize
            guard wordCancellable == nil else { return }
            wordCancellable = controller.$highlightWordIndex
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.paintWord() }
        }

        /// Paints the current word straight into the storage (no view update).
        /// During the footnote announcement the last word remains (early return
        /// on `skip`); miss locating the text in the panel or out-of-range range
        /// clears the painting (honest consequence of expansion without a box).
        func paintWord() {
            guard let tv = box, let st = tv.textStorage, let c = controller else { return }
            guard !PiperTTS.isOfflineVoice(c.voiceInUse),
                  let ctx = context?(),
                  c.highlightWordIndex >= 0,
                  let seg = c.segments.first(where: { $0.index == c.highlightIndex }),
                  !seg.words.isEmpty
            else { clearWord(); return }
            let spoken = seg.words.map(\.text)
            let target = c.highlightWordIndex
            // The footnote announcement exists only in the audio: while it is
            // being spoken there is no word to paint (keep the last one), and
            // afterwards its words leave the sequence so they never drag the
            // matching cursor (see `announcementIndices`).
            let skip = ClickableTextView.announcementIndices(
                spoken, portuguese: ReadAloudFilter.isPortugueseVoice(c.voiceInUse))
            guard !skip.contains(target) else { return }
            let filtered: [String]
            let adjusted: Int
            if skip.isEmpty {
                filtered = spoken
                adjusted = target
            } else {
                filtered = spoken.enumerated().filter { !skip.contains($0.offset) }.map(\.element)
                adjusted = target - skip.filter { $0 < target }.count
            }
            guard adjusted >= 0, adjusted < filtered.count,
                  let loc = ClickableTextView.locateWord(
                      full: ctx.full, entry: ctx.entry,
                      segWords: filtered, target: adjusted)
            else { clearWord(); return }
            let range = NSRange(location: loc.low, length: loc.high - loc.low)
            guard range.length > 0, range.location + range.length <= st.length else { clearWord(); return }
            if wordRange == range { return }
            clearWord()
            // Captures what is really under the run before painting: on clear,
            // the restore is exact even if the sentence moved on meanwhile.
            var saved: [(range: NSRange, attrs: [NSAttributedString.Key: Any])] = []
            st.enumerateAttributes(in: range, options: []) { attrs, r, _ in
                saved.append((r, attrs))
            }
            st.beginEditing()
            st.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: pointSize), range: range)
            st.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            st.addAttribute(.backgroundColor, value: Self.wordBG, range: range)
            st.endEditing()
            wordRange = range
            wordSavedRuns = saved
        }

        /// Removes the word run, restoring the exact attributes captured when
        /// it was painted (repainting the sentence style blindly reinstated the
        /// blue background over a sentence that had already moved on).
        func clearWord() {
            guard let r = wordRange, let tv = box, let st = tv.textStorage,
                  r.location + r.length <= st.length else {
                wordRange = nil
                wordSavedRuns = nil
                return
            }
            st.beginEditing()
            if let saved = wordSavedRuns {
                for run in saved where run.range.location + run.range.length <= st.length {
                    st.setAttributes(run.attrs, range: run.range)
                }
            } else {
                // Defensive fallback (no capture at hand): restore the
                // sentence style, as before.
                st.addAttribute(.font, value: NSFont.systemFont(ofSize: pointSize), range: r)
                st.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r)
                st.addAttribute(.backgroundColor, value: Self.sentenceBG, range: r)
            }
            st.endEditing()
            wordRange = nil
            wordSavedRuns = nil
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ClickReportingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // Required so the click reaches the text and not the view containing it.
        textView.isAutomaticLinkDetectionEnabled = false
        // Explicit adaptive color: without it, unattributed text came out black
        // and fixed, illegible in dark mode — regardless of the attrs pipeline.
        textView.textColor = .labelColor
        // VoiceOver: the panel is a text area where each sentence is playable.
        // Plano item 22: rótulos no catálogo bilíngue (antes falavam inglês
        // mesmo com a interface em português).
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityLabel(L.get("a11y.panel.title", locale: language))
        textView.setAccessibilityHelp(L.get("a11y.panel.hint", locale: language))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.onCharacterTap = { [weak textView] index in
            guard index >= 0, let textView else { return }
            onTap(index)
            textView.setSelectedRange(NSRange(location: min(index, (textView.string as NSString).length), length: 0))
        }
        scroll.documentView = textView
        // Plano item 20: vizinha de frase — closure + ações customizadas na
        // primeira montagem (o update reatribui a cada body, como o onTap).
        textView.onJumpSentence = onSentenceJump
        textView.setAccessibilityCustomActions(sentenceJumpActions(for: textView))
        if let controller {
            context.coordinator.bind(controller: controller, textView: textView,
                                     context: sentenceContext, pointSize: pointSize)
        }
        return scroll
    }

    /// Plano item 20: ações customizadas (VoiceOver) do painel — frase
    /// anterior/próxima sobre a MESMA API dos botões da barra. O alvo é o
    /// próprio `ClickReportingTextView` (os métodos `@objc` leem
    /// `onJumpSentence`, reatribuído a cada update). Sem closure: lista vazia.
    private func sentenceJumpActions(for textView: ClickReportingTextView) -> [NSAccessibilityCustomAction] {
        guard onSentenceJump != nil else { return [] }
        let anterior = NSAccessibilityCustomAction(
            name: L.get("ui.previousSentence", locale: language),
            target: textView,
            selector: #selector(ClickReportingTextView.jumpToPreviousSentence(_:)))
        let proxima = NSAccessibilityCustomAction(
            name: L.get("ui.nextSentence", locale: language),
            target: textView,
            selector: #selector(ClickReportingTextView.jumpToNextSentence(_:)))
        return [anterior, proxima]
    }

    /// Background runs (range + color) of a storage: equality means the
    /// highlight already shows exactly this — repainting would only redo layout.
    /// Word indices of the footnote announcement that `forSpeech` inserts
    /// into the spoken sequence ("nota de rodapé N" / "footnote N"). They
    /// exist only in the audio: left in the sequence, the first announcement
    /// word that equals a later displayed word ("de", "nota" — common in
    /// Portuguese) drags `locateWord`'s cursor past the rest of the sentence,
    /// every real word after it misses, and the panel yellow falls behind the
    /// voice until the sentence ends (measured on the marker sentence: all
    /// targets after the announcement missed). The template is the `L`
    /// catalog — the same single source `expandFootnoteMarkers` speaks.
    /// Pure; a literal run of the same words in the document text would also
    /// be skipped (rare: `clean` removes "nota N" cross-references anyway).
    static func announcementIndices(_ segWords: [String], portuguese: Bool) -> Set<Int> {
        let template = L.get("speech.footnote", locale: portuguese ? .pt : .en)
        let parts = template.split(separator: " ").map(String.init)
        guard parts.count >= 2, segWords.count >= parts.count else { return [] }
        var out = Set<Int>()
        let lower = segWords.map { $0.lowercased() }
        func partMatches(_ part: String, _ word: String) -> Bool {
            guard part == "{0}" else { return part.lowercased() == word }
            // The number slot: a token of digits (the service may keep or
            // drop surrounding punctuation), never a lettered word.
            let digits = word.filter(\.isNumber)
            let rest = word.filter { !$0.isNumber && !$0.isPunctuation }
            return !digits.isEmpty && rest.isEmpty
        }
        var i = 0
        while i + parts.count <= segWords.count {
            if parts.enumerated().allSatisfy({ (k, part) in
                partMatches(part, lower[i + k])
            }) {
                out.formUnion(i..<(i + parts.count))
                i += parts.count
            } else {
                i += 1
            }
        }
        return out
    }

    /// Locates the spoken word `target` inside the sentence (UTF-16 offsets in
    /// `full`), by text matching from the previous match on. Nil on miss —
    /// the caller keeps the last highlight instead of erasing it. Pure (tested).
    ///
    /// Match is by WHOLE word (non-letter/non-digit on both sides): expansions
    /// of the spoken text (years spelled out, `p. 12` read aloud) contain short
    /// fragments like the `e` of `novecentos e cinquenta` that matched INSIDE
    /// later displayed words, dragging the cursor forward — the yellow jumped
    /// on citations with year + page while the audio flowed on.
    static func locateWord(full: String, entry: Range<String.Index>, segWords: [String], target: Int) -> (low: Int, high: Int)? {
        let phraseText = String(full[entry])
        var cursor = phraseText.startIndex
        var found: Range<String.Index>?
        for (i, raw) in segWords.enumerated() {
            guard i <= target else { break }
            let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            var from = cursor
            var match: Range<String.Index>?
            while from < phraseText.endIndex {
                guard let m = phraseText.range(
                    of: needle, options: .caseInsensitive,
                    range: from..<phraseText.endIndex) else { break }
                if isWholeWord(phraseText, m) { match = m; break }
                from = phraseText.index(after: m.lowerBound)
            }
            guard let m = match else { continue }
            if i == target { found = m }
            cursor = m.upperBound
        }
        guard let local = found else { return nil }
        let dLow = phraseText.distance(from: phraseText.startIndex, to: local.lowerBound)
        let dHigh = phraseText.distance(from: phraseText.startIndex, to: local.upperBound)
        guard let bLow = full.index(entry.lowerBound, offsetBy: dLow, limitedBy: full.endIndex),
              let bHigh = full.index(entry.lowerBound, offsetBy: dHigh, limitedBy: full.endIndex) else { return nil }
        let ns = NSRange(bLow..<bHigh, in: full)
        guard ns.length > 0 else { return nil }
        return (ns.location, ns.location + ns.length)
    }

    /// Whole-word boundary for the karaoke matcher: the character before the
    /// match and the one where it ends must both be outside letter/digit
    /// (Unicode-aware, like the match itself).
    private static func isWholeWord(_ text: String, _ range: Range<String.Index>) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }
    /// already shows exactly this. Colors compare by resolved sRGB components,
    /// never by `description` (dynamic colors describe differently per appearance).
    @MainActor
    static func bgRuns(_ storage: NSAttributedString) -> [String] {
        var out: [String] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.backgroundColor, in: full, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let canon: String
            if let c = color.usingColorSpace(.sRGB) {
                canon = String(format: "%.3f,%.3f,%.3f,%.3f",
                               c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
            } else {
                canon = String(describing: color)
            }
            out.append("\(range.location):\(range.length):\(canon)")
        }
        return out
    }
    /// storage (restoring base font/color there) and applies the desired
    /// runs. Same characters on both sides by contract — the caller checks.
    @MainActor
    static func paintHighlight(storage: NSTextStorage, desired: NSAttributedString, pointSize: CGFloat, protected: NSRange? = nil) {
        let baseFont = NSFont.systemFont(ofSize: pointSize)
        let full = NSRange(location: 0, length: min(storage.length, desired.length))
        guard full.length > 0 else { return }
        func hits(_ range: NSRange) -> Bool {
            guard let p = protected, p.length > 0 else { return false }
            return NSIntersectionRange(range, p).length > 0
        }
        storage.beginEditing()
        storage.enumerateAttribute(.backgroundColor, in: full, options: []) { value, range, _ in
            guard value != nil, !hits(range) else { return }
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.font, value: baseFont, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        desired.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            guard attrs[.backgroundColor] != nil else { return }
            // Sentence background yields to the live word run (split around it).
            if let p = protected, p.length > 0 {
                let inter = NSIntersectionRange(range, p)
                if inter.length > 0 {
                    if range.location < inter.location {
                        let left = NSRange(location: range.location, length: inter.location - range.location)
                        storage.addAttribute(.backgroundColor, value: attrs[.backgroundColor] as Any, range: left)
                    }
                    let rightLoc = inter.location + inter.length
                    let rangeEnd = range.location + range.length
                    if rightLoc < rangeEnd {
                        let right = NSRange(location: rightLoc, length: rangeEnd - rightLoc)
                        storage.addAttribute(.backgroundColor, value: attrs[.backgroundColor] as Any, range: right)
                    }
                    return
                }
            }
            storage.addAttribute(.backgroundColor, value: attrs[.backgroundColor] as Any, range: range)
            if let font = attrs[.font] { storage.addAttribute(.font, value: font, range: range) }
            if let fg = attrs[.foregroundColor] { storage.addAttribute(.foregroundColor, value: fg, range: range) }
        }
        storage.endEditing()
    }

    /// Background runs outside the protected (live word) run: equality means
    /// the sentence highlight already shows — word ticks skip the repaint.
    @MainActor
    static func sentenceRuns(_ storage: NSAttributedString, protected: NSRange?) -> [String] {
        var out: [String] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.backgroundColor, in: full, options: []) { value, range, _ in
            guard value != nil else { return }
            if let p = protected, p.length > 0,
               NSIntersectionRange(range, p).length > 0 { return }
            out.append("\(range.location):\(range.length)")
        }
        return out
    }

    /// Label and help from the bilingual catalog, in the CURRENT language.
    ///
    /// Applied both here and in `updateNSView`: `makeNSView` runs once, so
    /// switching the interface language would otherwise leave the panel
    /// announcing itself in the language chosen at launch.
    private func applyAccessibilityLabels(to textView: ClickReportingTextView) {
        textView.setAccessibilityLabel(L.get("a11y.panelLabel", locale: language))
        textView.setAccessibilityHelp(L.get("a11y.panelHelp", locale: language))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClickReportingTextView else { return }
        // Plano item 22: os rótulos do painel seguem a linguagem VIVA —
        // makeNSView rodou uma vez só; update roda a cada body.
        textView.setAccessibilityLabel(L.get("a11y.panel.title", locale: language))
        textView.setAccessibilityHelp(L.get("a11y.panel.hint", locale: language))
        // Plano item 20: vizinha de frase — closure e ações customizadas
        // retribuídas a cada update, como o `onTap` abaixo.
        textView.onJumpSentence = onSentenceJump
        textView.setAccessibilityCustomActions(sentenceJumpActions(for: textView))
        // The click closure is reassigned on EVERY update: `makeNSView` runs only
        // once and captured the first `body`'s `onTap`. When switching files,
        // the old closure mapped the new document's clicks against the old text
        // (finding B5). Reassigning keeps `onTap` always the current document's.
        // Same for the word-locating closure: the coordinator kept the first
        // document's text and the panel yellow drifted from the 2nd sentence on.
        if let controller {
            context.coordinator.bind(
                controller: controller, textView: textView,
                context: sentenceContext, pointSize: pointSize)
        }
        textView.onCharacterTap = { [weak textView] index in
            guard index >= 0, let textView else { return }
            onTap(index)
            textView.setSelectedRange(NSRange(location: min(index, (textView.string as NSString).length), length: 0))
        }
        // Highlight path: sentence background flows through `attributed`; the
        // live word run is painted directly by the coordinator (zero SwiftUI
        // rebuilds per word) and this path never touches it. Word ticks with
        // unchanged sentence background skip entirely.
        let plain = String(attributed.characters)
        if let storage = textView.textStorage, storage.string == plain {
            let protected = context.coordinator.wordRange
            let current = NSAttributedString(attributed)
            guard Self.sentenceRuns(storage, protected: protected)
                != Self.sentenceRuns(current, protected: protected) else { return }
            Self.paintHighlight(storage: storage, desired: current, pointSize: pointSize, protected: protected)
        } else if let storage = textView.textStorage {
            let current = NSAttributedString(attributed)
            if !storage.isEqual(to: current) {
                storage.setAttributedString(current)
                context.coordinator.wordRange = nil
                context.coordinator.wordSavedRuns = nil
                textView.font = NSFont.systemFont(ofSize: pointSize)
                textView.textContainer?.widthTracksTextView = true
            }
        }
        // Teleprompter: scrolls to the sentence being read when it changes (not on every
        // word, to avoid jitter); with follow off, it does not touch
        // the user's scrolling.
        if follow,
           let target = scrollTo,
           target.location >= 0,
           target.location + target.length <= (textView.string as NSString).length,
           (target.location != context.coordinator.lastScrolledLocation
            || target.length != context.coordinator.lastScrolledLength) {
            context.coordinator.lastScrolledLocation = target.location
            context.coordinator.lastScrolledLength = target.length
            textView.scrollRangeToVisible(target)
            // Plano item 21: o destaque é só pintura para VoiceOver — mas o
            // VO de TEXTO segue a SELEÇÃO do NSTextView. Durante o follow, a
            // frase corrente vira seleção (mesma régua do teleprompter: só
            // quando o target MUDA — nunca por tick de palavra).
            textView.setSelectedRange(target, affinity: .downstream, stillSelecting: false)
        } else if scrollTo == nil {
            context.coordinator.lastScrolledLocation = -1
            context.coordinator.lastScrolledLength = -1
        }
    }
}

/// `NSTextView` that reports the clicked character — only the CLICK, not the
/// drag: without the guard, drag-to-select triggered the reading
/// jump at the press point (found in the audit; the PDF already filtered
/// displacement <4 pt in `ClickablePDFView`).
final class ClickReportingTextView: NSTextView {
    var onCharacterTap: ((Int) -> Void)?

    /// Plano item 20: vizinha de frase — executada pelas ações customizadas
    /// (VoiceOver) deste text view; a closure vem da `body` (reatribuída a
    /// cada update).
    var onJumpSentence: ((Int) -> Void)?

    @objc func jumpToPreviousSentence(_ sender: Any?) { onJumpSentence?(-1) }
    @objc func jumpToNextSentence(_ sender: Any?) { onJumpSentence?(1) }

    private var downPoint: NSPoint?
    private var downChar: Int?
    /// Last reported tap, for the double-click debounce.
    private var lastTapAt: Date?

    /// Minimum gap between reported taps: a double click is two down/up pairs
    /// (both under 4 pt) and would jump the reading twice (restart + double
    /// scroll). Word selection is untouched — it happens in `super.mouseUp`.
    static let tapDebounce: TimeInterval = 0.25

    /// Word range for the dictionary entry: the selection when it exists,
    /// else the word under the click (pure NSString logic, unit-tested).
    static func lookupRange(in text: NSString, selection: NSRange, click: Int) -> NSRange? {
        if selection.length > 0,
           selection.location + selection.length <= text.length {
            return selection
        }
        guard click >= 0, click < text.length else { return nil }
        var found: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) {
            _, range, _, stop in
            if NSLocationInRange(click, range) || click == range.upperBound {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// Dictionary lookup on the selected (or clicked) word — a recurrent
    /// request for reading apps. Uses the system dictionary popup, no dependency.
    override func menu(for event: NSEvent) -> NSMenu? {
        let current = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        var click = NSNotFound
        if let manager = layoutManager, let container = textContainer {
            let glyph = manager.glyphIndex(for: point, in: container)
            click = manager.characterIndexForGlyph(at: glyph)
        }
        guard let range = Self.lookupRange(
            in: string as NSString, selection: selectedRange(), click: click
        ) else { return current }
        let word = (string as NSString).substring(with: range)
        guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return current }
        current.addItem(.separator())
        let item = NSMenuItem(
            title: "Look Up “\(word)”", action: #selector(lookUpClickedWord), keyEquivalent: "")
        item.target = self
        item.representedObject = NSStringFromRange(range)
        current.addItem(item)
        return current
    }

    @objc private func lookUpClickedWord(_ sender: NSMenuItem) {
        let range: NSRange
        if let raw = sender.representedObject as? String {
            range = NSRangeFromString(raw)
        } else {
            range = selectedRange()
        }
        guard range.location + range.length <= (string as NSString).length else { return }
        showDefinition(for: textStorage?.attributedSubstring(from: range) ?? NSAttributedString(), range: NSRange(location: 0, length: range.length))
    }

    override func mouseDown(with event: NSEvent) {
        // The event point comes in view coordinates; TextKit works with
        // the text container's, which has its own inset. The conversion
        // window→view is independent of scrolling (only the visible passage changes).
        downPoint = event.locationInWindow
        let pointInContainer = convert(event.locationInWindow, from: nil)
        if let manager = layoutManager, let container = textContainer {
            let glyph = manager.glyphIndex(for: pointInContainer, in: container)
            downChar = manager.characterIndexForGlyph(at: glyph)
        } else {
            downChar = nil
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let upPoint = event.locationInWindow
        super.mouseUp(with: event)
        defer {
            downPoint = nil
            downChar = nil
        }
        guard let downPoint, let downChar,
              hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < 4
        else { return }
        // Debounce: the second click of a double click would jump the reading
        // again (restart + double scroll).
        let now = Date()
        if let last = lastTapAt, now.timeIntervalSince(last) < Self.tapDebounce {
            lastTapAt = nil
            return
        }
        lastTapAt = now
        onCharacterTap?(downChar)
    }
}
