import Foundation
import AVFoundation

/// Motor de síntese em FLUXO: usa o CLI `edge-tts` por fatia e entrega cada
/// uma assim que fica pronta. Sem UI — ver INTERFACE.md seção 1.
enum EdgeTTS {
    /// Caminho do CLI edge-tts (primeiro existente; senão "edge-tts" no PATH).
    static let edgeTTSPath: String = EdgeTTS.firstExisting([
        NSHomeDirectory() + "/.local/bin/edge-tts",
        "/opt/homebrew/bin/edge-tts",
        "/usr/local/bin/edge-tts",
    ]) ?? "edge-tts"

    /// Caminho do ffmpeg, se houver; senão nil.
    static let ffmpegPath: String? = EdgeTTS.firstExisting([
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ])

    /// Interpretador Python que consegue importar `edge_tts`.
///
/// A busca cobre as duas instalações reais que existem: venv do pipx (esta
/// máquina) e venv solto em `~/.local/share/edge-tts-venv` (MacBook Pro). No
/// MacBook só o venv tem o pacote — o `python3` do sistema dá
/// `ModuleNotFoundError`, então cair nele faria a síntese falhar sem motivo
/// aparente.
    static var pythonPath: String {
        let pronto = BundledEnv.readyPython()
        return BundledEnv.pickPython(
            support: pronto, supportValid: pronto != nil, legacy: legacyPython())
    }

    private static let legacyLock = NSLock()
    private static var legacyCache: String?

    private static func legacyPython() -> String {
        legacyLock.lock()
        if let cached = legacyCache {
            legacyLock.unlock()
            return cached
        }
        legacyLock.unlock()
        let found = firstPythonWithEdgeTTS()
        legacyLock.lock()
        legacyCache = found
        legacyLock.unlock()
        return found
    }

    /// Interpretador para sintetizar agora: prepara o ambiente embutido
    /// (com progresso no status) e só cai para o legado em dev — se o
    /// preparo falhar E o legado não importar edge_tts, o erro do preparo
    /// (legível) é o que a UI mostra.
    static func pythonForSynthesis(progress: @escaping (String) -> Void) throws -> String {
        if let pronto = BundledEnv.readyPython() { return pronto }
        do {
            return try BundledEnv.ensure(progress: progress)
        } catch {
            let legacy = legacyPython()
            if canImport(legacy, module: "edge_tts") { return legacy }
            throw error
        }
    }

