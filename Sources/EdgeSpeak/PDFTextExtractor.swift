import Foundation
import PDFKit

/// Extrai o texto de um PDF em **ordem de leitura**, reagrupando por geometria.
///
/// O `PDFPage.string` devolve o texto linha a linha, na ordem de impressão —
/// cada quebra visual vira um `\n`. Isso picava a leitura, e pior: em páginas de
/// **duas colunas** a ordem de impressão alterna esquerda/direita, o que
/// embaralha o texto. Aqui cada linha vem com a sua caixa, e a ordem é
/// reconstruída por **corte recursivo (XY-cut)**: separa a página pela maior
/// calha horizontal (faixas) e vertical (colunas), de cima para baixo e da
/// esquerda para a direita, até não haver calha. Assim uma página de duas
/// colunas é lida coluna inteira da esquerda, depois a da direita.
///
/// Cabeçalhos e rodapés saem por frequência (mesmo texto em várias páginas) e
/// por estarem na faixa das margens.
enum PDFTextExtractor {

    /// Uma linha impressa, com a caixa que o PDFKit reporta (origem no canto
    /// inferior esquerdo da página).
    private struct Line {
        let text: String
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
        let page: Int
        /// Palavras da linha com caixas (via PyMuPDF); vazio na via PDFKit.
        var words: [(text: String, box: CGRect, page: Int)] = []
        /// Limites da coluna a que a linha pertence, definidos na ordem de
        /// leitura (XY-cut). Sem isso, o recuo e a "linha cheia" seriam medidos
        /// contra a largura da página inteira e errariam em duas colunas.
        var colLeft: CGFloat = 0
        var colRight: CGFloat = 0

    var width: CGFloat { maxX - minX }
    /// Caixa da linha em coordenadas de página (origem no canto inferior
    /// esquerdo), para o destaque geométrico.
    var box: CGRect {
        CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
        var columnWidth: CGFloat { max(1, colRight - colLeft) }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func extract(_ document: PDFDocument) -> String {
        extractSegments(document).map { $0.text }.joined(separator: "\n")
    }

    /// Parágrafos com página e caixas das linhas (0-based), para o destaque
    /// geométrico por página.
    ///
    /// A lógica de XY-cut, cabeçalho/rodapé, parágrafos e hífen é a mesma do
    /// `extract`: a página é a da primeira linha de cada parágrafo, e os
    /// rects são só os dessa página (o resto do cruzamento é ignorado).
    static func extractSegments(_ document: PDFDocument) -> [(text: String, page: Int, rects: [CGRect], words: [(text: String, box: CGRect, page: Int)])] {
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }

        var perPage: [[Line]] = []
        // PyMuPDF primeiro (palavras com caixas: sem palavras coladas);
        // PDFKit como reserva (sem Python ou sem PyMuPDF).
        if let url = document.documentURL,
           let ext = PdfWords.lines(pdfURL: url, pageCount: document.pageCount),
           ext.count == pages.count {
            perPage = ext.enumerated().map { (i, lines) in
                lines.compactMap { lineFromExternal(text: $0.text, box: $0.box, words: $0.words.map { (text: $0.text, box: $0.box, page: i) }, pageIndex: i) }
            }
        } else {
            for (index, page) in pages.enumerated() {
                perPage.append(lines(of: page, pageIndex: index))
            }
        }
        var heights: [CGFloat] = []
        for page in pages {
            heights.append(page.bounds(for: .mediaBox).height)
        }

        let repeated = repeatedKeys(perPage)
        let leading = median(spacings(of: perPage)) ?? 12

        var ordered: [Line] = []
        for (index, pageLines) in perPage.enumerated() {
            var kept: [Line] = []
            for line in pageLines {
                let text = line.trimmed
                if text.isEmpty { continue }
                if repeated.contains(repeatedKey(text)) { continue }
                if isMarginNoise(text, line: line, pageHeight: heights[index]) { continue }
                kept.append(line)
            }
            ordered.append(contentsOf: readingOrder(kept, leading: leading))
        }

        return paragraphs(from: ordered, leading: leading)
    }

