import AppKit
import PDFKit
import SwiftUI
import Testing

@testable import EdgeSpeak

/// Onda 3 — acessibilidade (plano PLANO-MELHORIAS-2026-10-17.md, itens
/// 18, 19, 20, 22 e 25). Cada teste cobre a parte PURA do item; os
/// comportamentos de monitor de teclado, foco e contraste ao vivo ficam
/// para a verificação manual (registrados no plano, "Ao vivo: sim").
struct LaneAccessibilityTests {

    // MARK: Item 18 — anúncio terminal e banner de falha

    /// Terminais do plano: carregado, erro, concluído, cancelado — nada de
    /// tick de progresso (`nil`), nada de "está tocando" (falar em cima da
    /// leitura é ruído, não anúncio).
    @Test func terminalEventsClassifyPerThePlan() {
        // Carregado: arquivo e colagem entram como conteúdo.
        #expect(AccessibilityAnnouncements.kind(of: "status.fileLoaded") == .loaded)
        #expect(AccessibilityAnnouncements.kind(of: "status.textPasted") == .loaded)
        // Concluído / cancelado.
        #expect(AccessibilityAnnouncements.kind(of: "status.finished") == .finished)
        #expect(AccessibilityAnnouncements.kind(of: "common.synthesisCancelled") == .cancelled)
        #expect(AccessibilityAnnouncements.kind(of: "status.stopped") == .cancelled)
        #expect(AccessibilityAnnouncements.kind(of: "status.importCancelled") == .cancelled)
        // Falha: chave direta e chaves de `failureKey` (erros do motor via l10nKey).
        #expect(AccessibilityAnnouncements.kind(of: "status.onlineBlocked") == .failure)
        #expect(AccessibilityAnnouncements.kind(of: "status.openFailed") == .failure)
        #expect(AccessibilityAnnouncements.kind(of: "pdf.exportFailed") == .failure)
        #expect(AccessibilityAnnouncements.kind(of: "error.synthesisFailed") == .failure)
        #expect(AccessibilityAnnouncements.kind(of: "error.pdfWithoutTextLayer") == .failure)
        // Pre-tick: nunca anuncia (o motivo da política existir).
        #expect(AccessibilityAnnouncements.kind(of: "status.playing") == nil)
        #expect(AccessibilityAnnouncements.kind(of: "status.paused") == nil)
        #expect(AccessibilityAnnouncements.kind(of: "status.generatingNext") == nil)
        #expect(AccessibilityAnnouncements.kind(of: "status.playingWhileSynthesizing") == nil)
        #expect(AccessibilityAnnouncements.kind(of: "status.synthesisSlow") == nil)
        #expect(AccessibilityAnnouncements.kind(of: "warn.durationUnmeasured") == nil)
        // Progresso cru: sem chave, sem anúncio.
        #expect(AccessibilityAnnouncements.kind(of: nil) == nil)
        #expect(AccessibilityAnnouncements.kind(of: "") == nil)
    }

    /// Falha = banner permanente: as de falha batem no `isFailure` (o banner
    /// nunca se apaga sozinho); progresso e sucesso não seguram.
    @Test func failureHoldMatchesTheBannerRule() {
        #expect(AccessibilityAnnouncements.isFailure("error.diskFull"))
        #expect(AccessibilityAnnouncements.isFailure("status.openFailed"))
        #expect(!AccessibilityAnnouncements.isFailure("status.fileLoaded"))
        #expect(!AccessibilityAnnouncements.isFailure("status.playing"))
        #expect(!AccessibilityAnnouncements.isFailure(nil))
    }

    /// Keys `status.failure.*` viram falha por prefixo — os chaves novos do
    /// catálogo desta onda não precisam de registro caso a caso.
    @Test func failurePrefixCatchesTheFamily() {
        #expect(AccessibilityAnnouncements.kind(of: "status.failure.teste") == .failure)
        #expect(AccessibilityAnnouncements.kind(of: "status.playing.failure") == nil)
    }

    // MARK: Item 19 — espaço do controle focado

