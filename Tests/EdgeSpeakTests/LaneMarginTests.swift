import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import EdgeSpeak

/// Plano item 54 — `isMarginNoise` contra um rodapé curto REAL na margem.
///
/// MEDIÇÃO (2026-10-18). PDF sintético de uma página, 612 × 792 pt; faixa de
/// topo = `minY > 681,12` e faixa de pé = `maxY < 110,88` (14% de cada lado,
/// `PDFTextExtractor.swift:286-287`). As 8 linhas medidas com a MESMA API que
/// o extrator usa (`PDFPage.selection(for:)` + `selectionsByLine()` +
/// `bounds(for:)`); a tabela sai impressa por
/// `measurementOfTheMarginBandAndBothRules`:
///
/// | linha                | chars | maxY  | faixa | regra do HEAD | regra da árvore |
/// |----------------------|-------|-------|-------|---------------|-----------------|
/// | `Baire 1911.` (y=90) | 11    | 99,2  | pé    | DESCARTADA    | mantida         |
/// | `EBSCO` (y=70)       | 5     | 79,2  | pé    | descartada    | descartada      |
/// | `42` (y=50)          | 2     | 59,2  | pé    | descartada    | descartada      |
/// | `Filosofia` (y=30)   | 9     | 39,2  | pé    | descartada    | descartada      |
/// | `Draft` (y=745)      | 5     | 754,2 | topo  | descartada    | descartada      |
/// | `Page 42 of 200`     | 14    | 729,2 | topo  | descartada    | descartada      |
/// | `12/03/2019`         | 10    | 709,2 | topo  | descartada    | descartada      |
/// | `https://example.com/x` | 21 | 694,2 | topo  | descartada    | descartada      |
///
/// O ANTES foi medido com o extrator de verdade, não por paráfrase: com a
/// regra do HEAD (`if text.count <= 12 { return true }`,
/// `git show HEAD:Sources/EdgeSpeak/PDFTextExtractor.swift:298`) restaurada só
/// durante a medição, `PDFTextExtractor.extract` devolveu APENAS a linha de
/// corpo — "Baire 1911." (11 caracteres, nenhuma das três regras de padrão
/// casando) sumiu sem aviso, e nenhum filtro posterior pode ressuscitar uma
/// linha já descartada. Com a regra da árvore
/// (`text.count <= 12 && !mistura(letra, dígito)`, `:293-299`) a mesma página
/// sai com o rodapé e com os quatro tipos de ruído ainda fora.
///
/// CUSTO MEDIDO da regra conservadora, do outro lado: um rótulo de margem
/// que mistura letra e dígito ("Vol. 3", 6 chars) deixa de ser comido pela
/// contagem — aqui ele passa a entrar no texto em documento de 1–2 páginas;
/// com três ou mais, `repeatedKeys` o remove antes (mínimo documentado no
/// código: 3 ocorrências em 3 páginas).
struct LaneMarginTests {
    /// PDF data-backed (CoreGraphics + CoreText): o `PDFDocument` fica sem
    /// `documentURL` e o extrator segue o caminho PDFKit — nenhum
    /// subprocesso Python a partir dos testes.
    private func makePDF(_ lines: [(text: String, y: CGFloat, size: CGFloat)]) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil)
        for item in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, item.size, nil)
            let attrs = [kCTFontAttributeName: font] as CFDictionary
            let line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, item.text as CFString, attrs))
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: 72, y: item.y)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        let pdf = try #require(PDFDocument(data: data as Data))
        #expect(pdf.documentURL == nil)
        return pdf
    }

    /// Corpo e margens do PDF de medição. O corpo não tem dígito nenhum, para
    /// que `!saida.contains("42")` prove sozinho que a linha de página caiu.
    private var measuredPage: [(text: String, y: CGFloat, size: CGFloat)] {
        var lines: [(text: String, y: CGFloat, size: CGFloat)] = (0..<6).map { i in
            (text: "Corpo da pagina com palavras suficientes para nao ser margem.",
             y: CGFloat(600 - i * 18), size: 12)
        }
        lines.append((text: "Baire 1911.", y: 90, size: 12))        // rodapé real curto
        lines.append((text: "EBSCO", y: 70, size: 12))              // rótulo, sem dígito
        lines.append((text: "Filosofia", y: 30, size: 12))          // rótulo real, sem dígito
        lines.append((text: "42", y: 50, size: 12))                 // número de página
        lines.append((text: "Draft", y: 745, size: 12))             // rótulo de topo
        lines.append((text: "Page 42 of 200", y: 720, size: 12))    // paginação explícita
        lines.append((text: "12/03/2019", y: 700, size: 12))        // data
        lines.append((text: "https://example.com/x", y: 685, size: 12))  // URL
        return lines
    }

    /// A regra do HEAD, transcrita linha a linha, para medir o ANTES sem
    /// mexer na árvore. Fonte: `git show HEAD:Sources/EdgeSpeak/PDFTextExtractor.swift`.
    private func headRuleDrops(_ text: String, maxY: CGFloat, minY: CGFloat, pageHeight: CGFloat) -> Bool {
        let inTopBand = minY > pageHeight * 0.86
        let inBottomBand = maxY < pageHeight * 0.14
        guard inTopBand || inBottomBand else { return false }
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        if matches(#"^(?:Page\s+)?\d{1,4}(?:\s+(?:of|de)\s+\d{1,4})?$"#) { return true }
        if matches(#"^\d{1,4}\s*[/.\-]\s*\d{1,4}\s*[/.\-]\s*\d{2,4}"#) { return true }
        if matches(#"^(?:about|chrome|file|https?):"#) { return true }
        if text.count <= 12 { return true }
        return false
    }

    /// A regra da árvore, transcrita: só cai sem mistura de letra e dígito.
    private func treeRuleDrops(_ text: String, maxY: CGFloat, minY: CGFloat, pageHeight: CGFloat) -> Bool {
        let inTopBand = minY > pageHeight * 0.86
        let inBottomBand = maxY < pageHeight * 0.14
        guard inTopBand || inBottomBand else { return false }
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        if matches(#"^(?:Page\s+)?\d{1,4}(?:\s+(?:of|de)\s+\d{1,4})?$"#) { return true }
        if matches(#"^\d{1,4}\s*[/.\-]\s*\d{1,4}\s*[/.\-]\s*\d{2,4}"#) { return true }
        if matches(#"^(?:about|chrome|file|https?):"#) { return true }
        let mixes = text.contains(where: \.isLetter) && text.contains(where: \.isNumber)
        if text.count <= 12 && !mixes { return true }
        return false
    }

    /// A medição: imprime a geometria REAL de cada linha da margem e o veredito
    /// das duas regras sobre ela. A geometria vem da mesma API do extrator.
    @Test func measurementOfTheMarginBandAndBothRules() throws {
        let pdf = try makePDF(measuredPage)
        let page = try #require(pdf.page(at: 0))
        let height = page.bounds(for: .mediaBox).height
        let selection = try #require(page.selection(for: page.bounds(for: .mediaBox)))
        var measured = 0
        for line in selection.selectionsByLine() {
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = line.bounds(for: page)
            let inBand = box.minY > height * 0.86 || box.maxY < height * 0.14
            guard inBand else { continue }
            measured += 1
            let head = headRuleDrops(text, maxY: box.maxY, minY: box.minY, pageHeight: height)
            let tree = treeRuleDrops(text, maxY: box.maxY, minY: box.minY, pageHeight: height)
            print("""
                [item 54] "\(text)" chars=\(text.count) \
                maxY=\(String(format: "%.1f", box.maxY)) \
                faixa=\(box.minY > height * 0.86 ? "topo" : "pe") \
                HEAD=\(head ? "descarta" : "mantem") \
                arvore=\(tree ? "descarta" : "mantem")
                """)
        }
        #expect(measured > 0, "o PDF de medição precisa de linhas na faixa de margem")
    }

    /// Os dois lados no mesmo PDF: o rodapé curto de verdade sobrevive e o
    /// ruído de página continua fora.
    @Test func shortRealFooterSurvivesAndPageNoiseStaysDropped() throws {
        let said = PDFTextExtractor.extract(try makePDF(measuredPage))
        // Lado que conserta: linha real curta na faixa de pé.
        #expect(said.contains("Baire 1911."), "rodapé real de 11 caracteres sumiu: \(said.prefix(300))")
        #expect(said.contains("Corpo da pagina com palavras suficientes"))
        // Lado que não pode regredir: os quatro tipos de ruído do contrato.
        #expect(!said.contains("EBSCO"))
        #expect(!said.contains("Page 42"), "paginação explícita vazou")
        #expect(!said.contains("42"), "número de página vazou")
        #expect(!said.contains("2019"), "data vazou")
        #expect(!said.contains("https://"), "URL vazou")
    }

    /// Fora da faixa de margem a contagem nunca foi regra: uma linha curta no
    /// meio do corpo sobrevive antes e depois.
    @Test func shortLineOutsideTheBandIsNeverMarginNoise() throws {
        var lines: [(text: String, y: CGFloat, size: CGFloat)] = (0..<5).map { i in
            (text: "Corpo da pagina com palavras suficientes para nao ser margem.",
             y: CGFloat(600 - i * 18), size: 12)
        }
        lines.append((text: "Baire.", y: 400, size: 12))   // 6 chars, no meio da página
        let said = PDFTextExtractor.extract(try makePDF(lines))
        #expect(said.contains("Baire."))
    }

    /// Limite conservador ACEITO e registrado: rótulo de margem sem dígito
    /// continua caindo (é o preço de não olhar o conteúdo). Se um dia a
    /// extração passar a decidir por outra evidência (fonte menor, itálico,
    /// repetição em 1 página), este teste é o que muda primeiro.
    @Test func labelsWithoutDigitsInTheMarginStillGoAway() throws {
        let said = PDFTextExtractor.extract(try makePDF(measuredPage))
        #expect(!said.contains("EBSCO"))
        #expect(!said.contains("Draft"))
        #expect(!said.contains("Filosofia"))
    }

    /// Custo MEDIDO da regra conservadora, do outro lado: um rótulo de margem
    /// que mistura letra e dígito ("Vol. 3") deixa de ser comido pela
    /// contagem. Em documento de 1–2 páginas ele entra no texto; com 3 ou mais,
    /// `repeatedKeys` o remove (3 ocorrências em 3 páginas). Fica registrado
    /// para o merge não ler isso como ruído novo.
    @Test func digitMixingMarginLabelSurvivesAsMeasuredCost() throws {
        var page: [(text: String, y: CGFloat, size: CGFloat)] = (0..<5).map { i in
            (text: "Corpo da pagina com palavras suficientes para nao ser margem.",
             y: CGFloat(600 - i * 18), size: 12)
        }
        page.append((text: "Vol. 3", y: 60, size: 12))
        let said = PDFTextExtractor.extract(try makePDF(page))
        #expect(said.contains("Vol. 3"), "letra+dígito na margem não é mais comido pela contagem")
    }
}
