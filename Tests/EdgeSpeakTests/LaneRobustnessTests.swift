import AppKit
import Combine
import Foundation
import Testing

@testable import EdgeSpeak

/// Robustez de recursos e processo — itens 44, 48, 49, 50, 51, 52 e 53 do plano
/// de melhorias de 2026-10-17.
///
/// O que é testável sem motor vivo entra aqui: as decisões puras (espaço em
/// disco, poda de `.part`, poda das posições de leitura), as funções de limpeza
/// (parciais da leitura offline, diretório fantasma) e o canal do ⌘Q.
struct LaneRobustnessTests {
    private func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func ephemeralDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "lane-robustness-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: - Item 44: ⌘Q cancela a leitura em voo

    /// O encerramento posta o canal que `ContentView.requestStop` observa. A
    /// prova usa o MESMO mecanismo da view (`NotificationCenter.Publisher`):
    /// se a entrega não fosse síncrona no thread que posta, o handler não
    /// rodaria antes de o processo morrer — e o filho Python ficaria órfão.
    @Test func terminatePostsStopReading() {
        let delegate = AppDelegate()
        var received = false
        let cancellable = NotificationCenter.default
            .publisher(for: .edgeSpeakStopReading)
            .sink { _ in received = true }
        defer { cancellable.cancel() }

        delegate.stopReadingBeforeTerminating()

        #expect(received, "o canal .edgeSpeakStopReading não chegou no encerramento")
    }

    // MARK: - Item 48: espaço livre com piso

    /// A decisão pura: abaixo do piso aborta, no piso (ou acima) passa e a
    /// medição indisponível NUNCA bloqueia — a leitura não pode depender de um
    /// recurso que o sistema pode não informar.
    @Test func diskSpaceDecision() {
        #expect(DiskSpace.allowsStart(available: nil, floor: 1_000))
        #expect(DiskSpace.allowsStart(available: 1_000, floor: 1_000))
        #expect(DiskSpace.allowsStart(available: 1_001, floor: 1_000))
        #expect(DiskSpace.allowsStart(available: 999, floor: 1_000) == false)
        #expect(DiskSpace.allowsStart(available: 0, floor: 1_000) == false)
    }

    /// O volume real responde: o piso de 1 byte cabe em qualquer disco que
    /// rode a suíte, e o texto do erro sai legível.
    @Test func liveVolumeIsReadableAndSized() {
        let temp = FileManager.default.temporaryDirectory
        if let available = DiskSpace.availableBytes(at: temp) {
            #expect(available > 0)
            #expect(DiskSpace.humanSize(available).contains("B"))
        }
        #expect(DiskSpace.hasRoom(at: temp, floor: 1))
        #expect(DiskSpace.freeSpaceText(at: temp) != "0 MB")
    }

    @Test func humanSizeUnits() {
        #expect(DiskSpace.humanSize(0) == "0 MB")
        #expect(DiskSpace.humanSize(512 * 1_024 * 1_024) == "512 MB")
        #expect(DiskSpace.humanSize(1024 * 1_024 * 1_024) == "1.0 GB")
    }

    /// A chave nova existe nos dois idiomas, com o número interpolado.
    @Test func diskFullMessageIsLocalizedInBothLanguages() {
        let pt = L.get("error.diskFull", locale: .pt, args: "820 MB")
        let en = L.get("error.diskFull", locale: .en, args: "820 MB")
        #expect(pt != "error.diskFull")
        #expect(en != "error.diskFull")
        #expect(pt.contains("820 MB"))
        #expect(en.contains("820 MB"))
        #expect(pt != en)
    }

    // MARK: - Item 49: parciais da leitura offline

    /// Liberar os parciais não leva o WAV montado junto: é ele que um
    /// replay/restart toca.
    @Test func releasePhraseWavsKeepsTheAssembledFile() throws {
        let dir = tempDir("release")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir.appendingPathComponent("EdgeSpeak.wav"))
        try write(dir.appendingPathComponent("wavs/phrase-00000.wav"))
        try write(dir.appendingPathComponent("wavs/phrase-00001.wav"))

