import Foundation

/// Skips DOIs and page numbers but KEEPS citations unwrapped (academic request):
/// "(Smith, 2020)" is spoken as "Smith, 2020" — the reference matters, the
/// brackets do not. Toggleable via Settings (key below; the switch itself
/// lands with the UI lanes, which own `SettingsView.swift`).
///
/// Pure string filter, no engine dependency: the reading pipeline applies it
/// after footnote resolution. New file on purpose: `ReadAloudFilter.swift`
/// belongs to another lane, so the rule lands isolated and the wiring follows it.
enum CitationSkip {
    /// Persisted toggle. Lives here (not in `AppSetting`) only until the lanes
    /// land; the key name is stable so the future switch binds without migration.
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
    static func stripDOI(_ text: String) -> String {
        var out = replacing(text, pattern: #"https?://\S*10\.[0-9]{4,}/\S+"#)
        out = replacing(out, pattern: #"(?:doi:\s*)?10\.[0-9]{4,}/\S+"#)
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
