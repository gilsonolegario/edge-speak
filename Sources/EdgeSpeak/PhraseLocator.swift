import CoreGraphics
import Foundation

/// Locates the reading sentence closest to a point clicked in the PDF.
///
/// Phrase navigation idea inspired by PDFVoice (MIT): containment wins,
/// else the nearest rectangle, else nothing (margin). Only the idea — no
/// third-party code (see CREDITS.md).
enum PhraseLocator {
    /// Maximum distance from the point to the rectangle for a jump to count (pt).
    static let maxDistance: CGFloat = 40

    /// Global index of the clicked sentence, or nil when the point falls in the margin.
    ///
    /// Same page; the rect that CONTAINS the point wins; else the nearest
    /// rect up to `maxDistance`; sentences without rects are ignored.
    static func phraseIndex(
        near point: CGPoint, on page: Int, among phrases: [TextImport.Phrase]
    ) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for phrase in phrases {
            guard phrase.page == page, !phrase.rects.isEmpty else { continue }
            for rect in phrase.rects {
                if rect.contains(point) { return phrase.index }
                let d = distance(from: point, to: rect)
                if d <= maxDistance, best == nil || d < best!.distance {
                    best = (phrase.index, d)
                }
            }
        }
        return best?.index
    }

    /// Point→rectangle Euclidean distance (0 when inside).
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
