import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import AppKit

struct ContentView: View {
    @StateObject private var controller = SpeechController()

    @State private var text: String = ""
    @State private var pdfDocument: PDFDocument?
    @State private var frases: [TextImport.Phrase] = []
    @State private var frasesFiltradas: [TextImport.Phrase] = []
    @AppStorage(AppSetting.integralKey) private var integralMode: Bool = AppSetting.integralDefault
    @State private var showTextPanel: Bool = false
    @AppStorage(AppSetting.voiceKey) private var voice: String = AppSetting.voiceDefault
    /// Cadência da leitura, escolhida pelo usuário; persiste o `percent: Int`
    /// e vale para a próxima síntese.
    @AppStorage(AppSetting.rateKey) private var ratePercent: Int = AppSetting.rateDefault
    private var rate: EdgeTTS.Rate { EdgeTTS.Rate(percent: ratePercent) }
    @State private var showingImporter = false
    /// Segue a frase lida no PDF; desligar congela a rolagem.
    @AppStorage(AppSetting.followKey) private var followReading: Bool = AppSetting.followDefault
    /// Lê corpos de notas de rodapé (default ligado); desligado, marcadores
    /// viram pausa e corpos saem da lista de leitura.
    @AppStorage(AppSetting.footnoteKey) private var lêNotas: Bool = AppSetting.footnoteDefault
    /// Cada incremento força o PDF a voltar ao trecho lido.
    @State private var revealToken: Int = 0
    /// Geração da carga em curso: a leitura do PDF roda em fundo, e se o
    /// usuário abrir outro arquivo no meio dela o resultado atrasado é
    /// descartado em vez de sobrescrever o documento novo.
    @State private var loadGeneration = 0

    /// Tamanho da fonte do texto, em pontos.
    ///
    /// Persistido porque é uma preferência de leitura: quem precisa de fonte
    /// grande não quer reconfigurar a cada abertura.
    @AppStorage(AppSetting.fontKey) private var fontSize: Double = AppSetting.fontDefault

    /// Idioma da interface (PT padrão); todas as frases abaixo saem do
    /// catálogo `L` neste idioma.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var idioma: L.Idioma { L.Idioma(rawValue: appLanguageRaw) ?? .pt }

    private var textFont: Font { .system(size: fontSize) }

    private func adjustFont(by delta: Double) {
        fontSize = min(
            AppSetting.maxFontSize,
            max(AppSetting.minFontSize, fontSize + delta))
    }

