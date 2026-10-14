import SwiftUI
import PDFKit

/// Shows the PDF rendered in full (all pages), faithful to the original,
/// with the sentence being read highlighted.
///
/// The highlight is geometric: it receives the boxes of the SENTENCE's lines (from the
/// extractor) and draws a blue `.highlight` annotation per box. No text
/// search — the filtered/reflowed text is never identical to the PDF's. `nil` clears.
struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    /// Page of the sentence (0-based); `nil` clears the highlight.
    var page: Int? = nil
    /// Boxes of the sentence's lines, in page coordinates.
    var rects: [CGRect] = []
    /// Box of the word being read, in page coordinates; `nil` clears.
    var wordRect: CGRect? = nil
    /// Page that OWNS `wordRect`. A sentence that crosses a page break keeps
    /// the page where it starts, but its continuation words are boxes of the
    /// next page: drawing them on the sentence's page put the yellow on the
    /// wrong place (measured: 11 sentences and 628 words in Neutrality_v82).
    /// `nil` falls back to the sentence's page.
    var wordPage: Int? = nil
    /// Follow the reading: scrolls to the passage; when off, freezes the scroll.
    var follow: Bool = true
    /// Transient follow brake: a manual scroll holds ONLY for the moment;
    /// any highlight advance releases it. The master (`follow`) still applies.
    var scrollHold: Bool = false
    /// Each change forces back to the passage even with follow off.
    var revealToken: Int = 0
    /// Scroll started by the user: the owner turns follow off here (manual
    /// scroll always beats the automatic one). `nil` turns the notice off.
    var onUserScroll: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Click on the PDF: page (0-based) + point in page coordinates.
    /// `nil` (default) turns it off; only the PDF uses it — in Text the jump already exists.
    var onPageClick: ((Int, CGPoint) -> Void)?

    /// Header info shown above PDF: document title, current page, voice/rate
    var documentTitle: String = ""
    var currentPageText: String = ""
    var voiceText: String = ""

    typealias NSViewType = NSView

    /// `PDFView` that tells click from drag: stores the point at mouseDown and
    /// only reports at mouseUp with displacement <4 pt; the rest (selection, scroll)
    /// follows PDFKit's normal behavior.
    final class ClickablePDFView: PDFView {
        var onClickPage: ((PDFPage, CGPoint) -> Void)?
        private var downPoint: NSPoint?
        override func mouseDown(with event: NSEvent) {
            downPoint = event.locationInWindow
            super.mouseDown(with: event)
        }
        override func mouseUp(with event: NSEvent) {
            let upPoint = event.locationInWindow
            super.mouseUp(with: event)
            defer { downPoint = nil }
            guard let downPoint,
                  hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < 4
            else { return }
            let viewPoint = convert(upPoint, from: nil)
            guard let page = page(for: viewPoint, nearest: false) else { return }
            onClickPage?(page, convert(viewPoint, to: page))
        }
    }

    final class Coordinator {
        /// Key of the SENTENCE (page + boxes) of the current annotations, without the word:
        /// a word change must not recreate the sentence's annotations (flicker).
        var lastPhraseKey: String?
        /// Last applied word box + page, to swap the annotation
        /// only when the word changes — never together with the sentence.
        var lastWordRect: CGRect?
        var lastWordPage: Int?
        var lastToken: Int = 0
        /// Live annotations of the sentence's BLUE highlight + the page containing them.
        var phraseAnnotations: [PDFAnnotation] = []
        var phrasePage: PDFPage?
        /// Live annotation of the word-by-word highlight + the page containing it.
        var wordAnnotation: PDFAnnotation?
        var wordPage: PDFPage?
        /// Last follow seen (so the detector does not report with follow off) and
        /// the manual-scroll notice relayed by `updateNSView`.
        var follow: Bool = true
        var onUserScroll: () -> Void = {}
        /// Marker up to which an origin change is the app's own: `go(to:)`
        /// applies the scroll right after the call, and without the window the app would
        /// read itself as the user and turn follow off by itself.
        var suppressUntil: Date = .distantPast
        /// Baseline of the inner clip view's geometry (origin, size,
        /// scale): only an ORIGIN change with everything else still is a scroll.
        var lastOrigin: CGPoint?
        var lastSize: CGSize?
        var lastScale: CGFloat?
        /// Observed `NSClipView` + signature token, to remove on dismantle.
        weak var observedClipView: NSClipView?
        var boundsObserver: NSObjectProtocol?
        weak var containerView: NSView?
        weak var pdfView: PDFView?
    }

    /// Silence window after each programmatic `go(to:)`, in seconds.
    static let programmaticScrollQuietWindow: TimeInterval = 0.5

    /// Pure decision of the detector: it is a user scroll only when follow
    /// is on, outside the silence window of the app's own `go(to:)`, the
    /// origin changed and neither size nor scale changed (zoom and
    /// resize touch size/scale, never only the origin).
    static func isUserScroll(
        follow: Bool, suppressed: Bool,
        oldOrigin: CGPoint, newOrigin: CGPoint,
        oldSize: CGSize, newSize: CGSize,
        oldScale: CGFloat, newScale: CGFloat
    ) -> Bool {
        guard follow, !suppressed else { return false }
        let originMoved = abs(newOrigin.x - oldOrigin.x) > 0.5
            || abs(newOrigin.y - oldOrigin.y) > 0.5
        let sizeChanged = abs(newSize.width - oldSize.width) > 0.5
            || abs(newSize.height - oldSize.height) > 0.5
        let zoomChanged = abs(newScale - oldScale) > 0.001
        return originMoved && !sizeChanged && !zoomChanged
    }

    /// Pure decision of the word follow: it scrolls only when follow is
    /// on and the word is outside the visible area.
    static func shouldScrollToWord(follow: Bool, wordVisible: Bool) -> Bool {
        follow && !wordVisible
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let header = NSTextField(labelWithString: headerText())
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.isEditable = false
        header.isSelectable = false
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        header.identifier = NSUserInterfaceItemIdentifier("pdfHeader")

        let pdfView = ClickablePDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.document = document
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.identifier = NSUserInterfaceItemIdentifier("pdfView")

        container.addSubview(header)
        container.addSubview(pdfView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.containerView = container
        observeUserScroll(in: pdfView, coordinator: context.coordinator)
        return container
    }
    
    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let token = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.boundsObserver = nil
        }
        coordinator.observedClipView = nil
        coordinator.containerView = nil
        coordinator.pdfView = nil
    }

    /// Finds the `PDFView`'s inner `NSClipView` (PDFKit does not expose it in a
    /// public property in this SDK version: it lives inside the embedded
    /// `NSScrollView`) and observes its bounds change: the
    /// origin is the scroll position. Registers once; `updateNSView`
    /// tries again when not found yet (the hierarchy may be born late)
    /// and `dismantleNSView` removes the observer.
    private func observeUserScroll(in view: PDFView, coordinator: Coordinator) {
        guard coordinator.boundsObserver == nil,
              let clip = Self.findClipView(in: view)
        else { return }
        clip.postsBoundsChangedNotifications = true
        coordinator.lastOrigin = clip.bounds.origin
        coordinator.lastSize = clip.bounds.size
        coordinator.lastScale = view.scaleFactor
        coordinator.observedClipView = clip
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main
        ) { [weak coordinator, weak view, weak clip] _ in
            guard let coordinator, let view, let clip else { return }
            Self.handleBoundsChange(clipView: clip, pdfView: view, coordinator: coordinator)
        }
    }

    /// Searches in depth for the first `NSScrollView` and returns its
    /// `contentView`; `nil` when the hierarchy does not exist yet.
    private static func findClipView(in view: NSView) -> NSClipView? {
        if let scroll = view as? NSScrollView { return scroll.contentView }
        for sub in view.subviews {
            if let found = findClipView(in: sub) { return found }
        }
        return nil
    }

    private func findPdfView(in view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        for sub in view.subviews {
            if let found = findPdfView(in: sub) { return found }
        }
        return nil
    }

    private func findHeaderField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier == NSUserInterfaceItemIdentifier("pdfHeader") { return field }
        for sub in view.subviews {
            if let found = findHeaderField(in: sub) { return found }
        }
        return nil
    }

    private func headerText() -> String {
        let parts: [String] = [
            documentTitle,
            currentPageText,
            voiceText,
        ].filter { !$0.isEmpty }
        return parts.joined(separator: " • ")
    }

    /// Detector filter: updates the baseline and reports only when the
    /// pure decision says it was the user (never by `go(to:)`, zoom or
    /// resize, never with follow already off).
    private static func handleBoundsChange(
        clipView: NSClipView, pdfView: PDFView, coordinator: Coordinator
    ) {
        let newOrigin = clipView.bounds.origin
        let newSize = clipView.bounds.size
        let newScale = pdfView.scaleFactor
        let userScroll = isUserScroll(
            follow: coordinator.follow,
            suppressed: Date.now < coordinator.suppressUntil,
            oldOrigin: coordinator.lastOrigin ?? newOrigin,
            newOrigin: newOrigin,
            oldSize: coordinator.lastSize ?? newSize,
            newSize: newSize,
            oldScale: coordinator.lastScale ?? newScale,
            newScale: newScale)
        coordinator.lastOrigin = newOrigin
        coordinator.lastSize = newSize
        coordinator.lastScale = newScale
        if userScroll { coordinator.onUserScroll() }
    }

    /// Marks the silence window before each programmatic scroll, so the
    /// detector does not confuse the app's own `go(to:)` with the user.
    private static func markProgrammaticScroll(_ coordinator: Coordinator) {
        coordinator.suppressUntil = Date.now.addingTimeInterval(
            programmaticScrollQuietWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let pdfView = findPdfView(in: nsView) ?? context.coordinator.pdfView
        let headerField = findHeaderField(in: nsView)
        if let headerField {
            headerField.stringValue = headerText()
        }
        guard let view = pdfView else { return }
        context.coordinator.pdfView = view
        if view.document !== document {
            view.document = document
            clearPhraseAnnotations(context.coordinator)
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastWordRect = nil
            context.coordinator.lastWordPage = nil
            context.coordinator.wordAnnotation = nil
            context.coordinator.wordPage = nil
        }
        if let clickable = view as? ClickablePDFView {
            clickable.onClickPage = { [document] pdfPage, point in
                onPageClick?(document.index(for: pdfPage), point)
            }
        }
        context.coordinator.follow = follow
        context.coordinator.onUserScroll = onUserScroll ?? {}
        observeUserScroll(in: view, coordinator: context.coordinator)
        let phraseKey = key(page: page, rects: rects)
        let tokenChanged = revealToken != context.coordinator.lastToken
        let phraseChanged = phraseKey != context.coordinator.lastPhraseKey || tokenChanged
        // The word's own page, not the sentence's: they differ when the
        // sentence crosses a page break.
        let wordPageIndex = wordPage ?? page
        let wordChanged = wordPageIndex != context.coordinator.lastWordPage
            || wordRect != context.coordinator.lastWordRect

        guard let page, let pdfPage = document.page(at: page) else {
            view.setCurrentSelection(nil, animate: false)
            clearPhraseAnnotations(context.coordinator)
            clearWordAnnotation(context.coordinator)
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastWordRect = nil
            context.coordinator.lastWordPage = nil
            context.coordinator.lastToken = revealToken
            return
        }
        if wordChanged {
            let wordOwnPage = wordPageIndex.flatMap { document.page(at: $0) } ?? pdfPage
            updateWordAnnotation(on: wordOwnPage, rect: wordRect, context.coordinator)
            if let word = wordRect, Self.shouldScrollToWord(
                follow: (follow && !scrollHold) || tokenChanged,
                wordVisible: view.convert(view.visibleRect, to: wordOwnPage).intersects(word)
            ) {
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: word, on: wordOwnPage)
            }
            context.coordinator.lastWordRect = wordRect
            context.coordinator.lastWordPage = wordPageIndex
        }
        guard !rects.isEmpty else {
            clearPhraseAnnotations(context.coordinator)
            view.setCurrentSelection(nil, animate: false)
            if (follow && !scrollHold) || tokenChanged {
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: pdfPage)
            }
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastToken = revealToken
            return
        }
        if phraseChanged {
            clearPhraseAnnotations(context.coordinator)
            view.setCurrentSelection(nil, animate: false)
            for box in rects {
                let annot = PDFAnnotation(
                    bounds: box, forType: .highlight, withProperties: nil)
                annot.color = NSColor.controlAccentColor.withAlphaComponent(0.28)
                pdfPage.addAnnotation(annot)
                context.coordinator.phraseAnnotations.append(annot)
            }
            context.coordinator.phrasePage = pdfPage
            if (follow && !scrollHold) || tokenChanged {
                let box = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: box, on: pdfPage)
            }
            context.coordinator.lastPhraseKey = phraseKey
            context.coordinator.lastToken = revealToken
        }
    }

    /// Removes the sentence's live annotations, if any; without it the old highlight
    /// would be orphaned in the document (which the app never saves).
    private func clearPhraseAnnotations(_ coordinator: Coordinator) {
        if let page = coordinator.phrasePage {
            for annot in coordinator.phraseAnnotations {
                page.removeAnnotation(annot)
            }
        }
        coordinator.phraseAnnotations = []
        coordinator.phrasePage = nil
    }

    /// Removes the word's live annotation, if any; without it the old highlight
    /// would be orphaned in the document (which the app never saves).
    private func clearWordAnnotation(_ coordinator: Coordinator) {
        if let annot = coordinator.wordAnnotation,
           let page = coordinator.wordPage {
            page.removeAnnotation(annot)
        }
        coordinator.wordAnnotation = nil
        coordinator.wordPage = nil
    }

    /// Swaps the word's annotation: removes the previous one before adding the
    /// new one; same page and same bounds reuse the live one (avoids flicker
    /// when only the token changed).
    private func updateWordAnnotation(
        on pdfPage: PDFPage, rect: CGRect?, _ coordinator: Coordinator
    ) {
        guard let rect else {
            clearWordAnnotation(coordinator)
            return
        }
        if coordinator.wordPage === pdfPage,
           let annot = coordinator.wordAnnotation,
           annot.bounds == rect {
            return
        }
        clearWordAnnotation(coordinator)
        let annot = PDFAnnotation(
            bounds: rect, forType: .highlight, withProperties: nil)
        annot.color = NSColor.systemYellow.withAlphaComponent(0.55)
        pdfPage.addAnnotation(annot)
        coordinator.wordAnnotation = annot
        coordinator.wordPage = pdfPage
    }

    /// Dedup key of the SENTENCE: page + boxes (without the word — the
    /// word has its own key in the Coordinator).
    private func key(page: Int?, rects: [CGRect]) -> String {
        guard let page else { return "nil" }
        let boxes = rects.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }
            .joined(separator: ";")
        return "\(page)|\(boxes)"
    }
}
