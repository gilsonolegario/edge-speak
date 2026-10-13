import Foundation
import PDFKit

/// Importação de arquivo (.pdf/.md/.txt): fonte única das frases de leitura.
///
/// Monta a lista de frases com índice global estável + página; o texto
/// filtrado e o integral derivam da MESMA lista (integral = sem filtro).
enum TextImport {
    /// Uma frase de leitura: índice global estável na lista ativa + página
    /// de origem (0-based; nil para texto sem PDF) + caixas das linhas que
    /// a frase ocupa ([] sem PDF).
    struct Phrase: Hashable, Sendable {
        struct WordBox: Hashable, Sendable {
            let text: String
            let rect: CGRect
        }
        let index: Int
        let text: String
        let page: Int?
        let rects: [CGRect]
        let words: [WordBox]
        let paragraphEnd: Bool

        init(index: Int, text: String, page: Int?, rects: [CGRect], words: [WordBox] = [], paragraphEnd: Bool = false) {
            self.index = index
            self.text = text
            self.page = page
            self.rects = rects
            self.words = words
            self.paragraphEnd = paragraphEnd
        }
    }

    static func readDocument(url: URL) throws -> (
        filtrado: String, integral: String, pdf: PDFDocument?,
        frases: [Phrase], frasesFiltradas: [Phrase]
    ) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else {
                throw NSError(
                    domain: "EdgeSpeak",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Não foi possível abrir o PDF."]
                )
            }
            var segments = PDFTextExtractor.extractSegments(doc)
            if segments.isEmpty {
                // Sem camada de geometria: cai para o texto bruto por página.
                var parts: [String] = []
                for i in 0..<doc.pageCount {
                    if let s = doc.page(at: i)?.string, !s.isEmpty {
                        parts.append(s)
                    }
                }
                let joined = parts.joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { segments = [(joined, 0, [], [])] }
            }
            guard !segments.isEmpty else {
                throw NSError(
                    domain: "EdgeSpeak",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "PDF sem camada de texto; não há o que ler."]
                )
            }
            let frases = makePhrases(from: segments.map { ($0.text, $0.page as Int?, $0.rects, $0.words.map { Phrase.WordBox(text: $0.text, rect: $0.box) }) })
            let frasesFiltradas = makePhrases(from: filtered(segments.map { ($0.text, $0.page as Int?, $0.rects, $0.words.map { Phrase.WordBox(text: $0.text, rect: $0.box) }) }, isPDF: true))
            return (
                filtrado: join(frasesFiltradas), integral: join(frases), pdf: doc,
                frases: frases, frasesFiltradas: frasesFiltradas
            )
        case "md", "markdown", "txt", "text":
            let raw = try String(contentsOf: url, encoding: .utf8)
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "EdgeSpeak",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Arquivo vazio; não há o que ler."]
                )
            }
            let base = normalizeMarkdown(raw)
            let frases = makePhrases(from: [(base, nil, [], [])])
            let frasesFiltradas = makePhrases(from: filtered([(base, nil, [], [])], isPDF: false))
            return (
                filtrado: join(frasesFiltradas), integral: join(frases), pdf: nil,
                frases: frases, frasesFiltradas: frasesFiltradas
            )
        default:
            throw NSError(
                domain: "EdgeSpeak",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Extensão não suportada: .\(ext). Use .pdf, .md ou .txt."]
            )
        }
    }

    /// Frases do texto digitado/colado (sem arquivo): mesma UMA flag integral.
    static func editorPhrases(_ text: String, integral: Bool) -> [Phrase] {
        let base = integral ? text : ReadAloudFilter.clean(text)
        return makePhrases(from: [(base, nil, [], [])])
    }

    // MARK: - Pipeline

    /// Corta a bibliografia (regra doc-scope), limpa por trecho e preserva
    /// a página e as caixas de cada um para repartir depois.
    private static func filtered(
        _ segments: [(text: String, page: Int?, rects: [CGRect], words: [Phrase.WordBox])], isPDF: Bool
    ) -> [(text: String, page: Int?, rects: [CGRect], words: [Phrase.WordBox])] {
        var list = segments
        if let cut = ReadAloudFilter.bibliographyStart(in: list.map { $0.text }) {
            list = Array(list[..<cut])
        }
        return list.compactMap { seg in
            let cleaned = ReadAloudFilter.clean(seg.text, isPDF: isPDF)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : (cleaned, seg.page, seg.rects, seg.words)
        }
    }

    /// Reparte os trechos em frases, com índice global sequencial. Cada frase
    /// recebe as caixas das linhas que ela ocupa (casamento em ordem dos
    /// tokens da frase contra as palavras do parágrafo, agrupado por linha);
    /// sem nenhuma caixa casada, herda as caixas do parágrafo. `words`
    /// continua sendo as palavras do parágrafo (o karaokê casa por texto).
    /// A última frase de cada bloco marca o fim do parágrafo.
    private static func makePhrases(from segments: [(text: String, page: Int?, rects: [CGRect], words: [Phrase.WordBox])]) -> [Phrase] {
        var out: [Phrase] = []
        for seg in segments {
            var cursor = 0
            let blocks = seg.text.components(separatedBy: .newlines)
            for block in blocks {
                let t = block.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                let sentences = splitSentences(t)
                for (i, sentence) in sentences.enumerated() {
                    let boxes = boxesForSentence(sentence, words: seg.words, cursor: &cursor)
                    out.append(Phrase(
                        index: out.count, text: sentence, page: seg.page,
                        rects: boxes.isEmpty ? seg.rects : boxes, words: seg.words,
                        paragraphEnd: i == sentences.count - 1))
                }
            }
        }
        return out
    }

    /// Minúsculas, só letras e dígitos: mesma normalização do karaokê.
    private static func normalizedWord(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Caixas das palavras da frase, em ordem, agrupadas por linha. Cada
    /// token é buscado a partir do cursor; o não achado é pulado sem
    /// deslocar o cursor.
    private static func boxesForSentence(
        _ sentence: String, words: [Phrase.WordBox], cursor: inout Int
    ) -> [CGRect] {
        var boxes: [CGRect] = []
        let tokens = sentence.components(separatedBy: .whitespacesAndNewlines)
        for token in tokens {
            let needle = normalizedWord(token)
            guard !needle.isEmpty else { continue }
            var found: Int?
            for j in cursor..<words.count
            where normalizedWord(words[j].text) == needle {
                found = j
                break
            }
            guard let j = found else { continue }
            boxes.append(words[j].rect)
            cursor = j + 1
        }
        return groupByLine(boxes)
    }

    /// Agrupa caixas por linha (sobreposição vertical acima da metade da
    /// menor altura) e une minX/minY/maxX/maxY por linha.
    private static func groupByLine(_ boxes: [CGRect]) -> [CGRect] {
        var rows: [CGRect] = []
        for box in boxes {
            var placed = false
            for i in rows.indices {
                let row = rows[i]
                let overlap = min(row.maxY, box.maxY) - max(row.minY, box.minY)
                let minHeight = min(row.height, box.height)
                let sameLine: Bool = if minHeight <= 0 {
                    abs(row.midY - box.midY) < 1.0
                } else {
                    overlap > 0.5 * minHeight
                }
                if sameLine {
                    rows[i] = row.union(box)
                    placed = true
                    break
                }
            }
            if !placed { rows.append(box) }
        }
        return rows.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    private static func join(_ phrases: [Phrase]) -> String {
        phrases.map { $0.text }.joined(separator: "\n")
    }

    /// Reparte um texto em frases pela pontuação terminal seguida de maiúscula.
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        let blocks = text.components(separatedBy: .newlines)
        let pattern = #"(?<=[.!?…])\s+(?=[A-ZÀ-Ú0-9\(\["“'«])"#
        let re = try? NSRegularExpression(pattern: pattern, options: [])
        for block in blocks {
            let t = block.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            guard let re else { out.append(t); continue }
            var parts: [String] = []
            var start = t.startIndex
            let ns = NSRange(t.startIndex..., in: t)
            for m in re.matches(in: t, options: [], range: ns) {
                guard let r = Range(m.range, in: t) else { continue }
                parts.append(String(t[start..<r.lowerBound]))
                start = r.upperBound
            }
            parts.append(String(t[start...]))
            for p in parts {
                let s = p.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
            }
        }
        return out
    }

    /// Normalização leve de markdown para fala.
    static func normalizeMarkdown(_ s: String) -> String {
        var out = s
        // Remover cercas de código (``` ... ```), mantendo o conteúdo interno.
        out = out.replacingOccurrences(of: "```", with: "")
        // [texto](url) -> texto
        if let re = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#, options: []) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        // Remover marcação no início de linha (# * > - e numeradas "1. ").
        var lines: [String] = []
        for line in out.components(separatedBy: "\n") {
            var l = line
            if let re = try? NSRegularExpression(pattern: #"^\s*(#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)"#, options: []) {
                l = re.stringByReplacingMatches(
                    in: l, options: [],
                    range: NSRange(l.startIndex..., in: l), withTemplate: "")
            }
            lines.append(l)
        }
        out = lines.joined(separator: "\n")
        // Remover backticks e asteriscos/underscores inline.
        out = out.replacingOccurrences(of: "`", with: "")
        if let re = try? NSRegularExpression(pattern: #"(\*\*|__|\*|_)"#, options: []) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Colapsar 3+ linhas em branco em 2.
        if let re = try? NSRegularExpression(pattern: #"\n{3,}"#, options: []) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
