import AppKit
import Foundation
import Testing

@testable import EdgeSpeak

/// Onda 2 — feedback de uso (plano PLANO-MELHORIAS-2026-10-17.md, itens
/// 1, 15, 16, 24, 31, 32, 33, 34, 35). Cada teste cobre a pureza testável
/// do item; a parte de view requer o app ao vivo (registrado no plano).
///
/// `.serialized`: dois testes usam o registro global de importação de
/// `PdfWords` (uma extração por vez, como na UI) — sem a marca, o
/// cancelamento de um podia cair no processo do outro, em paralelo.
@Suite(.serialized)
struct WaveTwoFeedbackTests {

    // MARK: Item 1 — colar texto no estado vazio

    @Test func pasteIntakeKeepsRealTextAndDropsBlank() {
        // Colado de verdade (com brancos nas pontas): entra como veio —
        // o usuário edita depois; a tela não reescreve o que chegou.
        #expect(EmptyStatePaste.usable("  Olá mundo \n") == "  Olá mundo \n")
        // Em branco: nada colável — colar vazio criaria "editor fantasma".
        #expect(EmptyStatePaste.usable("   \n\t ") == nil)
        #expect(EmptyStatePaste.usable("") == nil)
    }

    @Test func pasteIntakeReadsThePasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("EdgeSpeak-wave2-test"))

        pb.clearContents()
        pb.setString("Colado do outro app", forType: .string)
        #expect(EmptyStatePaste.usable(from: pb) == "Colado do outro app")
        // Pasteboard vazio e colagem-only-whitespace: recusados.
        pb.clearContents()
        #expect(EmptyStatePaste.usable(from: pb) == nil)
        pb.setString("   ", forType: .string)
        #expect(EmptyStatePaste.usable(from: pb) == nil)
    }

    // MARK: Item 15 (revisto em 2026-10-18) — a troca de voz reinicia a leitura em curso

    @Test func voiceChangeRestartsOnlyWhileReading() {
        // Silêncio total: nada a anular — a troca é a voz de sempre.
        #expect(!FeedbackPolicy.voiceChangeRestartsReading(busy: false, playing: false, paused: false))
        #expect(FeedbackPolicy.voiceChangeRestartsReading(busy: true, playing: false, paused: false))
        #expect(FeedbackPolicy.voiceChangeRestartsReading(busy: false, playing: true, paused: false))
        // Pausado: o run existe e a voz nova assume DA FRASE ATUAL.
        #expect(FeedbackPolicy.voiceChangeRestartsReading(busy: false, playing: false, paused: true))
        #expect(FeedbackPolicy.voiceChangeRestartsReading(busy: true, playing: true, paused: false))
    }

    // MARK: Item 24 — sem idioma misturado, cancelamento não é falha

    @Test func importerCancellationIsSilent() {
        #expect(FeedbackPolicy.isUserCancelled(
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        #expect(!FeedbackPolicy.isUserCancelled(
            NSError(domain: NSCocoaErrorDomain, code: 1)))
        #expect(!FeedbackPolicy.isUserCancelled(
            NSError(domain: "OutroDominio", code: NSUserCancelledError)))
    }

    /// Os erros do `TextImport` carregam `l10nKey` em `userInfo`; passando
    /// pelo `failureKey`, a chave do catálogo volta (a causa sai em UM
    /// idioma, a frase não mistura `localizedDescription` em inglês).
    @Test func openFailureGoesThroughTheCatalogKey() {
        let semCamada = SpeechController.failureKey(for: TextImport.makeTestError(key: "error.pdfWithoutTextLayer"))
        #expect(semCamada.0 == "error.pdfWithoutTextLayer")
        #expect(semCamada.1.isEmpty)
        let desconhecido = SpeechController.failureKey(for: NSError(domain: "X", code: 2))
        #expect(desconhecido.0 == "error.synthesisFailed")
    }

    // MARK: Item 32 — prazo visível e cancelamento que mata o processo

    /// Fonte única do orçamento: 15 s + 3 s/página, teto de 180 s.
    @Test func importBudgetMatchesTheRule() {
        #expect(PdfWords.importDeadlineSeconds(pageCount: 0) == 15)
        #expect(PdfWords.importDeadlineSeconds(pageCount: 10) == 45)
        #expect(PdfWords.importDeadlineSeconds(pageCount: 30) == 105)
        #expect(PdfWords.importDeadlineSeconds(pageCount: 60) == 180)
        #expect(PdfWords.importDeadlineSeconds(pageCount: 1_000) == 180)
        #expect(PdfWords.importDeadlineSeconds(pageCount: -3) == 15)
    }

    /// Cancelamento SEM importação: no-op seguro (não estoura, não mente).
    @Test func cancelWithoutImportIsHarmless() {
        // Não há extração própria em teste; o resultado pode ser true ou
        // false conforme concorrência de suíte — o que importa é a chamada
        // segura. (A prova de KILL fica no teste abaixo, self-guardado.)
        _ = PdfWords.cancelActiveImport()
    }

    /// A prova do conserto: um processo vivo registrada pela `watchImport`
    /// morre RÁPIDO no `cancelActiveImport` (SIGKILL + reap — o padrão dos
    /// motores), em vez de correr até o próprio prazo.
    @Test func cancelKillsTheImportProcess() async throws {
        // Espera (limitada) o pool global de importação ficar livre:
        // no teste há uma extração por vez, como na UI.
        for _ in 0..<100 where PdfWords.activeImportDeadline == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let t0 = Date()
        let watch = Task.detached(priority: .userInitiated) {
            PdfWords.watchImport(process: proc, deadline: Date(timeIntervalSinceNow: 10))
        }
        // A `watchImport` registra o prazo (o mesmo canal que a barra de
        // status lê); aguarda o registro aparecer.
        var registrado = false
        for _ in 0..<100 where PdfWords.activeImportDeadline == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        registrado = PdfWords.activeImportDeadline != nil
        #expect(registrado, "a watchImport deve registrar o prazo visível")
        #expect(PdfWords.cancelActiveImport() == true)
        let finished = await watch.value
        let decorrido = Date().timeIntervalSince(t0)
        #expect(finished == false, "cancelado, não «terminou em tempo»")
        #expect(decorrido < 8, "morte rápida e não a 30 s do sleep: \(decorrido)")
        #expect(proc.terminationStatus == Int(SIGKILL))
    }

    /// Prazo curto: o processo vira zumbi sem SIGKILL? O endurecimento de
    /// sempre deve reajá-lo — e «false» é a resposta (timeout, não sucesso).
    @Test func timedOutImportIsKilledAndReaped() async throws {
        for _ in 0..<100 where PdfWords.activeImportDeadline == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let watch = Task.detached(priority: .userInitiated) {
            PdfWords.watchImport(process: proc, deadline: .distantPast)
        }
        let finished = await watch.value
        #expect(finished == false)
        #expect(proc.terminationStatus != 0)
        #expect(!proc.isRunning, "reap: o processo não fica pendurado")
    }

    // MARK: Itens 33/34/35 e chaves novas — resolvem nos DOIS idiomas

    @Test func ondaTwoKeysResolveForEachSide() {
        let novas: [String] = [
            "status.textPasted", "status.pasteEmpty",
            "status.importCancelled", "status.clickOutsidePhrase",
            "help.voiceNextSynthesis",
            "ui.sleepArmed", "ui.cancelImport", "ui.importRemaining",
        ]
        for key in novas {
            for locale in [L.Language.pt, .en] {
                #expect(L.get(key, locale: locale) != key, "chave sem PT/EN: \(key)")
            }
        }
        // Interpolação de args nas duas faces.
        #expect(L.get("ui.sleepArmed", locale: .pt, args: 15) == "Temporizador (15 min)")
        #expect(L.get("ui.sleepArmed", locale: .en, args: 15) == "Sleep timer (15 min)")
        #expect(L.get("ui.importRemaining", locale: .pt, args: 42) == "(42 s restantes)")
        #expect(L.get("ui.importRemaining", locale: .en, args: 42) == "(42s left)")
        #expect(L.get("status.textPasted", locale: .pt, args: 120).contains("120"))
        #expect(L.get("status.textPasted", locale: .en, args: 120).contains("120"))
    }

    /// Plano item 34: a mensagem de arquivo carregado CONVIDA ao Enter —
    /// a leitura não exige achar o botão de Play primeiro.
    @Test func fileLoadedInvitesTheEnterKey() {
        #expect(L.get("status.fileLoaded", locale: .pt, args: "A.pdf", 10).contains("Enter"))
        #expect(L.get("status.fileLoaded", locale: .en, args: "A.pdf", 10).contains("Enter"))
    }
}

/// Erro de teste com a mesma forma que o `TextImport.makeError` monta
/// (o conserto do item 24 confia nessa forma): chave+args no `userInfo`.
extension TextImport {
    static func makeTestError(key: String, args: [Any] = []) -> NSError {
        NSError(
            domain: "EdgeSpeak",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: L.resolve(key, args: args),
                "l10nKey": key,
                "l10nArgs": args,
            ])
    }
}
