import SwiftUI
import AppKit

/// Texto clicável que informa qual trecho foi clicado.
///
/// Por que não um `Text` do SwiftUI: ele renderiza o `AttributedString`, mas
/// devolve apenas "clicaram no texto", sem dizer ONDE. Para pular a leitura
/// até a frase é necessário o índice do caractere sob o cursor, e só o
/// TextKit fornece isso de forma confiável.
///
/// Por que `NSScrollView` em volta: o `NSTextView` não tem tamanho intrínseco.
/// Dar a ele a altura do texto inteiro faz o painel engolir a janela e
/// esconder o PDF (defeito medido); com rolagem interna o painel tem altura
/// limitada e o texto rola dentro dele.
struct ClickableTextView: NSViewRepresentable {
    let attributed: AttributedString
    /// Tamanho em pontos. Passamos o número em vez de `Font` porque `Font` é
    /// um invólucro opaco, e o `NSTextView` precisa do valor em ponto.
    let pointSize: CGFloat
    /// Recebe o índice do caractere clicado dentro do texto.
    let onTap: (Int) -> Void
    /// Trecho (UTF-16) da frase lida, para o teleprompter rolar até ele.
    var scrollTo: NSRange? = nil
    /// Seguir a leitura; desligado, a rolagem manual é respeitada.
    var follow: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastScrolledLocation: Int = -1
        var lastScrolledLength: Int = -1
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ClickReportingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // Necessário para o clique chegar ao texto e não à view que o contém.
        textView.isAutomaticLinkDetectionEnabled = false
        // Cor explícita adaptativa: sem isto, texto sem atributo saía preto
        // fixo, ilegível no modo escuro — independente do pipeline de attrs.
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.onCharacterTap = { [weak textView] index in
            guard index >= 0, let textView else { return }
            onTap(index)
            textView.setSelectedRange(NSRange(location: min(index, (textView.string as NSString).length), length: 0))
        }
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClickReportingTextView else { return }
        // A closure de clique é reatribuída a CADA update: `makeNSView` só roda
        // uma vez e capturava o `onTap` do primeiro `body`. Ao trocar de
        // arquivo, a closure antiga mapeava o clique contra o texto anterior
        // (achado B5). Reatribuir mantém `onTap` sempre o do documento corrente.
        textView.onCharacterTap = { [weak textView] index in
            guard index >= 0, let textView else { return }
            onTap(index)
            textView.setSelectedRange(NSRange(location: min(index, (textView.string as NSString).length), length: 0))
        }
        let current = NSAttributedString(attributed)
        if let storage = textView.textStorage, !storage.isEqual(to: current) {
            storage.setAttributedString(current)
            textView.font = NSFont.systemFont(ofSize: pointSize)
            textView.textContainer?.widthTracksTextView = true
        }
        // Teleprompter: rola até a frase lida quando ela muda (não a cada
        // palavra, para não tremer); com follow desligado, não toca na
        // rolagem do usuário.
        if follow,
           let target = scrollTo,
           target.location >= 0,
           target.location + target.length <= (textView.string as NSString).length,
           (target.location != context.coordinator.lastScrolledLocation
            || target.length != context.coordinator.lastScrolledLength) {
            context.coordinator.lastScrolledLocation = target.location
            context.coordinator.lastScrolledLength = target.length
            textView.scrollRangeToVisible(target)
        } else if scrollTo == nil {
            context.coordinator.lastScrolledLocation = -1
            context.coordinator.lastScrolledLength = -1
        }
    }
}

/// `NSTextView` que reporta o caractere clicado — só o CLIQUE, não o
/// arrasto: sem a guarda, arrastar para selecionar disparava o salto da
/// leitura no ponto da pressão (achado da auditoria; o PDF já filtrava
/// deslocamento <4 pt no `ClickablePDFView`).
final class ClickReportingTextView: NSTextView {
    var onCharacterTap: ((Int) -> Void)?

    private var downPoint: NSPoint?
    private var downChar: Int?

    override func mouseDown(with event: NSEvent) {
        // O ponto do evento vem em coordenadas da view; o TextKit trabalha com
        // as do container de texto, que tem inset próprio. A conversão
        // janela→view independe da rolagem (só muda o trecho visível).
        downPoint = event.locationInWindow
        let pointInContainer = convert(event.locationInWindow, from: nil)
        if let manager = layoutManager, let container = textContainer {
            let glyph = manager.glyphIndex(for: pointInContainer, in: container)
            downChar = manager.characterIndexForGlyph(at: glyph)
        } else {
            downChar = nil
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let upPoint = event.locationInWindow
        super.mouseUp(with: event)
        defer {
            downPoint = nil
            downChar = nil
        }
        guard let downPoint, let downChar,
              hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < 4
        else { return }
        onCharacterTap?(downChar)
    }
}
