import Foundation

/// Removes from the text the parts that should not be read aloud.
///
/// Why it exists: PDFs and Markdown carry a lot of material that is citation,
/// notation or markup. Reading "see Figure 3, p. 47" or "cf. [12], p. 210" aloud
/// is noise; the essential is to read the argument, not the apparatus.
///
/// The filter never invents text: when it removes a passage, it leaves a space
/// so the next sentence still makes sense in the reading.
enum ReadAloudFilter {

    /// Patterns of discarded passages, in checking order.
    ///
    /// Each entry is (regex, replacement). They are checked in sequence
    /// on text already treated by the previous steps.
    private static let rules: [(pattern: String, template: String)] = [
        // Note calls glued to the text: "disso¹²", "hipótese¹", "6–7).²¹".
        // Catches the Unicode index right after any character (including
        // parenthesis and period), which is where the call usually sits.
        (#"[⁰¹²³⁴⁵⁶⁷⁸⁹²³¹]+"#, ""),
        // Notes in brackets at the end of a passage: "anterior [12]."
        (#"[\s,;]*\[[\d\s,e;–-]{1,20}\]"#, ""),
        // Footnotes and calls: "^1 Text..." or loose markers.
        (#"^\s*\[\d+\]\s*"#, ""),
        // "nota 3", "notas 1 e 2", "cf. nota 2"
        (#"(?i)\b(nota|notas)\s+\d+([\s,e]+\d+)*\b[.,;:]?"#, ""),
        // Pagination inside parentheses: "(Carnap, 1934, p. 210)".
        // It comes before loose pagination on purpose: if the loose one runs first,
        // it consumes "p. 210" and leaves an orphan ")" in the middle of the text.
        (#"(?i)\(\s*[^()]{0,60}?(p|pp?\.|pág\.|página)s?\s*\d+([\s–—-]+\d+)*\s*\)"#, ""),
        // Loose pagination: "p. 47", "pp. 12-15", "Figura 3, p. 47."
        // Consumes the PREPOSITION before the notation ("The proof is on
        // p. 47 of the book" — without it a naked "on" was left, read
        // "on of the book") — same shape as the "da/do/em §" rule that
        // stripPDFArtifacts already has.
        (#"(?i)(?:\b(?:da|do|das|dos|na|no|nas|nos|em|on|in|at|of)\s+)?[,\s]*\b(pp?\.|pág\.|página)s?\s*\d+([\s–—-]+\d+)*\b[.,;:]?"#, ""),
        // Cross-references: "Cf. Seção 4.2", "ver cap. 3", "Figura 3:".
        // The prefix is only removed when it is an isolated word followed by PERIOD or
        // space: without the period, "veremos" (ver + emos) would be cut and the text
        // would lose words — which is what happened in the first version.
        (#"(?i)(?<![A-Za-zÀ-ÿ])cf\.(?=\s|$)"#, ""),
        (#"(?i)(?<![A-Za-zÀ-ÿ])vide\b(?=\s+[A-Za-zÀ-ÿ])"#, ""),
        (#"(?i)(?<![A-Za-zÀ-ÿ])ver(?=\s+(cap\.|capítulo|seção|figura|tabela|gráfico|item|itens|p\.|pp\.))"#, ""),
        (#"(?i)(?<![A-Za-zÀ-ÿ])conforme\s+(o\s+|a\s+)?(cap\.|capítulo|seção|figura|tabela)"#, ""),
        // Cross-reference requires the number: "Seção 4.2", "cap. 3", "Figura 3".
        // The TITLE stays out on purpose — "Chapter 21" is content, not a
        // cross-reference, and removing it made the reading lose information.
        (#"(?i)\b(seção|seções|secção|secções|cap\.|caps\.|capítulo|capítulos)\s*[\dIVX]+([\.\d]*)\b[.:–—-]?"#, ""),
        (#"(?i)\b(figure|figura|tabela|table|gráfico|grafico|quadro|imagem)\s*\d+\s*[.:–—-]?"#, ""),
        // Section numbering with a period at line start: "1. What Is...".
        // Without the period (e.g. "1 Introduction") it stays as is: the rule without the
        // period removed the "9" of dates like "9 Oct 2026".
        (#"(?m)^\s*\d{1,2}\.\s+(?=[A-Z])"#, ""),
        // Footnote paragraph, which the PDF interleaves into the body:
        // "Footnote 19. Van Fraassen argued...". It is apparatus; it must not be read.
        (#"(?m)^\s*Footnote\s+\d+[.:]?.*$"#, ""),
        // "ibid.", "op. cit.", "loco cit.". Also consumes the period
        // and the following space: without it an orphan "." remains after the name
        // ("(Avery . 1944") and the citation rule no longer matches.
        // "et al." stays: citations are kept unwrapped (owner choice), and the
        // sentence splitter does not break on "al.,".
        (#"(?i)\b(?:ibid|op\.?\s*cit|loco\s+cit)\.?\s*"#, ""),
        // "(nota 4)", "[nota 5]", "(*)"
        (#"\(\s*(note|\*|\d{1,2})\s*\)"#, ""),
        (#"\*\s*\)"#, ""),
        // Loose asterisk of a note call: "* Feigl (1956)". Removes only the
        // marker: the rest of the note is content and stays for the bibliography
        // block to handle.
        (#"(?m)^\s*\*+\s*"#, ""),
        // Sections by symbol: "§4", "§ 4.2", "§§ 3-5".
        (#"§{1,2}\s*[\d]+([\.\d]*)?([\s–—-]+[\d]+)*"#, ""),
        // Print pagination: "Page 3 of 33", "Página 3 de 33".
        (#"(?m)^\s*(?:Page|Página)\s+\d+\s+(?:of|de)\s+\d+\s*$"#, ""),
        // Browser print footer: "about:srcdoc", "about:blank".
        (#"(?m)^\s*about:\S*\s*$"#, ""),
        // Print header with date and time: "10/10/26, 01:17".
        (#"(?m)^\s*\d{1,2}/\d{1,2}/\d{2,4}[,.]?\s*\d{1,2}:\d{2}(?::\d{2})?\s*$"#, ""),
        // Author-year citation in parentheses: "(Carnap 1974, 256)",
        // "(Avery et al. 1944, 155)", "(Creath 1985, 122)" — with or without author.
        // Requires the 4-digit year; without it it does nothing, so as not to eat a
        // content parenthesis. UNWRAPS (keeps "Carnap 1974, 256"): citations are
        // content by owner choice — only the parens go.
        (#"(?i)\(\s*((?:[A-ZÀ-Þ][\p{L}'’.\-]+(?:[ \t]*(?:,|and|&|e)[ \t]*[A-ZÀ-Þ][\p{L}'’.\-]+|[ \t]+et[ \t]+al\.?)*,?[ \t]*)?\d{4}[a-z]?(?:[ \t]*,[ \t]*[\d–—\-]+)*)\s*\)"#, "$1"),
        // Page-only citation in parentheses: "(259)".
        (#"\(\s*\d{1,3}\s*\)"#, ""),
        // Formula line: contains a logical/mathematical connective AND (has no
        // lowercase OR is at most 60 characters). The second condition is what
        // keeps prose that merely mentions symbols ("RHB = ∃X..." inside a 90+
        // letter sentence, measured 2026-10-13: the old rule erased the whole
        // note-4 passage in filtered mode). Short prose with a symbol
        // ("see ∃X here") still falls — rare and documented; the status quo
        // erased everything containing a symbol.
        (#"(?m)^[^a-zà-ÿ\n]*[∀∃∧∨¬→↔⊨⊢≡≢⊂⊆∈∑∫∂±×÷√≤≥∞][^a-zà-ÿ\n]*$|(?m)^(?=.{0,60}$).*[∀∃∧∨¬→↔⊨⊢≡≢⊂⊆∈∑∫∂±×÷√≤≥∞].*$"#, ""),
        // Note-number line: digits, spaces and punctuation ONLY ("7", "(3)",
        // "12.—"). The old class `[^a-zà-ÿ\n]` also ate a title without
        // lowercase ("RESULTADOS") and a short Cyrillic/Greek line.
        (#"(?m)^[\d\s\p{P}]{1,16}$"#, ""),
        // Formulas: removes the WHOLE term — operand, symbol and operand. Without
        // removing all three, "and P(v) = 0" remains and the reading makes no sense.
        // The operand is optionally parenthesized: "P(v)", "(a+b)", "42".
        (#"\b[A-Za-z]\w*\s*(?:\([A-Za-z0-9]+\))?\s*[=<>≤≥±×÷∑∫∂√]\s*(?:\([A-Za-z0-9]+\)|\d+(?:\.\d+)?|\w+)\b"#, ""),
        // Inline formulas: $...$ and \(...\)
        (#"\$[^$\n]{1,80}\$"#, ""),
        (#"\\\([^\\)]{1,80}\\\)"#, ""),
        // Loose URLs. The closing class keeps the pattern from eating the
        // punctuation that follows the link: with a bare `\S+`, a URL at the end
        // of a sentence swallowed the period and the sentence stopped closing
        // (the splitter needs the terminal punctuation).
        (#"https?://\S*[^\s.,;:)\]}"']|www\.\S*[^\s.,;:)\]}"']"#, ""),
    ]

    /// Words that mark the start of the bibliography (short label in the final half).
    private static let bibliographyKeywords = [
        "referencias bibliograficas", "referências bibliográficas",
        "bibliografia", "bibliography", "references", "works cited",
        "obras citadas", "leituras adicionais", "further reading",
    ]

    /// Index of the first text opening the bibliography, or nil.
    ///
    /// Same rule as the internal cut: short label (<= 60) in the final half.
    /// Serves the per-sentence pipeline, which needs to truncate before splitting.
    static func bibliographyStart(in texts: [String]) -> Int? {
        texts.firstIndex(where: { text in
            let l = text.trimmingCharacters(in: .whitespaces).lowercased()
            guard !l.isEmpty, l.count <= 60 else { return false }
            return bibliographyKeywords.contains { l.contains($0) }
        }).flatMap { $0 >= texts.count / 2 ? $0 : nil }
    }

    /// Applies the filter to the text.
    ///
    /// - Parameter mode: in PDFs, it also removes headers and footers
    ///   (page number, repeated title), which otherwise become useless speech.
    static func clean(_ text: String, isPDF: Bool = false) -> String {
        // NFKC normalization first: unifies compatibility variants
        // (full width, ligatures, superscripts) before any rule.
        var out = text.precomposedStringWithCompatibilityMapping

        // 0) Note calls in superscript: "beliefs.¹", "(314).⁴". It must
        //    run BEFORE the reflow: at line end the marker hides the
        //    punctuation and the next line (the footnote) ends up glued.
        out = out.replacingOccurrences(
            of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹²³¹]+"#, with: "", options: .regularExpression)

        // 0) PDF: fixes hyphenation and split pages BEFORE regrouping.
        //    The line break is the evidence of hyphenation; if the reflow runs
        //    first, it disappears and the hyphen stays glued mid-word.
        if isPDF { out = stripPDFArtifacts(out) }
        // Hyphen joins in ANY source (audit-leitura items 11-12): "argu-\nment"
        // in .txt/.md glued exactly like in PDF. Runs BEFORE the reflow, else
        // the line break disappears and the hyphen stays glued mid-word.
        out = joinLineHyphens(out)

        // 1) Regroups broken lines: the apparatus rules depend on
        //    seeing the whole sentence, else a note at the end of the printed line
        //    would stick to the next one.
        out = reflow(out)

        // 2) Passages that should not be read (citations, bibliography).
        out = stripQuotedBlocks(out)

        // 3) Apparatus rules (notes, pages, cross-references).
        for rule in rules {
            guard let re = try? NSRegularExpression(
                pattern: rule.pattern, options: [.anchorsMatchLines]
            ) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: rule.template)
        }

        // 3) Final cleanup: lines left with only punctuation and quotes.
        out = out
            .components(separatedBy: .newlines)
            .map { line -> String in
                let stripped = line.trimmingCharacters(in: .whitespaces)
                let withoutPunctuation = stripped.trimmingCharacters(
                    in: CharacterSet(charactersIn: ".,;:–—-()[]\"'“”…"))
                return withoutPunctuation.isEmpty && !stripped.isEmpty ? "" : line
            }
            .joined(separator: "\n")

        // 4) Double spaces, empty parentheses, orphan punctuation and empty lines.
        out = out.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([.,;:!?])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "([,;:])\\s*([.,;:!?])", with: "$2", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adapts a sentence for speech: expansions that `clean` does not make because
    /// they would change the displayed text. The highlight follows the original; only the
    /// synthesizer receives the adapted one. Includes logical notation ("R = ∃uT(u,o)"
    /// becomes "R equals there exists u such that T of u, o"), in the voice's language.
    /// - `readFootnotes`: with `false`, the note marker becomes a pause and the body
    ///   (outside the reading list) never reaches here. Default `true`.
    static func forSpeech(_ text: String, voice: String, readFootnotes: Bool = true, marker: Int? = nil) -> String {
        let pt = isPortugueseVoice(voice)
        // Blackboard-bold before NFKC: normalization merges "ℕ" with "N",
        // "ℤ" with "Z" etc., and the regex table would receive them already dead.
        // Literal replacement (no regex), in the voice's language.
        var out = text
        for (symbol, en, ptTemplate) in foldables {
            out = out.replacingOccurrences(of: symbol, with: pt ? ptTemplate : en)
        }
        out = out.precomposedStringWithCompatibilityMapping
        out = expandAbbreviations(out, portuguese: pt)
        // Years spelled out only in Portuguese (the list is PT); in English the engine
        // already reads "1944" as "nineteen forty-four" by itself.
        if pt { out = spellOutYears(out) }
        out = expandLogic(out, portuguese: pt)
        out = expandFootnoteMarkers(out, portuguese: pt, announce: readFootnotes, marker: marker)
        // The expansions can duplicate spaces and commas, or glue a comma
        // to the next symbol ("x,(W"). Order: first collapse, then space.
        out = out.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: ",\\s*\\.", with: ".", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: ",([^\\s\\d])", with: ", $1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Portuguese voice (code "pt" or the offline suffix "ptbr").
    static func isPortugueseVoice(_ voice: String) -> Bool {
        let v = voice.lowercased()
        return v.hasPrefix("pt") || v.contains("ptbr") || v.contains("pt-br")
    }

    /// Footnote marker glued to the text ("argumento.7", "ideia,2",
    /// "hipótese12"): becomes "nota de rodapé 7"/"footnote 7" in the voice's language.
    ///
    /// Why textual here: `clean` already removes the Unicode superscript before
    /// splitting the sentences, so what reaches `forSpeech` is the ASCII
    /// digit glued (NFKC also merges "texto⁷" into "texto7"). Geometry
    /// (small elevated digit in `Phrase.WordBox` boxes) would distinguish
    /// glued better from "mp3", but `forSpeech` only receives text and voice —
    /// passing the boxes would require touching the callers (out of scope of
    /// phase 1). When in doubt between announcing and staying silent, this rule SILENCES: the glued
    /// 1-digit run ("voz1", "mp3") stays as is; only a 2-digit glued run
    /// in a word of 3+ lowercase letters becomes an announcement ("palavra12").
    /// 1–2 digits (never 4, so as not to bite the years
    /// 1500–2100 that `spellOutYears` handles) and the following digit cannot
    /// be a letter, digit or period (protects "3.14", "3,14", "4.2.1" and "7z").
    /// Period and comma require a letter or closing before (they protect "9 Oct",
    /// "Figura 7" and "1." at line start); "3 x 4" has no period nor
    /// glued digit and passes intact. The TEXTUAL glued run only announces
    /// with TWO digits ("palavra12") — one digit in a word of letters is an
    /// identifier ("version2", "mp3"), the third rule no longer announces
    /// it. The text comes from the `L` catalog ("speech.footnote"), single
    /// source in both languages.
    private static func expandFootnoteMarkers(_ text: String, portuguese pt: Bool, announce: Bool = true, marker: Int? = nil) -> String {
        // No announcement (option off): the marker becomes a short pause, so the
        // sentence runs without promising any note.
        if !announce {
            var silenced = text
            for pattern in [
                #"(?<=[A-Za-zÀ-ÿ\)\]"'”’])\.(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#,
                #"(?<=[A-Za-zÀ-ÿ\)\]"'”’]),(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#,
                #"([A-Za-zÀ-ÿ]{2,}[a-zà-ÿ])(\d{2})(?![\dA-Za-zÀ-ÿ.])"#,
            ] {
                guard let re = Self.regex(pattern) else { continue }
                silenced = re.stringByReplacingMatches(
                    in: silenced, options: [],
                    range: NSRange(silenced.startIndex..., in: silenced),
                    withTemplate: ",")
            }
            return silenced
        }
        let template = L.get("speech.footnote", locale: pt ? .pt : .en)
        let marker1 = template.replacingOccurrences(of: "{0}", with: "$1")
        let marker2 = template.replacingOccurrences(of: "{0}", with: "$2")
        let pageRules: [(String, String)] = [
            // ".7" after a letter or closing: "argumento.7" (not "3.14", which has
            // a digit before, nor loose ".5", which has a space before).
            (#"(?<=[A-Za-zÀ-ÿ\)\]"'”’])\.(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#, ", \(marker1),"),
            // ",2" after a letter or closing: "ideia,2" (not "3,14", which has
            // a digit before).
            (#"(?<=[A-Za-zÀ-ÿ\)\]"'”’]),(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#, ", \(marker1),"),
            // 2-digit glued run in a word of 3+ lowercase letters:
            // "palavra12" (not "mp3"/"B2", short, nor "abc123", long).
            // ONE digit is never a note ("version2", "cap2" are identifiers);
            // the announcement promised two digits in the comment and the
            // rule stopped at one ("chapter12"/"version2" were both read
            // "chapter, footnote").
            (#"([A-Za-zÀ-ÿ]{2,}[a-zà-ÿ])(\d{2})(?![\dA-Za-zÀ-ÿ.])"#, "$1, \(marker2),"),
        ]
        var out = text
        for (pattern, replacement) in pageRules {
            guard let re = Self.regex(pattern) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: replacement)
        }
        // Pipeline marker without textual expansion: the digit came in a form
        // the regex silences ("mundo 7", "teoria7") — announce at the sentence
        // end, where the linked bodies begin. Without duplicating: if the
        // expansion above already announced this N, nothing to do.
        if announce, let m = marker {
            let announcement = template.replacingOccurrences(of: "{0}", with: "\(m)")
            if !out.localizedCaseInsensitiveContains(announcement) {
                out += ", \(announcement),"
            }
        }
        return out
    }

    /// Blackboard-bold sets, which NFKC merges with ASCII and hence leave
    /// in `forSpeech` before normalization (here there is no regex, only literal).
    private static let foldables: [(String, String, String)] = [
        ("ℕ", " the natural numbers ", " os números naturais "),
        ("ℤ", " the integers ", " os números inteiros "),
        ("ℚ", " the rational numbers ", " os números racionais "),
        ("ℝ", " the real numbers ", " os números reais "),
        ("ℂ", " the complex numbers ", " os números complexos "),
    ]

    /// Horseshoe (⊃): superset between sets, conditional between formulas.
    ///
    /// Tie-break of the researched table: near ∈/⊆/∪/∩/∅ (a 12-character
    /// window on both sides) it is a set; near ¬/∧/∨/⊢ it is a formula, which
    /// is also the default when there is no sign at all. It is heuristic by
    /// nature — the table says not to guess when in doubt, and the app's
    /// historical default was "implies".
    private static func resolveHorseshoe(_ text: String, portuguese pt: Bool) -> String {
        guard text.contains("⊃") else { return text }
        let markers = Set("∈∪∩∅⊆⊂⊇")
        let windowSize = 12
        let sup = pt ? " é superconjunto de " : " is a superset of "
        let cond = pt ? " implica " : " implies "
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "⊃" {
                let startIndex = max(0, i - windowSize)
                let endIndex = min(chars.count, i + windowSize + 1)
                let nearby = String(chars[startIndex..<endIndex])
                out += nearby.contains(where: markers.contains) ? sup : cond
                i += 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Set builder `{x | φ}` / `{x : φ}`: the brace opens as
    /// "o conjunto de"/"the set of", the bar, the colon and the ∋ become
    /// "tal que"/"such that", and the closing brace is SILENCE (end-of-
    /// enumeration pause). Only what has a "such that" marker inside the
    /// braces enters: without it, `{...}` is grouping (LaTeX, subscript) and becomes
    /// silence via the brace rule, not "the set of".
    private static func expandSetBuilder(_ text: String, portuguese pt: Bool) -> String {
        guard text.contains("{"), let re = Self.regex(#"\{([^{}]*)\}"#)
        else { return text }
        let setPrefix = pt ? "o conjunto de " : "the set of "
        // Pause on both sides: "o conjunto de x, tal que, …".
        let suchThat = pt ? ", tal que, " : ", such that, "
        var out = text
        // Back to front: the swaps at the end do not change the offsets at the start.
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let span = Range(m.range, in: out),
                  let content = Range(m.range(at: 1), in: out)
            else { continue }
            var inside = String(out[content])
            guard inside.contains(where: { "|:∶".contains($0) }) else { continue }
            for symbol in ["|", ":", "∋", "∶"] {
                inside = inside.replacingOccurrences(of: symbol, with: " \(suchThat) ")
            }
            out.replaceSubrange(span, with: setPrefix + inside + " ")
        }
        return out
    }

    /// Logical symbols spelled out, in the voice's language. Order matters: long
    /// forms before short ones ("∃!" before "∃", "∉" before "∈").
    private static func expandLogic(_ text: String, portuguese pt: Bool) -> String {
        // (default, EN model, PT model). "$1" is the captured group.
        var out = expandSetBuilder(text, portuguese: pt)
        out = resolveHorseshoe(out, portuguese: pt)
        let rules: [(String, String, String)] = [
            (#"∃!\s*([A-Za-z])"#, "there exists exactly one $1, such that,", "existe exatamente um $1, tal que,"),
            (#"∃\s*([A-Za-z])"#, "there exists $1, such that,", "existe $1, tal que,"),
            (#"∃"#, "there exists", "existe"),
            // Iota (℩x φ, Russell/PM definite description): read as the x such that.
            (#"℩\s*([A-Za-z])"#, "the $1, such that", "o $1, tal que"),
            (#"℩"#, " such that ", " tal que "),
            (#"∀\s*([A-Za-z])"#, "for all $1,", "para todo $1,"),
            (#"∀"#, "for all", "para todo"),
            (#"ε\s*([A-Za-z])"#, "epsilon $1,", "épsilon $1,"),
            (#"ε"#, "epsilon", "épsilon"),
            // Modal: only the proper symbols. ASCII "[]" and "<>" stay out
            // on purpose: a bracket already becomes a pause (and disappears as a citation in
            // clean) and "<>" is the ASCII "different" — reading either as
            // "possibly" would ruin common prose.
            (#"□"#, " necessarily ", " necessariamente "),
            (#"◇"#, " possibly ", " possivelmente "),
            // ⊢/⊨ require a short pause before and after (the voice needs to breathe between the
            // premises and the conclusion).
            (#"⊨"#, ", entails, ", ", acarreta, "),
            (#"\|="#, ", entails, ", ", acarreta, "),
            (#"⊢"#, ", proves, ", ", prova, "),
            (#"\|-"#, ", proves, ", ", prova, "),
            // Turn negations: ⊬ "does not prove", ⊭ "does not entail".
            (#"⊬"#, ", does not prove, ", ", não prova, "),
            (#"⊭"#, ", does not entail, ", ", não acarreta, "),
            (#"<->"#, ", if and only if, ", ", se e somente se, "),
            (#"⇔"#, ", if and only if, ", ", se e somente se, "),
            (#"↔"#, ", if and only if, ", ", se e somente se, "),
            (#"=>"#, " implies ", " implica "),
            (#"⇒"#, " implies ", " implica "),
            (#"->"#, " implies ", " implica "),
            (#"→"#, " implies ", " implica "),
            // Material implication: ⊇ (long) before ⊃ (short), by discipline.
            // ⊃ decides by context — see `resolveHorseshoe`; this is only the safety
            // net for whatever symbol remains.
            (#"⊇"#, " is a superset of ", " é superconjunto de "),
            (#"⊃"#, " implies ", " implica "),
            (#"∧"#, " and ", " e "),
            (#"∨"#, " or ", " ou "),
            (#"¬"#, " not ", " não "),
            (#"∪"#, " union ", " união "),
            (#"∩"#, " intersection ", " intersecção "),
            // Difference: ∖ (proper) is safe; the ASCII bar only counts between
            // operands, else LaTeX commands like "\(" would become "difference".
            (#"∖"#, " difference ", " diferença "),
            (#"(?<=[A-Za-z0-9\)\]])\s*\\\s*(?=[A-Za-z0-9\(\[])"#, " difference ", " diferença "),
            (#"∅"#, " the empty set ", " o conjunto vazio "),
            (#"℘"#, " power set ", " conjunto das partes "),
            // ℕ ℤ ℚ ℝ ℂ stay out of this table on purpose: they leave in
            // `forSpeech` before NFKC (see `foldaveis`).
            // Product: only the proper ×. The ASCII "x" (as in "3 x 4") stays
            // intact on purpose — it is a common letter in prose.
            (#"×"#, " times ", " vezes "),
            // ∴/∵ require a pause before (start of conclusion/justification).
            (#"∴"#, ", therefore ", ", portanto "),
            (#"∵"#, ", because ", ", porque "),
            (#"∉"#, " is not in ", " não pertence a "),
            (#"∈"#, " in ", " pertence a "),
            (#"⊆"#, " is a subset of ", " é subconjunto de "),
            (#"⊂"#, " is a proper subset of ", " é subconjunto próprio de "),
            // "≢" before "≡": the long form matches first, else the "≡"
            // inside "≢" would be read as asserted equivalence.
            (#"≢"#, " is not equivalent to ", " não é equivalente a "),
            (#"≡"#, " is equivalent to ", " é equivalente a "),
            (#"⊕"#, " xor ", " ou exclusivo "),
            (#"⊗"#, " tensor ", " tensor "),
            (#"≈"#, " is approximately equal to ", " é aproximadamente igual a "),
            (#"≃"#, " is asymptotically equal to ", " é assintoticamente igual a "),
            (#"∥"#, " is parallel to ", " é paralelo a "),
            // "∼" at the start (or after an opening parenthesis/comma) is negation
            // ("∼p" = "not p"); between terms it remains similarity. Without this
            // rule "∼p" came out "is similar to p", which is wrong.
            (#"(^|[^A-Za-z0-9\)\]\s]\s*)∼\s*"#, "$1not ", "$1não "),
            (#"∼"#, " is similar to ", " é semelhante a "),
            // ⊥/⊤: in PT, "falso"/"verdadeiro" (Brazilian class); EN keeps
            // bottom/top, also accepted in the English literature.
            (#"⊥"#, " bottom ", " falso "),
            (#"⊤"#, " top ", " verdadeiro "),
            // "&" is the ASCII conjunction: in prose (publishers, names) "and"/"e" is
            // always the right reading, so it covers without risk.
            (#"&"#, " and ", " e "),
            // "§2" is "seção 2"/"section 2".
            (#"§\s*(\d+)"#, " section $1 ", " seção $1 "),
            // Prime (p'): only when the letter stands alone as a token — this way
            // "it's", "O'Brien" and "students' rights" (apostrophe between letters)
            // do not become "line"/"prime".
            (#"(?:(?<=\s)|^)([A-Za-z])(['′])(?![\p{L}])"#, "$1 prime", "$1 linha"),
            // Quine corners (and Oxford brackets): fluent reading does not
            // verbalize the corner — it marks the mention with a pause and reads the content.
            (#"[⌜⟦]"#, ", ", ", "),
            (#"[⌝⟧]"#, "", ""),
            // Leftover brace (not a set builder): silence.
            (#"[{}]"#, "", ""),
            // ASCII comparison before the lone "=": "<=" and ">=" contain
            // "=", and the "=" lookaround already ignores them — without these rules the
            // reader would spell the pieces ("<", "=").
            (#"<="#, " is less than or equal to ", " é menor ou igual a "),
            (#">="#, " is greater than or equal to ", " é maior ou igual a "),
            (#"!="#, " is not equal to ", " é diferente de "),
            (#"<>"#, " is not equal to ", " é diferente de "),
            (#"/="#, " is not equal to ", " é diferente de "),
            // "~" is the ASCII negation (forallx lists ~ as a ¬ variant).
            (#"~"#, " not ", " não "),
            // "/" between letters in prose ("analytic/synthetic") reads "or"; with a
            // guard so as not to bite "and/or" (the guard comes AFTER the letter,
            // because the lookbehind evaluates before consuming it). Fractions
            // (digits) stay out.
            (#"([A-Za-z])(?<!\band)(?<!\bou)\s*/\s*([A-Za-z])"#, "$1 or $2", "$1 ou $2"),
            // "^" between letters/digits is superscript: silence (never
            // "circumflex"), the number continues and the voice goes on.
            (#"(?<=[A-Za-z0-9])\^(?=[A-Za-z0-9])"#, " ", " "),
            (#"(?<![=!<>])=(?![=])"#, " equals ", " é igual a "),
            (#"≠"#, " is not equal to ", " é diferente de "),
            (#"≤"#, " is less than or equal to ", " é menor ou igual a "),
            (#"≥"#, " is greater than or equal to ", " é maior ou igual a "),
            // Greeks by name, in both languages (EN "alpha", PT "alfa").
            // Uppercases included: NFKC does not merge Greek with Latin, so
            // "Α" (U+0391) never matches a common word written with "A".
            // The λ dot becomes a pause, never "dot": "λx.M" = "lambda x, M".
            (#"λ\s*([A-Za-z])\s*\."#, "lambda $1, ", "lambda $1, "),
            (#"λ"#, " lambda ", " lambda "),
            (#"Λ"#, " lambda ", " lambda "),
            (#"α"#, " alpha ", " alfa "),
            (#"Α"#, " alpha ", " alfa "),
            (#"β"#, " beta ", " beta "),
            (#"Β"#, " beta ", " beta "),
            (#"γ"#, " gamma ", " gama "),
            (#"Γ"#, " gamma ", " gama "),
            (#"δ"#, " delta ", " delta "),
            (#"Δ"#, " delta ", " delta "),
            (#"φ"#, " phi ", " fi "),
            (#"Φ"#, " phi ", " fi "),
            (#"ψ"#, " psi ", " psi "),
            (#"Ψ"#, " psi ", " psi "),
            (#"ω"#, " omega ", " ômega "),
            (#"Ω"#, " omega ", " ômega "),
            (#"μ"#, " mu ", " mi "),
            (#"Μ"#, " mu ", " mi "),
            (#"π"#, " pi ", " pi "),
            (#"Π"#, " pi ", " pi "),
            (#"σ"#, " sigma ", " sigma "),
            (#"Σ"#, " sigma ", " sigma "),
            (#"τ"#, " tau ", " tau "),
            (#"Τ"#, " tau ", " tau "),
            (#"θ"#, " theta ", " teta "),
            (#"Θ"#, " theta ", " teta "),
            // "T(u, o)" becomes "T of u, o": only a lone UPPERCASE is a functor, so
            // the common word "postulate(" does not become "of".
            (#"\b([A-Z])\(([^()]*)\)"#, "$1 of $2", "$1 de $2"),
            // "RH" becomes "R H" (names read letter by letter); the rest passes intact.
            // → movido para `spaceAcronyms` no fim: a regra por pares
            // soletrava palavras maiúsculas inteiras ("C A R N A P").
            // Subscript with a short name: "R_H" becomes "R H" (not "R underline H").
            // The space comes BEFORE the captured group: the "_" is only removed.
            // A loose "_" still becomes a space (bound variable).
            (#"(?<=[A-Z])_([A-Za-z])"#, " $1", " $1"),
            (#"_"#, " ", " "),
            // "Wx" becomes "W x" (bound variable); a common word has no such shape.
            (#"\b([A-Z])x\b"#, "$1 x", "$1 x"),
            // "A*" and "A∗" become "A star".
            (#"([A-Za-z])[*∗]"#, "$1 star", "$1 estrela"),
            // Brackets and the angle pair become a pause; the voice already respects parentheses.
            (#"[\[\]⟨⟩]"#, ",", ","),
        ]
        for (pattern, en, ptTemplate) in rules {
            guard let re = Self.regex(pattern) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: pt ? ptTemplate : en)
        }
        return spaceAcronyms(out)
    }

    /// Letter-by-letter reading of an acronym: "NASA" → "N A S A", limited to
    /// short siglas (2–5 letters) — a LONG all-caps word ("CARNAP",
    /// "AUFBAU") is a word, not a sigla, and the old rule pairwise spell-spelled
    /// the whole title. A SEQUENCE of 3+ tokens all in caps ("CARNAP AND
    /// THE AUFBAU") is a title in caps: stays whole.
    private static func spaceAcronyms(_ text: String) -> String {
        if let title = Self.regex(
            #"(?:^|[\s,;:-])\p{Lu}{2,}(?:[-\s,;:]+\p{Lu}{2,}){2,}(?=$|[-\s,;:.])"#
        ), title.firstMatch(
            in: text, options: [], range: NSRange(text.startIndex..., in: text)
        ) != nil {
            return text
        }
        guard let re = Self.regex(#"\p{Lu}+"#) else { return text }
        var out = text
        for m in re.matches(
            in: text, options: [],
            range: NSRange(text.startIndex..., in: text)
        ).reversed() {
            guard let span = Range(m.range, in: out) else { continue }
            let run = String(out[span])
            guard run.count >= 2, run.count <= 5 else { continue }
            out.replaceSubrange(span, with: run.map { String($0) }.joined(separator: " "))
        }
        return out
    }

    /// Compiled cache of the filter's regexes: the patterns repeat at every
    /// phrase and `forSpeech` runs twice per phrase (audio + published list);
    /// recompiling dozens of `NSRegularExpression` per phrase was measurable work
    /// at synthesis time. Same behavior: a pattern that does not compile stays nil.
    private static let regexCacheLock = NSLock()
    private static var regexCache: [String: NSRegularExpression?] = [:]
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        if let cached = regexCache[pattern] { regexCacheLock.unlock(); return cached }
        regexCacheLock.unlock()
        let compiled = try? NSRegularExpression(pattern: pattern)
        regexCacheLock.lock()
        regexCache[pattern] = compiled
        regexCacheLock.unlock()
        return compiled
    }

    /// Common abbreviations spelled out (only the safe ones, with a final period).
    /// Each entry carries the reading for each voice language — the single
    /// table read "senhorita" and "etcétera" in an ENGLISH voice (item 7 of
    /// wave 1); `nil` in EN leaves the entry to the engine itself, which
    /// already reads "Dr." as "doctor".
    private static let abbreviations: [(pattern: String, en: String?, pt: String)] = [
        (#"(?i)\bSrta\."#, nil, "senhorita"),
        (#"(?i)\bSra\."#, nil, "senhora"),
        (#"(?i)\bSr\."#, nil, "senhor"),
        (#"(?i)\bDra\."#, nil, "doutora"),
        (#"(?i)\bDr\."#, nil, "doutor"),
        (#"(?i)\bProfa\."#, nil, "professora"),
        (#"(?i)\bProf\."#, nil, "professor"),
        (#"(?i)\bAv\."#, nil, "avenida"),
        (#"(?i)\bnº\.?"#, "number", "número"),
        (#"(?i)\bart\."#, nil, "artigo"),
        (#"(?i)\bp\.\s*ex\."#, nil, "por exemplo"),
        (#"(?i)\betc\."#, "et cetera", "etcétera"),
        // "p."/"pp." with a number are page notation: the integral went by
        // reading "pê ponto quarenta e sete"; the filtered one already
        // consumes the notation (see `rules`). "pp." first, or the "p."
        // rule would eat its tail.
        (#"(?i)\bpp\.(?=\s*\d)"#, "pages", "páginas"),
        (#"(?i)\bp\.(?=\s*\d)"#, "page", "página"),
        // Latin siglas that the integral read raw ("i. e" letter by letter).
        (#"(?i)\be\.g\."#, "for example", "por exemplo"),
        (#"(?i)\bi\.e\."#, "that is", "isto é"),
        (#"(?i)\bcf\."#, "compare", "conferir"),
        // "et al." stays in the TEXT (cit unwrapped, owner choice) — here it
        // is just read the natural way, as spoken.
        (#"(?i)\bet\s+al\.?"#, "and others", "e outros"),
        (#"(?i)\bibid\.?"#, "same source", "mesma fonte"),
    ]

    private static func expandAbbreviations(_ text: String, portuguese pt: Bool) -> String {
        var out = text
        for (pattern, en, ptTemplate) in abbreviations {
            guard let spoken = pt ? ptTemplate : en else { continue }
            guard let re = Self.regex(pattern) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: spoken)
        }
        return out
    }

    /// Years 1500–2100 spelled out ("1998" becomes "mil novecentos e noventa
    /// e oito"). Only the isolated numeral; out of the range it stays as is.
    /// With DATE context only ("em 1994", "de 1998 a 2004", "1944 d.C."):
    /// a bare numeral is a quantity ("run 1900 iterations" read the natural
    /// "mil e novecentos" from the engine) — spelling every 1500–2100 made
    /// the highlight crawl over years-read-as-counts and quantities lost
    /// their natural reading.
    static func spellOutYears(_ text: String) -> String {
        guard let re = Self.regex(#"\b(1[5-9]\d{2}|20\d{2}|2100)\b"#) else {
            return text
        }
        // Back to front: the swaps at the end do not change the offsets at the start.
        var out = text
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for m in matches {
            guard let numeral = Range(m.range(at: 1), in: text),
                  let year = Int(text[numeral]),
                  let spelledOut = numberSpelledOut(year),
                  let target = Range(m.range, in: out),
                  hasDateContext(text, match: m.range)
            else { continue }
            out.replaceSubrange(target, with: spelledOut)
        }
        return out
    }

    /// Date context for `spellOutYears`: a date preposition closes on the
    /// numeral ("em/de/ano/in/since", also "a" of the "de 1998 a 2004"
    /// range) or the era "a.C."/"d.C." right before or after the numeral.
    /// Only a text window: the 16 characters of the modulus cover
    /// "…outubro de " and "desde ". Without context, it does not spell out.
    private static func hasDateContext(_ text: String, match: NSRange) -> Bool {
        let ns = text as NSString
        let prefix = ns.substring(
            to: max(0, min(match.location, ns.length))
        ).suffix(16)
        let suffix = ns.substring(
            from: max(0, min(match.location + match.length, ns.length))
        ).prefix(6)
        let nsPrefix = String(prefix) as NSString
        let preposition = Self.regex(#"(?i)\b(?:em|de|ano|in|since|a)\s+$"#)
        let era = Self.regex(#"(?i)\b[ad]\.?\s*c\.?\s*$"#)
        if (preposition?.firstMatch(in: String(prefix), range: NSRange(location: 0, length: nsPrefix.length)) != nil)
            || (era?.firstMatch(in: String(prefix), range: NSRange(location: 0, length: nsPrefix.length)) != nil) {
            return true
        }
        let nsSuffix = String(suffix) as NSString
        let eraAfter = Self.regex(#"(?i)^\s*[ad]\.?\s*c\.?"#)
        return eraAfter?.firstMatch(in: String(suffix), range: NSRange(location: 0, length: nsSuffix.length)) != nil
    }

    private static let ones = ["", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove"]
    private static let tenToNineteen = ["dez", "onze", "doze", "treze", "catorze", "quinze", "dezesseis", "dezessete", "dezoito", "dezenove"]
    private static let tens = ["", "", "vinte", "trinta", "quarenta", "cinquenta", "sessenta", "setenta", "oitenta", "noventa"]
    private static let hundreds = ["", "cento", "duzentos", "trezentos", "quatrocentos", "quinhentos", "seiscentos", "setecentos", "oitocentos", "novecentos"]

    /// Number 0–9999 spelled out (covers the years 1500–2100).
    static func numberSpelledOut(_ n: Int) -> String? {
        guard (0...9999).contains(n) else { return nil }
        if n == 0 { return "zero" }
        if n == 100 { return "cem" }
        if n == 1000 { return "mil" }
        var parts: [String] = []
        var remainder = n
        let mil = remainder / 1000
        remainder %= 1000
        var core = ""
        if remainder > 0 {
            var passages: [String] = []
            if remainder == 100 {
                // "dois mil e cem" (não "dois mil e cento"): só o resto
                // exato de 100 é "cem"; 100 como total já saiu acima.
                passages = ["cem"]
            } else {
                let c = remainder / 100
                let dz = remainder % 100
                if c > 0 { passages.append(hundreds[c]) }
                if dz > 0 {
                    if dz < 10 {
                        passages.append(ones[dz])
                    } else if dz < 20 {
                        passages.append(tenToNineteen[dz - 10])
                    } else {
                        let d = dz / 10
                        let u = dz % 10
                        passages.append(u == 0 ? tens[d] : "\(tens[d]) e \(ones[u])")
                    }
                }
            }
            core = passages.joined(separator: " e ")
        }
        if mil > 0 {
            if mil == 1 {
                // "mil novecentos…" (no "e" after mil, as one speaks).
                parts.append(remainder > 0 ? "mil \(core)" : "mil")
            } else {
                parts.append(remainder > 0 ? "\(hundredTen(mil)) mil e \(core)" : "\(hundredTen(mil)) mil")
            }
        } else if remainder > 0 {
            parts.append(core)
        }
        return parts.joined(separator: " ")
    }

    private static func hundredTen(_ n: Int) -> String {
        // Only reaches here with 2–9 (thousands); no internal "e".
        numberSpelledOut(n) ?? "\(n)"
    }

    /// Removes quote blocks: lines between quotes, citation lists and
    /// bibliography sections.
    private static func stripQuotedBlocks(_ text: String) -> String {
        var out = text

        // Quote block: paragraph that starts and ends between quotes. The `.`
        // deliberately does NOT cross a line break — the old version used
        // [\s\S] and matched from one quote to another many lines later, erasing
        // entire sections of the article (that was the grave defect in the real PDF).
        if let re = try? NSRegularExpression(
            pattern: #"^[“\"]\s*\S.{40,}?[”\"][ \t]*$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }

        // Bibliography sections at the end: from the label onwards. The label may
        // come with a prefix ("Selected Bibliography"), so it matches by
        // keyword on a short line, not by equality. Requires being in the
        // final half of the text so as not to cut a mention mid-body.
        let lines = out.components(separatedBy: "\n")
        if let cutoff = bibliographyStart(in: lines) {
            out = lines[..<cutoff].joined(separator: "\n")
        }

        // Footnotes in a block: short lines starting with an asterisk.
        if let re = try? NSRegularExpression(
            pattern: #"^\s*\*+\s*\S[^\n]{0,80}\n"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out
    }

    /// Regroups lines broken in the middle of a sentence.
    ///
    /// Why it exists: PDF extraction returns text with hard breaks at
    /// every printed line. Without joining, each line becomes a very short passage,
    /// the voice restarts at each one and the reading becomes choppy.
    ///
    /// The criterion is the line WIDTH, not the next line's first letter: in a
    /// justified sentence, every line reaches near the margin and only the last
    /// line of the paragraph is short. Joining by "starts with lowercase" left
    /// every break before a proper name loose ("...Boucher and | Forbes 2024"),
    /// fragmenting the reading.
    static func reflow(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let sizes = lines
            .map { $0.trimmingCharacters(in: .whitespaces).count }
            .filter { $0 > 0 }
        // "Full" width = 85% of the 75th percentile of lengths (body lines
        // occupy the whole column; p75 keeps an outlier from inflating it).
        let sortedSizes = sizes.sorted()
        let fullWidth: Int = {
            guard !sortedSizes.isEmpty else { return 30 }
            let p75 = sortedSizes[Int(Double(sortedSizes.count) * 0.75)]
            return max(30, Int(Double(p75) * 0.85))
        }()

        var output: [String] = []
        var paragraph = ""
        var lastPhysical = ""

        for linha in lines {
            let trimmedLine = linha.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                if !paragraph.isEmpty { output.append(paragraph); paragraph = "" }
                lastPhysical = ""
                continue
            }
            let sentenceEnded = lastPhysical.last.map { ".!?…”".contains($0) } ?? false
            let previousComplete = lastPhysical.count >= fullWidth
            let nextContinues = trimmedLine.first.map {
                $0.isLowercase || "([“\"'".contains($0) || $0.isNumber
            } ?? false
            // Joins if the previous line did NOT close a sentence AND the next looks like
            // a continuation (lowercase, parenthesis, number) or the previous filled
            // the column. The first criterion saves page breaks — there the
            // last line is short even mid-paragraph; the second
            // saves breaks before a proper name ("(Boucher and | Forbes").
            let isContinued = !paragraph.isEmpty && !sentenceEnded
                && (nextContinues || previousComplete)

            if isContinued {
                paragraph += " " + trimmedLine
            } else {
                if !paragraph.isEmpty { output.append(paragraph) }
                paragraph = trimmedLine
            }
            lastPhysical = trimmedLine
        }
        if !paragraph.isEmpty { output.append(paragraph) }
        return output.joined(separator: "\n")
    }

    /// Removes lines repeating on many pages.
    ///
    /// Why it exists: browser/publisher printing repeats the title and the date
    /// at the top of every sheet and the footer at the bottom. Without removing, the voice reads the same
    /// header at every page break — it was the worst defect of the user's real PDF
    /// (33 pages, identical header on all).
    ///
    /// The criterion is conservative: it only discards a short line appearing 3+ times
    /// that does not close a sentence. A poem refrain or a sentence repeated in the body
    /// end in punctuation and stay intact.
    private static func stripRepeatedLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var tally: [String: Int] = [:]
        for linha in lines {
            let l = linha.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { tally[l, default: 0] += 1 }
        }
        return lines.filter { linha in
            let l = linha.trimmingCharacters(in: .whitespaces)
            guard let c = tally[l], c >= 3 else { return true }
            let isSentenceEnd = ".,;:!?…".contains(l.last ?? " ")
            return !(l.count <= 80 && !isSentenceEnd)
        }.joined(separator: "\n")
    }

    /// Hyphenation at the line break becomes a whole word: "procu-
    /// \nrar" → "procurar". Only the hyphen GLUED to the left letter unites:
    /// the dash BETWEEN spaces ("the author - a philosopher") is a pause,
    /// not a syllable split. Runs BEFORE the reflow (PDF and text alike), or
    /// the break disappears there and the hyphen stays glued mid-word — in
    /// non-PDF the word came  out with a space inside ("argu- ment").
    /// End-of-line hyphenation becomes one word BEFORE the reflow (after it,
    /// the break disappears and the hyphen stays mid-word). Conservative like
    /// the Python path (`_join_end`): only a LOWERCASE start glues; an
    /// uppercase start is a true compound ("Wrinkled-\nSeed") and keeps the
    /// hyphen. The invisible shapes of the same break (U+2010, soft hyphen,
    /// en dash) count as hyphens; a stray soft hyphen inside a word is wiped
    /// (the voice chokes on it and it is invisible on screen).
    private static func joinLineHyphens(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "\u{00AD}", with: "")
        out = out.replacingOccurrences(of: "\u{2010}", with: "-")
        out = out.replacingOccurrences(
            of: #"(\p{Ll})[-‐]\n\s*(\p{Ll})"#, with: "$1$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"(\p{Ll})[-‐]\s+(\p{Ll})"#, with: "$1$2", options: .regularExpression)
        return out
    }

    /// PDF-specific cleanup: repeated headers/footers.
    private static func stripPDFArtifacts(_ text: String) -> String {
        var out = stripRepeatedLines(text)
        // Footer with page number. Runs BEFORE the reflow because the page's text may
        // continue after it. Does NOT eat the line breaks around:
        // reflow replaced by a space glued the next paragraph.
        out = out.replacingOccurrences(
            of: #"(?i)\bPage\s+\d+\s+(?:of|de)\s+\d+"#,
            with: "", options: .regularExpression)
        // Browser print footer.
        out = out.replacingOccurrences(
            of: #"(?im)^\s*about:\S*\s*$"#, with: "", options: .regularExpression)
        // Isolated page numbers on their own line.
        if let re = try? NSRegularExpression(
            pattern: #"^\s*[-–—]?\s*\d{1,4}\s*[-–—]?\s*$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Date split across sheets: "7 de outubro de 20" on one page and "26" on the
        // next. Joins before the reflow, else it would become "de 20 Gilson".
        if let re = try? NSRegularExpression(
            pattern: #"(?m)^(\s*\d{1,2}\s+de\s+\p{L}+\s+de\s+\d{1,2})\n\s*(\d{1,2})\s*$"#,
            options: []
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "$1$2")
        }

        // "da §4", "do § 3", "na §4.2" — also consumes the article, else a
        // loose "da" remains in the text.
        out = out.replacingOccurrences(
            of: #"\b(?:da|do|na|no|em)\s+§{1,2}\s*[\d]+([\.\d]*)?([\s–—-]+[\d]+)*"#,
            with: "", options: .regularExpression)

        // Symbol sections BEFORE the reflow: the PDF line ends with "§" and the
        // number comes on the next line; without this order the reflow joins the "§" to the
        // next word and the reading says "da Nós dois".
        out = out.replacingOccurrences(
            of: #"§{1,2}\s*[\d]+([\.\d]*)?([\s–—-]+[\d]+)*"#,
            with: "", options: .regularExpression)

        // Line-break hyphenation: in joinLineBreakHyphen (shared with
        // .txt/colagem), same point in the pipeline (before the reflow).
        // Page number split in half: "7 de outubro de 20" + "26".
        if let re = try? NSRegularExpression(
            pattern: #"(\d{2,4})\n(\d{1,2})$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "$1$2")
        }
        // Junk WITHOUT letters at a line of its own (ornament, print
        // footer) goes. A title all in caps ("THE PROBLEM", "CARNAP AND
        // THE AUFBAU") has letters and is CONTENT: the old rule erased the
        // whole uppercase line (wave 1, item 12) — the repeated header it
        // was created for keeps being caught by `stripRepeatedLines`.
        if let re = try? NSRegularExpression(
            pattern: #"^[ \t]*[^\n\p{L}]{8,}[ \t]*$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Date in the header: "7 de outubro de 2026". The voice must not read the
        // repeated header on every page. Only when the date stands alone on the
        // line (header), not when it is part of a sentence.
        if let re = try? NSRegularExpression(
            pattern: #"(?m)^\s*\d{1,2}\s+de\s+\p{L}{3,12}\s+de\s+\d{4}\s*$"#,
            options: []
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out
    }
}