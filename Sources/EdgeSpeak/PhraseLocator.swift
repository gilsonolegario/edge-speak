import CoreGraphics
import Foundation

/// Localiza a frase de leitura mais próxima de um ponto clicado no PDF.
///
/// Ideia de navegação por frase inspirada no PDFVoice (MIT): contenção vence,
/// senão o retângulo mais próximo, senão nada (margem). Só a ideia — sem
/// código de terceiros (ver CREDITS.md).
enum PhraseLocator {
    /// Distância máxima do ponto ao retângulo para valer um salto (pt).
    static let maxDistance: CGFloat = 40

    /// Índice global da frase clicada, ou nil quando o ponto cai na margem.
    ///
    /// Mesma página; vence o rect que CONTÉM o ponto; senão o rect mais
    /// próximo até `maxDistance`; frases sem rects são ignoradas.
    static func phraseIndex(
        near point: CGPoint, on page: Int, among phrases: [TextImport.Phrase]
    ) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for phrase in phrases {
            guard phrase.page == page, !phrase.rects.isEmpty else { continue }
            for rect in phrase.rects {
                if rect.contains(point) { return phrase.index }
                let d = distance(from: point, to: rect)
                if d <= maxDistance, best == nil || d < best!.distance {
                    best = (phrase.index, d)
                }
            }
        }
        return best?.index
    }

    /// Distância euclidiana ponto→retângulo (0 quando dentro).
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
