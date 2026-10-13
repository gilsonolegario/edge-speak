import Foundation
import AppKit
import Combine

/// Caixa Sendable para levar mensagens de progresso da thread de fundo à main.
private final class StatusRelay: @unchecked Sendable {
    weak var controller: SpeechController?
}

@MainActor
final class SpeechController: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var status: String = ""
    /// Chave+args do status atual no catálogo `L`, para re-resolver o texto
    /// na troca de idioma. Nil quando o status é mensagem crua dos motores
    /// (progresso, fora do catálogo) — aí não há o que re-resolver.
    private var statusKey: String?
    private var statusArgs: [String] = []
    /// Idioma atual da interface, lido do padrão persistido (a UI grava via
    /// `@AppStorage`; aqui não há `@AppStorage`, então lê o `UserDefaults`).
    private var idiomaAtual: L.Idioma {
        L.Idioma(
            rawValue: UserDefaults.standard.string(forKey: AppSetting.languageKey)
                ?? AppSetting.languageDefault) ?? .pt
    }
    @Published var isPlaying: Bool = false
    @Published var isPaused: Bool = false
    @Published private(set) var hasAudio: Bool = false

    /// Reprodução em fluxo: cada fatia toca assim que chega.
    let streamer = StreamingPlayer()

    /// Fatias sintetizadas até agora e total previsto, para a barra de progresso.
    @Published private(set) var completedChunks: Int = 0
    @Published private(set) var totalChunks: Int = 0
    private var audioURL: URL?
    /// Frases lidas, com o instante de início, para o highlight e o clique.
    @Published private(set) var segments: [EdgeTTS.Segment] = []
    /// Lista ativa de frases (para a UI clicar por índice).
    @Published private(set) var phrases: [TextImport.Phrase] = []
    /// Chave (texto+voz+cadência) da leitura atual; o áudio mora em disco.
    private var currentKey: String?
    /// Voz da leitura atual (para exportar com a extensão certa e o crédito).
    @Published private(set) var voiceInUse: String = ""
    /// Identidade do documento aberto (URL do arquivo), gravada pela UI.
    /// É o que ancora a posição salva: pausar/parar guarda o `elapsed` sob
    /// (documento+voz); terminar ou descartar a transcrição limpa.
    var documentIDForPosition: String?
    /// Task da síntese em curso, para poder cancelar.
    private var synthTask: Task<Void, Never>?
    /// Geração da síntese: cada `play` novo incrementa; `cancelSynthesis`
    /// invalida. A tarefa guarda a geração do nascimento e só escreve
    /// (streamer, segments, status, isBusy) se ainda for a corrente.
    private var synthGeneration = 0
    /// Chave (texto+voz+cadência) da síntese em voo, para o no-op de `play`
    /// repetido durante a espera da primeira fatia (quando `currentKey`
    /// ainda é o da leitura anterior).
    private var synthKeyInFlight: String?
    /// Frase clicada sem áudio ainda (nada sintetizado ou síntese em curso):
    /// cada fatia que chega tenta o pulo de novo, até conseguir. É o que faz
    /// o clique no PDF/texto "tocar dali" mesmo antes da primeira fatia.
    private var pendingJumpIndex: Int?

    /// Frase em leitura, espelhada do streamer para a UI atualizar.
    ///
    /// Por que espelhar: `currentSegmentText` vive no `StreamingPlayer`, e o
    /// `sink` de `objectWillChange` só republica o controller quando
    /// `isPlaying`/`isPaused`/`status` mudam — o destaque (texto e PDF)
    /// ficaria parado na primeira frase. Aqui cada frase nova republica.
    /// É o que move a UI (texto clicável + PDF por página).
    @Published private(set) var highlightText: String?
    @Published private(set) var highlightIndex: Int = -1
    @Published private(set) var highlightPage: Int?
    /// Palavra em leitura (índice dentro da frase ativa), espelhada do streamer.
    @Published private(set) var highlightWordIndex: Int = -1
    /// Volume de saída, 0…1. Espelha o streamer para a barra estilo IINA.
    @Published var volume: Float = 1.0 {
        didSet { streamer.volume = volume }
    }
    /// Ligação com o streamer, para o estado de reprodução não divergir.
    ///
    /// Por que existe: `isPlaying`/`isPaused` vivem nos DOIS objetos e, antes
    /// desta ligação, só eram copiados em poucos pontos. Quando o `StreamingPlayer`
    /// terminava uma fatia sozinho (fim da fila), o controlador continuava
    /// com `isPlaying = true` — a UI mostrava "Tocando…" e os botões Pausar/Parar
    /// ativos sem haver som. Aqui o streamer é a fonte da verdade.
    private var streamCancellable: AnyCancellable?
    private var highlightCancellables: Set<AnyCancellable> = []

    init() {
        streamCancellable = streamer.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.mirrorStreamerState()
            }
        streamer.$currentSegmentText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if self.highlightText != text { self.highlightText = text }
            }
            .store(in: &highlightCancellables)
        streamer.$currentSegmentIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] index in
                self?.highlightIndex = index
            }
            .store(in: &highlightCancellables)
        streamer.$currentSegmentPage
            .receive(on: RunLoop.main)
            .sink { [weak self] page in
                self?.highlightPage = page
            }
            .store(in: &highlightCancellables)
        streamer.$currentWordIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] index in
                if self?.highlightWordIndex != index { self?.highlightWordIndex = index }
            }
            .store(in: &highlightCancellables)
        // Fim da fila com síntese fechada: a leitura terminou — não há para
        // onde retomar, então esquece a posição (reabrir começa do zero).
        streamer.$isFinished
            .receive(on: RunLoop.main)
            .sink { [weak self] done in
                guard let self, done else { return }
                self.clearSavedPositionOnFinish()
            }
            .store(in: &highlightCancellables)
    }

    private func mirrorStreamerState() {
        let playing = streamer.isPlaying
        let paused = streamer.isPaused
        if isPlaying != playing { isPlaying = playing }
        if isPaused != paused { isPaused = paused }
        // Espera com a fila vazia: diz que está gerando, não "tocando" —
        // o silêncio com status de toque parecia travamento.
        if streamer.isStarved, isBusy {
            mostra("status.generatingNext")
            return
        }
        // O status passa a descrever o que está acontecendo de fato. Sem isto,
        // "Tocando…" sobrevivia ao fim do áudio.
        if !isBusy {
            switch (playing, paused, streamer.isFinished) {
            case (true, _, _): mostra("status.playing")
            case (_, true, _): mostra("status.paused")
            case (false, false, true): mostra("status.finished")
            default: break
            }
        }
    }
    /// Mensagem de falha honesta: o 403 da Microsoft (bloqueio global do
    /// endpoint antigo desde 2026-10-10, verificado) não é instabilidade —
    /// repetir não adianta, e o usuário precisa saber que a saída é a voz
    /// offline.
    nonisolated static func failureMessage(for error: Error, locale: L.Idioma = .pt) -> String {
        let (chave, args) = failureKey(for: error)
        return L.resolve(chave, locale: locale, args: args)
    }

    /// Chave+args da falha, para guardar e re-resolver na troca de idioma.
    nonisolated static func failureKey(for error: Error) -> (String, [Any]) {
        let detail = error.localizedDescription
        if detail.contains("403") {
            return ("status.onlineBlocked", [])
        }
        return ("error.synthesisFailed", [detail])
    }

    /// Sinaliza cancelamento pedido pelo usuário (lido pelas filas de fundo).
    /// Uma instância por geração: o `play` novo cria outra em vez de zerar
    /// a antiga, então a tarefa velha presa num `run` bloqueante continua
    /// lendo `isCancelled == true` e não volta a enfileirar.
    private var cancelFlag = CancelFlag()

    /// Estado de cancelamento legível entre threads.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
        }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        func reset() { lock.lock(); flag = false; lock.unlock() }
    }

    /// Lê a lista ativa de frases (já filtrada ou integral, a escolha é da UI).
    /// - `lêNotas`: com `false`, marcadores de nota viram pausa e corpos
    /// ficam fora da lista (a ContentView filtra); entra na chave do cache,
    /// porque o áudio é outro.
    func play(phrases list: [TextImport.Phrase], voice: String, rate: EdgeTTS.Rate = .normal, lêNotas: Bool = true) {
        let trimmed = list.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !trimmed.isEmpty else {
            mostra("status.noText")
            return
        }
        // Fronteira de parágrafo une com `\n` (respiro na fala; invalida o
        // cache antigo UMA vez, que é o desejado — o texto de cada frase não muda).
        var fullText = ""
        for (idx, ph) in trimmed.enumerated() {
            if idx > 0 { fullText += trimmed[idx - 1].paragraphEnd ? "\n" : " " }
            fullText += ph.text
        }
        let key = CacheDisco.key(text: fullText, voice: voice, rate: rate, lêNotas: lêNotas)
        let sameInput = currentKey == key
        // Só retoma se for a MESMA lista, voz e cadência. Sem esta checagem,
        // carregar outro arquivo durante a pausa e apertar Play tocava a
        // leitura anterior, que não era o esperado.
        if streamer.isPaused, sameInput {
            streamer.resume()
            isPlaying = true
            isPaused = false
            mostra("status.playing")
            return
        }
        // Pausado com a síntese da MESMA leitura ainda em curso (a primeira
        // fatia não chegou ou a fila esvaziou): retoma o que há e o resto
        // engata ao chegar. Antes caía no no-op da síntese em voo e o Play
        // parecia morto (achado da auditoria).
        if streamer.isPaused, isBusy, let inflight = synthKeyInFlight, inflight == key {
            streamer.resume()
            isPlaying = streamer.isPlaying
            isPaused = streamer.isPaused
            if streamer.isPlaying {
                mostra("status.playingWhileSynthesizing")
            } else {
                mostra("status.generatingNext")
            }
            return
        }
        // Já tocando o mesmo conteúdo: nada a fazer.
        if streamer.isPlaying, sameInput, isBusy { return }
        // Síntese em curso da MESMA leitura (primeira fatia ainda não chegou,
        // `currentKey` ainda é o antigo): não iniciar a segunda síntese.
        if isBusy, let inflight = synthKeyInFlight, inflight == key { return }
        // Síntese em curso com outro texto/voz: reinicia.
        if isBusy, !sameInput {
            cancelSynthesis()
        }
        // Replay do áudio já sintetizado: evita refazer a parte lenta (rede).
        if sameInput, hasAudio, let audioURL {
            streamer.restart(audioURL: audioURL, segments: segments)
            voiceInUse = voice
            isPlaying = true
            isPaused = false
            hasAudio = true
            mostra("status.playing")
            return
        }
        // Cache em disco: reabrir o mesmo PDF/voz/cadência toca sem rede.
        if !sameInput, let hit = CacheDisco.lookup(key: key) {
            currentKey = key
            voiceInUse = voice
            phrases = trimmed
            audioURL = hit.audioURL
            segments = hit.segments
            completedChunks = 0
            totalChunks = 0
            streamer.restart(audioURL: hit.audioURL, segments: hit.segments)
            hasAudio = true
            isPlaying = true
            isPaused = false
            mostra("status.playingFromCache")
            return
        }
        // Texto novo (ou voz nova): parar o que estiver tocando e sintetizar.
        streamer.stop()
        PiperTTS.stopActiveSession()
        voiceInUse = voice
        isBusy = true
        isPlaying = false
        isPaused = false
        // Por que o relay: o fluxo é assíncrono e roda fora do main; o relay
        // leva o progresso de volta à main sem estender a vida do controller.
        let relay = StatusRelay()
        relay.controller = self
        // Aviso honesto antes de começar. Medido em português (26k chars,
        // 27 fatias): 1391 chars/s e primeira fatia audível em 4,3 s. Uso
        // 700 como estimativa — rede ruim fica abaixo do medido, e prometer
        // o número ideal faz a espera real parecer travamento.
        let estimate = max(1, Int(Double(fullText.count) / 700.0))
        if fullText.count > 4000 {
            if estimate >= 60 {
                mostra("status.longTextEstimate", fullText.count, estimate / 60)
            } else {
                mostra("status.synthesizingCount", fullText.count, estimate)
            }
        } else {
            mostra("status.synthesizing")
        }
        cancelFlag = CancelFlag()
        synthGeneration += 1
        let gen = synthGeneration
        let flag = cancelFlag
        synthKeyInFlight = key
        synthTask = Task {
            // Voz offline (Piper local) ou online (edge-tts): o mesmo fluxo —
            // a primeira fatia toca em segundos e o áudio único sai no fim.
            // Offline avisa o download na primeira vez (rede só sob demanda).
            let stream: AsyncThrowingStream<EdgeTTS.ChunkDelivery, Error>
            if PiperTTS.isOfflineVoice(voice) {
                stream = PiperTTS.synthesizeStreaming(
                    phrases: trimmed,
                    voice: voice,
                    rate: rate,
                    lêNotas: lêNotas,
                    shouldCancel: { flag.isCancelled },
                    progress: { msg in
                        Task { @MainActor in
                            guard gen == relay.controller?.synthGeneration else { return }
                            relay.controller?.recebeProgresso(msg)
                            if let parsed = Self.parseProgress(msg) {
                                relay.controller?.completedChunks = parsed.done
                                relay.controller?.totalChunks = parsed.total
                            }
                        }
                    }
                )
            } else {
                stream = EdgeTTS.synthesizeStreaming(
                    phrases: trimmed,
                    voice: voice,
                    maxChars: 1800,
                    rate: rate,
                    lêNotas: lêNotas,
                    shouldCancel: { flag.isCancelled },
                    progress: { msg in
                        Task { @MainActor in
                            guard gen == relay.controller?.synthGeneration else { return }
                            relay.controller?.recebeProgresso(msg)
                            // "Sintetizando i/n…" → barra de progresso real.
                            if let parsed = Self.parseProgress(msg) {
                                relay.controller?.completedChunks = parsed.done
                                relay.controller?.totalChunks = parsed.total
                            }
                        }
                    }
                )
            }

            var allSegments: [EdgeTTS.Segment] = []
            var started = false
            var finalResult: EdgeTTS.Result?

            do {
                for try await event in stream {
                    if Task.isCancelled || flag.isCancelled { break }
                    // Geração velha não escreve: confere na main antes do efeito.
                    let stale = await MainActor.run { gen != self.synthGeneration }
                    if stale { break }
                    switch event {
                    case .chunk(_, let url, let chunkSegments):
                        // Os segmentos já trazem índice global + página desde
                        // a primeira fatia: o salto por frase não espera o fim.
                        allSegments.append(contentsOf: chunkSegments)
                        if !started {
                            started = true
                            let wrote = await MainActor.run { () -> Bool in
                                guard gen == self.synthGeneration, !flag.isCancelled else { return false }
                                self.streamer.start(
                                    urls: [url],
                                    chunkSegments: [chunkSegments])
                                self.phrases = trimmed
                                self.segments = allSegments
                                self.hasAudio = true
                                self.isPlaying = true
                                self.isPaused = false
                                self.mostra("status.playingWhileSynthesizing")
                                self.retryPendingJump()
                                return true
                            }
                            if !wrote { break }
                        } else {
                            let wrote = await MainActor.run { () -> Bool in
                                guard gen == self.synthGeneration, !flag.isCancelled else { return false }
                                self.streamer.enqueue(
                                    urls: [url], chunkSegments: [chunkSegments])
                                self.segments = allSegments
                                // Só promete "Tocando…" com som saindo: antes,
                                // esta linha apagava o "Gerando o áudio
                                // seguinte…" do espelho e o silêncio da fila
                                // vazia parecia travamento em vez de espera.
                                if self.streamer.isPlaying {
                                    self.mostra("status.playingWhileSynthesizing")
                                } else if self.streamer.isStarved {
                                    self.mostra("status.generatingNext")
                                }
                                self.retryPendingJump()
                                return true
                            }
                            if !wrote { break }
                        }
                    case .final(let result):
                        finalResult = result
                    }
                }
            } catch {
                if !flag.isCancelled && !Task.isCancelled {
                    await MainActor.run {
                        guard gen == self.synthGeneration else { return }
                        self.isBusy = false
                        self.synthKeyInFlight = nil
                        // Pulo pendente morre com a síntese: sem isto, um
                        // clique anterior disparava sozinho numa leitura futura.
                        self.pendingJumpIndex = nil
                        let (chaveFalha, argsFalha) = SpeechController.failureKey(for: error)
                        self.defineStatus(chave: chaveFalha, args: argsFalha)
                    }
                }
                return
            }

            guard !flag.isCancelled, !Task.isCancelled else { return }
            let staleFinal = await MainActor.run { gen != self.synthGeneration }
            guard !staleFinal else { return }
            if let finalResult {
                await MainActor.run {
                    guard gen == self.synthGeneration, !flag.isCancelled else { return }
                    self.currentKey = key
                    self.audioURL = finalResult.audioURL
                    self.segments = finalResult.segments
                    self.isBusy = false
                    self.synthKeyInFlight = nil
                    self.streamer.markSynthesisComplete()
                    // Síntese fechada e pulo ainda pendente: o índice não
                    // existe na lista — limpar, para não disparar numa
                    // leitura futura com outra lista.
                    self.pendingJumpIndex = nil
                    // Guarda em disco: a próxima abertura igual toca sem rede.
                    // Guarda em disco fora da main: copiar o MP3/WAV final aqui
                    // dentro congelava a UI no fim da síntese (achado da auditoria).
                    let chaveCache = key
                    let audioCache = finalResult.audioURL
                    let segmentosCache = finalResult.segments
                    Task.detached(priority: .utility) {
                        CacheDisco.store(
                            key: chaveCache, audioURL: audioCache,
                            segments: segmentosCache)
                    }
                    if self.streamer.isQueueExhausted {
                        self.isPlaying = false
                        self.isPaused = false
                        self.mostra("status.finished")
                    } else if self.streamer.isPaused {
                        // Não sobrescrever a pausa com "Tocando…".
                        self.isPlaying = false
                        self.isPaused = true
                        self.mostra("status.paused")
                    } else if self.streamer.isPlaying {
                        self.isPlaying = true
                        self.mostra("status.playing")
                    }
                }
            }
        }
    }

    /// Há transcrição a descartar: áudio pronto, síntese em curso ou chave
    /// corrente. É o que habilita o item "Gerar leitura nova" no menu.
    var hasTranscription: Bool { hasAudio || isBusy || currentKey != nil }

    /// Descarta a transcrição corrente para forçar síntese nova no próximo play.
    ///
    /// Por que existe: o `play` reaproveita o áudio quando a chave não muda
    /// (`sameInput`, com retomada de pausa e replay do cache). Sem limpar
    /// `currentKey`/`hasAudio`/segmentos aqui, trocar o modo de texto e
    /// apertar play retomaria a leitura antiga em vez da nova.
    func discardTranscription() {
        let oldKey = currentKey
        let inflight = synthKeyInFlight
        if isBusy { cancelSynthesis() }
        streamer.stop()
        PiperTTS.stopActiveSession()
        // Lista nova, posição velha não vale: sem isto, o próximo play
        // retomaria um ponto da leitura descartada.
        if let doc = documentIDForPosition, !voiceInUse.isEmpty {
            ReadingPositionStore.clear(documentID: doc, voice: voiceInUse)
        }
        hasAudio = false
        audioURL = nil
        segments = []
        phrases = []
        currentKey = nil
        synthKeyInFlight = nil
        pendingJumpIndex = nil
        completedChunks = 0
        totalChunks = 0
        voiceInUse = ""
        highlightText = nil
        highlightIndex = -1
        highlightPage = nil
        highlightWordIndex = -1
        isPlaying = false
        isPaused = false
        if let oldKey { CacheDisco.remove(key: oldKey) }
        if let inflight, inflight != oldKey { CacheDisco.remove(key: inflight) }
        mostra("status.transcriptionDiscarded")
    }

    /// Cancela a síntese em andamento (não afeta áudio já tocando).
    func cancelSynthesis() {
        guard isBusy else { return }
        // Invalida a geração: a tarefa velha, mesmo presa num `run`
        // bloqueante, falha em toda checagem `gen == synthGeneration` e
        // para sem escrever no streamer, no status ou em `isBusy`.
        synthGeneration += 1
        cancelFlag.cancel()
        synthTask?.cancel()
        synthTask = nil
        synthKeyInFlight = nil
        pendingJumpIndex = nil
        isBusy = false
        mostra("common.synthesisCancelled")
        // Os processos edge-tts noticeiros são encerrados pelo timeout/grupo;
        // forçar o encerramento aqui evita esperar o resto das fatias.
        EdgeTTS.killRunningProcesses()
        // O Piper filho morre junto com a leitura: sem processo sobrando.
        PiperTTS.killRunningProcesses()
    }

    /// Tempo já reproduzido e duração conhecida, para a barra de navegação.
    var elapsed: TimeInterval { streamer.elapsed }
    var knownDuration: TimeInterval { streamer.knownDuration }

    /// Salta para um instante. É o que faz a barra arrastável.
    func seek(to time: TimeInterval) { streamer.seek(to: time) }

    /// Avança/recua N segundos, limitado a [0, duração conhecida].
    func skip(_ seconds: TimeInterval) {
        guard controllerHasAudio else { return }
        let target = min(max(0, elapsed + seconds), knownDuration)
        streamer.seek(to: target)
    }

    private var controllerHasAudio: Bool { hasAudio && knownDuration > 0 }

    /// Salta para o início da frase de índice global `index`.
    ///
    /// Funciona DURANTE o streaming: o tocador indexa por índice global
    /// desde a primeira fatia.
    func seek(toSegmentAt index: Int) {
        if !streamer.seek(toSegment: index) {
            mostra("status.waitForSynthesisToJump")
        }
    }

    /// Clique no texto/PDF: pula a leitura para a frase correspondente.
    ///
    /// Quando a frase ainda não tem áudio (nada sintetizado ou síntese em
    /// curso), guarda o índice como pendente em vez de ignorar: cada fatia
    /// que chega tenta o pulo (`retryPendingJump`), então o clique passa a
    /// "tocar dali" assim que o trecho existe. Devolve false enquanto o
    /// áudio não chegou.
    @discardableResult
    func jumpToSegment(_ index: Int) -> Bool {
        guard index >= 0 else { return false }
        if streamer.jumpToSegment(index) {
            pendingJumpIndex = nil
            isPlaying = streamer.isPlaying
            isPaused = streamer.isPaused
            mostra("status.playing")
            return true
        } else {
            pendingJumpIndex = index
            mostra("status.generatingPassage")
            return false
        }
    }

    /// Tenta o pulo pendente contra o áudio que já chegou; limpa quando
    /// consegue. Chamado a cada fatia (início e continuação).
    @discardableResult
    private func retryPendingJump() -> Bool {
        guard let pending = pendingJumpIndex else { return false }
        if streamer.jumpToSegment(pending) {
            pendingJumpIndex = nil
            isPlaying = streamer.isPlaying
            isPaused = streamer.isPaused
            mostra("status.playing")
            return true
        }
        return false
    }

    func pause() {
        guard streamer.isPlaying else { return }
        streamer.pause()
        isPlaying = false
        isPaused = true
        // Relógio continua vivo na pausa: guarda de onde retomar.
        savePositionNow()
        mostra("status.paused")
    }

    func resume() {
        guard streamer.isPaused else { return }
        streamer.resume()
        isPlaying = streamer.isPlaying
        isPaused = streamer.isPaused
        mostra("status.playing")
    }

    func stopPlayback() {
        pendingJumpIndex = nil
        // O `stop` zera o relógio: captura antes, para a retomada saber de onde.
        let pos = streamer.elapsed
        let doc = documentIDForPosition
        let voz = voiceInUse
        streamer.stop()
        // Com síntese em curso, a sessão segue (o cancelamento a encerra);
        // parada sem síntese não deixa processo sobrando.
        if !isBusy { PiperTTS.stopActiveSession() }
        isPlaying = false
        isPaused = false
        if let doc, !voz.isEmpty {
            ReadingPositionStore.save(documentID: doc, voice: voz, position: pos)
        }
        mostra("status.stopped")
    }

    /// Guarda a posição atual sob (documento+voz), para a retomada.
    /// Sem documento (modo só-texto) ou sem voz em uso, não há o que ancorar.
    private func savePositionNow() {
        guard let doc = documentIDForPosition, !voiceInUse.isEmpty else { return }
        ReadingPositionStore.save(documentID: doc, voice: voiceInUse, position: streamer.elapsed)
    }

    /// Leitura concluída: esquece a posição (reabrir começa do zero).
    private func clearSavedPositionOnFinish() {
        guard let doc = documentIDForPosition, !voiceInUse.isEmpty else { return }
        ReadingPositionStore.clear(documentID: doc, voice: voiceInUse)
    }

    /// Extrai "i/n" da mensagem de progresso para alimentar a barra.
    ///
    /// Por que parsear texto e não passar um contador: o motor já produz a
    /// mensagem legível para o usuário; evitar duplicar esse estado aqui.
    nonisolated static func parseProgress(_ message: String) -> (done: Int, total: Int)? {
        guard let range = message.range(of: #"(\d+)/(\d+)"#, options: .regularExpression)
        else { return nil }
        let parts = message[range].split(separator: "/")
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0
        else { return nil }
        return (done, total)
    }

    /// Expõe o status para a UI (ex.: resultado de importação de arquivo).
    ///
    /// Mensagem crua, sem chave: a troca de idioma não a re-resolve. Quem tem
    /// chave no catálogo deve usar `setStatusKey`.
    func setStatus(_ message: String) {
        recebeProgresso(message)
    }

    /// Guarda a chave+args e mostra o texto já resolvido no idioma pedido
    /// (padrão: o atual). É o que a UI chama para mensagens do catálogo.
    func setStatusKey(_ chave: String, args: [Any] = [], locale: L.Idioma? = nil) {
        defineStatus(chave: chave, args: args, locale: locale ?? idiomaAtual)
    }

    /// Re-resolve o status guardado no idioma novo; sem chave guardada
    /// (progresso cru dos motores), mantém a mensagem como está.
    func refreshLocale(_ locale: L.Idioma) {
        guard let chave = statusKey else { return }
        status = L.resolve(chave, locale: locale, args: statusArgs)
    }

    /// Guarda a chave+args e resolve no idioma atual (forma curta interna).
    private func mostra(_ chave: String, _ args: Any...) {
        defineStatus(chave: chave, args: args, locale: idiomaAtual)
    }

    /// Núcleo da guarda: chave+args ficam para a troca de idioma re-resolver.
    private func defineStatus(chave: String, args: [Any], locale: L.Idioma? = nil) {
        statusKey = chave
        statusArgs = args.map { String(describing: $0) }
        status = L.resolve(chave, locale: locale ?? idiomaAtual, args: args)
    }

    /// Progresso vivo dos motores (texto cru, fora do catálogo): limpa a
    /// chave guardada para a troca de idioma não sobrescrever a mensagem atual.
    func recebeProgresso(_ msg: String) {
        statusKey = nil
        statusArgs = []
        status = msg
    }

    /// Limpa o cache em disco preservando a leitura corrente (botão da aba
    /// Avançado, via notificação `.edgeSpeakClearCache`).
    func clearCache() {
        let atual = currentKey
        Task.detached(priority: .utility) {
            let livres = CacheDisco.clearAll(preserving: atual)
            let texto = livres >= 1_048_576
                ? "\(livres / 1_048_576) MB" : "\(max(1, livres / 1_024)) KB"
            await MainActor.run { self.mostra("status.cacheCleared", texto) }
        }
    }

    func exportMP3() {        guard let audioURL else {
            mostra("status.noAudioToExport")
            return
        }
        // Offline gera WAV (PCM concatenado); online, MP3. O arquivo final
        // já está junto — aqui é só salvar com a extensão certa.
        let isWav = audioURL.pathExtension.lowercased() == "wav"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = isWav
            ? L.get("export.defaultWav", locale: idiomaAtual)
            : L.get("export.defaultMp3", locale: idiomaAtual)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard response == .OK, let dest = panel.url else { return }
                do {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                    }
                    try fm.copyItem(at: audioURL, to: dest)
                    self.mostra("status.audioSaved", dest.lastPathComponent)
                } catch {
                    self.mostra("status.exportFailed", error.localizedDescription)
                }
            }
        }
    }
}
