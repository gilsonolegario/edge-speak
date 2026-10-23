import SwiftUI
import PDFKit

/// Shows the PDF rendered in full (all pages), faithful to the original,
/// with the sentence being read highlighted.
///
/// The highlight is geometric: it receives the boxes of the SENTENCE's lines (from the
/// extractor) and draws a blue `.highlight` annotation per box. No text
/// search — the filtered/reflowed text is never identical to the PDF's. `nil` clears.
struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    /// Page of the sentence (0-based); `nil` clears the highlight.
    var page: Int? = nil
    /// Boxes of the sentence's lines, in page coordinates.
    var rects: [CGRect] = []
    /// Box of the word being read, in page coordinates; `nil` clears.
    var wordRect: CGRect? = nil
    /// Page that OWNS `wordRect`. A sentence that crosses a page break keeps
    /// the page where it starts, but its continuation words are boxes of the
    /// next page: drawing them on the sentence's page put the yellow on the
    /// wrong place (measured: 11 sentences and 628 words in Neutrality_v82).
    /// `nil` falls back to the sentence's page.
    var wordPage: Int? = nil
    /// Follow the reading: scrolls to the passage; when off, freezes the scroll.
    var follow: Bool = true
    /// Transient follow brake: a manual scroll holds ONLY for the moment;
    /// any highlight advance releases it. The master (`follow`) still applies.
    var scrollHold: Bool = false
    /// Each change forces back to the passage even with follow off.
    var revealToken: Int = 0
    /// Scroll started by the user: the owner turns follow off here (manual
    /// scroll always beats the automatic one). `nil` turns the notice off.
    var onUserScroll: (() -> Void)? = nil

    // MARK: Destaques do usuário (sidecar; spec §3–§6)

    /// Modo destacar (estilo Preview): ligado, o app para de zerar a seleção
    /// do usuário nos três pontos que hoje limpam o PDF, o subtítulo da
    /// janela recebe o aviso e o arrasto (≥ 4 pt) é consumido — SÓ o
    /// resultado da seleção nativa; arrasto, clique curto, setas, espaço,
    /// rolagem e zoom seguem exatamente como antes. Momentâneo, nunca
    /// persistido.
    var highlightMode: Bool = false
    /// Registros do sidecar para pintar (repaint na abertura; diff por id).
    var userHighlights: [StoredHighlight] = []
    /// Um toque por registro criado (criação E recriação de undo/redo):
    /// quem persiste é o dono do sidecar.
    var onHighlightAdded: ((StoredHighlight) -> Void)?
    /// Um toque por registro removido; o record chega antes de sair (o undo
    /// e o sidecar precisam do registro inteiro).
    var onHighlightRemoved: ((StoredHighlight) -> Void)?
    /// Título do item "Remover destaque" do menu de contexto (idioma da UI).
    var removeHighlightLabel: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Click on the PDF: page (0-based) + point in page coordinates.
    /// `nil` (default) turns it off; only the PDF uses it — in Text the jump already exists.
    var onPageClick: ((Int, CGPoint) -> Void)?

    /// Puro e testável (item 25): a régua de rótulos que seguem o
    /// `fontSize` do app (piso 11, teto 21). O cabeçalho interno do PDF foi
    /// movido para o subtítulo da janela; a régua sobrevive porque os
    /// testes a pinam e o subtítulo pode reusá-la.
    /// Pura e testável: nil (ou fora da faixa) volta ao 11 histórico.
    static func headerPointSize(for fontSize: Double?) -> CGFloat {
        guard let fontSize else { return 11 }
        return CGFloat(max(11, min(fontSize, 21)))
    }

    // MARK: Lane UI 2026-10-17 (itens 26, 40, 42)

    /// Plano item 26: relato da PÁGINA VISÍVEL (primeira de `visiblePages`) →
    /// o cabeçalho do app mostra a página na tela quando ninguém lê; durante
    /// a leitura o cabeçalho continua seguindo o trecho ancorado (o destaque
    /// é a verdade lá). Dispara no `handleBoundsChange` e a cada update.
    var onVisiblePageChange: ((Int) -> Void)? = nil

    /// Plano item 42: ir para página (0-based), pelo token — token evita
    /// re-navegação quando o alvo não muda e não interfere no follow.
    var goToPage: Int? = nil
    var goToPageToken: Int = 0

    /// Plano item 40: Find do PDFKit (⌘F — `document.findString`). Consulta
    /// trocada recomeça no primeiro resultado; cada avanço pula um. A seleção
    /// do Find é a seleção NATIVA do `PDFView` — distinta das anotações de
    /// leitura (azul por frase / amarelo por palavra), que seguem intocadas.
    var findQuery: String = ""
    var findAdvance: Int = 0
    /// Contagem de ocorrências (uma vez por consulta nova).
    var onFindCount: ((Int) -> Void)? = nil

    typealias NSViewType = NSView

    /// `PDFView` that tells click from drag: stores the point at mouseDown and
    /// only reports at mouseUp with displacement <4 pt; the rest (selection, scroll)
    /// follows PDFKit's normal behavior.
    ///
    /// Plano S2 — `PDFViewAnnotationHitNotification`: SEM observador, por
    /// decisão da spec (§4 «o app decide ignorá-la (sem observador, sem
    /// consumidor)» e §6). O clique sobre anotação (de leitura ou destaque do
    /// usuário) já é tratado por ESTE `mouseUp`: clique curto →
    /// `PhraseLocator` — o clique sobre um destaque pula a leitura como
    /// qualquer clique. Nada escuta a notificação e nenhum caminho novo a
    /// consumirá: qualquer futuro tratamento é tarefa de fase 2 da spec, não
    /// desta lane.
    final class ClickablePDFView: PDFView {
        var onClickPage: ((PDFPage, CGPoint) -> Void)?
        /// End of a DRAG (≥ 4 pt): the native selection is already done in
        /// `super.mouseUp`; only here the RESULT is consumed — and the
        /// consumer decides what to do with it (no mode: nothing).
        var onDragSelection: (() -> Void)?
        /// Context menu on an annotation signed "EdgeSpeak": "Remover destaque".
        ///_stealth: qualquer anotação sem a nossa assinatura segue o menu nativo.
        var onRemoveHighlight: ((String) -> Void)?
        /// Título do item de remoção (idioma da UI, injetado por update).
        var removeTitle: String = ""
        private var downPoint: NSPoint?
        /// Last reported click, for the double-click debounce.
        private var lastClickAt: Date?

        /// Minimum gap between reported clicks: a double click is two down/up
        /// pairs (both under 4 pt) and would jump the reading twice (restart +
        /// double scroll). PDFKit's own click handling is untouched — it happens
        /// in `super.mouseUp`.
        static let clickDebounce: TimeInterval = 0.25

        override func mouseDown(with event: NSEvent) {
            downPoint = event.locationInWindow
            super.mouseDown(with: event)
        }
        override func mouseUp(with event: NSEvent) {
            let upPoint = event.locationInWindow
            super.mouseUp(with: event)
            defer { downPoint = nil }
            guard let downPoint else { return }
            if hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < 4 {
                // Short click: jump to reading, whenever the highlight mode is
                // on or off (spec §4 — "clique é clique").
                let viewPoint = convert(upPoint, from: nil)
                guard let page = page(for: viewPoint, nearest: false) else { return }
                onClickPage?(page, convert(viewPoint, to: page))
            } else {
                onDragSelection?()
            }
        }
        /// Context menu: an item "Remover destaque" ONLY over an annotation
        /// signed by us (`textLabel == HighlightMarks.owner`); anything else
        /// (reading annotations, third-party, empty area) keeps the native menu.
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let id = identifierOfOurAnnotation(for: event) else {
                return super.menu(for: event)
            }
            let menu = NSMenu()
            let item = NSMenuItem(
                title: removeTitle.isEmpty
                    ? HighlightMarks.undoRemoveName : removeTitle,
                action: #selector(removeUserHighlightClicked(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
            return menu
        }
        /// Our annotation under the click: page + point (same conversion of the
        /// mouseUp), `annotation(at:)`, and the owner's signature as filter.
        private func identifierOfOurAnnotation(for event: NSEvent) -> String? {
            let point = convert(event.locationInWindow, from: nil)
            guard let page = page(for: point, nearest: false) else { return nil }
            let pagePoint = convert(point, to: page)
            guard let annotation = page.annotation(at: pagePoint) else { return nil }
            let owner = annotation.value(forAnnotationKey: .textLabel) as? String
            guard owner == HighlightMarks.owner else { return nil }
            return annotation.value(forAnnotationKey: .name) as? String
        }
        @objc private func removeUserHighlightClicked(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            onRemoveHighlight?(id)
        }
    }

    final class Coordinator {
        /// Key of the SENTENCE (page + boxes) of the current annotations, without the word:
        /// a word change must not recreate the sentence's annotations (flicker).
        var lastPhraseKey: String?
        /// Last applied word box + page, to swap the annotation
        /// only when the word changes — never together with the sentence.
        var lastWordRect: CGRect?
        var lastWordPage: Int?
        var lastToken: Int = 0
        /// Live annotations of the sentence's BLUE highlight + the page containing them.
        var phraseAnnotations: [PDFAnnotation] = []
        var phrasePage: PDFPage?
        /// Live annotation of the word-by-word highlight + the page containing it.
        var wordAnnotation: PDFAnnotation?
        var wordPage: PDFPage?
        /// Last follow seen (so the detector does not report with follow off) and
        /// the manual-scroll notice relayed by `updateNSView`.
        var follow: Bool = true
        var onUserScroll: () -> Void = {}
        /// Marker up to which an origin change is the app's own: `go(to:)`
        /// applies the scroll right after the call, and without the window the app would
        /// read itself as the user and turn follow off by itself.
        var suppressUntil: Date = .distantPast
        /// Baseline of the inner clip view's geometry (origin, size,
        /// scale): only an ORIGIN change with everything else still is a scroll.
        var lastOrigin: CGPoint?
        var lastSize: CGSize?
        var lastScale: CGFloat?
        /// Observed `NSClipView` + signature token, to remove on dismantle.
        weak var observedClipView: NSClipView?
        var boundsObserver: NSObjectProtocol?
        weak var containerView: NSView?
        weak var pdfView: PDFView?

        // MARK: Lane UI 2026-10-17 (itens 26, 40, 42)

        /// Índice da última página visível reportada (item 26).
        var lastVisiblePage: Int? = nil
        var onVisiblePageChange: (Int) -> Void = { _ in }
        /// Token do "ir para página" já executado (item 42).
        var lastGoToPageToken = 0
        /// Estado do Find (item 40): consulta em curso, resultados e cursor.
        var lastFindQuery: String? = nil
        var lastFindAdvance = 0
        var findMatches: [PDFSelection] = []
        var findShownIndex = 0
        var onFindCount: (Int) -> Void = { _ in }

        // MARK: Destaques do usuário — casa própria (spec §6)

        /// As anotações de uso SOBREVIVEM à leitura: elas SÃO de casa própria e
        /// nunca entram em `phraseAnnotations`/`wordAnnotation` (nenhum clear
        ///path as alcança). id → (página, anotações — UMA por linha, todas
        /// com o mesmo id em `.name`).
        var userAnnotations: [String: (page: PDFPage, annotations: [PDFAnnotation])] = [:]
        /// O registro inteiro por id (o undo e o sidecar precisam do conteúdo).
        var userRecords: [String: StoredHighlight] = [:]
        /// Do outro lado (dono do sidecar), espelhado a cada update.
        var onHighlightAdded: (StoredHighlight) -> Void = { _ in }
        var onHighlightRemoved: (StoredHighlight) -> Void = { _ in }

        /// Anexa UMA anotação do usuário; idempotente por id. `notify: false`
        /// é o caminho de repaint (o sidecar já tem o registro); `true` é a
        /// mutação viva (o dono grava).
        func attachUserHighlight(record: StoredHighlight, on page: PDFPage, notify: Bool) {
            guard userRecords[record.id] == nil else { return }
            let annots = PDFDocumentView.makeUserAnnotation(record, on: page)
            for annot in annots { page.addAnnotation(annot) }
            userAnnotations[record.id] = (page, annots)
            userRecords[record.id] = record
            if notify { onHighlightAdded(record) }
        }

        /// O ÚNICO caminho de remoção (menu, undo-de-criar, troca de
        /// documento). Devolve o registro destacado, para o undo.
        @discardableResult
        func detachUserHighlight(id: String, notify: Bool) -> StoredHighlight? {
            if let holder = userAnnotations.removeValue(forKey: id) {
                for annot in holder.annotations {
                    holder.page.removeAnnotation(annot)
                }
            }
            let record = userRecords.removeValue(forKey: id)
            if let record, notify { onHighlightRemoved(record) }
            return record
        }

        /// Criação com undo (⌘Z desfaz; ⇧⌘Z refaz de graça). Sem janela/gestor
        /// (raro), a mutação fica válida só sem desfazer (spec §9).
        func createUserHighlight(record: StoredHighlight, on page: PDFPage) {
            attachUserHighlight(record: record, on: page, notify: true)
            guard let manager = pdfView?.window?.undoManager else { return }
            manager.setActionName(HighlightMarks.undoCreateName)
            manager.registerUndo(withTarget: self) { coordinator in
                coordinator.undoCreateHighlight(record: record, page: page)
            }
        }

        private func undoCreateHighlight(record: StoredHighlight, page: PDFPage) {
            guard userRecords[record.id] != nil else { return }
            detachUserHighlight(id: record.id, notify: true)
            guard let manager = pdfView?.window?.undoManager else { return }
            manager.registerUndo(withTarget: self) { coordinator in
                coordinator.redoCreateHighlight(record: record, page: page)
            }
        }

        private func redoCreateHighlight(record: StoredHighlight, page: PDFPage) {
            attachUserHighlight(record: record, on: page, notify: true)
            guard let manager = pdfView?.window?.undoManager else { return }
            manager.registerUndo(withTarget: self) { coordinator in
                coordinator.undoCreateHighlight(record: record, page: page)
            }
        }

        /// O menu de contexto chamou: remove com undo (nome "Remover destaque").
        func removeUserHighlight(id: String) {
            guard let holder = userAnnotations[id],
                  let record = userRecords[id]
            else { return }
            let manager = pdfView?.window?.undoManager
            if let manager { manager.setActionName(HighlightMarks.undoRemoveName) }
            detachUserHighlight(id: id, notify: true)
            if let manager {
                let page = holder.page
                manager.registerUndo(withTarget: self) { coordinator in
                    coordinator.undoRemoveHighlight(record: record, page: page)
                }
            }
        }

        private func undoRemoveHighlight(record: StoredHighlight, page: PDFPage) {
            attachUserHighlight(record: record, on: page, notify: true)
            guard let manager = pdfView?.window?.undoManager else { return }
            manager.registerUndo(withTarget: self) { coordinator in
                coordinator.redoRemoveHighlight(record: record, page: page)
            }
        }

        private func redoRemoveHighlight(record: StoredHighlight, page: PDFPage) {
            guard userRecords[record.id] != nil else { return }
            detachUserHighlight(id: record.id, notify: true)
            guard let manager = pdfView?.window?.undoManager else { return }
            manager.registerUndo(withTarget: self) { coordinator in
                coordinator.undoRemoveHighlight(record: record, page: page)
            }
        }

        // MARK: Fim dos destaques do usuário
    }

    /// Silence window after each programmatic `go(to:)`, in seconds.
    static let programmaticScrollQuietWindow: TimeInterval = 0.5

    /// Pure decision of the detector: it is a user scroll only when follow
    /// is on, outside the silence window of the app's own `go(to:)`, the
    /// origin changed and neither size nor scale changed (zoom and
    /// resize touch size/scale, never only the origin).
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

    /// Pure decision of the word follow: it scrolls only when follow is
    /// on and the word is outside the visible area.
    static func shouldScrollToWord(follow: Bool, wordVisible: Bool) -> Bool {
        follow && !wordVisible
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        // Critério 2026-10-18 (área do PDF é a prioridade): o rótulo que o
        // cabeçalho levava (título • página • voz) passou para o subtítulo
        // da barra de título da janela — nenhum vazio permanente dentro do
        // conteúdo. O `PDFView` agora ocupa o container inteiro.

        let pdfView = ClickablePDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.document = document
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.identifier = NSUserInterfaceItemIdentifier("pdfView")

        container.addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.containerView = container
        observeUserScroll(in: pdfView, coordinator: context.coordinator)
        return container
    }
    
    /// `static` on purpose: the `NSViewRepresentable` requirement is a static
    /// method (`static func dismantleNSView(_:coordinator:)`) — an instance
    /// method of the same name compiles but never satisfies it, so it is never
    /// called and the scroll observer outlives the view.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let token = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.boundsObserver = nil
        }
        coordinator.observedClipView = nil
        coordinator.containerView = nil
        coordinator.pdfView = nil
    }

    /// Finds the `PDFView`'s inner `NSClipView` (PDFKit does not expose it in a
    /// public property in this SDK version: it lives inside the embedded
    /// `NSScrollView`) and observes its bounds change: the
    /// origin is the scroll position. Registers once; `updateNSView`
    /// tries again when not found yet (the hierarchy may be born late)
    /// and `dismantleNSView` removes the observer.
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

    /// Searches in depth for the first `NSScrollView` and returns its
    /// `contentView`; `nil` when the hierarchy does not exist yet.
    private static func findClipView(in view: NSView) -> NSClipView? {
        if let scroll = view as? NSScrollView { return scroll.contentView }
        for sub in view.subviews {
            if let found = findClipView(in: sub) { return found }
        }
        return nil
    }

    private func findPdfView(in view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        for sub in view.subviews {
            if let found = findPdfView(in: sub) { return found }
        }
        return nil
    }

    /// Detector filter: updates the baseline and reports only when the
    /// pure decision says it was the user (never by `go(to:)`, zoom or
    /// resize, never with follow already off).
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
        // Plano item 26: página visível reportada TAMBÉM fora da rolagem
        // (find, zoom, troca de página com roda — bounds mudam e o relato
        // comanda o cabeçalho sem entrar na decisão do follow).
        Self.reportVisiblePage(pdfView: pdfView, coordinator: coordinator)
    }

    /// Marks the silence window before each programmatic scroll, so the
    /// detector does not confuse the app's own `go(to:)` with the user.
    private static func markProgrammaticScroll(_ coordinator: Coordinator) {
        coordinator.suppressUntil = Date.now.addingTimeInterval(
            programmaticScrollQuietWindow)
    }

    /// Plano item 26: primeira página visível → callback do contentView.
    /// Silêncio quando nada é visível (documento vazio no meio da troca).
    private static func reportVisiblePage(pdfView: PDFView, coordinator: Coordinator) {
        guard let first = pdfView.visiblePages.first,
              let document = pdfView.document
        else { return }
        let index = document.index(for: first)
        if index != coordinator.lastVisiblePage {
            coordinator.lastVisiblePage = index
            coordinator.onVisiblePageChange(index)
        }
    }

    /// Plano item 40: executa o Find do PDFKit. Pureza de curso: consulta
    /// nova → pasta de resultados + relato da contagem; avanço → salto
    /// ciclando (`FindPolicy`). A seleção mostrada é a seleção NATIVA do
    /// `PDFView` (como no Preview) — nada de anotação nova, o realce de
    /// leitura (azul/amarelo) segue como sempre.
    static func runFind(
        view: PDFView, document: PDFDocument, coordinator: Coordinator,
        query: String, advance: Int
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            coordinator.lastFindQuery = nil
            coordinator.findMatches = []
            coordinator.findShownIndex = 0
            return
        }
        if trimmed != coordinator.lastFindQuery {
            coordinator.lastFindQuery = trimmed
            coordinator.findMatches = document.findString(trimmed, withOptions: [.caseInsensitive])
            coordinator.findShownIndex = 0
            coordinator.onFindCount(coordinator.findMatches.count)
            Self.showFindMatch(coordinator: coordinator, view: view)
            return
        }
        guard advance != coordinator.lastFindAdvance,
              !coordinator.findMatches.isEmpty
        else { return }
        coordinator.lastFindAdvance = advance
        coordinator.findShownIndex = FindPolicy.next(
            shown: coordinator.findShownIndex, count: coordinator.findMatches.count)
        Self.showFindMatch(coordinator: coordinator, view: view)
    }

    private static func showFindMatch(coordinator: Coordinator, view: PDFView) {
        guard coordinator.findShownIndex < coordinator.findMatches.count else { return }
        let match = coordinator.findMatches[coordinator.findShownIndex]
        view.setCurrentSelection(match, animate: true)
        view.go(to: match)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let pdfView = findPdfView(in: nsView) ?? context.coordinator.pdfView
        guard let view = pdfView else { return }
        context.coordinator.pdfView = view
        if view.document !== document {
            view.document = document
            // As anotações de usuário pertencem ao documento que saiu: soltar
            // o mapa aqui (e com o diff logo abaixo), o repaint no NOVO doc
            // acontece a partir do sidecar (spec §6, §8 passo 3).
            for (_, holder) in context.coordinator.userAnnotations {
                for annot in holder.annotations {
                    holder.page.removeAnnotation(annot)
                }
            }
            context.coordinator.userAnnotations = [:]
            context.coordinator.userRecords = [:]
            Self.clearPhraseAnnotations(context.coordinator)
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastWordRect = nil
            context.coordinator.lastWordPage = nil
            context.coordinator.wordAnnotation = nil
            context.coordinator.wordPage = nil
        }
        if let clickable = view as? ClickablePDFView {
            clickable.onClickPage = { [document] pdfPage, point in
                onPageClick?(document.index(for: pdfPage), point)
            }
            // Remoção pelo menu de contexto — caminho único do Coordinator.
            clickable.onRemoveHighlight = { id in
                context.coordinator.removeUserHighlight(id: id)
            }
            // Fim do arrasto: a seleção nativa JÁ EXISTE; consumir só quando o
            // modo pedir (fora do modo, tudo igual a antes — nada muda).
            clickable.onDragSelection = { [weak clickable] in
                guard let clickable, highlightMode else { return }
                Self.applySelectionAsHighlight(
                    view: clickable, document: document,
                    coordinator: context.coordinator)
            }
            clickable.removeTitle = removeHighlightLabel
        }
        context.coordinator.follow = follow
        context.coordinator.onUserScroll = onUserScroll ?? {}
        context.coordinator.onHighlightAdded = onHighlightAdded ?? { _ in }
        context.coordinator.onHighlightRemoved = onHighlightRemoved ?? { _ in }
        context.coordinator.onVisiblePageChange = onVisiblePageChange ?? { _ in }
        context.coordinator.onFindCount = onFindCount ?? { _ in }
        observeUserScroll(in: view, coordinator: context.coordinator)
        // Repaint por diff de ids: o sidecar (via ContentView) decide o que está
        // em tela. Anexação idempotente e silenciosa aqui (sem notificar
        // persistência) — nada duplica, nada é apagado por engano.
        Self.syncUserAnnotations(
            document: document, coordinator: context.coordinator,
            desired: userHighlights)
        let phraseKey = key(page: page, rects: rects)
        let tokenChanged = revealToken != context.coordinator.lastToken
        let phraseChanged = phraseKey != context.coordinator.lastPhraseKey || tokenChanged
        // Plano item 40: Find do PDFKit — roda POR MUDANÇA de consulta/avanço
        // (one-shot por tick que muda), nunca a cada batida de palavra.
        Self.runFind(
            view: view, document: document, coordinator: context.coordinator,
            query: findQuery, advance: findAdvance)
        // Plano item 42: navegação por página via TOKEN (o alvo pode repetir
        // entre documentos o valor 0, que por si não dispara nada).
        if goToPageToken != context.coordinator.lastGoToPageToken {
            context.coordinator.lastGoToPageToken = goToPageToken
            if let target = goToPage,
               let targetPage = document.page(at: target) {
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: targetPage)
                Self.reportVisiblePage(pdfView: view, coordinator: context.coordinator)
            }
        }
        // The word's own page, not the sentence's: they differ when the
        // sentence crosses a page break.
        let wordPageIndex = wordPage ?? page
        let wordChanged = wordPageIndex != context.coordinator.lastWordPage
            || wordRect != context.coordinator.lastWordRect

        guard let page, let pdfPage = document.page(at: page) else {
            // Modo destacar: a seleção do usuário NÃO é mais zerada por tick
            // (única mudança permitida no caminho de leitura, spec §4). Fora do
            // modo, comportamento idêntico ao de antes.
            // Plano item 40: com o Find ativo, a seleção É a do Find — os
            // re-renders mordiscam o resultado do ⌘F sem esta guarda.
            if !highlightMode, context.coordinator.lastFindQuery == nil {
                view.setCurrentSelection(nil, animate: false)
            }
            Self.clearPhraseAnnotations(context.coordinator)
            Self.clearWordAnnotation(context.coordinator)
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastWordRect = nil
            context.coordinator.lastWordPage = nil
            context.coordinator.lastToken = revealToken
            return
        }
        if wordChanged {
            let wordOwnPage = wordPageIndex.flatMap { document.page(at: $0) } ?? pdfPage
            updateWordAnnotation(on: wordOwnPage, rect: wordRect, context.coordinator)
            if let word = wordRect, Self.shouldScrollToWord(
                follow: (follow && !scrollHold) || tokenChanged,
                wordVisible: view.convert(view.visibleRect, to: wordOwnPage).intersects(word)
            ) {
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: word, on: wordOwnPage)
            }
            context.coordinator.lastWordRect = wordRect
            context.coordinator.lastWordPage = wordPageIndex
        }
        guard !rects.isEmpty else {
            Self.clearPhraseAnnotations(context.coordinator)
            // Plano item 40: guarda do Find, como acima.
            if !highlightMode, context.coordinator.lastFindQuery == nil {
                view.setCurrentSelection(nil, animate: false)
            }
            if (follow && !scrollHold) || tokenChanged {
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: pdfPage)
            }
            context.coordinator.lastPhraseKey = nil
            context.coordinator.lastToken = revealToken
            return
        }
        if phraseChanged {
            Self.clearPhraseAnnotations(context.coordinator)
            // Plano item 40: guarda do Find, como acima. Durante a leitura a
            // frase muda por tempo; quem buscar LENDO o PDF ainda vê o
            // resultado atritar a cada frase — decisão: a leitura manda.
            if !highlightMode, context.coordinator.lastFindQuery == nil {
                view.setCurrentSelection(nil, animate: false)
            }
            for box in rects {
                let annot = PDFAnnotation(
                    bounds: box, forType: .highlight, withProperties: nil)
                annot.color = NSColor.controlAccentColor.withAlphaComponent(0.28)
                // Marcação de leitura identifiável (menu de contexto/exporto);
                // PDFKit lhes dá o nome do usuário do Sistema — jamais o selo
                // "EdgeSpeak", que é o seletor do menu.
                annot.userName = HighlightMarks.readingOwner
                pdfPage.addAnnotation(annot)
                context.coordinator.phraseAnnotations.append(annot)
            }
            context.coordinator.phrasePage = pdfPage
            if (follow && !scrollHold) || tokenChanged {
                let box = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                Self.markProgrammaticScroll(context.coordinator)
                view.go(to: box, on: pdfPage)
            }
            context.coordinator.lastPhraseKey = phraseKey
            context.coordinator.lastToken = revealToken
        }
    }

    /// Removes the sentence's live annotations, if any; without it the old highlight
    /// would be orphaned in the document (which the app never saves).
    static func clearPhraseAnnotations(_ coordinator: Coordinator) {  // internal p/ teste, spec §7.4
        if let page = coordinator.phrasePage {
            for annot in coordinator.phraseAnnotations {
                page.removeAnnotation(annot)
            }
        }
        coordinator.phraseAnnotations = []
        coordinator.phrasePage = nil
    }

    /// Removes the word's live annotation, if any; without it the old highlight
    /// would be orphaned in the document (which the app never saves).
    static func clearWordAnnotation(_ coordinator: Coordinator) {
        if let annot = coordinator.wordAnnotation,
           let page = coordinator.wordPage {
            page.removeAnnotation(annot)
        }
        coordinator.wordAnnotation = nil
        coordinator.wordPage = nil
    }

    /// Swaps the word's annotation: removes the previous one before adding the
    /// new one; same page and same bounds reuse the live one (avoids flicker
    /// when only the token changed).
    private func updateWordAnnotation(
        on pdfPage: PDFPage, rect: CGRect?, _ coordinator: Coordinator
    ) {
        guard let rect else {
            Self.clearWordAnnotation(coordinator)
            return
        }
        if coordinator.wordPage === pdfPage,
           let annot = coordinator.wordAnnotation,
           annot.bounds == rect {
            return
        }
        Self.clearWordAnnotation(coordinator)
        let annot = PDFAnnotation(
            bounds: rect, forType: .highlight, withProperties: nil)
        annot.color = NSColor.systemYellow.withAlphaComponent(0.55)
        // Mesma marca das frases: efêmera de leitura, removível seletivamente
        // na exportação; o seletor do menu (`textLabel == "EdgeSpeak"`) segue
        // fora do alcance delas.
        annot.userName = HighlightMarks.readingOwner
        pdfPage.addAnnotation(annot)
        coordinator.wordAnnotation = annot
        coordinator.wordPage = pdfPage
    }

    /// Dedup key of the SENTENCE: page + boxes (without the word — the
    /// word has its own key in the Coordinator).
    private func key(page: Int?, rects: [CGRect]) -> String {
        guard let page else { return "nil" }
        let boxes = rects.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }
            .joined(separator: ";")
        return "\(page)|\(boxes)"
    }

    // MARK: Destaques do usuário (spec §3–§6)

    /// Consome a seleção atual em destaques do usuário (só chega aqui com o
    /// modo ligado): o caminho canônico — `selectionsByLine()` → `bounds(for:)`
    /// em page space → um registro + uma anotação por página. Depois limpa a
    /// seleção como feedback (spec §4), mesmo no modo (a `guarda` dos ticks não
    /// a recria).
    static func applySelectionAsHighlight(
        view: PDFView, document: PDFDocument, coordinator: Coordinator
    ) {
        guard let selection = view.currentSelection else { return }
        var pieces: [HighlightStore.HighlightLine] = []
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            // Page space, independente de zoom (reuso §a). Uma seleção que cruza
            // páginas vira um registro POR página (spec §3).
            let piece = HighlightStore.HighlightLine(
                page: document.index(for: page),
                rect: line.bounds(for: page),
                text: line.string ?? "")
            pieces.append(piece)
        }
        for group in HighlightStore.groupLinesByPage(pieces) {
            guard let page = document.page(at: group.page) else { continue }
            let quads = HighlightStore.quads(
                forLineRects: group.rects, rotation: page.rotation)
            // Linhas degeneradas caem fora do registro juntas do seu quad.
            let valid = zip(group.rects, quads).filter { !$1.isEmpty }
            guard !valid.isEmpty else { continue }
            coordinator.createUserHighlight(
                record: StoredHighlight(
                    id: UUID().uuidString,
                    page: group.page,
                    quads: valid.map(\.1),
                    text: group.text,
                    colorSlug: HighlightMarks.colorSlug,
                    createdAt: Date()),
                on: page)
        }
        view.setCurrentSelection(nil, animate: false)
    }

    /// Traz as anotações viva-próprias ao alvo (`desired`, os registros do
    /// sidecar): remove as sobras, anexa as faltantes em silêncio. Barato quando
    /// nada muda; na abertura, pinta o sidecar inteiro (repaint, spec §8.3).
    static func syncUserAnnotations(
        document: PDFDocument, coordinator: Coordinator, desired: [StoredHighlight]
    ) {
        let wanted = Set(desired.map(\.id))
        let surplus = coordinator.userAnnotations.filter { !wanted.contains($0.key) }
        for (id, holder) in surplus {
            for annot in holder.annotations {
                holder.page.removeAnnotation(annot)
            }
            coordinator.userAnnotations[id] = nil
            coordinator.userRecords[id] = nil
        }
        for record in desired {
            guard coordinator.userRecords[record.id] == nil else { continue }
            guard let page = document.page(at: record.page) else { continue }
            coordinator.attachUserHighlight(record: record, on: page, notify: false)
        }
    }

    /// As anotações do usuário: UMA POR LINHA — um `PDFAnnotation` `.highlight`
    /// por retângulo derivado de `record.quads` (minX/minY/maxX/maxY de cada
    /// quad), SEM `quadrilateralPoints` e SEM inset. Motivo medido (não é
    /// hipótese): a construção antiga (UMA anotação com `bounds` = união e
    /// quads absolutos) é TRANSLADADA por +bounds.origin tanto no PDFKit ao
    /// vivo (+70 pt = bounds.minX) quanto no poppler do arquivo exportado
    /// (1 faixa errada de 15; 0 de 21 na outra página); o ensaio por linha,
    /// no mesmo padrão da anotação de leitura acima, pintou EXATO (15/15 e
    /// 14/14). Todas as anotações carregam magenta α 0,33, a assinatura duas
    /// vezes (`userName` + `textLabel` "EdgeSpeak" — PDFKit dá às anotações
    /// alheias o nome do usuário do Sistema, então o SELO é discriminante) e o
    /// id do registro em `.name` — o menu de contexto clicando em QUALQUER
    /// linha remove o registro INTEIRO.
    static func makeUserAnnotation(_ record: StoredHighlight, on page: PDFPage) -> [PDFAnnotation] {
        var rects = HighlightStore.lineRects(forQuads: record.quads)
        // Sem nenhuma linha válida o registro não teria faixa em tela; o bounds
        // da página mantém UMA anotação assinada (contrato da união antiga,
        // que caía em `bounds.isNull`).
        if rects.isEmpty { rects = [page.bounds(for: .mediaBox)] }
        return rects.map { rect in
            let annotation = PDFAnnotation(
                bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = NSColor.magenta.withAlphaComponent(0.33)
            annotation.userName = HighlightMarks.owner
            annotation.setValue(HighlightMarks.owner, forAnnotationKey: .textLabel)
            // O id do registro via `.name` (`/NM`) — `userData` não existe no
            // PDFKit de macOS; o undo é feito pela casa (Coordinator), o nome
            // aqui serve de ponta de conversa para o menu de contexto.
            annotation.setValue(record.id, forAnnotationKey: .name)
            return annotation
        }
    }
}
