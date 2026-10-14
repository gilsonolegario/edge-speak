import SwiftUI
import AppKit

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

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastScrolledLocation: Int = -1
        var lastScrolledLength: Int = -1
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
        return scroll
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
        let current = NSAttributedString(attributed)
        if let storage = textView.textStorage, !storage.isEqual(to: current) {
            storage.setAttributedString(current)
            textView.font = NSFont.systemFont(ofSize: pointSize)
            textView.textContainer?.widthTracksTextView = true
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
