import Foundation

/// Síntese offline com Piper (voz neural local, sem rede na leitura).
///
/// O app lança `Tools/piper_synth.py` como processo filho (a voz carrega UMA
/// vez) e o mata ao parar/trocar — sem daemon instalado. Na primeira
/// utilização cria um venv próprio e baixa a voz sob demanda, com aviso na UI.
enum PiperTTS {
    /// Vozes offline expostas na seção "Offline" do seletor.
    static let faberPtBR = "offline-faber-ptbr"
    static let lessacEnUS = "offline-lessac-enus"
    static let edressonPtBR = "offline-edresson-ptbr"
    static let caduPtBR = "offline-cadu-ptbr"
    static let jeffPtBR = "offline-jeff-ptbr"

    static let offlineVoices = [faberPtBR, edressonPtBR, caduPtBR, jeffPtBR, lessacEnUS]

    /// Rótulo curto para o menu.
    static func label(for voice: String) -> String {
        switch voice {
        case faberPtBR: "Faber (BR, masculino, offline)"
        case edressonPtBR: "Edresson (BR, offline)"
        case caduPtBR: "Cadu (BR, offline)"
        case jeffPtBR: "Jeff (BR, offline)"
        case lessacEnUS: "Lessac (EUA, masculino, offline)"
        default: voice
        }
    }

    static func isOfflineVoice(_ voice: String) -> Bool {
        offlineVoices.contains(voice)
    }

    // MARK: - Caminhos (modelos/venv fora do repo, em Application Support)

