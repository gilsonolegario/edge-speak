import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device summary of the CURRENT reading stretch (macOS 26+, Apple
/// Intelligence).
///
/// Fail-closed: nil when the model is missing, disabled, or errors — reading
/// never depends on it. Wired to the menu: `Summarize Current Passage` (⌘⇧M)
/// posts `.edgeSpeakSummarize`, `ContentView` resolves the window around the
/// reading position (`excerpt`) and shows the result in a sheet; `isAvailable`
/// separates "this Mac cannot" from "the model failed" without either case
/// touching the reading.
enum ArticleSummary {
    /// Max input characters: a window ceiling, not a prefix. The summary is
    /// about the CURRENT stretch (see `excerpt`), so the budget bounds the whole
    /// window — enough for the reading sentence and its neighbourhood (~a page),
    /// beyond which the prompt cost grows without better summaries.
    static let maxInputChars = 3_000

    /// Sentences of context kept BEFORE the reading position: enough for the
    /// deictic references of the moment ("this claim", "the argument above") to
    /// still resolve, and few enough that the summary stays about the stretch
    /// instead of the previous page.
    static let excerptContextBefore = 2

    /// The passage the summary is about: the window that starts at the reading
    /// position, never the document's opening (menu ⌘⇧M promised "the passage"
    /// and used to deliver the first `maxInputChars` of the file).
    ///
    /// Starts `contextBefore` sentences before `position`, grows forward on
    /// whole sentences while the character budget allows, and is clamped to the
    /// list's bounds. Context never costs the current sentence: if the budget
    /// runs out among the context, the window restarts at the position itself.
    /// An empty list yields an empty excerpt; callers treat that as "nothing to
    /// summarize". Pure, so the window is covered by tests without the model.
    static func excerpt(
        sentences: [String],
        at position: Int,
        contextBefore: Int = excerptContextBefore,
        maxChars: Int = maxInputChars
    ) -> String {
        let list = sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !list.isEmpty else { return "" }
        let current = min(max(position, 0), list.count - 1)
        let start = max(0, current - max(contextBefore, 0))

        var picked: [Int] = []
        var used = 0
        var i = start
        while i < list.count {
            defer { i += 1 }
            guard !list[i].isEmpty else { continue }
            let cost = list[i].count + (picked.isEmpty ? 0 : 1)
            if used + cost > maxChars {
                // A single sentence longer than the budget still gets in, clipped:
                // dropping it would summarize someone else's stretch.
                if picked.isEmpty { picked.append(i) }
                break
            }
            picked.append(i)
            used += cost
        }

        if !picked.contains(current), start < current {
            return excerpt(sentences: sentences, at: current, contextBefore: 0, maxChars: maxChars)
        }
        let joined = picked.map { list[$0] }.joined(separator: " ")
        return clipped(joined)
    }

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

    /// Can this Mac summarize? False below macOS 26 and whenever Apple
    /// Intelligence is off or the model has not been downloaded. Non-gated on
    /// purpose: the UI calls it from a macOS 14 target and must be able to tell
    /// "this Mac cannot" from "the model failed".
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return modelAvailable }
        #endif
        return false
    }

    /// Non-gated entry point for the UI: a summary, or nil when there is no
    /// model or the model fails (fail-closed; the reading never depends on it).
    static func summarizeIfAvailable(text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return await summarize(text: text) }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Nil on any miss (empty text, model unavailable, any error).
    /// macOS 26+ only; older systems link the framework weak (Package.swift)
    /// and never reach this body.
    @available(macOS 26, *)
    static func summarize(text: String) async -> String? {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        guard modelAvailable else { return nil }
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
