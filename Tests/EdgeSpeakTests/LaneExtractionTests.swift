import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import EdgeSpeak

/// Faixa de margem × regra por contagem: texto real curto deve sobreviver.
///
/// `isMarginNoise` descarta tudo com <= 12 caracteres na faixa de topo
/// (14%) ou pé (14%) sem olhar o conteúdo. Uma linha de rodapé curta de
/// verdade ("Baire 1911.", 11 chars) morria em silêncio. O contrato
/// documentado é: número de página, data/hora, URL e rótulo curto —
/// trecho que mistura letras com dígitos não é nenhuma das quatro
/// categorias (medido 2026-10-17).
struct LaneExtractionTests {
    /// PDF de uma página (CoreGraphics + CoreText), data-backed: o
    /// `PDFDocument` fica sem `documentURL` e o extrator segue o caminho
    /// PDFKit — nenhum subprocesso Python a partir dos testes.
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
        // Data-backed: garante o caminho PDFKit (sem PyMuPDF nos testes).
        #expect(pdf.documentURL == nil)
        return pdf
    }

    @Test func shortMarginFootnoteSurvivesTheCountRule() throws {
        var lines: [(text: String, y: CGFloat, size: CGFloat)] = (0..<6).map { i in
            (text: "Body line \(i) with enough words to be running prose text.",
             y: CGFloat(600 - i * 18), size: 12)
        }
        lines.append((text: "Baire 1911.", y: 90, size: 12))  // citação curta: texto real
        lines.append((text: "EBSCO", y: 70, size: 12))        // rótulo curto: continua ruído
        lines.append((text: "42", y: 50, size: 12))           // número de página: continua ruído
        let pdf = try makePDF(lines)
        let said = PDFTextExtractor.extract(pdf)
        #expect(said.contains("Baire 1911."))
        #expect(!said.contains("EBSCO"))
        #expect(!said.contains("42"))
    }
}