    // MARK: - Linhas

    private static func lines(of page: PDFPage, pageIndex: Int) -> [Line] {
        let crop = page.bounds(for: .cropBox)
        let rect = crop.isEmpty ? page.bounds(for: .mediaBox) : crop
        guard let selection = page.selection(for: rect) else { return [] }

        var out: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            let raw = (lineSelection.string ?? "").replacingOccurrences(of: "\n", with: " ")
            let box = lineSelection.bounds(for: page)
            // O índice sobrescrito da nota ("(314).⁴") cola no fim da linha e
            // esconde a pontuação: sem tirá-lo, a linha não "fecha frase" e a
            // nota de rodapé é emendada no parágrafo anterior.
            let semNota = raw.replacingOccurrences(
                of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹]+"#, with: "", options: .regularExpression)
            let trimmed = semNota.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, box.width > 0, box.height > 0 else { continue }
            out.append(Line(
                text: semNota,
                minX: box.minX,
                maxX: box.maxX,
                minY: box.minY,
                maxY: box.maxY,
                page: pageIndex
            ))
        }
        // Topo primeiro. PDFKit não garante a ordem; a geometria garante.
        out.sort { lhs, rhs in
            if abs(lhs.minY - rhs.minY) > 1 { return lhs.minY > rhs.minY }
            return lhs.minX < rhs.minX
        }
        return out
    }

    /// Uma linha vinda do PyMuPDF, com o mesmo tratamento da via PDFKit
    /// (tira índice de nota, descarta vazia). Nil = descartar.
    private static func lineFromExternal(text: String, box: CGRect, words: [(text: String, box: CGRect, page: Int)], pageIndex: Int) -> Line? {
        let semNota = text.replacingOccurrences(
            of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹]+"#, with: "", options: .regularExpression)
        let trimmed = semNota.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Line(
            text: semNota,
            minX: box.minX,
            maxX: box.maxX,
            minY: box.minY,
            maxY: box.maxY,
            page: pageIndex,
            words: words
        )
    }

    // MARK: - Ordem de leitura (XY-cut)

    /// Ordena as linhas de uma página pela maior calha, primeiro vertical
    /// (colunas), depois horizontal (faixas). A escolha pela calha vertical
    /// primeiro é o que faz uma página de duas colunas ser lida coluna a coluna;
    /// um título de largura total "costura" a calha e força o corte horizontal
    /// antes — que é exatamente o que se quer.
    private static func readingOrder(_ lines: [Line], leading: CGFloat) -> [Line] {
        guard lines.count > 1 else { return leaf(lines) }

        if let (left, right) = splitVertically(lines, minGap: max(12, leading)) {
            return readingOrder(left, leading: leading) + readingOrder(right, leading: leading)
        }
        if let (top, bottom) = splitHorizontally(lines, minGap: leading * 1.25) {
            return readingOrder(top, leading: leading) + readingOrder(bottom, leading: leading)
        }
        return leaf(lines)
    }

    /// Folha: sem calha útil. Ordena topo→base (e esquerda→direita para linhas
    /// na mesma altura) e marca a coluna como a própria caixa do bloco.
    private static func leaf(_ lines: [Line]) -> [Line] {
        let left = lines.map { $0.minX }.min() ?? 0
        let right = lines.map { $0.maxX }.max() ?? 0
        return lines
            .sorted { lhs, rhs in
                if abs(lhs.maxY - rhs.maxY) > 1 { return lhs.maxY > rhs.maxY }
                return lhs.minX < rhs.minX
            }
            .map { line in
                var copy = line
                copy.colLeft = left
                copy.colRight = right
                return copy
            }
    }

    /// Separa em colunas por uma calha vertical limpa (nenhuma linha a cruza),
    /// exigindo ao menos três linhas de cada lado — assim uma heurística fraca
    /// não corta uma página de coluna única.
    private static func splitVertically(_ lines: [Line], minGap: CGFloat) -> ([Line], [Line])? {
        guard let g = largestGap(lines.map { (lo: $0.minX, hi: $0.maxX) }),
              g.gap >= minGap else { return nil }
        let left = lines.filter { $0.maxX <= g.cut }
        let right = lines.filter { $0.minX >= g.cut }
        guard left.count >= 3, right.count >= 3, left.count + right.count == lines.count else {
            return nil
        }
        return (left, right)
    }

