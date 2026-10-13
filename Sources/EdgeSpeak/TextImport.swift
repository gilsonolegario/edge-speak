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
            /// Página da caixa (nil quando desconhecida/teste). Permite
            /// partir a frase na virada de página em vez de desenhar
            /// caixas de duas páginas na primeira.
            let page: Int?

            /// `init` explícito (não memberwise): neste toolchain, membro
            /// com default não entra no inicializador sintetizado.
            init(text: String, rect: CGRect, page: Int? = nil) {
                self.text = text
                self.rect = rect
                self.page = page
            }
        }
        let index: Int
        let text: String
        let page: Int?
        let rects: [CGRect]
        let words: [WordBox]
        let paragraphEnd: Bool
        /// Número da nota de rodapé quando a frase É o corpo de uma nota
        /// (nil para texto corrido). Preenchido por `resolveFootnotes`.
        let notaNumero: Int?

        init(index: Int, text: String, page: Int?, rects: [CGRect], words: [WordBox] = [], paragraphEnd: Bool = false, notaNumero: Int? = nil) {
            self.index = index
            self.text = text
            self.page = page
            self.rects = rects
            self.words = words
            self.paragraphEnd = paragraphEnd
            self.notaNumero = notaNumero
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
            // Passo de ANÁLISE entre abrir e transcrever: com os segmentos
            // extraídos, separa o que não é texto corrido (corpos de notas
            // ligados aos marcadores, rótulos soltos descartados) antes de
            // repartir em frases de leitura. É aqui que moram as próximas
            // separações (fórmulas densas, legendas) sem tocar no leitor.
            let frases = resolveFootnotes(makePhrases(from: segments.map { ($0.text, $0.page as Int?, $0.rects, $0.words.map { Phrase.WordBox(text: $0.text, rect: $0.box, page: $0.page) }) }))
            let frasesFiltradas = resolveFootnotes(makePhrases(from: filtered(segments.map { ($0.text, $0.page as Int?, $0.rects, $0.words.map { Phrase.WordBox(text: $0.text, rect: $0.box, page: $0.page) }) }, isPDF: true)))
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
    /// Interna para teste (TextImportTests monta segmentos sintéticos).
    static func makePhrases(from segments: [(text: String, page: Int?, rects: [CGRect], words: [Phrase.WordBox])]) -> [Phrase] {
        var out: [Phrase] = []
        for seg in segments {
            var cursor = 0
            let blocks = seg.text.components(separatedBy: .newlines)
            for block in blocks {
                let t = block.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                let sentences = splitSentences(t)
                for (i, sentence) in sentences.enumerated() {
                    let casados = boxesForSentence(sentence, words: seg.words, cursor: &cursor)
                    let trechos = trechosPorPagina(
                        sentence: sentence, casados: casados, paginaPadrao: seg.page)
                    if trechos.isEmpty {
                        out.append(Phrase(
                            index: out.count, text: sentence, page: seg.page,
                            rects: seg.rects, words: seg.words,
                            paragraphEnd: i == sentences.count - 1))
                        continue
                    }
                    // Uma frase, uma página: cada trecho leva só as caixas
                    // e palavras da sua página; só o último herda o fim.
                    for (k, trecho) in trechos.enumerated() {
                        let ultimo = k == trechos.count - 1
                        let pagina = trecho.pagina ?? seg.page
                        out.append(Phrase(
                            index: out.count, text: trecho.texto,
                            page: pagina,
                            rects: trecho.caixas.isEmpty ? seg.rects : trecho.caixas,
                            words: seg.words.filter { $0.page == nil || $0.page == pagina },
                            paragraphEnd: ultimo && i == sentences.count - 1))
                    }
                }
            }
        }
        return out
    }

    /// Liga corpos de notas de rodapé aos seus marcadores, na mesma lista.
///
/// Regra geral (vale para todo PDF): ponto + número sobrescrito é marcador;
/// o corpo mora no rodapé da página (ou em notas de fim, no fim do
/// documento). O que faz aqui:
/// - número solto de 1–2 dígitos com página (rótulo sem corpo, como os
///   "1".."15" do artigo de teste) é descartado — lido, viraria "um";
/// - corpo ("12 Autores, ...", número + texto longo) procura o marcador N na
///   mesma página e, faltando, o marcador anterior mais próximo no documento
///   (cobre notas de fim); achando, perde o número e vai para logo após a
///   frase do marcador — é lido direto após o anúncio, como o dono pediu;
/// - sem marcador, o corpo fica intacto onde está (pode ser data ou
///   enumeração: mexer seria corrupção, e a leitura segue correta).
/// Os índices das frases que ficam NÃO mudam (são propriedade, não posição)
/// — destaque e salto por índice continuam valendo.
    static func resolveFootnotes(_ phrases: [Phrase]) -> [Phrase] {
        var lista = phrases.filter { ph in
            guard ph.page != nil else { return true }
            let t = ph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(t.count <= 2 && Int(t) != nil)
        }
        struct Corpo { var pos: Int; var numero: Int; var texto: String; var frase: Phrase }
        var corpos: [Corpo] = []
        for (pos, ph) in lista.enumerated() {
            guard ph.page != nil, ph.notaNumero == nil else { continue }
            let t = ph.text.drop(while: { $0.isWhitespace })
            let digitos = String(t.prefix(while: { $0.isNumber }))
            guard (1...2).contains(digitos.count), let n = Int(digitos) else { continue }
            let resto = t.dropFirst(digitos.count)
            guard resto.first?.isWhitespace == true else { continue } // "12."/"12)" não é corpo
            let corpo = resto.drop(while: { $0.isWhitespace })
            guard corpo.count >= 12 else { continue }
            corpos.append(Corpo(pos: pos, numero: n, texto: String(corpo), frase: ph))
        }
        // De trás para frente: mover não desloca as posições ainda por tratar.
        for corpo in corpos.reversed() {
            let alvo = marcaAnterior(
                numero: corpo.numero, pagina: corpo.frase.page,
                ate: corpo.pos, em: lista, excluindo: corpo.pos)
            guard let m = alvo else { continue } // sem marcador: intacto
            let movida = Phrase(
                index: corpo.frase.index, text: corpo.texto,
                page: corpo.frase.page, rects: corpo.frase.rects,
                words: corpo.frase.words,
                paragraphEnd: corpo.frase.paragraphEnd,
                notaNumero: corpo.numero)
            lista.remove(at: corpo.pos)
            let destino = m > corpo.pos ? m : m + 1
            lista.insert(movida, at: destino)
        }
        return lista
    }

    /// Posição da frase com o marcador N: mesma página primeiro (em ordem),
    /// senão a anterior mais próxima no documento (notas de fim). `nil` sem
    /// marcador — e sem marcador não se move nada.
    private static func marcaAnterior(
        numero n: Int, pagina: Int?, ate pos: Int, em lista: [Phrase], excluindo: Int
    ) -> Int? {
        let ns = String(n)
        let formas = [
            #"(?<=[A-Za-zÀ-ÿ\)\]"'”’])\."# + ns + #"(?![\dA-Za-zÀ-ÿ.])"#,
            #"(?<=[A-Za-zÀ-ÿ\)\]"'”’]),"# + ns + #"(?![\dA-Za-zÀ-ÿ.])"#,
            #"([A-Za-zÀ-ÿ]{2,}[a-zà-ÿ])"# + ns + #"(?![\dA-Za-zÀ-ÿ.])"#,
        ]
        let res = formas.compactMap { try? NSRegularExpression(pattern: $0) }
        func tem(_ texto: String) -> Bool {
            let faixa = NSRange(texto.startIndex..., in: texto)
            return res.contains { $0.firstMatch(in: texto, options: [], range: faixa) != nil }
        }
        if let pagina {
            for (i, ph) in lista.enumerated() where i != excluindo && ph.page == pagina {
                if tem(ph.text) { return i }
            }
        }
        for i in stride(from: pos - 1, through: 0, by: -1) {
            if tem(lista[i].text) { return i }
        }
        return nil
    }

    /// Minúsculas, só letras e dígitos: mesma normalização do karaokê.
    /// NFKC antes: ligadura "ﬁ" vira "fi" (pesquisa §6 — sem isto, o token
    /// nunca casa com a caixa).
    static func normalizedWord(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Casa os tokens da frase com as caixas, em ordem. Devolve, por token
    /// casado, a posição do token, a caixa e a página. Interna para teste.
    ///
    /// Cada token é buscado a partir do cursor; o não achado é pulado sem
    /// deslocar o cursor. Hífen de fim de linha tem duas tentativas extras,
    /// ambas sem consumir em falha:
    /// - texto cru ("procu-", "rar") contra caixa junta ("procurar"):
    ///   token sem o "-" mais o próximo colados;
    /// - texto junto ("procurar", ex. JSON antigo) contra caixas partidas:
    ///   token contra as 2 caixas seguintes coladas (hífens fora), com a
    ///   união como caixa.
    /// Sem isto, a frase hifenizada caía nas caixas do parágrafo inteiro.
    static func boxesForSentence(
        _ sentence: String, words: [Phrase.WordBox], cursor: inout Int
    ) -> [(token: Int, box: CGRect, page: Int?)] {
        var casados: [(token: Int, box: CGRect, page: Int?)] = []
        let tokens = sentence.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var t = 0
        while t < tokens.count {
            let needle = normalizedWord(tokens[t])
            guard !needle.isEmpty else { t += 1; continue }
            var found: Int?
            for j in cursor..<words.count
            where normalizedWord(words[j].text) == needle {
                found = j
                break
            }
            if let j = found {
                casados.append((token: t, box: words[j].rect, page: words[j].page))
                cursor = j + 1
                t += 1
                continue
            }
            // Texto cru contra caixa junta.
            if tokens[t].hasSuffix("-"), t + 1 < tokens.count {
                let junto = normalizedWord(String(tokens[t].dropLast()))
                    + normalizedWord(tokens[t + 1])
                if !junto.isEmpty {
                    var achou = false
                    for j in cursor..<words.count
                    where normalizedWord(words[j].text) == junto {
                        casados.append((token: t, box: words[j].rect, page: words[j].page))
                        cursor = j + 1
                        t += 2
                        achou = true
                        break
                    }
                    if achou { continue }
                }
            }
            // Texto junto contra caixas partidas (2 seguintes).
            if cursor + 1 < words.count {
                let duas = normalizedWord(words[cursor].text)
                    + normalizedWord(words[cursor + 1].text)
                if !duas.isEmpty, duas == needle {
                    let uniao = words[cursor].rect.union(words[cursor + 1].rect)
                    casados.append((
                        token: t, box: uniao,
                        page: words[cursor].page ?? words[cursor + 1].page))
                    cursor += 2
                    t += 1
                    continue
                }
            }
            t += 1
        }
        return casados
    }

    /// Parte a frase na virada de página: devolve (texto, página, caixas)
    /// por trecho, na ordem. Sem virada, um trecho só. Interna para teste.
    ///
    /// Por que partir (pesquisa §5): o texto se junta para narrar, mas a
    /// caixa nunca atravessa páginas — antes, a frase levava as caixas da
    /// primeira página e o destaque saía na página errada.
    static func trechosPorPagina(
        sentence: String,
        casados: [(token: Int, box: CGRect, page: Int?)],
        paginaPadrao: Int?
    ) -> [(texto: String, pagina: Int?, caixas: [CGRect])] {
        let tokens = sentence.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // Página por token: a da caixa casada; sem caixa, herda a anterior.
        var paginaPorToken = [Int?](repeating: nil, count: tokens.count)
        var atual = paginaPadrao
        var c = 0
        for t in 0..<tokens.count {
            while c < casados.count, casados[c].token < t { c += 1 }
            if c < casados.count, casados[c].token == t, let pg = casados[c].page {
                atual = pg
            }
            paginaPorToken[t] = atual
        }
        // Agrupa consecutivos de mesma página.
        var trechos: [(texto: String, pagina: Int?, caixas: [CGRect])] = []
        var ini = 0
        for t in 1...tokens.count {
            if t == tokens.count || paginaPorToken[t] != paginaPorToken[ini] {
                let faixa = Array(tokens[ini..<t])
                let caixas = casados
                    .filter { $0.token >= ini && $0.token < t }
                    .map(\.box)
                trechos.append((
                    texto: faixa.joined(separator: " "),
                    pagina: paginaPorToken[ini],
                    caixas: groupByLine(caixas)))
                ini = t
            }
        }
        return trechos
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