    /// Carrega um arquivo para o leitor (usado pelo botão e pelo arrastar).
    private func load(url: URL) {
        // O stopPlayback sozinho para o áudio mas deixa a tarefa de síntese
        // viva: ela voltaria a enfileirar áudio e frases do documento velho
        // por cima do recém-carregado. Cancela primeiro, para a sessão
        // antiga morrer antes da troca de texto e frases.
        if isReading || controller.isBusy {
            controller.cancelSynthesis()
            controller.stopPlayback()
        }
        // A extração do PDF espera o processo Python com laço de
        // Thread.sleep (até 180 s num arquivo grande): na principal a UI
        // congelava. Roda em fundo com status vivo; o escopo de segurança
        // dura até o fim da leitura, e a geração descarta o resultado
        // atrasado se outro arquivo passar na frente.
        loadGeneration += 1
        let generation = loadGeneration
        let speech = controller
        let loc = idioma
        let scoped = url.startAccessingSecurityScopedResource()
        controller.setStatusKey("status.readingPDF", locale: idioma)
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try TextImport.readDocument(url: url)
                await MainActor.run {
                    guard generation == loadGeneration else { return }
                    text = r.filtrado
                    pdfDocument = r.pdf
                    frases = r.frases
                    frasesFiltradas = r.frasesFiltradas
                    speech.setStatusKey(
                        "status.fileLoaded",
                        args: [url.lastPathComponent, r.filtrado.count],
                        locale: loc)
                }
            } catch {
                await MainActor.run {
                    guard generation == loadGeneration else { return }
                    speech.setStatusKey(
                        "status.openFailed",
                        args: [error.localizedDescription],
                        locale: loc)
                }
            }
        }
    }

    /// Frases da lista ativa (integral ou filtrada; importada ou da sessão).
    private var activePhrases: [TextImport.Phrase] {
        if pdfDocument != nil {
            return integralMode ? frases : frasesFiltradas
        }
        return controller.phrases
    }

    /// Texto da lista ativa, para contagem e estado dos botões.
    private var activeText: String {
        if pdfDocument != nil {
            return activePhrases.map { $0.text }.joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vazio: sem PDF, sem texto e sem leitura — mostra o placeholder.
    private var isEmpty: Bool {
        pdfDocument == nil && activeText.isEmpty && !isReading && !controller.isBusy
    }

    /// Lista a ser lida (PDF: lista ativa; editor: reparte na hora, UMA flag).
    private func playList() -> [TextImport.Phrase] {
        if pdfDocument != nil {
            // Sem notas, os corpos saem; os índices das que ficam NÃO mudam
            // (são propriedade, não posição) — destaque e salto seguem valendo.
            return lêNotas ? activePhrases : activePhrases.filter { $0.notaNumero == nil }
        }
        return TextImport.editorPhrases(text, integral: integralMode)
    }

    private var canPlay: Bool {
        if pdfDocument != nil {
            return !activePhrases.isEmpty && (!isReading || controller.isPaused || controller.isBusy)
        }
        return !activeText.isEmpty && (!isReading || controller.isPaused || controller.isBusy)
    }

    /// Pausado com som pronto: o play retoma em vez de reiniciar.
    private var canPause: Bool { controller.isPlaying && !controller.isPaused }
    /// Verdadeiro enquanto houver áudio em reprodução ou pausado — inclusive
    /// durante a síntese em fluxo, quando já está tocando mas ainda falta áudio.
    private var isReading: Bool { controller.isPlaying || controller.isPaused }

    /// Fração da síntese concluída, para a barra de progresso.
    private var synthesisFraction: Double? {
        guard controller.isBusy, controller.totalChunks > 0 else { return nil }
        return Double(controller.completedChunks) / Double(controller.totalChunks)
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText]
        for ext in ["md", "markdown"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }

    /// Texto exibido + faixas de cada frase (índice global), para o clique.
    private func displayModel() -> (text: String, ranges: [(range: Range<String.Index>, index: Int)]) {
        let list = activePhrases
        var joined = ""
        var ranges: [(range: Range<String.Index>, index: Int)] = []
        for phrase in list {
            if !joined.isEmpty { joined += "\n" }
            let start = joined.endIndex
            joined += phrase.text
            ranges.append((start..<joined.endIndex, phrase.index))
        }
        return (joined, ranges)
    }

    /// Frase atual da lista ativa, pelo índice global que o streamer publica.
    private var currentPhrase: TextImport.Phrase? {
        let target = controller.highlightIndex
        guard target >= 0 else { return nil }
        return activePhrases.first { $0.index == target }
    }

    /// Minúsculas, só letras e dígitos: tira pontuação e hífens para o
    /// casamento palavra falada→caixa no PDF.
    private static func normalizedWord(_ s: String) -> String {
        WordAligner.normalizada(s)
    }

    /// Estado do casamento palavra→caixa: só anda para frente dentro da
    /// frase (ver `WordAligner`). É `@State` para sobreviver aos ciclos de
    /// avaliação da vista — o amarelo não pode recomeçar do zero a cada tique.
    @State private var wordAligner = WordAligner()

    /// Caixa da palavra em leitura no PDF (karaokê geométrico): só com PDF,
    /// só em voz online (o Piper não emite tempos de palavra) e só com a
    /// caixa casada por texto — nunca por índice.
    private var currentWordRect: CGRect? {
        guard pdfDocument != nil,
              !PiperTTS.isOfflineVoice(controller.voiceInUse),
              controller.highlightWordIndex >= 0,
              let phrase = currentPhrase,
              !phrase.words.isEmpty,
              let seg = controller.segments.first(
                  where: { $0.index == controller.highlightIndex }),
              !seg.words.isEmpty,
              controller.highlightWordIndex < seg.words.count
        else { return nil }
        return wordAligner.caixa(
            frase: controller.highlightIndex,
            alvo: controller.highlightWordIndex,
            faladas: seg.words.map(\.text),
            pdf: phrase.words)
    }

    /// O texto com a frase em leitura destacada, e clicável para pular.
    private var clickablePhrases: some View {
        let model = displayModel()
        // Teleprompter: a frase lida vira alvo de rolagem (UTF-16, como o
        // TextKit conta); a palavra continua destacada dentro dela.
        let scroll: NSRange? = {
            guard controller.highlightIndex >= 0,
                  let e = model.ranges.first(where: { $0.index == controller.highlightIndex })
            else { return nil }
            return NSRange(e.range, in: model.text)
        }()
        return ClickableTextView(
            attributed: attributedPhrases(model.text, ranges: model.ranges),
            pointSize: fontSize,
            onTap: { charIndex in
                // O índice vem em UTF-16 (TextKit); converte para a faixa.
                let clamped = min(max(0, charIndex), model.text.utf16.count)
                let idx = String.Index(utf16Offset: clamped, in: model.text)
                for entry in model.ranges
                where entry.range.contains(idx)
                    || (idx == model.text.endIndex && idx == entry.range.upperBound) {
                    clickToPlay(index: entry.index)
                    return
                }
            },
            scrollTo: scroll,
            follow: followReading
        )
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 300, alignment: .leading)
    }

    /// Destaca pelo ÍNDICE global (não por busca de texto): frases repetidas
    /// destacariam a ocorrência errada sem isso. Com karaokê palavra a
    /// palavra no modo online (painel Texto, com ou sem PDF): a frase ativa
    /// leva fundo e a palavra ativa leva negrito + fundo mais forte. Sem
    /// karaokê no offline (o Piper não emite tempos de palavra).
    ///
    /// Durante a leitura o resultado é cacheado por (frase, palavra): a vista
    /// é reavaliada a cada tique do progresso, e reconstruir 45k letras do
    /// zero em cada um saturava a main. Fora da leitura calcula direto.
    @State private var attrKey = ""
    @State private var attrValue = AttributedString("")
    private func attributedPhrases(
        _ full: String, ranges: [(range: Range<String.Index>, index: Int)]
    ) -> AttributedString {
        guard isReading || controller.isBusy else {
            return buildAttributedPhrases(full, ranges: ranges)
        }
        let key = "\(controller.highlightIndex)#\(controller.highlightWordIndex)"
        if key == attrKey { return attrValue }
        let value = buildAttributedPhrases(full, ranges: ranges)
        DispatchQueue.main.async {
            if self.attrKey != key { self.attrKey = key; self.attrValue = value }
        }
        return value
    }

    private func buildAttributedPhrases(
        _ full: String, ranges: [(range: Range<String.Index>, index: Int)]
    ) -> AttributedString {
        var attributed = AttributedString(full)
        // Escopo AppKit de propósito: atributos em escopo SwiftUI
        // (`.backgroundColor`, `.foregroundColor`) NÃO têm par no
        // `NSAttributedString` — o painel os descartava e nada destacava.
        // Sem isto o texto-base saía preto fixo, ilegível no modo escuro.
        attributed[attributed.startIndex..<attributed.endIndex].appKit.foregroundColor = NSColor.labelColor
        let target = controller.highlightIndex
        guard target >= 0 else { return attributed }
        guard let entry = ranges.first(where: { $0.index == target }),
              let range = Range(entry.range, in: attributed)
        else { return attributed }
        // Cor do sistema: acompanha o tema claro/escuro.
        attributed[range].appKit.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.35)
        // Karaokê palavra a palavra no modo online (texto ou PDF: o painel
        // Texto usa os mesmos segmentos do streamer); o Piper não emite
        // tempos de palavra.
        guard !PiperTTS.isOfflineVoice(controller.voiceInUse),
              controller.highlightWordIndex >= 0,
              let seg = controller.segments.first(where: { $0.index == target }),
              !seg.words.isEmpty
        else { return attributed }
        // Alinha palavra→trecho por CASAMENTO DE TEXTO, não por índice: o
        // texto falado expande anos/abreviaturas ("1998" vira várias
        // palavras), e o índice direto caía na palavra errada. Cada palavra
        // é buscada a partir do fim da anterior; a não achada é pulada sem
        // deslocar as seguintes.
        let phraseText = String(full[entry.range])
        var cursor = phraseText.startIndex
        var wordLocal: Range<String.Index>?
        for (i, w) in seg.words.enumerated() {
            guard i <= controller.highlightWordIndex else { break }
            let needle = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty,
                  let found = phraseText.range(
                      of: needle, options: .caseInsensitive,
                      range: cursor..<phraseText.endIndex) else { continue }
            if i == controller.highlightWordIndex { wordLocal = found }
            cursor = found.upperBound
        }
        guard let local = wordLocal else { return attributed }
        // Converte o trecho da frase para a base da string cheia.
        let distLow = phraseText.distance(from: phraseText.startIndex, to: local.lowerBound)
        let distHigh = phraseText.distance(from: phraseText.startIndex, to: local.upperBound)
        let baseLow = full.index(entry.range.lowerBound, offsetBy: distLow)
        let baseHigh = full.index(entry.range.lowerBound, offsetBy: distHigh)
        if let wordRange = Range(baseLow..<baseHigh, in: attributed) {
            attributed[wordRange].appKit.font = NSFont.boldSystemFont(ofSize: fontSize)
            // Palavra em cor própria, distinta da linha: texto branco em
            // negrito sobre fundo de destaque forte — legível nos dois temas
            // e inconfundível com o fundo suave da frase.
            attributed[wordRange].appKit.foregroundColor = NSColor.white
            attributed[wordRange].appKit.backgroundColor =
                NSColor.controlAccentColor.withAlphaComponent(0.65)
        }
        return attributed
    }

    var body: some View {
        // Contêiner de tipo ESTÁVEL (`Container`, nunca trocado) entre a janela e
        // o conteúdo que muda de forma (vazio → editor → PDF → painel). Sem
        // esta âncora, cada troca de conteúdo recria a raiz da vista e a barra
        // de ferramentas se perde na transição — medida: sem PDF a barra
        // aparecia (7 botões na árvore de acessibilidade), abrindo um PDF
        // ela sumia. O tipo do contêiner não muda, então a barra sobrevive.
        Container { textArea }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.top, 16)
            // Reserva a faixa inferior para a barra flutuante não cobrir a
            // última linha do texto.
            .padding(.bottom, isEmpty ? 16 : 74)
            .frame(minWidth: 720, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            // Barra flutuante sobre o conteúdo, como a OSC do IINA. Sempre
            // visível enquanto há conteúdo: sem auto-ocultar, para não
            // atrapalhar o acompanhamento da leitura.
            .overlay(alignment: .bottom) {
                if !isEmpty {
                    PlayerBar(
                        controller: controller,
                        textLength: activeText.count,
                        canPlay: canPlay,
                        onTogglePlay: togglePlay,
                        onTransport: { if pdfDocument != nil { revealToken += 1 } }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
            // Faixa de status transitória: só aparece quando é notícia.
            .overlay(alignment: .top) { statusBanner }
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: Self.importTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    load(url: url)
                case .failure(let error):
                    controller.setStatusKey(
                        "status.openFailed",
                        args: [error.localizedDescription],
                        locale: idioma)
                }
            }
            // Arrastar um arquivo (PDF, markdown, texto) para a janela importa o
            // conteúdo, do mesmo jeito que o botão.
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in load(url: url) }
                }
                return true
            }
            // Duplo-clique no Finder ("Abrir com o EdgeSpeak") e arraste ao ícone
            // chegam pelo AppDelegate; argumento de linha de comando cobre
            // `open --args` e o binário direto.
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakOpenFile)) { note in
                guard let url = note.object as? URL else { return }
                load(url: url)
            }
            .onAppear {
                // Migra voz que deixou de existir no catálogo (só havia a
                // multilingual) e saneia valor órfão guardado: sem catálogo o
                // Picker fica sem item selecionado e a síntese falharia.
                if voice == "pt-BR-ThalitaNeural" {
                    voice = "pt-BR-ThalitaMultilingualNeural"
                } else if !AppSetting.isKnown(voice) {
                    voice = AppSetting.voiceDefault
                }
                // Pré-aquece o ambiente embutido em fundo, sem travar a UI e sem
                // mexer no status: quando o usuário pedir a leitura, o `ensure`
                // já passou (ou roda então, com progresso no status).
                Task.detached(priority: .background) {
                    _ = try? BundledEnv.ensure(progress: { _ in })
                }
                for arg in CommandLine.arguments.dropFirst() {
                    let url = URL(fileURLWithPath: arg)
                    let ext = url.pathExtension.lowercased()
                    if FileManager.default.fileExists(atPath: url.path),
                       ["pdf", "md", "markdown", "txt", "text"].contains(ext) {
                        load(url: url)
                        break
                    }
                }
                installEventMonitors()
            }
            .onDisappear { removeEventMonitors() }
            .onChange(of: controller.status) { _, _ in showStatusBriefly() }
            .onChange(of: controller.isBusy) { _, busy in
                if busy { revealStatus() } else { showStatusBriefly() }
            }
            .onChange(of: integralMode) { _, _ in handleIntegralModeChange() }
            .onChange(of: appLanguageRaw) { _, _ in controller.refreshLocale(idioma) }
    }

    // MARK: - Área de texto

    /// Vazio com affordance: ícone + instrução + ação, sem cara de travado.
    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L.get("ui.emptyPlaceholder", locale: idioma))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingImporter = true
            } label: {
                Label(L.get("ui.openFile", locale: idioma), systemImage: "doc")
            }
            .buttonStyle(.borderedProminent)
            .help(L.get("help.importFile", locale: idioma))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// PDF sempre como visão principal; visão secundária "Texto" (painel) com
    /// o texto clicável que pula pelo índice. Sem PDF: editor (parado) ou
    /// texto clicável (lendo). O texto é somente-leitura durante a leitura:
    /// o destaque é reconstruído a cada frase, e editar nesse meio tornaria
    /// o highlight inconsistente com o áudio já sintetizado.
    private var textArea: some View {
        Group {
            if isEmpty {
                emptyPlaceholder
            } else if let doc = pdfDocument {
                VStack(spacing: 8) {
                    PDFDocumentView(
                        document: doc,
                        page: (isReading || controller.isBusy)
                            ? currentPhrase?.page : nil,
                        rects: (isReading || controller.isBusy)
                            ? (currentPhrase?.rects ?? []) : [],
                        wordRect: (isReading || controller.isBusy)
                            ? currentWordRect : nil,
                        follow: followReading,
                        revealToken: revealToken,
                        onUserScroll: { followReading = false },
                        onPageClick: { page, point in
                            // Clique no PDF toca a partir da frase clicada;
                            // na margem (nil) ignora; sem áudio ainda, começa
                            // a leitura e pula quando a fatia chegar.
                            guard let idx = PhraseLocator.phraseIndex(
                                near: point, on: page, among: activePhrases)
                            else { return }
                            clickToPlay(index: idx)
                        })
                    // A rolagem manual desliga o follow (o PDFDocumentView avisa
                    // via onUserScroll); o botão aparece quando o follow está
                    // desligado, durante a leitura.
                    if isReading && !followReading {
                        HStack {
                            Spacer()
                            Button {
                                revealToken += 1
                                followReading = true
                            } label: {
                                Label(L.get("ui.goToPassage", locale: idioma), systemImage: "location.fill")
                            }
                            .buttonStyle(.link)
                            .font(.footnote)
                        }
                    }
                    DisclosureGroup(L.get("ui.textPanel", locale: idioma), isExpanded: $showTextPanel) {
                        // Fonte e modo de texto vivem no menu de Opções (toolbar).
                        clickablePhrases
                    }
                    .font(.system(size: 12))
                }
            } else if isReading || controller.isBusy {
                clickablePhrases
            } else {
                TextEditor(text: $text)
                    .font(textFont)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(controller.isBusy)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(8)
        // Moldura em vez de fundo solto: separa visualmente o texto das
        // ações e dá um respiro, sem nada de "caixa" pesada.
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    controller.isBusy || isReading
                        ? Color.accentColor.opacity(0.45)
                        : Color.primary.opacity(0.12),
                    lineWidth: 1)
        )
    }

    private func togglePlay() {
        if canPause {
            controller.pause()
        } else {
            controller.play(phrases: playList(), voice: voice, rate: rate, lêNotas: lêNotas)
        }
    }

    /// Clique que toca: pula para a frase clicada; sem áudio nem síntese em
    /// curso, começa a leitura e pula quando a fatia chegar (o controller
    /// guarda o pendente e tenta a cada fatia; vindo do cache, a retentativa
    /// imediata já consegue).
    private func clickToPlay(index: Int) {
        // O token de revelação leva o PDF até o trecho clicado na hora — sem
        // ele o salto só mudava o áudio e a vista ficava parada (o seguimento
        // desligado nunca rola sozinho).
        revealToken += 1
        if controller.jumpToSegment(index) { return }
        guard !controller.hasAudio, !controller.isBusy else { return }
        // Sem áudio nenhum, sintetiza A PARTIR da frase clicada. Com a lista
        // inteira, o tocador já tinha o começo do documento tocando antes de a
        // fatia do trecho clicado existir — era isso que fazia o play começar
        // pelo início em vez do ponto do clique.
        let lista = playList()
        guard let pos = lista.firstIndex(where: { $0.index == index }) else { return }
        controller.play(phrases: Array(lista[pos...]), voice: voice, rate: rate, lêNotas: lêNotas)
        controller.jumpToSegment(index)
    }

    /// Troca de modo (integral/filtrado) descarta a transcrição velha e, se
    /// havia leitura em curso, recomeça com a lista nova pelo mesmo caminho
    /// do botão de play. Sem leitura, só descarta: o próximo play já usa o
    /// modo novo. Não há laço: nem o descarte nem o play mudam `integralMode`.
    private func handleIntegralModeChange() {
        let active = isReading || controller.isBusy
        controller.discardTranscription()
        if active {
            controller.play(phrases: playList(), voice: voice, rate: rate, lêNotas: lêNotas)
        }
    }

    // MARK: - Faixa de status

    @State private var statusVisible = false
    @State private var statusHideWork: DispatchWorkItem?

    private func revealStatus() {
        statusHideWork?.cancel()
        statusHideWork = nil
        if !statusVisible { statusVisible = true }
    }

    /// Mostra a mensagem e some sozinha — exceto durante a síntese, quando a
    /// mensagem é o progresso vivo e não deve piscar.
    private func showStatusBriefly() {
        guard !controller.status.isEmpty else { return }
        if controller.isBusy { revealStatus(); return }
        revealStatus()
        let work = DispatchWorkItem { statusVisible = false }
        statusHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if statusVisible, !controller.status.isEmpty {
            HStack(spacing: 8) {
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(controller.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if controller.segments.isEmpty && controller.hasAudio {
                    Text(L.get("ui.noHighlight", locale: idioma))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if let fraction = synthesisFraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if PiperTTS.isOfflineVoice(controller.voiceInUse) {
                    Text(L.get("ui.offlineVoiceBadge", locale: idioma))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    // MARK: - Barra de ferramentas

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showingImporter = true
            } label: {
                Label(L.get("ui.open", locale: idioma), systemImage: "folder")
            }
            .disabled(controller.isBusy)
            .help(L.get("help.importFile", locale: idioma))
        }
        ToolbarItem(placement: .principal) {
            voicePicker
        }
        ToolbarItem(placement: .primaryAction) {
            optionsMenu
        }
    }

    private var voicePicker: some View {
        Picker(L.get("ui.voiceLabel", locale: idioma), selection: $voice) {
            Section(L.get("section.offline", locale: idioma)) {
                ForEach(PiperTTS.offlineVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option)).tag(option)
                }
            }
            Section(L.get("section.english", locale: idioma)) {
                ForEach(AppSetting.englishVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option)).tag(option)
                }
            }
            Section(L.get("section.portuguese", locale: idioma)) {
                ForEach(AppSetting.portugueseVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option)).tag(option)
                }
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 240)
        .disabled(controller.isBusy)
        .help(L.get("help.readingVoice", locale: idioma))
    }

    /// Só ação do momento: ritmo e modo de texto moram nos Ajustes (⌘,).
    /// O "Seguir leitura" fica aqui e lá, mas nos dois aponta para a MESMA
    /// chave (`AppSetting.followKey`), então nunca diverge.
    private var optionsMenu: some View {
        Menu {
            if pdfDocument != nil {
                Toggle(L.get("ui.followReading", locale: idioma), isOn: $followReading)
                Divider()
            }

            Button {
                adjustFont(by: -2)
            } label: {
                Label(L.get("ui.decreaseFont", locale: idioma), systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(fontSize <= AppSetting.minFontSize)

            Button {
                adjustFont(by: 2)
            } label: {
                Label(L.get("ui.increaseFont", locale: idioma), systemImage: "textformat.size.larger")
            }
            .keyboardShortcut("+", modifiers: .command)
            .keyboardShortcut("=", modifiers: .command)
            .disabled(fontSize >= AppSetting.maxFontSize)

            Button {
                fontSize = AppSetting.fontDefault
            } label: {
                Label(L.get("ui.defaultSize", locale: idioma), systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
            Button {
                controller.discardTranscription()
                controller.play(phrases: playList(), voice: voice, rate: rate, lêNotas: lêNotas)
            } label: {
                Label(L.get("ui.newReading", locale: idioma), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!controller.hasTranscription)
            .help(L.get("help.redoSynthesis", locale: idioma))

            Divider()
            // SettingsLink abre a cena `Settings` do EdgeSpeakApp; é o que
            // compila mais limpo aqui (sem @Environment e sem id de cena).
            SettingsLink {
                Label(L.get("ui.settings", locale: idioma), systemImage: "gear")
            }
        } label: {
            Label(L.get("ui.options", locale: idioma), systemImage: "slider.horizontal.3")
        }
        .help(L.get("help.optionsMenu", locale: idioma))
    }

    // MARK: - Teclado e rato (monitores locais)

    @State private var eventMonitors: [Any?] = []

    /// Monitor local de eventos de teclado.
    ///
    /// O `PDFView` é AppKit e engole os atalhos do SwiftUI: sem o monitor, o
    /// espaço não alternaria play/pausa fora da escrita nem ⌥←/⌥→ pulariam
    /// 15 s com o PDF em foco.
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyDown(event)
        }
        eventMonitors = [keys]
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        eventMonitors = []
    }

    /// Espaço alterna play/pausa fora da escrita e da leitura do PDF; ⌥←/⌥→
    /// pulam 15 s fora da escrita. Fora desses casos o evento segue normal.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window ?? NSApp.keyWindow else { return event }
        let responder = window.firstResponder
        let editingText = responder is NSTextView || responder is NSTextField
        let readingPDF = responder is PDFView
        // Arrow keys chegam com `.numericPad`/`.function`; caps lock deslocaria
        // a comparação. Remove os três antes de exigir `.option` puro.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // Espaço (keyCode 49). No editor o espaço precisa inserir texto; no PDF,
        // rolar — nesses casos o evento passa.
        if event.keyCode == 49, mods.isEmpty {
            if editingText || readingPDF { return event }
            // Durante a síntese o botão de play fica desabilitado: a chave de
            // identidade (`currentKey`) só é gravada no fim, então um play novo
            // seria tratado como "outro texto" e cancelaria e reiniciaria a
            // síntese em curso. Espaço segue a regra do botão e ignora.
            if controller.isBusy { return nil }
            if canPlay || canPause { togglePlay() }
            return nil
        }

        // ⌥← / ⌥→ (keyCode 123 / 124): ±15 s. No editor, ⌥← navega por palavra,
        // então lá o evento passa. Durante a síntese os botões ficam
        // desabilitados; o atalho segue a mesma regra.
        if mods == .option, event.keyCode == 123 || event.keyCode == 124 {
            if editingText { return event }
            guard !controller.isBusy else { return event }
            controller.skip(event.keyCode == 123 ? -15 : 15)
            // Navegação explícita: leva o PDF ao trecho mesmo com o "Seguir
            // leitura" desligado, como o trilho e os botões de ±15 s.
            if pdfDocument != nil { revealToken += 1 }
            return nil
        }

        return event
    }
}

/// Contêiner de tipo fixo, só para dar à janela uma raiz que não muda de
/// identidade quando o conteúdo muda (vazio → editor → PDF → painel).
///
/// Existe por causa da barra de ferramentas: aplicada direto ao conteúdo que
/// troca de forma, ela se perdia na troca (comprovado: sem PDF a barra
/// aparecia, abrindo um PDF sumia). Aqui a raiz é sempre a mesma.
private struct Container<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}