    /// Separa em faixas por uma calha horizontal limpa (título × corpo, corpo ×
    /// rodapé já removido).
    private static func splitHorizontally(_ lines: [Line], minGap: CGFloat) -> ([Line], [Line])? {
        guard let g = largestGap(lines.map { (lo: $0.minY, hi: $0.maxY) }),
              g.gap >= minGap else { return nil }
        let top = lines.filter { $0.minY >= g.cut }
        let bottom = lines.filter { $0.maxY <= g.cut }
        guard !top.isEmpty, !bottom.isEmpty, top.count + bottom.count == lines.count else {
            return nil
        }
        return (top, bottom)
    }

    /// Maior vão sem nenhuma caixa, entre intervalos `(lo, hi)`. Devolve o vão e
    /// a coordenada de corte no meio dele.
    private static func largestGap(_ intervals: [(lo: CGFloat, hi: CGFloat)]) -> (gap: CGFloat, cut: CGFloat)? {
        guard intervals.count > 1 else { return nil }
        let sorted = intervals.sorted { $0.lo < $1.lo }
        var hiSoFar = sorted[0].hi
        var best: (gap: CGFloat, cut: CGFloat)?
        for i in 1..<sorted.count {
            let gap = sorted[i].lo - hiSoFar
            if gap > (best?.gap ?? 0) {
                best = (gap, (hiSoFar + sorted[i].lo) / 2)
            }
            hiSoFar = max(hiSoFar, sorted[i].hi)
        }
        return best
    }

    // MARK: - Cabeçalhos e rodapés

    /// Textos que se repetem em várias páginas são cabeçalho/rodapé correntes.
    private static func repeatedKeys(_ perPage: [[Line]]) -> Set<String> {
        var count: [String: Int] = [:]
        var pagesSeen: [String: Set<Int>] = [:]
        for pageLines in perPage {
            for line in pageLines {
                let key = repeatedKey(line.trimmed)
                guard !key.isEmpty, key.count <= 120 else { continue }
                count[key, default: 0] += 1
                pagesSeen[key, default: []].insert(line.page)
            }
        }
        return Set(count.compactMap { key, total in
            total >= 3 && (pagesSeen[key]?.count ?? 0) >= 3 ? key : nil
        })
    }

    /// Chave de comparação que ignora o que muda de página para página — no
    /// cabeçalho corrente "394 Rudolf Carnap" o número varia, mas o resto se
    /// repete. Troca cada bloco de dígitos por "#".
    private static func repeatedKey(_ text: String) -> String {
        var out = ""
        var inDigits = false
        for ch in text {
            if ch.isNumber {
                if !inDigits { out.append("#"); inDigits = true }
            } else {
                out.append(ch)
                inDigits = false
            }
        }
        return out
    }

