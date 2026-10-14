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

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var lastScrolledLocation: Int = -1
        var lastScrolledLength: Int = -1
        /// Currently painted word run (protected from sentence repaints).
        var wordRange: NSRange?
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
            guard wordCancellable == nil else { return }
            self.box = textView
            self.controller = controller
            self.context = context
            self.pointSize = pointSize
            wordCancellable = controller.$highlightWordIndex
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.paintWord() }
        }

        /// Paints the current word straight into the storage (no view update).
        /// Miss (expansion without textual match) keeps the last word.
        func paintWord() {
            guard let tv = box, let st = tv.textStorage, let c = controller else { return }
            guard !PiperTTS.isOfflineVoice(c.voiceInUse),
                  let ctx = context?(),
                  c.highlightWordIndex >= 0,
                  let seg = c.segments.first(where: { $0.index == c.highlightIndex }),
                  !seg.words.isEmpty,
                  let loc = ClickableTextView.locateWord(
                      full: ctx.full, entry: ctx.entry,
                      segWords: seg.words.map(\.text), target: c.highlightWordIndex)
            else { clearWord(); return }
            let range = NSRange(location: loc.low, length: loc.high - loc.low)
            guard range.length > 0, range.location + range.length <= st.length else { clearWord(); return }
            if wordRange == range { return }
            clearWord()
            st.beginEditing()
            st.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: pointSize), range: range)
            st.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            st.addAttribute(.backgroundColor, value: Self.wordBG, range: range)
            st.endEditing()
            wordRange = range
        }

        /// Removes the word run, restoring the sentence style underneath.
        func clearWord() {
            guard let r = wordRange, let tv = box, let st = tv.textStorage,
                  r.location + r.length <= st.length else { wordRange = nil; return }
            st.beginEditing()
            st.addAttribute(.font, value: NSFont.systemFont(ofSize: pointSize), range: r)
            st.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r)
            st.addAttribute(.backgroundColor, value: Self.sentenceBG, range: r)
            st.endEditing()
            wordRange = nil
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
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityLabel("Reading text. Click a sentence to play from there.")
        textView.setAccessibilityHelp("Reading text. Activate a sentence to move playback to it.")
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
        if let controller {
            context.coordinator.bind(controller: controller, textView: textView,
                                     context: sentenceContext, pointSize: pointSize)
        }
        return scroll
    }

    /// Background runs (range + color) of a storage: equality means the
    /// highlight already shows exactly this — repainting would only redo layout.
    /// Locates the spoken word `target` inside the sentence (UTF-16 offsets in
    /// `full`), by text matching from the previous match on. Nil on miss —
    /// the caller keeps the last highlight instead of erasing it. Pure (tested).
    static func locateWord(full: String, entry: Range<String.Index>, segWords: [String], target: Int) -> (low: Int, high: Int)? {
        let phraseText = String(full[entry])
        var cursor = phraseText.startIndex
        var found: Range<String.Index>?
        for (i, raw) in segWords.enumerated() {
            guard i <= target else { break }
            let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty,
                  let m = phraseText.range(of: needle, options: .caseInsensitive,
                                           range: cursor..<phraseText.endIndex) else { continue }
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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClickReportingTextView else { return }
        // The click closure is reassigned on EVERY update: `makeNSView` runs only
        // once and captured the first `body`'s `onTap`. When switching files,
        // the old closure mapped the new document's clicks against the old text
        // (finding B5). Reassigning keeps `onTap` always the current document's.
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

    private var downPoint: NSPoint?
    private var downChar: Int?

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
        onCharacterTap?(downChar)
    }
}