    /// Com Full Keyboard Access o espaço é do CONTROLE em foco: botão,
    /// slider, picker (NSControl), editor (NSTextView) e PDF (PDFView) —
    /// o monitor passa o evento. First responder = janela/view comum:
    /// espaço é play/pause (o desvio da PlayerBar).
    @Test func spaceBelongsToTheFocusedControl() {
        #expect(SpaceKeyPolicy.belongsToFocusedControl(NSButton()))
        #expect(SpaceKeyPolicy.belongsToFocusedControl(NSSlider()))
        #expect(SpaceKeyPolicy.belongsToFocusedControl(NSTextField()))
        #expect(SpaceKeyPolicy.belongsToFocusedControl(NSPopUpButton()))
        #expect(SpaceKeyPolicy.belongsToFocusedControl(NSTextView()))
        #expect(SpaceKeyPolicy.belongsToFocusedControl(PDFView()))
        // Sem controle focado: o espaço é do leitor (play/pause).
        #expect(!SpaceKeyPolicy.belongsToFocusedControl(NSView()))
        #expect(!SpaceKeyPolicy.belongsToFocusedControl(nil))
        #expect(!SpaceKeyPolicy.belongsToFocusedControl(NSScrollView()))
        #expect(!SpaceKeyPolicy.belongsToFocusedControl(NSClipView()))
    }

    // MARK: Item 20 — vizinha de frase

    /// Por POSIÇÃO na lista de leitura (índice é propriedade). Nas pontas,
    /// prende — a mesma régua do ±15 s.
    @Test func sentenceNeighborStepsAndClamps() {
        let indices = [10, 12, 14, 16]
        #expect(SentenceNeighborPolicy.target(from: indices, current: 12, direction: 1) == 14)
        #expect(SentenceNeighborPolicy.target(from: indices, current: 12, direction: -1) == 10)
        // Primeiro → anterior prende no primeiro; último → próxima prende no último.
        #expect(SentenceNeighborPolicy.target(from: indices, current: 10, direction: -1) == 10)
        #expect(SentenceNeighborPolicy.target(from: indices, current: 16, direction: 1) == 16)
    }

    @Test func sentenceNeighborEdgeCases() {
        let indices = [10, 12]
        // Lista vazia: nada para onde ir.
        #expect(SentenceNeighborPolicy.target(from: [], current: 10, direction: 1) == nil)
        // Corrente nula (fora da lista): para a frente → primeira; para trás → nil.
        #expect(SentenceNeighborPolicy.target(from: indices, current: 99, direction: 1) == 10)
        #expect(SentenceNeighborPolicy.target(from: indices, current: 99, direction: -1) == nil)
        // Dose zero: sem direção, sem pulo.
        #expect(SentenceNeighborPolicy.target(from: indices, current: 10, direction: 0) == nil)
        // Índices negativos não existem na lista; corrente inválida cai no caso acima.
    }

    // MARK: Item 22 — rótulos no catálogo bilíngue

    /// As chaves novas da onda existem nos DOIS idiomas e nunca vazias — a
    /// mesma régua da `L10nCompletenessTests`, aplicada ao par novo.
    @Test func newA11yKeysExistInBothLanguages() {
        let chaves = [
            "ui.previousSentence",
            "ui.nextSentence",
            "help.previousSentence",
            "help.nextSentence",
            "a11y.panel.title",
            "a11y.panel.hint",
            "ui.editor.label",
            "ui.editor.hint",
        ]
        for chave in chaves {
            #expect(L.pt[chave] != nil, "sem PT: \(chave)")
            #expect(L.en[chave] != nil, "sem EN: \(chave)")
            #expect(!(L.pt[chave] ?? "").isEmpty)
            #expect(!(L.en[chave] ?? "").isEmpty)
        }
    }

    /// O painel resolve pelos rótulos SEM idioma fixo: a troca de idioma na
    /// interface chega ao painel via `updateNSView` com o idioma novo.
    @Test func panelLabelsResolvePerLanguage() {
        #expect(L.get("a11y.panel.hint", locale: .pt) == "Ative uma frase para mover a leitura para ela")
        #expect(L.get("a11y.panel.hint", locale: .en) == "Activate a sentence to move playback to it")
    }

    // MARK: Item 25 — cabeçalho do PDF amarrado à fonte

    /// Cresce junto com o `fontSize` do app, piso 11 (o tamanho histórico) e
    /// teto 21 (acompanha o aumento sem virar título). Nil = 11 (comportamento
    /// antigo, view sem a prop).
    @Test func pdfHeaderScalesWithAppFontAndStaysSane() {
        #expect(PDFDocumentView.headerPointSize(for: nil) == 11)
        #expect(PDFDocumentView.headerPointSize(for: 12) == 12)   // mínimo do app
        #expect(PDFDocumentView.headerPointSize(for: 17) == 17)   // default do app
        #expect(PDFDocumentView.headerPointSize(for: 10) == 11)   // nunca menor que o histórico
        #expect(PDFDocumentView.headerPointSize(for: 33) == 21)   // teto: cabeçalho, não título
        #expect(PDFDocumentView.headerPointSize(for: 42) == 21)
    }
}