    /// Ruído na faixa das margens: número de página, data/hora, URL, etiqueta curta.
    private static func isMarginNoise(_ text: String, line: Line, pageHeight: CGFloat) -> Bool {
        let inTopBand = line.minY > pageHeight * 0.86
        let inBottomBand = line.maxY < pageHeight * 0.14
        guard inTopBand || inBottomBand else { return false }

        if matches(text, #"^(?:Page\s+)?\d{1,4}(?:\s+(?:of|de)\s+\d{1,4})?$"#) { return true }
        if matches(text, #"^\d{1,4}\s*[/.\-]\s*\d{1,4}\s*[/.\-]\s*\d{2,4}"#) { return true }
        if matches(text, #"^(?:about|chrome|file|https?):"#) { return true }
        if text.count <= 12 { return true }
        return false
    }

    // MARK: - Parágrafos

    private static func paragraphs(from lines: [Line], leading: CGFloat) -> [(text: String, page: Int, rects: [CGRect], words: [(text: String, box: CGRect, page: Int)])] {
        guard !lines.isEmpty else { return [] }

        let globalLeft = median(lines.map { $0.minX }) ?? 0
        let globalRight = median(lines.map { $0.maxX }) ?? 0
        let paragraphGap = leading * 1.6
        let indent = max(8, leading * 0.8)

        // Título de seção tem fonte maior: a caixa da linha é mais alta que a do
        // corpo. É o sinal para não colar o título no parágrafo seguinte.
        let medianHeight = median(lines.map { $0.maxY - $0.minY }.filter { $0 > 0 })
        func isHeading(_ line: Line) -> Bool {
            guard let base = medianHeight, base > 0 else { return false }
            return (line.maxY - line.minY) > base * 1.18
        }
        func colLeft(_ line: Line) -> CGFloat {
            line.colRight > line.colLeft ? line.colLeft : globalLeft
        }
        func colWidth(_ line: Line) -> CGFloat {
            line.colRight > line.colLeft ? line.columnWidth : max(1, globalRight - globalLeft)
        }

        var result: [(text: String, page: Int, rects: [CGRect], words: [(text: String, box: CGRect, page: Int)])] = []
        var current = ""
        var currentPage = 0
        var currentLines: [Line] = []
        var previous: Line?

        // Fecha o parágrafo atual, levando só as caixas e palavras da sua página.
        func flush() {
            let pageLines = currentLines.filter { $0.page == currentPage }
            let rects = pageLines.map { $0.box }
            let words = pageLines.flatMap { line in
                line.words.map { (text: $0.text, box: $0.box, page: line.page) }
            }
            result.append((current, currentPage, rects, words))
        }

        for line in lines {
            let text = collapsed(line.trimmed)
            guard !text.isEmpty else { continue }

            if current.isEmpty {
                current = text
                currentPage = line.page
                currentLines = [line]
                previous = line
                continue
            }

            let continues: Bool
            if let prev = previous {
                let headingBoundary = isHeading(prev) || isHeading(line)
                if prev.page != line.page {
                    // Quebra de página: continua enquanto a frase não fechou.
                    continues = !headingBoundary && !endsSentence(prev.trimmed)
                } else {
                    // `gap` pode ser negativo na virada de coluna (o topo da
                    // direita fica acima do pé da esquerda): nesse caso a
                    // continuação é decidida por "linha cheia" e fim de frase,
                    // que é o fluxo correto de texto entre colunas.
                    let gap = prev.minY - line.maxY
                    let previousFull = prev.width >= colWidth(prev) * 0.82
                    let currentIndented = (line.minX - colLeft(line)) > indent
                        && (prev.minX - colLeft(prev)) <= indent
                    continues = !headingBoundary && previousFull
                        && gap < paragraphGap && !currentIndented
                        && !endsSentenceHard(prev.trimmed)
                }
            } else {
                continues = false
            }

            if continues {
                current = join(current, text)
                currentLines.append(line)
            } else {
                flush()
                current = text
                currentPage = line.page
                currentLines = [line]
            }
            previous = line
        }
        if !current.isEmpty { flush() }
        return result
    }

    /// Espaçamento vertical entre linhas consecutivas, por página, para estimar
    /// a entrelinha (leading) antes de montar os parágrafos.
    private static func spacings(of perPage: [[Line]]) -> [CGFloat] {
        var out: [CGFloat] = []
        for pageLines in perPage {
            let sorted = pageLines.sorted { $0.minY > $1.minY }
            for (upper, lower) in zip(sorted, sorted.dropFirst()) {
                let gap = upper.minY - lower.maxY
                if gap > 0 { out.append(gap) }
            }
        }
        return out
    }

    /// Junta duas linhas, tratando hifenização de fim de linha.
    private static func join(_ first: String, _ second: String) -> String {
        if let last = first.last, last == "-" || last == "‐" {
            return String(first.dropLast()) + second
        }
        return first + " " + second
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?\"')".contains(last)
    }

    /// Fecha frase de forma dura (só pontuação terminal): usado para não colar
    /// dois parágrafos que terminam em ponto.
    private static func endsSentenceHard(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?".contains(last)
    }

    private static func collapsed(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\s+"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
