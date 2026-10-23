import Foundation

/// Skips DOIs and page numbers but KEEPS citations unwrapped (academic request):
/// "(Smith, 2020)" is spoken as "Smith, 2020" — the reference matters, the
/// brackets do not. Toggleable in Settings (`settings.citations`, default on).
///
/// Pure string filter, no engine dependency: `speechText` welds it to the
/// `ReadAloudFilter` output of the reading pipeline, after footnote
/// resolution. Off means no-op: the engines speak exactly what they spoke
/// before. Display stays untouched — `clean` exhibits, `forSpeech` expands.
enum CitationSkip {
    /// Persisted toggle. Lives here (not in `AppSetting`) so the filter and the
    /// switch share one name; the key is stable, so it binds without migration.
    static let settingKey = "citationUnwrap"
    static let defaultOn = true

    /// Reads the toggle; true when never set.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? defaultOn
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: settingKey)
    }
    private static func replacing(_ text: String, pattern: String, template: String = " ") -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// "[12]" → "12": digits, commas, spaces and dashes only,
    /// so "[see Fig. 2]" survives untouched.
    static func unwrapBrackets(_ text: String) -> String {
        replacing(text, pattern: #"\[([0-9][0-9,\s;–\-]*)\]"#, template: "$1")
    }

    /// "(Smith, 2020)" → "Smith, 2020", "(Avery et al., 1944, 155)" kept too.
    /// Plain parentheticals ("(in 2020 we saw)") survive with their parens.
    static func unwrapAuthorYear(_ text: String) -> String {
        replacing(
            text,
            pattern: #"\(([A-Z][A-Za-z\-]+(?: et al\.)?, [0-9]{4}[a-z]?(?:, [0-9]+(?:[–\-][0-9]+)?)*)\)"#,
            template: "$1")
    }

    /// DOI strings with or without the "doi:" prefix.
    ///
    /// The closing class keeps the pattern from eating the punctuation that
    /// follows the DOI: with a bare `\S+`, "10.1234/abc-def," swallowed the
    /// comma and — worse — a DOI closing a sentence swallowed the period, so
    /// that sentence never split.
    static func stripDOI(_ text: String) -> String {
        var out = replacing(text, pattern: #"https?://\S*10\.[0-9]{4,}/\S*[^\s.,;:)\]}"']"#)
        out = replacing(out, pattern: #"(?:doi:\s*)?10\.[0-9]{4,}/\S*[^\s.,;:)\]}"']"#)
        return out
    }

    /// Lines holding only a page number ("123").
    static func stripPageNumberLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .range(of: #"^[0-9]{1,4}$"#, options: .regularExpression) != nil ? "" : String(line)
            }
            .joined(separator: "\n")
    }

    /// Welded speech text for the engines: the adaptation `ReadAloudFilter`
    /// already produced, with the citation pass on top when the toggle is on.
    /// The three call sites of the speech path (EdgeTTS streaming, EdgeTTS
    /// line file, PiperTTS) go through here, so the weld has one name — and
    /// `CitationSkipTests.speechWeld*` goes red if the pass leaves the
    /// composition.
    static func speechText(
        _ raw: String, voice: String, readFootnotes: Bool = true, marker: Int? = nil
    ) -> String {
        speechText(
            raw, voice: voice, readFootnotes: readFootnotes, marker: marker,
            unwrapping: isEnabled)
    }

    /// Flag variant of the weld, mirroring `forSpeech`: keeps tests off global
    /// state and off the real preferences.
    static func speechText(
        _ raw: String, voice: String, readFootnotes: Bool = true, marker: Int? = nil,
        unwrapping: Bool
    ) -> String {
        let spoken = ReadAloudFilter.forSpeech(
            raw, voice: voice, readFootnotes: readFootnotes, marker: marker)
        // A flag segue explícita no passe final: a versão de um argumento de
        // `forSpeech` relê `isEnabled` e fazia esta variante depender do toggle
        // global — a falha intermitente de 2026-10-17/18.
        return unwrapping ? forSpeech(spoken, unwrapping: true) : spoken
    }

    /// Full pass for speech: citations unwrapped when enabled, DOIs and page
    /// numbers always out. The flag variant keeps tests off global state.
    static func forSpeech(_ text: String) -> String {
        forSpeech(text, unwrapping: isEnabled)
    }

    static func forSpeech(_ text: String, unwrapping: Bool) -> String {
        var out = stripPageNumberLines(text)
        if unwrapping {
            out = unwrapBrackets(out)
            out = unwrapAuthorYear(out)
        }
        out = stripDOI(out)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