    private static func canImport(_ python: String, module: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = ["-c", "import \(module)"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

private static func firstPythonWithEdgeTTS() -> String {
    let candidates = [
        NSHomeDirectory() + "/Library/Application Support/pipx/venvs/edge-tts/bin/python",
        NSHomeDirectory() + "/.local/share/edge-tts-venv/bin/python",
        "/opt/homebrew/opt/python@3.14/bin/python3.14",
        "/opt/homebrew/bin/python3",
        "/usr/bin/python3",
    ]
    for candidate in candidates
    where FileManager.default.isExecutableFile(atPath: candidate) {
        // Só aceita o que de fato importa `edge_tts`: um interpretador
        // existente mas sem o pacote produziria uma falha confusa.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: candidate)
        probe.arguments = ["-c", "import edge_tts"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        if probe.terminationStatus == 0 { return candidate }
    }
    // Nenhum validado: devolve o primeiro existente e deixa o erro do script
    // aparecer na UI, que é mais útil que um "não encontrei" genérico.
    for candidate in candidates
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return "python3"
}

    /// Script que devolve o áudio e os tempos das frases.
    ///
    /// Procura dentro do bundle (para o app empacotado) e cai para o caminho
    /// do repositório quando roda direto do build, para desenvolvimento.
    static let synthTimingScript: String = {
        let name = "synth_timing.py"
        if let bundled = Bundle.main.url(forResource: "synth_timing", withExtension: "py") {
            return bundled.path
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EdgeSpeak
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // raiz do pacote
            .appendingPathComponent("Tools/\(name)").path
    }()

    /// Cadência da fala, em porcentagem: +0% é o ritmo natural, +30% fala
    /// 30% mais rápido. Vem do `--rate` do edge-tts.
///
/// Por que na síntese e não no player: aplicar `AVAudioPlayer.rate` depois
/// altera o pitch (voz fina/estrangulada). Pedindo ao serviço, a voz é
/// gerada na cadência certa — e o highlight continua sincronizado sozinho,
/// porque os tempos são lidos do áudio já produzido.
struct Rate: Equatable, Hashable, Sendable {
    let percent: Int

    static let normal = Rate(percent: 0)

    /// Passos apresentados na UI, do mais lento ao mais rápido.
    static let choices: [Rate] = [-20, -10, 0, 10, 20, 30, 50].map { Rate(percent: $0) }

    var label: String {
        percent == 0 ? "Normal" : (percent > 0 ? "+\(percent)%" : "\(percent)%")
    }

    /// O formato exato que o CLI espera (ex.: "+30%").
    var cliValue: String {
        percent >= 0 ? "+\(percent)%" : "\(percent)%"
    }
}

/// Uma frase lida, com o instante em que começa dentro do MP3 final.
    struct Segment: Codable, Sendable, Identifiable {
        /// Uma palavra da frase, com tempos locais à fatia (como a frase).
        struct Word: Codable, Sendable {
            let start: Double
            let duration: Double
            let text: String
        }
        let start: Double
        let duration: Double
        let text: String
        /// Palavras da frase, por ordem (vazio sem tempos de palavra).
        var words: [Word] = []
        /// Índice global da frase na lista ativa (-1 quando desconhecido).
        var index: Int = -1
        /// Página de origem (0-based; nil sem PDF).
        var page: Int?
        /// Caixas das linhas do parágrafo de origem ([] sem PDF ou sem tempos).
        var rects: [CGRect] = []
        var id: Int { index >= 0 ? index : Int(start * 1000) }

        enum CodingKeys: String, CodingKey {
            case start, duration, text, words, index, page, rects
        }

        init(start: Double, duration: Double, text: String, words: [Word] = [],
             index: Int = -1, page: Int? = nil, rects: [CGRect] = []) {
            self.start = start
            self.duration = duration
            self.text = text
            self.words = words
            self.index = index
            self.page = page
            self.rects = rects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Double.self, forKey: .start)
            duration = try c.decode(Double.self, forKey: .duration)
            text = try c.decode(String.self, forKey: .text)
            // JSON/cache antigos não trazem `words`: vira lista vazia.
            words = (try? c.decode([Word].self, forKey: .words)) ?? []
            index = (try? c.decode(Int.self, forKey: .index)) ?? -1
            page = try? c.decode(Int.self, forKey: .page)
            rects = (try? c.decode([CGRect].self, forKey: .rects)) ?? []
        }
    }

    /// Resultado da síntese: o áudio e os tempos das frases.
    struct Result: Sendable {
        let audioURL: URL
        let segments: [Segment]
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Fatias por frase

    /// Medido: o edge-tts gera ~35 caracteres por segundo (1760 chars ≈ 49 s).
    /// Por isso o prazo escala com o tamanho da fatia em vez de ser fixo — um
    /// timeout curto matava síntese legítima e parecia travamento.
    static func timeout(forChars chars: Int) -> TimeInterval {
        // 10 chars/s é bem mais pessimista que o observado: sobra folga para
        // rede ruim sem deixar a UI presa indefinidamente.
        min(600, max(60, Double(chars) / 10))
    }

    /// Quantas fatias sintetizar ao mesmo tempo (máx ~3).
    ///
    /// Acima disso o serviço estrangula e a PRIMEIRA fatia demora — o que
    /// anula a leitura progressiva. Pouca concorrência = áudio rápido.
    static let maxConcurrentChunks = 3

    /// Tentativas por fatia. O serviço falha esporadicamente sob carga; sem
    /// retry, uma falha isolada derrubaria a síntese inteira do documento.
    static let maxAttemptsPerChunk = 3

    /// Agrupa frases inteiras em fatias <= maxChars, com a PRIMEIRA curta.
    ///
    /// Frase nunca é cortada no meio: o script devolve ~1 evento por frase e
    /// o emparelhamento por ordem vira o índice global. Primeira curta para
    /// o áudio entrar em ~1 s; as demais vão atrás em ordem de índice.
    static func buildChunks(
        _ phrases: [TextImport.Phrase],
        maxChars: Int,
        firstChars: Int = 450
    ) -> [[TextImport.Phrase]] {
        var out: [[TextImport.Phrase]] = []
        var current: [TextImport.Phrase] = []
        var count = 0
        // A primeira fatia usa firstChars; as demais, maxChars.
        var first = true
        for phrase in phrases {
            let size = phrase.text.count
            let cap = first ? firstChars : maxChars
            if !current.isEmpty, count + 1 + size > cap {
                out.append(current)
                current = []
                count = 0
                first = false
            }
            if !current.isEmpty { count += 1 }  // espaço de junção
            current.append(phrase)
            count += size
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Emparelha os eventos do script com as frases da fatia, por ordem.
    ///
    /// O texto publicado é o da frase (lista ativa); do script vêm só os
    /// tempos. Eventos extras são ignorados; frases sem evento herdam o fim
    /// da anterior — nunca se inventa tempo, só índice, página e caixas.
    static func mapSegments(
        _ script: [Segment], _ phrases: [TextImport.Phrase]
    ) -> [Segment] {
        var out: [Segment] = []
        var lastEnd = 0.0
        for (i, phrase) in phrases.enumerated() {
            if i < script.count {
                let s = script[i]
                out.append(Segment(
                    start: s.start, duration: s.duration,
                    text: phrase.text, words: s.words,
                    index: phrase.index, page: phrase.page,
                    rects: phrase.rects))
                lastEnd = s.start + s.duration
            } else {
                out.append(Segment(
                    start: lastEnd, duration: 0,
                    text: phrase.text, index: phrase.index, page: phrase.page,
                    rects: phrase.rects))
            }
        }
        return out
    }

/// Sintetiza em fluxo: entrega cada fatia assim que fica pronta.
    ///
    /// Por que `AsyncStream` e não um callback: a entrega precisa acontecer no
    /// instante em que a tarefa termina. Com um `TaskGroup` de janela fixa,
    /// o consumidor só é resuming quando uma tarefa do grupo retorna — e o
    /// teste mostrou a fatia 0 pronta aos 38 s sendo entregue só aos 100 s,
    /// porque o grupo esperava as demais. O stream entrega na hora.
    ///
    /// As fatias são sintetizadas em paralelo, mas entregues EM ORDEM: a
    /// reprodução só pode seguir adiante, nunca voltar atrás.
    static func synthesizeStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        maxChars: Int,
        rate: Rate = .normal,
        lêNotas: Bool = true,
        shouldCancel: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void
    ) -> AsyncThrowingStream<ChunkDelivery, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let final = try await runStreaming(
                        phrases: phrases, voice: voice, maxChars: maxChars, rate: rate,
                        lêNotas: lêNotas,
                        shouldCancel: shouldCancel, progress: progress,
                        onChunk: { continuation.yield($0) }
                    )
                    continuation.yield(.final(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Corpo da síntese em fluxo. Emite um `Result` por fatia, em ordem, e no
    /// fim emite o `Result` final com o MP3 único.
    private static func runStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        maxChars: Int,
        rate: Rate,
        lêNotas: Bool,
        shouldCancel: @escaping () -> Bool,
        progress: @escaping (String) -> Void,
        onChunk: @escaping (ChunkDelivery) -> Void
    ) async throws -> Result {
        let groups = buildChunks(phrases, maxChars: maxChars)
        guard !groups.isEmpty else {
            throw makeError("Nada para sintetizar: o texto está vazio.")
        }
        try Task.checkCancellation()

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-\(UUID().uuidString)", isDirectory: true)
        let chunksDir = dir.appendingPathComponent("chunks", isDirectory: true)

        do {
            purgeStaleDirectories(keeping: dir)
            try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)

            let total = groups.count
            var chunkURLs = [URL?](repeating: nil, count: total)
            var chunkSegments = [[Segment]](repeating: [], count: total)
            var chunkDurations = [Double](repeating: 0, count: total)
            let done = Counter()
            // Publicador serial: as fatias podem terminar fora de ordem, mas
            // a entrega precisa ser em ordem. `nextToDeliver` marca até onde
            // já foi emitido.
            let state = OrderedPublisher(total: total)

            try await withThrowingTaskGroup(of: (Int, URL, [Segment]).self) {
                group in
                var inFlight = 0
                for (i, groupPhrases) in groups.enumerated() {
                    // Enche o cano desde t=0. Antes, a primeira fatia ia
                    // sozinha e as seguintes só começavam quando ela
                    // terminava — com a variação medida do serviço (2 s a
                    // 30 s+ por fatia), a fila esvaziava aos ~30 s e a
                    // leitura pausava. Medido: 3 em paralelo não se atrasam
                    // entre si (primeira pronta em ~1 s com o cano cheio).
                    let limit = maxConcurrentChunks
                    while inFlight >= limit {
                        if let finished = try await group.next() {
                            chunkURLs[finished.0] = finished.1
                            chunkSegments[finished.0] = finished.2
                            inFlight -= 1
                            state.emitReady({ chunkURLs[$0] != nil }) { j in
                        onChunk(.chunk(index: j, url: chunkURLs[j]!, segments: chunkSegments[j]))
                    }
                        }
                    }
                    group.addTask {
                        try Task.checkCancellation()
                        // Adaptado para a fala (abreviaturas, anos, lógica); o publicado
                        // segue o original via `mapSegments`. Fronteira de parágrafo
                        // vira quebra de linha (respiro do TTS); `\n` não casa o
                        // `_SENT_END` do script, então o 1:1 frase↔evento segue.
                        var piece = ""
                        for (idx, ph) in groupPhrases.enumerated() {
                            if idx > 0 { piece += groupPhrases[idx - 1].paragraphEnd ? "\n" : " " }
                            piece += ReadAloudFilter.forSpeech(ph.text, voice: voice, lêNotas: lêNotas)
                        }
                        let outURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.mp3", i))
                        let jsonURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.json", i))
                        let textURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.txt", i))
                        // Fronteira com o script: uma linha por frase da fatia,
                        // com o MESMO texto de fala já enviado (forSpeech, na
                        // ordem das frases). O script emparelha 1:1 por ordem,
                        // sem derivar as frases com regex próprio.
                        let linesURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.lines.txt", i))
                        let speechLines = groupPhrases.map {
                            ReadAloudFilter.forSpeech($0.text, voice: voice, lêNotas: lêNotas)
                        }
                        // Por que o script Python e não o CLI: o CLI só grava
                        // SRT por frase; o script lê os eventos SentenceBoundary
                        // da biblioteca e devolve o tempo de cada uma em JSON.
                        try piece.write(to: textURL, atomically: true, encoding: .utf8)
                        try speechLines.joined(separator: "\n")
                            .write(to: linesURL, atomically: true, encoding: .utf8)
                        // Retry: sob carga o serviço falha esporadicamente.
                        // Tentar de novo evita perder o documento por uma
                        // falha de rede pontual.
                        var lastError = "erro desconhecido"
                        for attempt in 1...self.maxAttemptsPerChunk {
                            do {
                                try Task.checkCancellation()
                                let py = try Self.pythonForSynthesis(progress: progress)
                                try Task.checkCancellation()
                                try? FileManager.default.removeItem(at: outURL)
                                let (status, stderr) = try self.run(
                                    py,
                                    [synthTimingScript,
                                     "--text-file", textURL.path,
                                     "--lines-file", linesURL.path,
                                     "--voice", voice,
                                     "--rate", rate.cliValue,
                                     "--out-mp3", outURL.path,
                                     "--out-json", jsonURL.path],
                                    timeout: self.timeout(forChars: piece.count)
                                )
                                guard status == 0 else {
                                    lastError = "status \(status): \(self.tail(stderr, max: 300))"
                                    throw self.makeError(lastError)
                                }
                                guard let size = self.fileSize(outURL), size > 0 else {
                                    lastError = "não gerou áudio: \(self.tail(stderr, max: 300))"
                                    throw self.makeError(lastError)
                                }
                                progress("Sintetizando \(done.increment())/\(total)…")
                                let script = try self.loadSegments(jsonURL)
                                return (i, outURL, self.mapSegments(script, groupPhrases))
                            } catch {
                                lastError = self.tail(error.localizedDescription, max: 300)
                                // 403 é bloqueio do serviço, não instabilidade:
                                // repetir a mesma chamada não adianta, falha já.
                                if lastError.contains("403") { break }
                                if attempt < self.maxAttemptsPerChunk {
                                    // Espera curta e progressiva: falhas do
                                    // serviço costumam se resolver em segundos.
                                    try? await Task.sleep(
                                        nanoseconds: UInt64(attempt) * 800_000_000)
                                }
                            }
                        }
                        throw self.makeError(
                            "edge-tts falhou após \(self.maxAttemptsPerChunk) "
                                + "tentativas na fatia \(i + 1)/\(total): \(lastError)")
                    }
                    inFlight += 1
                }
                while let finished = try await group.next() {
                    chunkURLs[finished.0] = finished.1
                    chunkSegments[finished.0] = finished.2
                    state.emitReady({ chunkURLs[$0] != nil }) { i in
                        onChunk(.chunk(index: i, url: chunkURLs[i]!, segments: chunkSegments[i]))
                    }
                }
            }
            if shouldCancel() { throw makeError("Síntese cancelada.") }

            let ordered = chunkURLs.compactMap { $0 }
            guard ordered.count == total else {
                throw makeError("Síntese incompleta: \(ordered.count) de \(total) fatias.")
            }
            for url in ordered {
                chunkDurations[chunkURLs.firstIndex(of: url) ?? 0] = await duration(of: url)
            }
            let outURL = try concat(ordered, into: dir.appendingPathComponent("EdgeSpeak.mp3"))
            var segments: [Segment] = []
            var offset: Double = 0
            for i in 0..<total {
                for seg in chunkSegments[i] {
                    // As palavras andam junto com a frase: mesmo deslocamento.
                    let shifted = seg.words.map { w in Segment.Word(
                        start: w.start + offset, duration: w.duration, text: w.text) }
                    segments.append(Segment(
                        start: seg.start + offset, duration: seg.duration,
                        text: seg.text, words: shifted,
                        index: seg.index, page: seg.page,
                        rects: seg.rects))
                }
                offset += chunkDurations[i]
            }
            // A partir daqui este diretório é o da leitura corrente: as
            // próximas purgas (inclusive de outras vozes/motores) o preservam.
            keptLock.lock()
            protectedDir = dir
            keptLock.unlock()
            return Result(audioURL: outURL, segments: segments)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Uma entrega do fluxo: uma fatia pronta, ou o resultado final.
    enum ChunkDelivery: Sendable {
        case chunk(index: Int, url: URL, segments: [Segment])
        case final(Result)
    }

    /// Publica as fatias em ordem, ignorando as que chegam fora de sequência.
    ///
    /// Por que uma classe com lock: o emissor roda dentro do consumidor do
    /// grupo, e o índice precisa ser lido e incrementado sem corrida.
    /// Interna (não privada) para o harness headless cobrir a ordem.
    final class OrderedPublisher: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private let total: Int

        init(total: Int) { self.total = total }

        /// Chama `body` para cada índice que já está pronto, em ordem.
        func emitReady(_ isReady: (Int) -> Bool, _ body: (Int) -> Void) {
            lock.lock()
            var toEmit: [Int] = []
            while next < total, isReady(next) {
                toEmit.append(next)
                next += 1
            }
            lock.unlock()
            for i in toEmit { body(i) }
        }
    }

    /// Junta as fatias num MP3 único (ffmpeg quando disponível).
    private static func concat(_ ordered: [URL], into outURL: URL) throws -> URL {
        let fm = FileManager.default
        if let ffmpeg = ffmpegPath {
            let listURL = outURL.deletingLastPathComponent().appendingPathComponent("list.txt")
            let list = ordered.map { "file '\($0.path)'" }.joined(separator: "\n") + "\n"
            try list.write(to: listURL, atomically: true, encoding: .utf8)
            let (status, stderr) = try run(
                ffmpeg,
                ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", outURL.path])
            guard status == 0 else {
                throw makeError("ffmpeg falhou (status \(status)): \(tail(stderr))")
            }
        } else {
            guard fm.createFile(atPath: outURL.path, contents: nil) else {
                throw makeError("Não foi possível criar \(outURL.lastPathComponent).")
            }
            let handle = try FileHandle(forWritingTo: outURL)
            defer { try? handle.close() }
            for url in ordered { try handle.write(contentsOf: Data(contentsOf: url)) }
        }
        guard let size = fileSize(outURL), size > 0 else {
            throw makeError("A concatenação não gerou áudio.")
        }
        return outURL
    }

    /// Lê os tempos de frase gravados pelo synth_timing.py.
    private static func loadSegments(_ jsonURL: URL) throws -> [Segment] {
        guard let data = try? Data(contentsOf: jsonURL),
              let parsed = try? JSONDecoder().decode(Timings.self, from: data)
        else {
            // Sem tempos não há highlight, mas o áudio continua válido:
            // degrada em silêncio em vez de falhar a síntese.
            return []
        }
        return parsed.segments
    }

    private struct Timings: Decodable {
        let segments: [Segment]
    }

    /// Duração real do MP3, em segundos.
    ///
    /// Por que ler o arquivo em vez de somar os tempos das frases: há silêncio
    /// no fim de cada fatia, e é esse silêncio que precisa entrar na conta para
    /// o highlight das fatias seguintes não adiantar nem atrasar.
    private static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) {
            return Double(CMTimeGetSeconds(d))
        }
        return 0
    }

    /// Encerra qualquer edge-tts deixado pendente por uma síntese cancelada.
    /// Sem isso, o usuário cancela mas os processos filhos seguem consumindo CPU.
    ///
    /// Casa pelo nome do script (`synth_timing.py`), que só este app invoca —
    /// nunca por "python" solto, para não atingir processos alheios. Os
    /// `Process` criados em `run` também são guardados e encerrados direto.
    static func killRunningProcesses() {
        runningLock.lock()
        let tracked = Array(runningSynth.values)
        runningLock.unlock()
        for proc in tracked {
            if proc.isRunning { proc.terminate() }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "synth_timing.py"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// Processos de síntese em curso (só os que rodam `synth_timing.py`),
    /// para o cancelamento encerrá-los direto sem depender só do pkill.
    private static let runningLock = NSLock()
    private static var runningSynth: [Int32: Process] = [:]

    /// Diretório da leitura corrente (o que contém o MP3 do `Result`): o
    /// `purgeStaleDirectories` nunca o apaga, senão o replay posterior cai no
    /// guarda silencioso do `restart` com `hasAudio` verdadeiro e nada toca.
    private static let keptLock = NSLock()
    private static var protectedDir: URL?

    /// Contador de fatias concluídas, seguro para várias filas.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }; return current
        }
        @discardableResult
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            current += 1
            return current
        }
    }

    // MARK: - Ajuda

    /// Executa um processo bloqueante; stderr vai para arquivo (sem risco de
    /// deadlock de pipe). Retorna status e o conteúdo de stderr.
    private static func run(_ path: String, _ args: [String]) throws -> (status: Int32, stderr: String) {
        try run(path, args, timeout: timeout(forChars: 100_000))
    }

    /// Executa com prazo: se o processo não terminar a tempo, é terminado.
    /// Sem isso, uma falha de rede deixa o edge-tts pendurado e a UI em
    /// "Sintetizando…" indefinidamente.
    private static func run(
        _ path: String, _ args: [String], timeout: TimeInterval
    ) throws -> (status: Int32, stderr: String) {
        let fm = FileManager.default
        let errURL = fm.temporaryDirectory
            .appendingPathComponent("edgespeak-stderr-\(UUID().uuidString).log")
        guard fm.createFile(atPath: errURL.path, contents: nil) else {
            throw makeError("Não foi possível criar arquivo temporário de stderr.")
        }
        defer { try? fm.removeItem(at: errURL) }

        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            throw makeError("Não foi possível executar \(path): \(error.localizedDescription)")
        }
        // Só as sínteses deste app entram no registro de cancelamento: o
        // primeiro argumento é o caminho do `synth_timing.py`.
        let isSynth = args.first?.hasSuffix("synth_timing.py") ?? false
        if isSynth {
            runningLock.lock()
            runningSynth[process.processIdentifier] = process
            runningLock.unlock()
        }
        defer {
            if isSynth {
                runningLock.lock()
                runningSynth.removeValue(forKey: process.processIdentifier)
                runningLock.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            // Dá um instante para o SIGTERM; depois força.
            let hard = Date().addingTimeInterval(2)
            while process.isRunning && Date() < hard {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? errHandle.close()
            let partial = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw makeError(
                "\(URL(fileURLWithPath: path).lastPathComponent) não respondeu em "
                    + "\(Int(timeout))s e foi encerrado. \(tail(partial, max: 400))")
        }
        process.waitUntilExit()
        try? errHandle.close()

        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, stderr)
    }

    /// Remove diretórios EdgeSpeak-* de execuções anteriores. O MP3 fica em disco
    /// porque o AVAudioPlayer precisa dele enquanto toca, então os diretórios
    /// se acumulam (cada um com dezenas de MB) sem esse passo.
    static func purgeStaleDirectories(keeping current: URL) {
        let fm = FileManager.default
        keptLock.lock()
        let sheltered = protectedDir
        keptLock.unlock()
        let keepURLs = [current.standardizedFileURL, sheltered?.standardizedFileURL]
            .compactMap { $0 }
        guard let items = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in items
        where url.lastPathComponent.hasPrefix("EdgeSpeak-")
            && !keepURLs.contains(url.standardizedFileURL) {
            try? fm.removeItem(at: url)
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private static func tail(_ text: String, max: Int = 2000) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "(sem saída em stderr)" }
        return t.count <= max ? t : "…" + String(t.suffix(max))
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "EdgeSpeak.EdgeTTS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