        PiperTTS.releasePhraseWavs(in: dir)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("EdgeSpeak.wav").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("wavs").path))
    }

    /// Sem parâmetro, o alvo é a leitura registrada pelo motor — o caminho que
    /// o controle usa ao parar.
    @Test func releaseUsesTheRegisteredReading() throws {
        let dir = tempDir("registered")
        defer {
            try? FileManager.default.removeItem(at: dir)
            // Registro global: aponta para um caminho morto ao fim do teste.
            PiperTTS.registerRunDirectory(URL(fileURLWithPath: "/nao-existe-leitura-offline"))
        }
        try write(dir.appendingPathComponent("EdgeSpeak.wav"))
        try write(dir.appendingPathComponent("wavs/phrase-00000.wav"))
        PiperTTS.registerRunDirectory(dir)

        PiperTTS.releasePhraseWavs()

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("wavs").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("EdgeSpeak.wav").path))
    }

    // MARK: - Item 50: poda de `.part` órfãos

    /// Órfão de download (app morto no meio) sai; o `.part` recém-criado
    /// (download vivo) e os arquivos de voz ficam.
    @Test func pruneStalePartsRemovesOnlyOrphans() throws {
        let dir = tempDir("parts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let now = Date()
        let orphan = dir.appendingPathComponent("pt_BR-faber-medium.onnx.part")
        let fresh = dir.appendingPathComponent("pt_BR-cadu-medium.onnx.part")
        let onTheEdge = dir.appendingPathComponent("pt_BR-jeff-medium.onnx.part")
        let voice = dir.appendingPathComponent("pt_BR-faber-medium.onnx")
        try write(orphan, "velho")
        try write(fresh, "novo")
        try write(onTheEdge, "na borda")
        try write(voice, "voz")
        try fm.setAttributes(
            [.modificationDate: now.addingTimeInterval(-PiperTTS.partMaxAge - 60)],
            ofItemAtPath: orphan.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: fresh.path)
        try fm.setAttributes(
            [.modificationDate: now.addingTimeInterval(-PiperTTS.partMaxAge)], ofItemAtPath: onTheEdge.path)

        let removed = PiperTTS.pruneStaleParts(in: dir, now: now)

        // Os URLs volvem com `/private` resolvido: compara-se o nome.
        #expect(removed.map(\.lastPathComponent) == ["pt_BR-faber-medium.onnx.part"])
        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(fm.fileExists(atPath: fresh.path), "download vivo não pode ser podado")
        #expect(fm.fileExists(atPath: onTheEdge.path), "exatamente no limite ainda não é órfão")
        #expect(fm.fileExists(atPath: voice.path))
    }

    /// Diretório inexistente devolve lista vazia em vez de explodir: a poda
    /// roda antes do download, sem garantia de que a pasta já existe.
    @Test func pruneStalePartsToleratesAMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-ausente-\(UUID().uuidString)", isDirectory: true)
        #expect(PiperTTS.pruneStaleParts(in: missing).isEmpty)
    }

    // MARK: - Item 51: causa-raiz do ambiente embutido

    /// A causa do ambiente embutido vai junto da falha do caminho legado, e a
    /// chave do catálogo sobrevive (a troca de idioma continua re-resolvendo).
    @Test func withCauseAppendsTheRootCauseAndKeepsTheKey() {
        let fallback = NSError(domain: "EdgeSpeak.PiperTTS", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "falha do caminho legado",
            "l10nKey": "error.offlineVenvCreate",
            "l10nArgs": ["detalhe"],
        ])
        let cause = NSError(domain: "EdgeSpeak.BundledEnv", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "faltam os pacotes embutidos",
        ])

        let withoutCause = PiperTTS.withCause(fallback, cause: nil)
        #expect(withoutCause.localizedDescription == fallback.localizedDescription)
        // Causa em branco não inventa linha de diagnóstico.
        let blankCause = NSError(domain: "d", code: 1, userInfo: [NSLocalizedDescriptionKey: "   "])
        #expect(PiperTTS.withCause(fallback, cause: blankCause).localizedDescription
            == fallback.localizedDescription)

        let withCause = PiperTTS.withCause(fallback, cause: cause)
        #expect(withCause.localizedDescription.contains("falha do caminho legado"))
        #expect(withCause.localizedDescription.contains("faltam os pacotes embutidos"))
        #expect(withCause.userInfo["l10nKey"] as? String == "error.offlineVenvCreate")
        #expect((withCause.userInfo["l10nArgs"] as? [String]) == ["detalhe"])
        // A chave sobrevive à viagem: é o que o controle usa para re-resolver.
        let (key, args) = SpeechController.failureKey(for: withCause)
        #expect(key == "error.offlineVenvCreate")
        #expect((args as? [String]) == ["detalhe"])
    }

    // MARK: - Item 52: poda das posições de leitura

    @Test func documentIDParsing() {
        #expect(ReadingPositionStore.documentID(fromKey: "arquivo.pdf##voz") == "arquivo.pdf")
        #expect(ReadingPositionStore.documentID(fromKey: "file:///a/b.pdf##offline-faber-ptbr")
            == "file:///a/b.pdf")
        #expect(ReadingPositionStore.documentID(fromKey: "semSeparador") == nil)
        #expect(ReadingPositionStore.documentID(fromKey: "##voz") == nil)
        #expect(ReadingPositionStore.key(documentID: "a", voice: "v") == "a##v")
    }

    /// Só o que o teste pode julgar: identificador que não é URL de arquivo
    /// (chave antiga, formato futuro) existe; URL de arquivo segue o disco.
    @Test func documentExistsOnDiskOnlyJudgesFileURLs() throws {
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivo-\(UUID().uuidString).pdf")
        try write(live)
        defer { try? FileManager.default.removeItem(at: live) }

        #expect(ReadingPositionStore.documentExistsOnDisk(live.absoluteString))
        #expect(ReadingPositionStore.documentExistsOnDisk("sem-formato"))
        #expect(ReadingPositionStore.documentExistsOnDisk("https://example.com/x.pdf"))
        #expect(ReadingPositionStore.documentExistsOnDisk("file:///nada/aqui-\(UUID().uuidString).pdf")
            == false)
    }

    @Test func pruningKeepsWhatItCannotJudge() {
        let all = [
            "semSeparador": 10.0,
            ReadingPositionStore.key(documentID: "file:///morto", voice: "v"): 20.0,
            ReadingPositionStore.key(documentID: "file:///vivo", voice: "v"): 30.0,
        ]
        let kept = ReadingPositionStore.pruningMissingDocuments(all) { $0 == "file:///vivo" }
        #expect(kept == [ReadingPositionStore.key(documentID: "file:///vivo", voice: "v"): 30.0,
                         "semSeparador": 10.0])
    }

    /// Poda na leitura: a entrada do documento que sumiu do disco sai do
    /// `UserDefaults` e a do documento que existe continua retomando.
    @Test func loadPrunesEntriesWhoseDocumentIsGone() throws {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivo-\(UUID().uuidString).pdf")
        try write(live)
        defer { try? FileManager.default.removeItem(at: live) }
        let dead = "file:///nao/existe-\(UUID().uuidString).pdf"
        defaults.set([
            ReadingPositionStore.key(documentID: live.absoluteString, voice: "voz"): 42.0,
            ReadingPositionStore.key(documentID: dead, voice: "voz"): 77.0,
        ], forKey: ReadingPositionStore.defaultsKey)

        #expect(ReadingPositionStore.load(
            documentID: live.absoluteString, voice: "voz", defaults: defaults) == 42)

        let stored = defaults.dictionary(forKey: ReadingPositionStore.defaultsKey) ?? [:]
        #expect(stored.count == 1)
        #expect(stored.keys.contains(ReadingPositionStore.key(documentID: dead, voice: "voz")) == false)
        // A regravação não perdeu a posição do documento vivo.
        #expect(ReadingPositionStore.load(
            documentID: live.absoluteString, voice: "voz", defaults: defaults) == 42)
    }

    // MARK: - Item 53: proteção fantasma após erro de streaming

    /// A falha do streaming offline leva o diretório E a proteção: sem o
    /// `clearOfflineDirectory`, o `purge` seguinte pouparia um caminho que não
    /// existe mais.
    ///
    /// Cuidado deliberado: a proteção é global ao processo e outro conjunto da
    /// suíte conta com ela (`EngineProtectionTests`), então o teste guarda e
    /// devolve o valor anterior e NÃO roda `purgeStaleDirectories` — um purge
    /// aqui varreria o temp compartilhado e derrubaria os diretórios dos
    /// vizinhos que correm em paralelo.
    @Test func failedOfflineRunWithdrawsTheProtection() throws {
        let dir = tempDir("failed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = EdgeTTS.protectedOfflineDirectory
        defer {
            if let previous { EdgeTTS.keepOfflineDirectory(previous) }
            else { EdgeTTS.clearOfflineDirectory() }
        }
        try write(dir.appendingPathComponent("wavs/phrase-00000.wav"))
        EdgeTTS.keepOfflineDirectory(dir)

        PiperTTS.failOfflineRun(dir: dir)

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(EdgeTTS.protectedOfflineDirectory == nil,
                "proteção fantasma sobrou para o próximo purge")
    }
}
