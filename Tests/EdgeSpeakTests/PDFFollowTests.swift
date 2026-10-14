import CoreGraphics
import Testing

@testable import EdgeSpeak

/// Proof of the "manual scroll wins" rule: only an origin change with everything
/// else still and outside the `go(to:)` window counts as the user; a visible word
/// never scrolls by itself.
struct PDFFollowTests {
    private let origin = CGPoint(x: 0, y: 100)
    private let size = CGSize(width: 600, height: 800)

    /// Only origin changed, follow on, no recent `go(to:)`: that is the user.
    @Test func userScrollDetected() {
        #expect(PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1))
    }

    /// Right after the app's `go(to:)` the origin changes by itself: not the user.
    @Test func programmaticScrollNotDetected() {
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: true,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1))
    }

    /// Follow already off: no origin change raises a notice.
    @Test func disabledFollowIsUnaffected() {
        #expect(!PDFDocumentView.isUserScroll(
            follow: false, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1))
    }

    /// Zoom (scale changes) and resize (size changes) do not turn it off,
    /// even when the origin shifts along.
    @Test func zoomAndResizeDoNotDisable() {
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1.5))
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: origin,
            oldSize: size, newSize: CGSize(width: 700, height: 800),
            oldScale: 1, newScale: 1))
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: CGSize(width: 700, height: 800),
            oldScale: 1, newScale: 1))
    }

    /// A visible word does not scroll; out of view with follow it scrolls; without follow
    /// it never scrolls by itself.
    @Test func visibleWordDoesNotScroll() {
        #expect(!PDFDocumentView.shouldScrollToWord(follow: true, wordVisible: true))
        #expect(PDFDocumentView.shouldScrollToWord(follow: true, wordVisible: false))
        #expect(!PDFDocumentView.shouldScrollToWord(follow: false, wordVisible: false))
    }
}
