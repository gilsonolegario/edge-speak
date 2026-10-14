import CoreGraphics
import Vision

/// On-device OCR fallback for scanned pages (no text layer).
///
/// Fail-closed: throws on any miss and the caller keeps whatever the text
/// layer gave (possibly nothing). New file on purpose: the import pipeline
/// lives across Python and Swift files owned by other lanes, so the engine
/// lands isolated and the wiring follows them.
enum PageOCR {
    /// A page whose text layer yields fewer letters than this is a scan
    /// candidate (planning hypothesis: 40 letters ≈ two lines of prose;
    /// a watermark alone stays below it).
    static let minLetters = 40

    /// Pure gate, covered by tests without the Vision stack.
    static func needsOCR(pageText: String) -> Bool {
        pageText.trimmingCharacters(in: .whitespacesAndNewlines).count < minLetters
    }

    /// Recognizes the page image, best line first, joined by newline.
    /// Synchronous and off-main by contract: accurate recognition of a full
    /// page takes on the order of a second; the caller dispatches.
    static func recognize(_ image: CGImage, languages: [String] = ["en", "pt"]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
