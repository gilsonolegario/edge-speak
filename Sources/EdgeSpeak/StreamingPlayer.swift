import Foundation
import AVFoundation

/// Reproduz as fatias de áudio em sequência, sem esperar o documento inteiro.
///
/// Por que isto existe: com um PDF de 300 páginas a síntese completa leva
/// dezenas de minutos. Tocando cada fatia assim que ela chega, a leitura
/// começa em segundos. As fatias chegam em ordem de índice, então basta
/// encadear `AVAudioPlayer`s: no fim de uma, dispara a próxima.
///
/// As frases são indexadas pelo ÍNDICE GLOBAL desde a primeira fatia (cada
/// segmento já traz `index` + `page`): pular para uma frase funciona DURANTE
/// o streaming. Este é o ÚNICO emissor do destaque (`currentSegmentText`,
/// `currentSegmentIndex`, `currentSegmentPage`).
@MainActor
final class StreamingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isFinished = false

    /// Fila esvaziou antes da síntese terminar: não é fim, é espera.
    ///
    /// Sem isto, as fatias que chegassem depois nunca voltavam a tocar — a
    /// leitura "pausava" sozinha no fim da primeira fatia (~30 s), com as
    /// seguintes já prontas no disco. Com a flag, `enqueue` retoma.
    @Published private(set) var isStarved = false

    /// Tempo já reproduzido, em segundos, somando as fatias anteriores.
    @Published private(set) var elapsed: TimeInterval = 0

    /// Duração total do áudio que já chegou. Cresce enquanto a síntese segue,
    /// então a barra reflete o que existe até agora.
    @Published private(set) var knownDuration: TimeInterval = 0

    /// Frase em leitura (texto, índice global e página), para o destaque.
    @Published private(set) var currentSegmentText: String?
    @Published private(set) var currentSegmentIndex: Int = -1
    @Published private(set) var currentSegmentPage: Int?
    /// Palavra em leitura, como índice DENTRO da frase atual (-1 sem palavra).
    @Published private(set) var currentWordIndex: Int = -1

    /// Volume de saída, 0…1, aplicado ao player atual e aos seguintes.
    ///
    /// Existe para a barra estilo IINA ter controle de volume sem mexer no
    /// volume do sistema. O `AVAudioPlayer` já tem `volume`; aqui só se guarda
    /// o valor e se reaplica a cada fatia.
    @Published var volume: Float = 1.0 {
        didSet { current?.volume = volume }
    }

    private var queue: [URL] = []
    /// Tempos das frases de cada fatia, alinhados por índice com `queue`.
    ///
    /// Os tempos são locais à fatia (cada áudio recomeça em zero); a posição
    /// global é `chunkOffsets[i] + seg.start`. O `index` de cada segmento é
    /// global desde o início, por isso o salto por frase não espera o MP3.
    private var chunkSegments: [[EdgeTTS.Segment]] = []
    private var current: AVAudioPlayer?
    private var highlightTimer: Timer?
    private var pausedAt: TimeInterval = 0
    private var synthesisComplete = false
    private var nextIndex = 0
    /// Duração de cada fatia já tocada ou enfileirada, em ordem. É o que
    /// permite converter "posição global" ↔ "qual fatia e quanto therein".
    private var chunkDurations: [TimeInterval] = []
    /// Início de cada fatia no tempo global (offset acumulado).
    private var chunkOffsets: [TimeInterval] = []
    /// Geração da sessão de reprodução: `stop()` incrementa; o delegate só
    /// age quando a geração corrente ainda é a do player que terminou.
    private var playbackGeneration = 0
    private var currentGeneration = -1
    /// URLs com medição de duração em curso (tarefa de fundo). Evita medir a
    /// mesma fatia duas vezes; `stop()` limpa, e a geração invalida o resto.
    private var pendingProbes: Set<URL> = []

    /// Total de fatias enfileiradas.
    var pendingCount: Int { queue.count }

    /// Índice da fatia em reprodução (para a UI mostrar progresso).
    var currentChunkIndex: Int { nextIndex }

    /// Início de cada fatia no tempo global, para a UI e para testes.
    var chunkStarts: [TimeInterval] { chunkOffsets }

    /// Verdadeiro quando todas as fatias já foram tocadas.
    var isQueueExhausted: Bool { nextIndex >= queue.count }

    /// Inicia a reprodução com a primeira fatia.
    ///
    /// As durações chegam PRONTAS de quem sintetiza (tarefa de fundo, fora da
    /// main); aqui nada mede nem decodifica. Sem durações, dispara-se a
    /// medição em fundo por fatia (fora da main); o `playChunk` segue como
    /// retaguarda, via o próprio player da reprodução.
    func start(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments segments: [[EdgeTTS.Segment]]) {
        stop()
        guard let first = urls.first else { return }
        queue = urls
        chunkSegments = segments
        chunkDurations = Self.resolvedDurations(durations, count: urls.count)
        recomputeOffsets()
        nextIndex = 0
        isFinished = false
        synthesisComplete = false
        playChunk(first)
        probeMissingDurations(startingAt: 0)
    }

    /// Enfileira as fatias que terminaram de ser sintetizadas.
    ///
    /// Idem `start`: a duração vem pronta da tarefa de fundo; sem ela,
    /// mede-se em fundo (fora da main) e o total conhecido cresce na chegada
    /// das fatias, não no início da reprodução. A barra usa o total conhecido
    /// até aqui, sem I/O na main por fatia.
    func enqueue(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments segments: [[EdgeTTS.Segment]]) {
        guard !urls.isEmpty else { return }
        let base = queue.count
        queue.append(contentsOf: urls)
        chunkSegments.append(contentsOf: segments)
        chunkDurations.append(contentsOf: Self.resolvedDurations(durations, count: urls.count))
        recomputeOffsets()
        // Chegou áudio com a fila esvaziada: retoma de onde parou.
        if isStarved, nextIndex < queue.count {
            playChunk(queue[nextIndex])
        }
        probeMissingDurations(startingAt: base)
    }

    /// Normaliza as durações vindas da tarefa de fundo: usa as prontas
    /// quando o tamanho confere; senão, zeros (a medição em fundo preenche
    /// na chegada, e o `playChunk` completa ao tocar, sem I/O na main).
    private static func resolvedDurations(_ durations: [TimeInterval]?, count: Int) -> [TimeInterval] {
        if let durations, durations.count == count { return durations }
        return [TimeInterval](repeating: 0, count: count)
    }

    /// Mede em fundo as fatias sem duração, sem tocar na main.
    ///
    /// Cada sonda escreve SÓ no próprio índice, e só se ele continuar zerado
    /// e com a mesma URL — por isso a ordem das fatias nunca muda e o
    /// `restart` (sonda própria, outra sessão) não é atrapalhado. Fatia com
    /// duração do produtor ou com sonda em curso não é remedida.
    private func probeMissingDurations(startingAt base: Int) {
        let generation = playbackGeneration
        for index in base..<queue.count {
            guard index < chunkDurations.count, chunkDurations[index] == 0 else { continue }
            let url = queue[index]
            guard !pendingProbes.contains(url) else { continue }
            pendingProbes.insert(url)
            Task.detached(priority: .utility) {
                let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
                await MainActor.run {
                    self.finishProbe(url: url, index: index, duration: duration, generation: generation)
                }
            }
        }
    }

    /// Recebe a duração medida em fundo (já na main). Ignora quando a sessão
    /// morreu (`stop`/`restart` trocaram a geração), quando o índice saiu da
    /// fila ou trocou de URL, ou quando a duração já chegou por outra via.
    private func finishProbe(url: URL, index: Int, duration: TimeInterval, generation: Int) {
        guard generation == playbackGeneration else { return }
        guard pendingProbes.contains(url) else { return }
        pendingProbes.remove(url)
        guard index < queue.count, index < chunkDurations.count else { return }
        guard queue[index] == url, chunkDurations[index] == 0 else { return }
        guard duration > 0 else { return }
        chunkDurations[index] = duration
        recomputeOffsets()
    }

    /// Recalcula os inícios globais de cada fatia e a duração conhecida.
    private func recomputeOffsets() {
        chunkOffsets = []
        var acc: TimeInterval = 0
        for d in chunkDurations {
            chunkOffsets.append(acc)
            acc += d
        }
        knownDuration = acc
    }

    /// Posição global atual: deslocamento da fatia em reprodução mais o tempo
    /// dentro dela.
    var currentGlobalTime: TimeInterval {
        guard nextIndex < chunkOffsets.count else {
            return knownDuration
        }
        return chunkOffsets[nextIndex] + (current?.currentTime ?? 0)
    }

    /// Salta para um instante global. Serve tanto para arrastar a barra quanto
    /// para o ±15 s (que grampeia o alvo no conhecido e chama aqui).
    ///
    /// Só é possível ir até onde já existe áudio; pedir tempo além do medido
    /// deixa o player no início do trecho ainda não medido — a PRIMEIRA
    /// fatia sem duração —, sem pular nada. Com durações conhecidas os
    /// inícios são estritos e o recuo abaixo nunca dispara.
    func seek(to globalTime: TimeInterval) {
        guard !queue.isEmpty, !chunkOffsets.isEmpty else { return }
        let target = min(max(0, globalTime), knownDuration)
        var index = 0
        // Busca binária do início da fatia: é quem contém o instante pedido.
        var low = 0
        var high = chunkOffsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if chunkOffsets[mid] <= target { index = mid; low = mid + 1 } else { high = mid - 1 }
        }
        // Recuo à primeira fatia de mesmo início: sem duração medida os
        // offsets se repetem, e parar na última repetida pularia o áudio das
        // anteriores — a variante no trilho do clique que lia outra parte.
        while index > 0, chunkOffsets[index - 1] == chunkOffsets[index] {
            index -= 1
        }
        guard index < queue.count else { return }
        gotoChunk(index, within: target - chunkOffsets[index])
    }

    /// Toca a fatia `chunk` a partir de `within` (tempo local). É o final
    /// comum do `seek(to:)` (tempo global, para a barra) e do
    /// `seek(toSegment:)` (frase, para o clique): os dois usam a mesma
    /// máquina de estados.
    private func gotoChunk(_ chunk: Int, within: TimeInterval) {
        guard chunk < queue.count else { return }
        // `isFinished` conta como "tocar": arrastar para trás depois que o
        // áudio acabou deve voltar a reproduzir, e não ficar parado.
        // `isStarved` também: fila esvaziada com síntese em curso é espera,
        // não pausa — sem isto, o `else` abaixo regravava "pausado" logo após
        // o `playChunk` iniciar o áudio da fatia alvo, e o `play()` seguinte
        // virava no-op (`player.isPlaying` já verdadeiro): a UI mentia.
        let wasPlaying = isPlaying || isPaused || isFinished || isStarved

        if chunk != nextIndex {
            current?.stop()
            current = nil
            nextIndex = chunk
            playChunk(queue[chunk])
        }
        current?.currentTime = min(within, current?.duration ?? within)
        elapsed = (chunk < chunkOffsets.count ? chunkOffsets[chunk] : knownDuration)
            + (current?.currentTime ?? within)
        isFinished = false
        if wasPlaying, current != nil {
            current?.play()
            isPlaying = true
            isPaused = false
        } else {
            isPlaying = false
            isPaused = current != nil
            pausedAt = current?.currentTime ?? 0
        }
        updateHighlight(at: current?.currentTime ?? 0)
    }

    /// Salta para o início da frase de índice global `index`, indo DIRETO à
    /// fatia que a contém — sem passar por tempo global.
    ///
    /// Por que direto: no streaming as durações chegam atrasadas (sonda em
    /// fundo) e `knownDuration`/offsets ficam errados até medirem. O caminho
    /// antigo convertia frase→tempo global com offsets zerados e o `seek(to:)`
    /// grampeava no fim do áudio medido ou caía na fatia errada: o clique lia
    /// OUTRA parte. Aqui a fatia é a que contém a frase e o ponto é
    /// `seg.start` (tempo LOCAL, sempre certo); o destaque usa os mesmos
    /// tempos locais. O relógio exibido (`elapsed`) continua aproximado até
    /// as sondas chegarem — só ele. Devolve false quando a frase ainda não
    /// tem áudio.
    @discardableResult
    func seek(toSegment index: Int) -> Bool {
        for (chunk, segs) in chunkSegments.enumerated() {
            guard chunk < queue.count else { continue }
            if let seg = segs.first(where: { $0.index == index }) {
                gotoChunk(chunk, within: seg.start)
                return true
            }
        }
        return false
    }

    /// Clique no texto: pula para a frase e garante reprodução.
    @discardableResult
    func jumpToSegment(_ index: Int) -> Bool {
        guard seek(toSegment: index) else { return false }
        play()
        return true
    }

    func pause() {
        guard let player = current, player.isPlaying else { return }
        pausedAt = player.currentTime
        player.pause()
        highlightTimer?.invalidate()
        highlightTimer = nil
        isPlaying = false
        isPaused = true
    }

    func resume() {
        guard let player = current, isPaused else { return }
        player.currentTime = pausedAt
        player.play()
        isPlaying = true
        isPaused = false
        installHighlightTimer()
    }

    func stop() {
        playbackGeneration += 1
        currentGeneration = -1
        pendingProbes = []
        current?.stop()
        current = nil
        highlightTimer?.invalidate()
        highlightTimer = nil
        queue = []
        chunkSegments = []
        chunkDurations = []
        chunkOffsets = []
        nextIndex = 0
        elapsed = 0
        knownDuration = 0
        synthesisComplete = false
        isPlaying = false
        isPaused = false
        isFinished = false
        isStarved = false
        currentSegmentText = nil
        currentSegmentIndex = -1
        currentSegmentPage = nil
        currentWordIndex = -1
    }

    /// Recomeça a leitura do MP3 completo já sintetizado (ou vindo do cache).
    ///
    /// Aqui os tempos JÁ são globais (o arquivo é o concatenado), por isso a
    /// lista inteira vale como uma "fatia só" com offset zero.
    func restart(audioURL: URL, segments allSegments: [EdgeTTS.Segment]) {
        stop()
        guard let probe = try? AVAudioPlayer(contentsOf: audioURL) else { return }
        queue = [audioURL]
        chunkSegments = [allSegments]
        chunkDurations = [probe.duration]
        recomputeOffsets()
        nextIndex = 0
        synthesisComplete = true
        playChunk(audioURL)
    }

    /// Inicia a reprodução de onde estiver.
    func play() {
        // Fila esvaziada em espera (`isStarved`): sem `current`, o `guard`
        // abaixo saía sem fazer nada e a leitura nunca retomava pelo botão.
        if current == nil, nextIndex < queue.count {
            playChunk(queue[nextIndex])
            return
        }
        guard let player = current, !player.isPlaying else { return }
        player.play()
        isPlaying = true
        isPaused = false
        isFinished = false
        installHighlightTimer()
    }

    /// Fecha a fila: quando a última fatia terminar, a leitura acabou.
    func markSynthesisComplete() { synthesisComplete = true }

    private func playChunk(_ url: URL) {
        guard nextIndex < queue.count else {
            handleExhausted()
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = volume
            player.prepareToPlay()
            // Completa a duração quando a tarefa de fundo não a entregou: lê
            // do PRÓPRIO player da reprodução, sem I/O nem instância extras.
            if nextIndex < chunkDurations.count, chunkDurations[nextIndex] == 0 {
                chunkDurations[nextIndex] = player.duration
                recomputeOffsets()
            }
            player.play()
            current = player
            currentGeneration = playbackGeneration
            isPlaying = true
            isPaused = false
            isFinished = false
            isStarved = false
            installHighlightTimer()
        } catch {
            // Uma fatia corrompida não pode derrubar a leitura inteira: pula
            // para a PRÓXIMA da fila. Antes, repetia a MESMA url (`playChunk(url)`)
            // e queimava `nextIndex` até o esvaziamento sem marcar `isStarved` —
            // travamento permanente com as fatias seguintes já prontas no disco.
            nextIndex += 1
            if nextIndex < queue.count {
                playChunk(queue[nextIndex])
            } else {
                handleExhausted()
            }
        }
    }

    /// Fila esvaziada: fim só quando a síntese terminou; senão, espera
    /// (`isStarved`) para o `enqueue` retomar quando a próxima fatia chegar.
    private func handleExhausted() {
        isFinished = synthesisComplete
        isPlaying = false
        isStarved = !synthesisComplete
        current = nil
    }

    private func installHighlightTimer() {
        highlightTimer?.invalidate()
        guard !chunkSegments.isEmpty else { return }
        // 10 Hz bastam: a palavra mais curta dura ~300 ms, e cada tique
        // reconstrói o destaque — 20 Hz com texto longo saturava a main.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.current else { return }
                self.updateHighlight(at: player.currentTime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightTimer = timer
    }

    private func updateHighlight(at seconds: Double) {
        elapsed = nextIndex < chunkOffsets.count
            ? chunkOffsets[nextIndex] + seconds
            : knownDuration
        guard nextIndex < chunkSegments.count else { return }
        let local = chunkSegments[nextIndex]
        guard !local.isEmpty else {
            currentSegmentText = nil
            currentSegmentIndex = -1
            currentSegmentPage = nil
            currentWordIndex = -1
            return
        }
        var low = 0
        var high = local.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if local[mid].start <= seconds { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        if found >= 0 {
            // Só republica quando MUDA: sem esta guarda, os 4 publicados
            // abaixo emitiam a cada tique e a vista reconstruía o texto
            // inteiro (45k letras) 10x/s — a main saturava e o destaque
            // parecia parado.
            let seg = local[found]
            let word = wordIndex(in: seg.words, at: seconds)
            if seg.text != currentSegmentText { currentSegmentText = seg.text }
            if seg.index != currentSegmentIndex { currentSegmentIndex = seg.index }
            if seg.page != currentSegmentPage { currentSegmentPage = seg.page }
            if word != currentWordIndex { currentWordIndex = word }
        } else {
            currentSegmentText = nil
            currentSegmentIndex = -1
            currentSegmentPage = nil
            currentWordIndex = -1
        }
    }

    /// Índice da palavra em leitura dentro da frase, por busca binária no
    /// instante local. -1 quando não há palavra (lista vazia ou antes da 1ª).
    private func wordIndex(in words: [EdgeTTS.Segment.Word], at seconds: Double) -> Int {
        guard !words.isEmpty else { return -1 }
        var low = 0
        var high = words.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= seconds { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Delegate tardio (ex.: disparou depois de um `stop()`): só vale o
        // player da sessão corrente; o resto é ignorado, sem mexer na fila.
        guard player === current, currentGeneration == playbackGeneration else { return }
        nextIndex += 1
        guard nextIndex < queue.count else {
            current = nil
            handleExhausted()
            currentSegmentText = nil
            currentSegmentIndex = -1
            currentSegmentPage = nil
            currentWordIndex = -1
            return
        }
        playChunk(queue[nextIndex])
    }
}
