import CoreGraphics
import Testing

@testable import EdgeSpeak

/// Prova da regra "rolagem manual vence": só a mudança de origem com o resto
/// parado e fora da janela do `go(to:)` conta como usuário; palavra visível
/// nunca rola sozinha.
struct PDFFollowTests {
    private let origin = CGPoint(x: 0, y: 100)
    private let size = CGSize(width: 600, height: 800)

    /// Só origem mudou, follow ligado, sem `go(to:)` recente: é o usuário.
    @Test func rolagemDoUsuarioDesliga() {
        #expect(PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1))
    }

    /// Logo após o `go(to:)` do app a origem muda sozinha: não é o usuário.
    @Test func rolagemProgramaticaNaoDesliga() {
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: true,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1))
    }

    /// Follow já desligado: nenhuma mudança de origem gera aviso.
    @Test func seguimentoDesligadoNaoEAfetado() {
        #expect(!PDFDocumentView.isUserScroll(
            follow: false, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1))
    }

    /// Zoom (escala muda) e redimensionamento (tamanho muda) não desligam,
    /// mesmo quando a origem se desloca junto.
    @Test func zoomEResizeNaoDesligam() {
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: size,
            oldScale: 1, newScale: 1.5))
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: origin,
            oldSize: size, newSize: CGSize(width: 700, height: 800),
            oldScale: 1, newScale: 1))
        #expect(!PDFDocumentView.isUserScroll(
            follow: true, suppressed: false,
            oldOrigin: origin, newOrigin: CGPoint(x: 0, y: 250),
            oldSize: size, newSize: CGSize(width: 700, height: 800),
            oldScale: 1, newScale: 1))
    }

    /// Palavra visível não rola; fora da vista com follow rola; sem follow
    /// nunca rola sozinha.
    @Test func palavraVisivelNaoRola() {
        #expect(!PDFDocumentView.shouldScrollToWord(follow: true, wordVisible: true))
        #expect(PDFDocumentView.shouldScrollToWord(follow: true, wordVisible: false))
        #expect(!PDFDocumentView.shouldScrollToWord(follow: false, wordVisible: false))
    }
}
