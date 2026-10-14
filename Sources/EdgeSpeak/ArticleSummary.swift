import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device summary of the reading passage (macOS 26+, Apple Intelligence).
///
/// Fail-closed: nil when the model is missing, disabled, or errors — reading
/// never depends on it. New file on purpose: the UI lanes own ContentView and
/// SettingsView, so the engine lands isolated and the wiring follows them.
enum ArticleSummary {
    /// Max input characters: the opening pages carry the thesis; beyond this
    /// the prompt cost grows without better summaries (planning hypothesis).
    static let maxInputChars = 3_000

    /// Deterministic prompt builder (pure; covered by tests without the model).
    static func prompt(for text: String) -> String {
        "Summarize the following academic passage in up to three sentences, in the passage's language:\n\n"
            + clipped(text)
    }

    /// Cuts at the last full stop inside the budget; falls back to the raw
    /// prefix when the passage has no sentence boundary there.
    static func clipped(_ text: String) -> String {
        guard text.count > maxInputChars else { return text }
        let prefix = text.prefix(maxInputChars)
        if let last = prefix.lastIndex(of: ".") {
            return String(prefix[...last])
        }
        return String(prefix)
    }

    #if canImport(FoundationModels)
    /// Nil on any miss (empty text, model unavailable, any error).
    /// macOS 26+ only; older systems link the framework weak (Package.swift)
    /// and never reach this body.
    @available(macOS 26, *)
    static func summarize(text: String) async -> String? {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(
                instructions: "You summarize academic passages briefly and plainly.")
            let response = try await session.respond(to: prompt(for: plain))
            let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        } catch {
            return nil
        }
    }
    #endif
}