    /// Pasta base: `~/Library/Application Support/EdgeSpeak`.
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeSpeak", isDirectory: true)
    }

    static var venvDir: URL { supportDir.appendingPathComponent("piper-venv", isDirectory: true) }
    /// Interpretador da voz offline: o venv de suporte (embutido) quando
    /// pronto, senão o venv legado em Application Support (máquinas de dev).
    static var venvPython: URL {
        if let pronto = BundledEnv.readyPython() {
            return URL(fileURLWithPath: pronto)
        }
        return venvDir.appendingPathComponent("bin/python", isDirectory: false)
    }
    static var voicesDir: URL { supportDir.appendingPathComponent("voices", isDirectory: true) }

    /// Script persistente: dentro do bundle (app empacotado) ou no repo (dev).
    static let synthScript: String = {
        let name = "piper_synth"
        if let bundled = Bundle.main.url(forResource: "piper_synth", withExtension: "py") {
            return bundled.path
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/\(name).py").path
    }()

    // MARK: - Vozes e wheel

    private static let hfBase = "https://huggingface.co/rhasspy/piper-voices/resolve/main/"

    private static func voiceFiles(for voice: String) -> (file: String, remote: String)? {
        guard let file = voiceFileBase(for: voice) else { return nil }
        return (file, hfBase + voiceRemotePath(for: voice)!)
    }

    /// Nome-base do modelo (.onnx/.onnx.json), sem extensão. Puro (testável).
    static func voiceFileBase(for voice: String) -> String? {
        switch voice {
        case faberPtBR: "pt_BR-faber-medium"
        case lessacEnUS: "en_US-lessac-medium"
        case edressonPtBR: "pt_BR-edresson-low"
        case caduPtBR: "pt_BR-cadu-medium"
        case jeffPtBR: "pt_BR-jeff-medium"
        default: nil
        }
    }

    private static func voiceRemotePath(for voice: String) -> String? {
        switch voice {
        case faberPtBR: "pt/pt_BR/faber/medium/pt_BR-faber-medium"
        case lessacEnUS: "en/en_US/lessac/medium/en_US-lessac-medium"
        case edressonPtBR: "pt/pt_BR/edresson/low/pt_BR-edresson-low"
        case caduPtBR: "pt/pt_BR/cadu/medium/pt_BR-cadu-medium"
        case jeffPtBR: "pt/pt_BR/jeff/medium/pt_BR-jeff-medium"
        default: nil
        }
    }

    /// Vozes embutidas no bundle (`Resources/voices`; reserva de dev em
    /// `Build/staging/voices`), ou nil.
    static var bundledVoicesDir: URL? {
        if let url = Bundle.main.url(forResource: "voices", withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for base in ["Build/staging", "Resources"] {
            let url = root.appendingPathComponent(base).appendingPathComponent("voices")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Escolha do .onnx: suporte, depois bundle, senão o caminho de suporte
    /// (alvo do download). Pura no essencial (testável com URLs fake).
    static func pickOnnx(support: URL, supportExists: Bool, bundle: URL?, bundleExists: Bool) -> URL {
        if supportExists { return support }
        if bundleExists, let bundle { return bundle }
        return support
    }

    /// Caminho local do .onnx (nil para voz desconhecida).
    static func onnxPath(for voice: String) -> String? {
        guard let file = voiceFileBase(for: voice) else { return nil }
        let fm = FileManager.default
        let support = voicesDir.appendingPathComponent(file + ".onnx")
        let supportJson = voicesDir.appendingPathComponent(file + ".onnx.json")
        var bundle: URL?
        var bundleOk = false
        if let dir = bundledVoicesDir {
            let b = dir.appendingPathComponent(file + ".onnx")
            let bj = dir.appendingPathComponent(file + ".onnx.json")
            bundle = b
            bundleOk = fm.fileExists(atPath: b.path) && fm.fileExists(atPath: bj.path)
        }
        return pickOnnx(
            support: support,
            supportExists: cachedVoiceValid(onnx: support, json: supportJson),
            bundle: bundle, bundleExists: bundleOk).path
    }

    /// Wheel do Piper por arquitetura (`uname -m`).
    static var wheelURL: String {
        var arch = "arm64"
        var sysinfo = utsname()
        uname(&sysinfo)
        let m = withUnsafeBytes(of: &sysinfo.machine) { bytes -> String in
            let c = bytes.bindMemory(to: CChar.self)
            return String(cString: c.baseAddress!)
        }
        if m.contains("x86_64") { arch = "x86_64" }
        let tag = arch == "arm64" ? "macosx_11_0_arm64" : "macosx_10_9_x86_64"
        return "https://github.com/OHF-Voice/piper1-gpl/releases/download/v1.8.0/piper_tts-1.8.0-cp39-abi3-\(tag).whl"
    }

    /// Pisos de sanidade para a voz baixada (hipótese de planejamento: o
    /// .onnx ronda ~63 MB e o .onnx.json, alguns KB; os pisos só rejeitam
    /// truncados grosseiros e mudam se o catálogo trocar de voz).
    static let onnxMinBytes: Int64 = 1_000_000
    static let jsonMinBytes: Int64 = 512

    /// Regra pura do download: recebido cobre o mínimo e, quando o servidor
    /// informou o tamanho, cobre o esperado. Testável sem rede.
    static func downloadComplete(received: Int64, expected: Int64, minBytes: Int64) -> Bool {
        guard received >= minBytes, received > 0 else { return false }
        if expected > 0 { return received >= expected }
        return true
    }

    /// Regra pura dos tamanhos em cache: ambos acima dos pisos.
    static func cachedVoiceSizesValid(onnxSize: Int?, jsonSize: Int?) -> Bool {
        guard let o = onnxSize, let j = jsonSize else { return false }
        return Int64(o) >= onnxMinBytes && Int64(j) >= jsonMinBytes
    }

    /// Voz em cache válida: tamanhos acima dos pisos e .onnx.json legível
    /// como JSON. Um .onnx parcial passa na existência mas cai aqui.
    static func cachedVoiceValid(onnx: URL, json: URL) -> Bool {
        let fm = FileManager.default
        guard let attrsO = try? fm.attributesOfItem(atPath: onnx.path),
              let attrsJ = try? fm.attributesOfItem(atPath: json.path),
              cachedVoiceSizesValid(onnxSize: attrsO[.size] as? Int, jsonSize: attrsJ[.size] as? Int),
              let data = try? Data(contentsOf: json),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return false }
        return true
    }

    /// Duração efetiva da frase: a medida no WAV; só cai para a declarada
    /// quando a medida falta ou vem zerada. Pura (testável sem áudio).
    static func effectiveDuration(measured: Double?, declared: Double) -> Double {
        if let m = measured, m > 0 { return m }
        return declared
    }

    /// `Rate.percent` em `length_scale` do Piper: +30% mais rápido = áudio 1/1,3.
    static func lengthScale(for rate: EdgeTTS.Rate) -> Double {
        1.0 / (1.0 + Double(rate.percent) / 100.0)
    }

    // MARK: - Preparação (venv + voz, sob demanda)

    /// Garante o venv com o Piper instalado; erro legível para a UI.
    static func ensureVenv() throws {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: venvPython.path) { return }
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: venvDir.path) {
            let (st, err) = runSync("/usr/bin/python3", ["-m", "venv", venvDir.path])
            guard st == 0 else {
                throw makeError("Não foi possível criar o ambiente da voz offline (\(tail(err))). Verifique se o python3 está instalado.")
            }
        }
        let pip = venvDir.appendingPathComponent("bin/pip").path
        let (st, err) = runSync(pip, ["install", "--quiet", wheelURL], timeout: 600)
        guard st == 0, fm.isExecutableFile(atPath: venvPython.path) else {
            throw makeError("Falha ao instalar a voz offline (\(tail(err))). Verifique a rede e tente de novo.")
        }
    }

    /// Baixa o .onnx + .onnx.json da voz, com progresso para a UI.
    static func ensureVoice(_ voice: String, progress: @escaping (String) -> Void) async throws -> String {
        guard let (file, remote) = voiceFiles(for: voice) else {
            throw makeError("Voz offline desconhecida: \(voice).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        let onnx = voicesDir.appendingPathComponent(file + ".onnx")
        let json = voicesDir.appendingPathComponent(file + ".onnx.json")
        if fm.fileExists(atPath: onnx.path), fm.fileExists(atPath: json.path) {
            // Existência não basta: parcial de queda anterior cai na
            // validação e é removido para baixar de novo.
            if cachedVoiceValid(onnx: onnx, json: json) {
                return onnx.path
            }
            try? fm.removeItem(at: onnx)
            try? fm.removeItem(at: json)
        }
        // Voz embutida no bundle: usa direto (só leitura), sem download.
        if let dir = bundledVoicesDir {
            let b = dir.appendingPathComponent(file + ".onnx")
            let bj = dir.appendingPathComponent(file + ".onnx.json")
            if fm.fileExists(atPath: b.path), fm.fileExists(atPath: bj.path) {
                return b.path
            }
        }
        progress("Baixando a voz offline \(file) (~63 MB, só desta vez)…")
        try await download(from: remote + ".onnx", to: onnx, label: file, progress: progress)
        try await download(from: remote + ".onnx.json", to: json, label: file, progress: progress)
        return onnx.path
    }

    private static func download(from url: String, to dest: URL, label: String, progress: @escaping (String) -> Void) async throws {
        guard let source = URL(string: url) else { throw makeError("Endereço inválido para a voz \(label).") }
        let (bytes, response) = try await URLSession.shared.bytes(from: source)
        let total = response.expectedContentLength
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Temporário no MESMO diretório (mesmo volume): o destino final só
        // aparece via rename atômico após validado; parcial nunca é aceito.
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        var received: Int64 = 0
        do {
            var lastReport = Date.distantPast
            // `AsyncBytes` entrega byte a byte: junta em blocos antes de gravar.
            var bloco = Data()
            bloco.reserveCapacity(65536)
            func despeja() throws {
                if !bloco.isEmpty {
                    try handle.write(contentsOf: bloco)
                    bloco.removeAll(keepingCapacity: true)
                }
            }
            for try await byte in bytes {
                bloco.append(byte)
                received += 1
                if bloco.count >= 65536 {
                    try despeja()
                    if Date().timeIntervalSince(lastReport) > 0.5 {
                        lastReport = Date()
                        if total > 0 {
                            progress("Baixando a voz offline (\(received / 1_048_576)/\(total / 1_048_576) MB)…")
                        } else {
                            progress("Baixando a voz offline (\(received / 1_048_576) MB)…")
                        }
                    }
                }
            }
            try despeja()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try? handle.close()
        let isJSON = dest.path.hasSuffix(".onnx.json")
        let piso = isJSON ? jsonMinBytes : onnxMinBytes
        guard downloadComplete(received: received, expected: total, minBytes: piso) else {
            try? FileManager.default.removeItem(at: tmp)
            throw makeError("O download da voz \(label) veio incompleto (\(received) de \(total > 0 ? "\(total)" : "?") bytes). Tente de novo.")
        }
        if isJSON {
            guard let dados = try? Data(contentsOf: tmp),
                  (try? JSONSerialization.jsonObject(with: dados)) != nil
            else {
                try? FileManager.default.removeItem(at: tmp)
                throw makeError("O download da voz \(label) veio corrompido. Tente de novo.")
            }
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - Sessão persistente (processo filho, morre com a leitura)

    private static let sessionLock = NSLock()
    private static var active: PiperSession?

    static func stopActiveSession() {
        sessionLock.lock()
        let s = active
        active = nil
        sessionLock.unlock()
        s?.stop()
    }

    /// Encerra sessões órfãs (ex.: após cancelamento). Mesmo estreitamento
    /// do EdgeTTS: só sob caminho do app, nunca execução manual alheia.
    static func killRunningProcesses() {
        stopActiveSession()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "[Ee]dge[Ss]peak.*piper_synth\\.py"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// Uma sessão: a voz já carregada, um pedido por linha JSON.
    private final class PiperSession: @unchecked Sendable {
        private let process: Process
        private let stdin: FileHandle
        private let stdout: FileHandle
        private let lock = NSLock()
        private var nextID = 0
        private var closed = false

        init(onnx: String, lengthScale: Double) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: PiperTTS.venvPython.path)
            proc.arguments = [PiperTTS.synthScript, "--onnx", onnx, "--length-scale", "\(lengthScale)"]
            let inPipe = Pipe()
            let outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                throw makeError("Não foi possível iniciar a voz offline: \(error.localizedDescription)")
            }
            process = proc
            stdin = inPipe.fileHandleForWriting
            stdout = outPipe.fileHandleForReading
            // Espera o "ready" (a carga da voz é a parte lenta, com prazo).
            let limite = Date().addingTimeInterval(300)
            var resto = Data()
            var pronto = false
            while Date() < limite, !pronto {
                let pedaço = stdout.availableData
                if pedaço.isEmpty {
                    if !proc.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                resto.append(pedaço)
                if resto.contains(0x0A),
                   let linha = String(data: resto, encoding: .utf8),
                   linha.contains("\"ready\"") {
                    pronto = true
                }
            }
            guard pronto else {
                proc.terminate()
                throw makeError("A voz offline não respondeu ao carregar. Tente de novo.")
            }
        }

        /// Sintetiza um texto para um WAV; devolve a duração DECLARADA pelo
        /// modelo (o chamador mede o WAV e usa a medida — ver `duration(of:)`
        /// e `effectiveDuration`).
        func synth(text: String, wav: String, lengthScale: Double) throws -> Double {
            lock.lock()
            defer { lock.unlock() }
            guard !closed, process.isRunning else {
                throw makeError("A voz offline foi encerrada no meio da leitura.")
            }
            let id = nextID
            nextID += 1
            let pedido: [String: Any] = ["id": id, "text": text, "wav": wav, "length_scale": lengthScale]
            let data = try JSONSerialization.data(withJSONObject: pedido)
            stdin.write(data + Data([0x0A]))
            // Resposta: uma linha JSON; prazo folgado (primeira frase inclui I/O).
            let deadline = Date().addingTimeInterval(300)
            var acumulada = Data()
            while Date() < deadline {
                let pedaço = stdout.availableData
                if pedaço.isEmpty {
                    if !process.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                acumulada.append(pedaço)
                if let fim = acumulada.firstIndex(of: 0x0A) {
                    let linha = acumulada[..<fim]
                    acumulada = acumulada[acumulada.index(after: fim)...]
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(linha)) as? [String: Any],
                          (obj["id"] as? Int) == id
                    else { continue }
                    if let erro = obj["error"] as? String {
                        throw makeError("A voz offline falhou numa frase: \(erro)")
                    }
                    return (obj["duration"] as? Double) ?? 0
                }
            }
            throw makeError("A voz offline não respondeu a tempo e foi encerrada.")
        }

        func stop() {
            lock.lock()
            closed = true
            lock.unlock()
            try? stdin.close()
            if process.isRunning {
                process.terminate()
                let limite = Date().addingTimeInterval(2)
                while process.isRunning, Date() < limite {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    // MARK: - Síntese frase a frase, em ordem (Piper é rápido; sem paralelismo)

    /// Sintetiza em fluxo: uma entrega por frase (texto+início+página no mesmo
    /// formato de `EdgeTTS.Segment`) e no fim o WAV único concatenado.
    static func synthesizeStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        rate: EdgeTTS.Rate = .normal,
        lêNotas: Bool = true,
        shouldCancel: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void
    ) -> AsyncThrowingStream<EdgeTTS.ChunkDelivery, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let final = try await runStreaming(
                        phrases: phrases, voice: voice, rate: rate,
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

    private static func runStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        rate: EdgeTTS.Rate,
        lêNotas: Bool,
        shouldCancel: @escaping () -> Bool,
        progress: @escaping (String) -> Void,
        onChunk: @escaping (EdgeTTS.ChunkDelivery) -> Void
    ) async throws -> EdgeTTS.Result {
        guard !phrases.isEmpty else { throw makeError("Nada para sintetizar: o texto está vazio.") }
        try Task.checkCancellation()
        // Ambiente embutido primeiro (sem rede); se não der, o `ensureVenv`
        // legado tenta o caminho das máquinas de dev.
        if BundledEnv.readyPython() == nil {
            _ = try? BundledEnv.ensure(progress: progress)
        }
        try ensureVenv()
        let onnx = try await ensureVoice(voice, progress: progress)
        try Task.checkCancellation()
        if shouldCancel() { throw makeError("Síntese cancelada.") }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-\(UUID().uuidString)", isDirectory: true)
        let wavsDir = dir.appendingPathComponent("wavs", isDirectory: true)
        try fm.createDirectory(at: wavsDir, withIntermediateDirectories: true)
        EdgeTTS.purgeStaleDirectories(keeping: dir)
        progress("Carregando a voz offline (só desta vez por leitura)…")

        let escala = lengthScale(for: rate)
        let session = try PiperSession(onnx: onnx, lengthScale: escala)
        sessionLock.lock()
        let anterior = active
        active = session
        sessionLock.unlock()
        anterior?.stop()

        do {
            var urls: [URL] = []
            var segments: [EdgeTTS.Segment] = []
            var offset = 0.0
            let total = phrases.count
            for (i, phrase) in phrases.enumerated() {
                try Task.checkCancellation()
                if shouldCancel() { throw makeError("Síntese cancelada.") }
                // Texto adaptado para a fala; o publicado segue o original.
                // Fim de parágrafo ganha `\n` (pausa do modelo; o vão entra na
                // duração medida do WAV e o offset acumulado segue correto).
                var falado = ReadAloudFilter.forSpeech(phrase.text, voice: voice, lêNotas: lêNotas)
                if falado.isEmpty { falado = phrase.text }
                if phrase.paragraphEnd { falado += "\n" }
                let wavURL = wavsDir.appendingPathComponent(String(format: "frase-%05d.wav", i))
                let declarado = try session.synth(text: falado, wav: wavURL.path, lengthScale: escala)
                guard let size = (try? fm.attributesOfItem(atPath: wavURL.path))?[.size] as? Int, size > 0 else {
                    throw makeError("A voz offline não gerou áudio na frase \(i + 1).")
                }
                // Duração REAL do WAV medido (o caminho online faz o mesmo em
                // `EdgeTTS.duration(of:)`): a declarada acumula deriva no
                // destaque das frases seguintes. Sem silêncio inserido: o
                // offset avança exatamente a duração medida.
                let dur = effectiveDuration(measured: duration(of: wavURL), declared: declarado)
                progress("Sintetizando \(i + 1)/\(total)…")
                let seg = EdgeTTS.Segment(start: offset, duration: dur, text: phrase.text, index: phrase.index, page: phrase.page, rects: phrase.rects)
                segments.append(seg)
                offset += dur
                urls.append(wavURL)
                // Entrega imediata: a primeira frase toca sem esperar o resto.
                let local = EdgeTTS.Segment(start: 0, duration: dur, text: phrase.text, index: phrase.index, page: phrase.page, rects: phrase.rects)
                onChunk(.chunk(index: i, url: wavURL, segments: [local]))
            }
            let final = try concatWavs(urls, into: dir.appendingPathComponent("EdgeSpeak.wav"))
            // A sessão morre com a leitura: sem processo sobrando.
            stopActiveSession()
            // `segments` já traz tempos globais (offset acumulado frase a frase).
            return EdgeTTS.Result(audioURL: final, segments: segments)
        } catch {
            session.stop()
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    // MARK: - WAV: duração e concatenação

    /// Duração lida do cabeçalho do WAV.
    static func duration(of url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 64), head.count >= 44 else { return nil }
        func u32(_ o: Int) -> UInt32 {
            head[o...o + 3].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func u16(_ o: Int) -> UInt16 {
            UInt16(head[o]) | (UInt16(head[o + 1]) << 8)
        }
        let taxa = Double(u32(24))
        let canais = Double(u16(22))
        let bits = Double(u16(34))
        guard taxa > 0, canais > 0, bits > 0,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return nil }
        let bytesPorAmostra = canais * bits / 8.0
        return Double(size - 44) / (taxa * bytesPorAmostra)
    }

    /// Junta os WAVs num único arquivo (ffmpeg quando houver, senão na mão:
    /// concatena o PCM sob um cabeçalho só, mesmo formato/taxa/canais).
    static func concatWavs(_ ordered: [URL], into outURL: URL) throws -> URL {
        guard !ordered.isEmpty else { throw makeError("Nada para juntar: nenhuma frase sintetizada.") }
        if ordered.count == 1 {
            try? FileManager.default.removeItem(at: outURL)
            try FileManager.default.copyItem(at: ordered[0], to: outURL)
            return outURL
        }
        if let ffmpeg = EdgeTTS.ffmpegPath {
            let listURL = outURL.deletingLastPathComponent().appendingPathComponent("lista.txt")
            let list = ordered.map { "file '\($0.path)'" }.joined(separator: "\n") + "\n"
            try list.write(to: listURL, atomically: true, encoding: .utf8)
            let (status, err) = runSync(ffmpeg, ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", outURL.path])
            guard status == 0 else { throw makeError("ffmpeg falhou (status \(status)): \(tail(err))") }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int, size > 0 else {
                throw makeError("A junção não gerou áudio.")
            }
            return outURL
        }
        // Na mão: cabeçalho do primeiro + PCM de todos (mesmo formato).
        var pcm = Data()
        var cabecalho: Data?
        for url in ordered {
            let dados = try Data(contentsOf: url)
            guard dados.count > 44 else { throw makeError("WAV inválido na junção.") }
            if cabecalho == nil { cabecalho = dados.prefix(44) }
            pcm.append(dados.suffix(from: 44))
        }
        guard var head = cabecalho else { throw makeError("A junção não gerou áudio.") }
        func escreveU32(_ v: UInt32, em o: Int) {
            head[o] = UInt8(v & 0xFF)
            head[o + 1] = UInt8((v >> 8) & 0xFF)
            head[o + 2] = UInt8((v >> 16) & 0xFF)
            head[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        escreveU32(UInt32(pcm.count + 36), em: 4)
        escreveU32(UInt32(pcm.count), em: 40)
        try? FileManager.default.removeItem(at: outURL)
        var final = head
        final.append(pcm)
        try final.write(to: outURL, options: .atomic)
        return outURL
    }

    // MARK: - Ajuda

    private static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> (Int32, String) {
        let fm = FileManager.default
        let errURL = fm.temporaryDirectory.appendingPathComponent("edgespeak-err-\(UUID().uuidString).log")
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: errURL) }
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else { return (1, "(sem stderr)") }
        defer { try? errHandle.close() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errHandle
        do {
            try proc.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let fim = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < fim {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
            return (1, "tempo esgotado após \(Int(timeout))s")
        }
        proc.waitUntilExit()
        try? errHandle.close()
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (proc.terminationStatus, err)
    }

    private static func tail(_ text: String, max: Int = 400) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "(sem detalhes)" }
        return t.count <= max ? t : "…" + String(t.suffix(max))
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "EdgeSpeak.PiperTTS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
