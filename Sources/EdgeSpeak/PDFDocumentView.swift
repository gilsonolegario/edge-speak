import SwiftUI
import PDFKit

/// Mostra o PDF renderizado por inteiro (todas as paginas), fiel ao original,
/// com destaque da frase em leitura.
///
/// O destaque é geométrico: recebe as caixas das linhas da FRASE (vindas
/// do extrator) e desenha uma anotação `.highlight` azul por caixa. Sem busca
/// por texto — o filtrado/refluído nunca é idêntico ao do PDF. `nil` limpa.
struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    /// Página da frase (0-based); `nil` limpa o destaque.
    var page: Int? = nil
    /// Caixas das linhas da frase, em coordenadas de página.
    var rects: [CGRect] = []
    /// Caixa da palavra em leitura, em coordenadas de página; `nil` limpa.
    var wordRect: CGRect? = nil
    /// Seguir a leitura: rola até o trecho; desligado, congela a rolagem.
    var follow: Bool = true
    /// Cada mudança força voltar ao trecho mesmo com follow desligado.
    var revealToken: Int = 0
    /// Rolagem iniciada pelo usuário: o dono desliga o seguimento aqui (a
    /// rolagem manual sempre vence a automática). `nil` desliga o aviso.
    var onUserScroll: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Clique no PDF: página (0-based) + ponto em coordenadas de página.
    /// `nil` (padrão) desliga; só o PDF usa — no Texto o pulo já existe.
    var onPageClick: ((Int, CGPoint) -> Void)?

    /// PDFView que distingue clique de arrasto: guarda o ponto no mouseDown e
    /// só reporta no mouseUp com deslocamento <4 pt; o resto (seleção, scroll)
    /// segue o comportamento normal do PDFKit.
    final class ClickablePDFView: PDFView {
        var onClickPage: ((PDFPage, CGPoint) -> Void)?
        private var downPoint: NSPoint?
        override func mouseDown(with event: NSEvent) {
            downPoint = event.locationInWindow
            super.mouseDown(with: event)
        }
        override func mouseUp(with event: NSEvent) {
            let upPoint = event.locationInWindow
            super.mouseUp(with: event)
            defer { downPoint = nil }
            guard let downPoint,
                  hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < 4
            else { return }
            let viewPoint = convert(upPoint, from: nil)
            guard let page = page(for: viewPoint, nearest: false) else { return }
            onClickPage?(page, convert(viewPoint, to: page))
        }
    }

    final class Coordinator {
        /// Chave da FRASE (página + caixas) das anotações atuais, sem a palavra:
        /// a troca de palavra não pode recriar as anotações da frase (piscaria).
        var lastPhraseKey: String?
        /// Última caixa de palavra aplicada + página, para trocar a anotação
        /// somente quando a palavra muda — nunca junto com a frase.
        var lastWordRect: CGRect?
        var lastWordPage: Int?
        var lastToken: Int = 0
        /// Anotações vivas do destaque AZUL da frase + a página que as contém.
        var phraseAnnotations: [PDFAnnotation] = []
        var phrasePage: PDFPage?
        /// Anotação viva do destaque palavra a palavra + a página que a contém.
        var wordAnnotation: PDFAnnotation?
        var wordPage: PDFPage?
        /// Último follow visto (para o detector não avisar com follow off) e
        /// o aviso de rolagem manual repassado pelo `updateNSView`.
        var follow: Bool = true
        var onUserScroll: () -> Void = {}
        /// Marco até o qual a mudança de origem é do próprio app: o `go(to:)`
        /// aplica a rolagem logo depois da chamada, e sem a janela o app se
        /// leria como usuário e desligaria o seguimento sozinho.
        var suppressUntil: Date = .distantPast
        /// Linha de base da geometria do clip view interno (origem, tamanho,
        /// escala): só mudança de ORIGEM com o resto parado é rolagem.
        var lastOrigin: CGPoint?
        var lastSize: CGSize?
        var lastScale: CGFloat?
        /// Clip view observado + ficha da assinatura, para remover no desmonte.
        weak var observedClipView: NSClipView?
        var boundsObserver: NSObjectProtocol?
    }

    /// Janela de silêncio após cada `go(to:)` programático, em segundos.
    static let programmaticScrollQuietWindow: TimeInterval = 0.5

    /// Decisão pura do detector: é rolagem do usuário somente quando o follow
    /// está ligado, fora da janela de silêncio do `go(to:)` do próprio app, a
    /// origem mudou e nem o tamanho nem a escala mudaram (zoom e
    /// redimensionamento mexem em tamanho/escala, nunca só na origem).
    static func isUserScroll(
        follow: Bool, suppressed: Bool,
        oldOrigin: CGPoint, newOrigin: CGPoint,
        oldSize: CGSize, newSize: CGSize,
        oldScale: CGFloat, newScale: CGFloat
    ) -> Bool {
        guard follow, !suppressed else { return false }
        let originMoved = abs(newOrigin.x - oldOrigin.x) > 0.5
            || abs(newOrigin.y - oldOrigin.y) > 0.5
        let sizeChanged = abs(newSize.width - oldSize.width) > 0.5
            || abs(newSize.height - oldSize.height) > 0.5
        let zoomChanged = abs(newScale - oldScale) > 0.001
        return originMoved && !sizeChanged && !zoomChanged
    }

    /// Decisão pura do seguimento da palavra: só rola quando o follow está
    /// ligado e a palavra está fora da área visível.
    static func shouldScrollToWord(follow: Bool, wordVisible: Bool) -> Bool {
        follow && !wordVisible
    }

    func makeNSView(context: Context) -> PDFView {
        let view = ClickablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.document = document
        observeUserScroll(in: view, coordinator: context.coordinator)
        return view
    }

    func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        if let token = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.boundsObserver = nil
        }
        coordinator.observedClipView = nil
    }

    /// Acha o `NSClipView` interno do `PDFView` (o PDFKit não o expõe em
    /// propriedade pública nesta versão do SDK: ele vive dentro do
    /// `NSScrollView` embutido) e observa a mudança dos seus limites: a
    /// origem é a posição da rolagem. Registra uma vez; o `updateNSView`
    /// tenta de novo quando ainda não achou (a hierarquia pode nascer tarde)
    /// e o `dismantleNSView` remove o observador.
    private func observeUserScroll(in view: PDFView, coordinator: Coordinator) {
        guard coordinator.boundsObserver == nil,
              let clip = Self.findClipView(in: view)
        else { return }
        clip.postsBoundsChangedNotifications = true
        coordinator.lastOrigin = clip.bounds.origin
        coordinator.lastSize = clip.bounds.size
        coordinator.lastScale = view.scaleFactor
        coordinator.observedClipView = clip
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main
        ) { [weak coordinator, weak view, weak clip] _ in
            guard let coordinator, let view, let clip else { return }
            Self.handleBoundsChange(clipView: clip, pdfView: view, coordinator: coordinator)
        }
    }

    /// Procura em profundidade o primeiro `NSScrollView` e devolve o seu
    /// `contentView`; `nil` quando a hierarquia ainda não existe.
    private static func findClipView(in view: NSView) -> NSClipView? {
        if let scroll = view as? NSScrollView { return scroll.contentView }
        for sub in view.subviews {
            if let found = findClipView(in: sub) { return found }
        }
        return nil
    }

    /// Filtro do detector: atualiza a linha de base e só avisa quando a
    /// decisão pura diz que foi o usuário (nunca por `go(to:)`, zoom ou
    /// redimensionamento, nunca com o follow já desligado).
    private static func handleBoundsChange(
        clipView: NSClipView, pdfView: PDFView, coordinator: Coordinator
    ) {
        let newOrigin = clipView.bounds.origin
        let newSize = clipView.bounds.size
        let newScale = pdfView.scaleFactor
        let userScroll = isUserScroll(
            follow: coordinator.follow,
            suppressed: Date.now < coordinator.suppressUntil,
            oldOrigin: coordinator.lastOrigin ?? newOrigin,
            newOrigin: newOrigin,
            oldSize: coordinator.lastSize ?? newSize,
            newSize: newSize,
            oldScale: coordinator.lastScale ?? newScale,
            newScale: newScale)
        coordinator.lastOrigin = newOrigin
        coordinator.lastSize = newSize
        coordinator.lastScale = newScale
        if userScroll { coordinator.onUserScroll() }
    }

    /// Marca a janela de silêncio antes de cada rolagem programática, para o
    /// detector não confundir o `go(to:)` do próprio app com o usuário.
    private static func markProgrammaticScroll(_ coordinator: Coordinator) {
        coordinator.suppressUntil = Date.now.addingTimeInterval(
            programmaticScrollQuietWindow)
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            // As anotações vivas pertenciam ao documento antigo (descartado sem
            // salvar); zera o estado de dedup e solta as referências.
            clearPhraseAnnotations(context.coordinator)
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastWordRect = nil
            context.coordinator.lastWordPage = nil
            context.coordinator.wordAnnotation = nil
            context.coordinator.wordPage = nil
        }
        // Liga o clique à página clicada (índice 0-based + ponto de página).
        if let clickable = view as? ClickablePDFView {
            clickable.onClickPage = { [document] pdfPage, point in
                onPageClick?(document.index(for: pdfPage), point)
            }
        }
        // Chave do follow e aviso de rolagem manual no coordenador (a struct
        // é refeita a cada avaliação; o detector lê do coordenador) + nova
        // tentativa de observar, caso a hierarquia ainda não existisse.
        context.coordinator.follow = follow
        context.coordinator.onUserScroll = onUserScroll ?? {}
        observeUserScroll(in: view, coordinator: context.coordinator)
        let phraseKey = key(page: page, rects: rects)
        let tokenChanged = revealToken != context.coordinator.lastToken
        let phraseChanged = phraseKey != context.coordinator.lastPhraseKey || tokenChanged
        // Palavra mudou: caixa nova (ou página nova, ou chega/limpa a caixa).
        let wordChanged = page != context.coordinator.lastWordPage
            || wordRect != context.coordinator.lastWordRect

        guard let page, let pdfPage = document.page(at: page) else {
            // Sem página (leitura terminou): limpa anotações e seleção; nada órfão.
            view.setCurrentSelection(nil, animate: false)
            clearPhraseAnnotations(context.coordinator)
            clearWordAnnotation(context.coordinator)
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastWordRect = nil
            context.coordinator.lastWordPage = nil
            context.coordinator.lastToken = revealToken
            return
        }
        // Karaokê geométrico: as anotações vivem na página, então rolam
        // junto sem reposicionamento manual. A frase troca SÓ pela chave
        // própria; a palavra troca SÓ a anotação amarela.
        if wordChanged {
            updateWordAnnotation(on: pdfPage, rect: wordRect, context.coordinator)
            // Seguir a leitura mira a caixa da palavra, mas só rola quando ela
            // está fora da área visível: rolar a cada palavra engasga a fala.
            if let word = wordRect, Self.shouldScrollToWord(
                follow: follow,
                wordVisible: view.convert(view.visibleRect, to: pdfPage).intersects(word)
            ) {
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: word, on: pdfPage)
            }
            context.coordinator.lastWordRect = wordRect
            context.coordinator.lastWordPage = page
        }
        guard !rects.isEmpty else {
            // Sem caixas (texto sem PDF): limpa a frase, só rola até a página.
            clearPhraseAnnotations(context.coordinator)
            view.setCurrentSelection(nil, animate: false)
            if follow || tokenChanged {
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: pdfPage)
            }
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastToken = revealToken
            return
        }
        // Frase: recriar as anotações somente quando a frase muda (retoques de
        // 10 Hz e troca de palavra não recriam nada). Desenhadas pela página,
        // rolam junto sem reposicionamento manual.
        if phraseChanged {
            clearPhraseAnnotations(context.coordinator)
            view.setCurrentSelection(nil, animate: false)
            for box in rects {
                let annot = PDFAnnotation(
                    bounds: box, forType: .highlight, withProperties: nil)
                annot.color = NSColor.controlAccentColor.withAlphaComponent(0.28)
                pdfPage.addAnnotation(annot)
                context.coordinator.phraseAnnotations.append(annot)
            }
            context.coordinator.phrasePage = pdfPage
            if follow || tokenChanged {
                let box = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: box, on: pdfPage)
            }
            context.coordinator.lastPhraseKey = phraseKey
            context.coordinator.lastToken = revealToken
        }
    }

    /// Remove as anotações vivas da frase, se houver; sem ela o destaque velho
    /// ficaria órfão no documento (que o app nunca salva).
    private func clearPhraseAnnotations(_ coordinator: Coordinator) {
        if let page = coordinator.phrasePage {
            for annot in coordinator.phraseAnnotations {
                page.removeAnnotation(annot)
            }
        }
        coordinator.phraseAnnotations = []
        coordinator.phrasePage = nil
    }

    /// Remove a anotação viva da palavra, se houver; sem ela o destaque velho
    /// ficaria órfão no documento (que o app nunca salva).
    private func clearWordAnnotation(_ coordinator: Coordinator) {
        if let annot = coordinator.wordAnnotation,
           let page = coordinator.wordPage {
            page.removeAnnotation(annot)
        }
        coordinator.wordAnnotation = nil
        coordinator.wordPage = nil
    }

    /// Troca a anotação da palavra: remove a anterior antes de adicionar a
    /// nova; mesma página e mesmos limites reaproveitam a viva (evita piscar
    /// quando só o token mudou).
    private func updateWordAnnotation(
        on pdfPage: PDFPage, rect: CGRect?, _ coordinator: Coordinator
    ) {
        guard let rect else {
            clearWordAnnotation(coordinator)
            return
        }
        if coordinator.wordPage === pdfPage,
           let annot = coordinator.wordAnnotation,
           annot.bounds == rect {
            return
        }
        clearWordAnnotation(coordinator)
        let annot = PDFAnnotation(
            bounds: rect, forType: .highlight, withProperties: nil)
        annot.color = NSColor.systemYellow.withAlphaComponent(0.55)
        pdfPage.addAnnotation(annot)
        coordinator.wordAnnotation = annot
        coordinator.wordPage = pdfPage
    }

    /// Chave de deduplicação da FRASE: página + caixas (sem a palavra — a
    /// palavra tem chave própria no Coordinator).
    private func key(page: Int?, rects: [CGRect]) -> String {
        guard let page else { return "nil" }
        let boxes = rects.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }
            .joined(separator: ";")
        return "\(page)|\(boxes)"
    }
}
