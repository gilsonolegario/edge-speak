import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import AppKit
// Plano item 57b (S1): `DocumentLanguage` (detecção pura) vive em
// AppSettings.swift e usa `NLLanguage`.
import NaturalLanguage

struct ContentView: View {
    @StateObject private var controller = SpeechController()

    @State private var text: String = ""
    @State private var pdfDocument: PDFDocument?
    /// Stable identity of the open document (file URL): anchors the
    /// saved position. Nil in text-only mode (no file, no resume).
    @State private var currentDocumentID: String?
    @State private var sentences: [TextImport.Phrase] = []
    @State private var filteredSentences: [TextImport.Phrase] = []
    @AppStorage(AppSetting.integralKey) private var integralMode: Bool = AppSetting.integralDefault
    /// Critério 2026-10-18: o painel "Text" é overlay sob demanda (botão na
    /// toolbar); fechado, não cobra nenhuma altura do PDF.
    @State private var showTextPanel: Bool = false
    @AppStorage(AppSetting.voiceKey) private var voice: String = AppSetting.voiceDefault
    /// Reading cadence, chosen by the user; persists the `percent: Int`
    /// and applies to the next synthesis.
    @AppStorage(AppSetting.rateKey) private var ratePercent: Int = AppSetting.rateDefault
    private var rate: EdgeTTS.Rate { EdgeTTS.Rate(percent: ratePercent) }
    @State private var showingImporter = false
    /// Follows the read sentence in the PDF; turning off freezes the scroll.
    @AppStorage(AppSetting.followKey) private var followReading: Bool = AppSetting.followDefault
    /// Honors the Settings switch of the same name. Before, the key was
    /// written by Settings and read nowhere: the resume happened regardless.
    /// Transient follow brake: manual scrolling beats the highlight ONLY
    /// for the moment — any highlight advance releases it and the view
    /// resumes following (before, a scroll turned off the persisted
    /// `followReading` forever and the highlight never crossed the page
    /// again). Not persisted; the Settings switch (`followReading`) still applies.
    @State private var scrollHold = false
    /// Reads footnote bodies (default on); when off, markers
    /// become pauses and bodies leave the reading list.
    @AppStorage(AppSetting.footnoteKey) private var readFootnotes: Bool = AppSetting.footnoteDefault
    /// Resume the saved position when reopening a document already read
    /// (Settings → Reading). Honored here; before, the switch was inert.
    @AppStorage(AppSetting.resumeKey) private var resumeFromLast: Bool = AppSetting.resumeDefault
    /// Each increment forces the PDF back to the read passage.
    @State private var revealToken: Int = 0
    /// Debounce for clicks: timestamp and index of the last click, to ignore
    /// rapid successive clicks on different passages that would thrash the
    /// synthesis (each click cancels the previous run).
    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickIndex: Int = -1
    /// Generation of the ongoing load: the PDF reading runs in the background, and if the
    /// user opens another file midway, the late result is
    /// discarded instead of overwriting the new document.
    @State private var loadGeneration = 0
    /// Plano item 32: «Lendo o PDF…» com prazo visível e cancelável na própria
    /// barra (PdfWords guarda o processo; aqui só o canal com o usuário).
    @State private var importActive = false
    /// Segundos restantes da extração; nil fora do intervalo com prazo vivo.
    @State private var importRemainder: Int?
    /// Plano item 31: retorno do arrasto — a borda acende enquanto o alvo
    /// aceita o drop (o caminho que FUNCIONA durante a síntese).
    @State private var dragTargeted = false

    // MARK: UITests lane 2026-10-17 (itens 26, 36, 40, 42, 57b/S1)

    /// Plano item 36: o registro de recentes acontece no momento da ABERTURA
    /// bem-sucedida (dentro do `load`); a leitura do menu é feita pela cena
    /// (`EdgeSpeakApp`), via a mesma chave.
    /// Plano item 40: consulta que filtra o painel e (com PDF aberto) aciona
    /// o Find do PDFKit; nunca vira destaque de leitura. ⌘F foca o campo da
    /// TOOLBAR por token (`searchFocusToken`), porque `.searchFocused` é
    /// macOS 15+ e o piso do app é 14.
    @State private var searchQuery: String = ""
    /// Plano item 40: cada Enter no campo avança uma ocorrência no PDF.
    @State private var findAdvance = 0
    /// Plano item 40 (revisão 2026-10-18): a contagem do Find vive ao lado
    /// do campo, NA TOOLBAR — não há mais faixa de resultados no conteúdo.
    @State private var findCount: Int? = nil
    /// Token do ⌘F (menu) — cada post foca o campo de busca.
    @State private var searchFocusToken = 0
    /// Plano item 26: página VISÍVEL do PDFView — o cabeçalho mostra a página
    /// que está na TELA quando ninguém lê, e a página do trecho ancorado
    /// durante a leitura (o destaque é a verdade na leitura).
    @State private var visiblePage: Int? = nil
    /// Plano item 42: ir para página — campo pequeno + token de navegação
    /// (token evita re-navegar quando a página não muda).
    @State private var goToPageField: String = ""
    @State private var goToPageTarget: Int = 0
    @State private var goToPageToken = 0

    // MARK: Destaques do usuário (spec §4): estado momentâneo, nunca persistido

    /// Modo destacar (estilo Preview) — `false` ao trocar de documento.
    @State private var highlightMode = false
    /// Registros do PDF aberto; a view os recebe por props e dif por id.
    @State private var userHighlights: [StoredHighlight] = []
    /// Gravador do sidecar do PDF aberto; `nil` em modo texto (sem PDF).
    @State private var highlighter: HighlightSidecarStore?

    private var highlightToggleLabel: String {
        L.get("ui.highlightText", locale: language)
    }
    private var highlightPrompt: String {
        L.get("pdf.highlight.prompt", locale: language)
    }
    private var highlightRemoveLabel: String {
        L.get("pdf.highlight.remove", locale: language)
    }

    /// Stop timer: minutes chosen in the menu (0 = off).
    /// Not persisted — a timer must not survive relaunch.
    @State private var sleepMinutes: Int = 0
    /// Moment when the reading stops; `nil` when the timer is off.
    /// Changes on every choice and fires the countdown (`task id:sleepDeadline`).
    @State private var sleepDeadline: Date?

    /// Text font size, in points.
    ///
    /// Persisted because it is a reading preference: whoever needs a large
    /// font does not want to reconfigure it at every opening.
    @AppStorage(AppSetting.fontKey) private var fontSize: Double = AppSetting.fontDefault

    /// Interface language (EN default); all sentences below come from the
    /// `L` catalog in this language.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var language: L.Language { L.Language(rawValue: appLanguageRaw) ?? .en }

    private var textFont: Font { .system(size: fontSize) }

    /// Plano item 26: título da JANELA — nome do documento aberto, não mais
    /// "EdgeSpeak" eterno. Decodificado pela política pura `DocumentTitle`
    /// (o antigo cabeçalho cortava `absoluteString` cru: "A%20Conting…pdf").
    private var documentName: String {
        DocumentTitle.name(fromDocumentID: currentDocumentID)
    }

    private func adjustFont(by delta: Double) {
        fontSize = min(
            AppSetting.maxFontSize,
            max(AppSetting.minFontSize, fontSize + delta))
    }

    private func load(url: URL) {
        // stopPlayback alone stops the audio but leaves the synthesis task
        // alive: it would enqueue audio and sentences of the old document
        // over the newly loaded one. Cancel first, so the old
        // session dies before the text and sentence swap.
        if isReading || controller.isBusy {
            controller.cancelSynthesis()
            controller.stopPlayback()
        }
        // Plano item 32: troca de arquivo CANDELA a extração anterior — sem
        // isto o Python do PDF velho corria até o próprio prazo (até 180 s)
        // atrás de um texto que ninguém mais vai ler.
        PdfWords.cancelActiveImport()
        // PDF extraction waits for the Python process with a
        // Thread.sleep loop (up to 180 s on a large file): on the main the UI
        // froze. Runs in the background with a live status; the safety scope
        // lasts until the end of the reading, and the generation discards the late
        // result if another file gets ahead.
        loadGeneration += 1
        let generation = loadGeneration
        let speech = controller
        let loc = language
        let scoped = url.startAccessingSecurityScopedResource()
        // Arquivo de texto importa numa fração de segundo: o botão de
        // cancelar seria ruído — só a rota de PDF (extrator com prazo) tem.
        importActive = url.pathExtension.lowercased() == "pdf"
        controller.setStatusKey("status.readingPDF", locale: language)
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try TextImport.readDocument(url: url)
                // Plano item 57b (S1): detecção pura JÁ EXISTENTE (`DocumentLanguage.suggest`,
                // testada em LaneLanguageTests) — roda no MESMO task de fundo e vira aviso de
                // status na volta; nada aqui inventa detecção nova.
                let langSuggestion = DocumentLanguage.suggest(for: r.filtered)
                // Sidecar dos destaques: hash + leitura no MESMO task de fundo
                // (hash de 5–20 MB custa dezenas de ms, uma vez por abertura —
                // spec §1); a poda de órfãos avalia por aqui, sem bloquear nada.
                let sidecar: (fingerprint: DocumentFingerprint?, records: [StoredHighlight]) = {
                    guard let pdf = r.pdf else { return (nil, []) }
                    guard let fingerprint = HighlightDiskStore.fingerprint(for: url)
                    else { return (nil, []) }
                    let records = HighlightDiskStore.read(
                        directory: HighlightDiskStore.defaultDirectory,
                        key: fingerprint.contentSHA256,
                        pageCount: pdf.pageCount)
                    HighlightDiskStore.sweepOrphans(
                        directory: HighlightDiskStore.defaultDirectory,
                        excluding: fingerprint.contentSHA256,
                        now: Date())
                    return (fingerprint, records)
                }()
                await MainActor.run {
                    guard generation == loadGeneration else { return }
                    text = r.filtered
                    pdfDocument = r.pdf
                    sentences = r.sentences
                    filteredSentences = r.filteredSentences
                    // Anchors the saved position to the file (applies to PDF and text:
                    // the identity is the URL, not the type). Only here, on success —
                    // the stop above saved the previous document's position.
                    currentDocumentID = url.absoluteString
                    // Plano item 36: registro do recente NO MOMENTO da abertura
                    // bem-sucedida (a única definição para "aberto").
                    RecentDocumentsPolicy.record(url)
                    speech.documentIDForPosition = url.absoluteString
                    // Troca de documento: flush do sidecar anterior, modo
                    // destacar desligado, repaint a partir do sidecar novo.
                    highlighter?.flushNow()
                    highlightMode = false
                    if let fingerprint = sidecar.fingerprint {
                        userHighlights = sidecar.records
                        highlighter = HighlightSidecarStore(
                            fingerprint: fingerprint,
                            records: sidecar.records,
                            directory: HighlightDiskStore.defaultDirectory)
                    } else {
                        userHighlights = []
                        highlighter = nil
                    }
                    // Texto trocado: invalida o cache de atributos (M3).
                    attrGeneration += 1
                    speech.setStatusKey(
                        "status.fileLoaded",
                        args: [url.lastPathComponent, r.filtered.count],
                        locale: loc)
                    // Plano item 57b (S1): aviso de idioma no MESMO canal de
                    // status — quando há voz compatível DIFERENTE da escolhida,
                    // ela é oferecida; idioma sem voz nenhuma também avisa.
                    switch LanguageNotice.decide(
                        suggestion: langSuggestion,
                        currentVoice: voice,
                        languageNameFor: { LanguageNotice.languageName(for: $0, locale: loc) })
                    {
                    case .compatible(let idioma, let opcao):
                        speech.setStatusKey(
                            "status.docLanguage",
                            args: [idioma, AppSetting.label(for: opcao, locale: loc)],
                            locale: loc)
                    case .noVoice(let idioma):
                        speech.setStatusKey(
                            "status.docLanguageNoVoice", args: [idioma], locale: loc)
                    case .none:
                        break
                    }                    // Plano item 42: o índice e o campo de página pertencem ao
                    // documento novo (o campo antigo não sobrevive à troca).
                    goToPageField = ""
                    visiblePage = nil
                    searchQuery = ""
                    findAdvance = 0
                    // Plano item 23: abrir PDF/texto REBUILDA a janela — o foco
                    // que o VoiceOver guardava cai em elemento mudo. O
                    // `.layoutChanged` re-narra a área nova; Política/efeito em
                    // `AccessibilityAnnouncements` (mesma struct do item 18).
                    AccessibilityAnnouncements.postLayoutChanged()
                    importActive = false
                }
            } catch {
                await MainActor.run {
                    guard generation == loadGeneration else { return }
                    // Plano item 24: a causa sai pelo failureKey (chave do
                    // catálogo, re-resolvível na troca de idioma) — nunca o
                    // `localizedDescription` em inglês dentro de frase em
                    // português.
                    let (key, args) = SpeechController.failureKey(for: error)
                    speech.setStatusKey(key, args: args, locale: loc)
                    importActive = false
                }
            }
        }
    }

    /// Plano item 32: botão «Cancelar importação» na barra de status. Mata o
    /// processo da extração (`PdfWords.cancelActiveImport` — SIGKILL + reap
    /// dentro do próprio loop, dono do PID), descarta o resultado pendente e
    /// recolhe a opção no mesmo estado.
    private func requestCancelImport() {
        PdfWords.cancelActiveImport()
        loadGeneration += 1
        importActive = false
        controller.setStatusKey("status.importCancelled", locale: language)
        showStatusBriefly()
    }

    /// Plano item 1: colar no ESTADO VAZIO (⌘V) — a promessa da primeira tela
    /// («ou cole um texto») não tinha nenhum caminho para `text`, além de
    /// abrir arquivo; aqui o texto entra e o convite ao Enter sai junto.
    private func pasteIntoEmptyEditor() {
        guard let pasted = EmptyStatePaste.usable(from: NSPasteboard.general) else {
            controller.setStatusKey("status.pasteEmpty", locale: language)
            return
        }
        acceptPaste(pasted)
    }

    /// Plano item 1: texto ARRASTADO de outro app para o estado vazio. Por
    /// cima do que já está aberto, NUNCA — o editor já aberto pertence ao
    /// que o usuário estava digitando.
    private func dropTextIntoEmptyState(_ raw: String) {
        guard isEmpty else { return }
        guard let pasted = EmptyStatePaste.usable(raw) else { return }
        acceptPaste(pasted)
    }

    private func acceptPaste(_ pasted: String) {
        text = pasted
        controller.setStatusKey("status.textPasted", args: [pasted.count], locale: language)
    }

    /// Plano item 24: falha de abertura pelo `failureKey` — a causa sai como
    /// chave do catálogo, re-resolvível na troca de idioma (nunca mais o
    /// «Falha ao abrir: The PDF has no text layer; nothing to read.» com
    /// inglês embutido em frase em português). Cancelar o painel não é falha.
    private func openImporterFailed(_ error: Error) {
        guard !FeedbackPolicy.isUserCancelled(error) else { return }
        let (key, args) = SpeechController.failureKey(for: error)
        controller.setStatusKey(key, args: args, locale: language)
    }

    private var activePhrases: [TextImport.Phrase] {
        if pdfDocument != nil {
            return integralMode ? sentences : filteredSentences
        }
        return controller.phrases
    }

    /// Text of the active list, for counting and button state.
    private var activeText: String {
        if pdfDocument != nil {
            return visiblePhrases.map { $0.text }.joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEmpty: Bool {
        pdfDocument == nil && activeText.isEmpty && !isReading && !controller.isBusy
    }

    /// What the panel shows and what the reading plays: ONE list.
    ///
    /// Why: with `readFootnotes` off, the note body left `playList()` but not
    /// the panel, so the click reached `clickToPlay`, found no index in the
    /// filtered list and returned without sound, error or warning — a click
    /// that promised a reading and delivered silence. Same predicate in both
    /// places ends the divergence by construction. Indices of the remaining
    /// phrases do NOT change (they are property, not position), so highlight
    /// and jump still hold.
    private var visiblePhrases: [TextImport.Phrase] {
        if pdfDocument != nil {
            return readFootnotes ? activePhrases : activePhrases.filter { $0.noteNumber == nil }
        }
        return controller.phrases
    }

    private func playList() -> [TextImport.Phrase] {
        if pdfDocument != nil { return visiblePhrases }
        return TextImport.editorPhrases(text, integral: integralMode)
    }

    private var canPlay: Bool {
        if pdfDocument != nil {
            return !activePhrases.isEmpty && (!isReading || controller.isPaused || controller.isBusy)
        }
        return !activeText.isEmpty && (!isReading || controller.isPaused || controller.isBusy)
    }

    /// Paused with ready audio: play resumes instead of restarting.
    private var canPause: Bool { controller.isPlaying && !controller.isPaused }

    /// Nothing playing and nothing to resume: the first slice of a synthesis
    /// already running has not arrived. Mirrors the play button's rule
    /// (PlayerBar) so space and the button never disagree.
    private var playWouldDoNothing: Bool {
        controller.isBusy && !controller.isPlaying && !controller.isPaused
    }

    /// True while there is audio playing or paused — including
    /// during streaming synthesis, when it is already playing but audio is still missing.
    private var isReading: Bool { controller.isPlaying || controller.isPaused }

    /// Fraction of the synthesis completed, for the progress bar.
    private var synthesisFraction: Double? {
        guard controller.isBusy, controller.totalChunks > 0 else { return nil }
        return Double(controller.completedChunks) / Double(controller.totalChunks)
    }

    /// 2026-10-18 ("seja criativo"): fração da fila de leitura já percorrida
    /// (posição da frase que a voz está lendo). Nil = parado ou sem lista.
    private var readingFraction: Double? {
        let target = controller.highlightIndex
        guard isReading, target >= 0 else { return nil }
        let list = playList()
        guard let pos = list.firstIndex(where: { $0.index == target }) else { return nil }
        return Double(pos + 1) / Double(list.count)
    }

    /// O fio de progresso no topo do conteúdo: leitura em curso mostra a
    /// posição da frase; sem leitura mas sintetizando, as fatias prontas —
    /// parado, nada (o topo do PDF fica limpo).
    @ViewBuilder private var readingHairline: some View {
        if let fraction = readingFraction ?? synthesisFraction {
            GeometryReader { geo in
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.45)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(2, geo.size.width * fraction), height: 2.5)
                .animation(.linear(duration: 0.35), value: fraction)
            }
            .frame(height: 2.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Plano item 40: lista EXIBIDA no painel — com a consulta de busca, o
    /// painel mostra só as frases que batem (a lista de LEITURA nunca muda:
    /// a busca não reinicia síntese nem vira destaque; os índices globais das
    /// frases são propriedade, e o clique continua pulando para a frase).
    private var displayPhrases: [TextImport.Phrase] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            ? activePhrases
            : SearchPolicy.filter(activePhrases, by: query)
    }

    private func displayModel() -> (text: String, ranges: [(range: Range<String.Index>, index: Int)]) {
        let list = displayPhrases
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

    private var currentPhrase: TextImport.Phrase? {
        let target = controller.highlightIndex
        guard target >= 0 else { return nil }
        return activePhrases.first { $0.index == target }
    }

    /// Position of the summary anchor inside `playList()`: the sentence being
    /// read, or the last one read when the reading is stopped (`highlightIndex`
    /// survives the stop, so ⌘⇧M after stop still summarizes where the reader
    /// left off). Nil before the first play and after the document is discarded
    /// — the caller then falls back to the first sentence, the only anchor
    /// available when no sentence has been reached yet.
    private var summaryPosition: Int? {
        let target = controller.highlightIndex
        guard target >= 0 else { return nil }
        let list = playList()
        guard !list.isEmpty else { return nil }
        if let exact = list.firstIndex(where: { $0.index == target }) { return exact }
        // Not in this list: a note body filtered out by "read footnotes", or a
        // mode that changed after the reading. Nearest sentence at or after the
        // position, else the last one — never back to the start.
        return list.firstIndex(where: { $0.index > target }) ?? list.count - 1
    }

    /// Sentence that anchors the PDF highlight. While a footnote body is read
    /// (`noteNumber != nil`), the PDF stays on the running text that announced
    /// it instead of jumping to the footer and back — the jump scrolled the
    /// view away and the following sentence looked late. The panel keeps
    /// highlighting the body itself (it sits right after the marker in list
    /// order), so the note is still announced and read, only the PDF anchor holds.
    private var pdfAnchorPhrase: TextImport.Phrase? {
        guard let cur = currentPhrase else { return nil }
        guard cur.noteNumber != nil else { return cur }
        let list = activePhrases
        guard let pos = list.firstIndex(where: { $0.index == cur.index }) else { return cur }
        for i in stride(from: pos - 1, through: 0, by: -1) {
            if list[i].noteNumber == nil { return list[i] }
        }
        return cur
    }

    /// Lowercase, letters and digits only: strips punctuation and hyphens for the
    /// spoken-word→box match in the PDF.
    private static func normalizedWord(_ s: String) -> String {
        WordAligner.normalized(s)
    }

    /// State of the word→box match: only moves forward within the
    /// sentence (see `WordAligner`). It is `@State` to survive the view's
    /// evaluation cycles — the yellow cannot restart from scratch on every tick.
    @State private var wordAligner = WordAligner()

    /// Box of the word being read in the PDF (geometric karaoke) WITH the page
    /// that owns it: only with PDF and only with the box matched by text —
    /// never by index. Works for both online (edge-tts timings) and offline
    /// (Piper estimated timings).
    ///
    /// The page travels with the box. A sentence that crosses a page break
    /// keeps the page where it starts, while its continuation words are boxes
    /// of the NEXT page (measured on Neutrality_v82: 11 sentences, 628 words,
    /// all at y=705 of the following page). The yellow annotation was added to
    /// the sentence's page, so those words were painted at the bottom of the
    /// previous one — on top of unrelated words, and only there.
    private var currentWordBox: (page: Int?, rect: CGRect)? {
        guard pdfDocument != nil,
              controller.highlightWordIndex >= 0,
              let phrase = currentPhrase,
              phrase.noteNumber == nil,
              !phrase.words.isEmpty,
              let seg = controller.segment(forIndex: controller.highlightIndex),
              !seg.words.isEmpty,
              controller.highlightWordIndex < seg.words.count
        else { return nil }
        guard let box = wordAligner.boxEntry(
            sentence: controller.highlightIndex,
            generation: attrGeneration,
            target: controller.highlightWordIndex,
            spokenWords: seg.words.map(\.text),
            pdf: phrase.words)
        else { return nil }
        return (page: box.page, rect: box.rect)
    }

    /// Just the rectangle, for the callers that only need the geometry.
    private var currentWordRect: CGRect? { currentWordBox?.rect }

    private var clickablePhrases: some View {
        let model = displayModel()
        // Teleprompter: the read sentence becomes the scroll target (UTF-16, as
        // TextKit counts); the word stays highlighted within it.
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
                // The index comes in UTF-16 (TextKit); converts to the range.
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
            follow: followReading,
            controller: controller,
            sentenceContext: {
                let i = controller.highlightIndex
                guard i >= 0,
                      let e = model.ranges.first(where: { $0.index == i }) else { return nil }
                return (model.text, e.range)
            },
            // Plano item 20: ações customizadas (VoiceOver) do painel usam o
            // MESMO jump por frase dos botões da barra e do ⌥↑/⌥↓.
            language: language,
            onSentenceJump: jumpToNeighboringSentence
        )
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 300, alignment: .leading)
    }

    /// Highlights by GLOBAL INDEX (not by text search): repeated sentences
    /// would highlight the wrong occurrence without it. The active sentence
    /// gets a background here (blue path, works); the active WORD is painted
    /// directly by the coordinator (direct drive, zero SwiftUI rebuilds per
    /// word). No karaoke offline (Piper emits no word times).
    ///
    /// During reading the result is cached by sentence: word ticks reuse the
    /// cached value and never rebuild.
    @State private var attrKey = ""
    @State private var attrValue = AttributedString("")
    /// Identity of the displayed text (document + full/filtered mode). Enters
    /// the attribute-cache key: without it, switching files or modes with the
    /// SAME (sentence, word) pair returned the previous text's `AttributedString`
    /// (wrong text / highlight on the wrong ranges — finding M3).
    @State private var attrGeneration = 0
    /// Sentence-level base (full text + base color + sentence background, no
    /// word): rebuilt only when the SENTENCE changes. Word ticks copy it and
    /// set one range — rebuilding 45k letters per word saturated the main
    /// thread and the yellow lagged the voice (independent review).
    @State private var attrBaseKey = ""
    @State private var attrBase = AttributedString("")
    private func attributedPhrases(
        _ full: String, ranges: [(range: Range<String.Index>, index: Int)]
    ) -> AttributedString {
        guard isReading || controller.isBusy else {
            return buildAttributedPhrases(full, ranges: ranges)
        }
        let key = "\(attrGeneration)#\(controller.highlightIndex)"
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
        let target = controller.highlightIndex
        // Sentence base memoized: full rebuild only when the sentence (or the
        // document) changes; word ticks copy the base and set one range.
        let sentenceKey = "\(attrGeneration)#\(target)"
        let base: AttributedString
        if sentenceKey == attrBaseKey, !attrBase.characters.isEmpty {
            base = attrBase
        } else {
            var fresh = AttributedString(full)
            // AppKit scope on purpose: attributes in SwiftUI scope
            // (`.backgroundColor`, `.foregroundColor`) have no counterpart in
            // `NSAttributedString` — the panel discarded them and nothing highlighted.
            // Without this the base text came out fixed black, illegible in dark mode.
            fresh[fresh.startIndex..<fresh.endIndex].appKit.foregroundColor = NSColor.labelColor
            if target >= 0,
               let entry = ranges.first(where: { $0.index == target }),
               let range = Range(entry.range, in: fresh) {
                // System color: follows the light/dark theme.
                fresh[range].appKit.backgroundColor =
                    NSColor.controlAccentColor.withAlphaComponent(0.35)
            }
            // Deferred like attrKey/attrValue: never mutate state during body.
            let stored = fresh
            DispatchQueue.main.async {
                if self.attrBaseKey != sentenceKey {
                    self.attrBaseKey = sentenceKey
                    self.attrBase = stored
                }
            }
            base = fresh
        }
        return base
    }

    var body: some View {
        // FIXED-type container (`Container`, never swapped) between the window and
        // the content that changes shape (empty → editor → PDF → panel). Without
        // this anchor, every content change recreates the view root and the toolbar
        // is lost in the transition — measured: without PDF the bar
        // appeared (7 buttons in the accessibility tree), opening a PDF
        // it vanished. The container type does not change, so the bar survives.
        // Plano itens 26/40 (título + campo de busca): no modifier
        // `FindSurface` — inline aqui o body estourava o orçamento do
        // type-checker AGAIN (mesmo sintoma que criou `ExternalActions`).
        Container { textArea }
            .modifier(FindSurface(
                title: documentName,
                subtitle: windowSubtitle))
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.top, 16)
        // Reserves the bottom band so the floating bar does not cover the
        // last line of the text.
        // Plano item 30: os números moram em PlayerBarMetrics — a barra e
        // este padding mudam juntos ou não mudam.
        .padding(.bottom, isEmpty ? 16 : PlayerBarMetrics.reserve)
            .frame(minWidth: 720, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            // Reports the hosting NSWindow for the space bar (see
            // `hostWindow`): zero interaction, observation only.
            .background { WindowProbe(box: hostWindow) }
            // Floating bar over the content, like IINA's OSC. Always
            // visible while there is content: no auto-hide, so as not to
            // hinder following the reading.
            .overlay(alignment: .bottom) {
                if !isEmpty {
                    PlayerBar(
                        controller: controller,
                        textLength: activeText.count,
                        canPlay: canPlay,
                        canNavigateSentences: controller.canSkip,
                        onTogglePlay: togglePlay,
                        onTransport: { if pdfDocument != nil { revealToken += 1 } },
                        onSentenceStep: jumpToNeighboringSentence
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, PlayerBarMetrics.gap)
                }
            }
            .overlay(alignment: .top) { statusBanner }
            // 2026-10-18 ("seja criativo"): o FIO DA LEITURA — 2,5 pt no
            // topo do conteúdo com o avanço da voz (frase atual na fila;
            // durante a síntese, fatias prontas); some quando parado, custo
            // de layout zero (overlay).
            .overlay(alignment: .top) { readingHairline }
            // Critério 2026-10-18: o painel "Text" (antes uma faixa fixa de
            // ~54 pt no conteúdo, e VAZIA fora da leitura) agora abre sob
            // demanda, flutuando acima da PlayerBar.
            .overlay(alignment: .bottom) {
                if showTextPanel, pdfDocument != nil {
                    textPanelOverlay
                }
            }
            .toolbar { toolbarContent }
            // Planos 1, 24 e 31: painel de arquivo + drop + falha de abertura
            // moram no modifier `ImportChannels` abaixo — inline, o body
            // estoura o orçamento do type-checker (padrão já usado por
            // `ExternalActions` e `WaveTwoFeedback`).
            .modifier(ImportChannels(
                showingImporter: $showingImporter,
                dragTargeted: $dragTargeted,
                onFile: { load(url: $0) },
                onOpenFailed: { openImporterFailed($0) },
                onDroppedText: { dropTextIntoEmptyState($0) }))
            // Double-click in Finder ("Open with EdgeSpeak") and drag onto the icon
            // arrive via the AppDelegate; command-line argument covers
            // `open --args` and the direct binary.
            // Plano item 2: o "Open… ⌘O" do menu posta o MESMO canal com
            // object nil — aqui isso significa "abrir o painel de arquivo".
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakOpenFile)) { note in
                guard let url = note.object as? URL else {
                    showingImporter = true
                    return
                }
                load(url: url)
            }
            // Media keys and the ⌘⇧M summary live in the `ExternalActions`
            // modifier below, NOT inline: with these two handlers in this chain
            // the body blew the type checker's budget ("unable to type-check
            // this expression in reasonable time", measured at line ~538).
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakClearCache)) { _ in
                controller.clearCache()
            }
            // The subscriptions that come from outside the window (menu, media
            // keys, cache) live in one modifier: inline, the chain pushed the
            // body past the type-checker's budget (measured).
            .modifier(ExternalActions(
                togglePlay: requestTogglePlay,
                stopReading: requestStop,
                summarize: requestSummary,
                toggleHighlight: toggleHighlightFromMenu,
                openFind: { searchFocusToken += 1 },
                showingSummary: $showingSummary,
                summaryText: summaryText,
                language: language))
            .onAppear {
                // Migrates a voice that stopped existing in the catalog (only the
                // multilingual existed) and sanitizes an orphaned stored value: without a catalog the
                // Picker has no selected item and synthesis would fail.
                if voice == "pt-BR-ThalitaNeural" {
                    voice = "pt-BR-ThalitaMultilingualNeural"
                } else if !AppSetting.isKnown(voice) {
                    voice = AppSetting.voiceDefault
                }
                // Pre-warms the bundled environment in the background, without freezing the UI and
                // without touching the status: when the user asks for the reading, `ensure`
                // has already run (or it runs then, with progress in the status).
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
            .onDisappear {
                removeEventMonitors()
                // Cancel synthesis when the window closes: otherwise the
                // Task keeps running in the background consuming CPU/network
                // after the user thinks the app is done.
                controller.cancelSynthesis()
                // Fechamento: flush imediato do sidecar (spec §2).
                highlighter?.flushNow()
            }
            .onChange(of: controller.status) { _, _ in showStatusBriefly() }
            .onChange(of: controller.isBusy) { _, busy in
                if busy { revealStatus() } else { showStatusBriefly() }
            }
            .onChange(of: integralMode) { _, _ in handleIntegralModeChange() }
            .onChange(of: isDropTarget) { _, dragging in
                if dragging { revealStatus() } else { showStatusBriefly() }
            }
            // Displayed text identity changed (document or text mode): the
            // per-sentence word→box cache key repeats across documents, so drop
            // it here or the PDF yellow reuses the old document's boxes.
            .onChange(of: attrGeneration) { _, _ in wordAligner.invalidate() }
            // Any advance of the highlight releases the transitory brake and the view
            // resumes following.
            .onChange(of: controller.highlightIndex) { _, _ in scrollHold = false }
            .onChange(of: appLanguageRaw) { _, _ in controller.refreshLocale(language) }
            // Plano item 15 (reinício direto na troca de voz) e plano item 32
            // (contador do prazo de extração) vivem no modifier
            // `WaveTwoFeedback` abaixo — inline aqui, o body estoura o
            // orçamento do type-checker (como já aconteceu antes; ver
            // `ExternalActions`).
            .modifier(WaveTwoFeedback(
                controller: controller,
                voice: $voice,
                importActive: $importActive,
                importRemainder: $importRemainder,
                loadGeneration: loadGeneration,
                language: language,
                showingSummary: $showingSummary,
                refocusToolbar: { toolbarAnchor = .openFile },
                restartReading: { new in restartReadingFromCurrentPoint(usingVoice: new) }))
            // Choice in the timer menu: 0 turns it off (deadline nil); N arms the
            // deadline in N minutes. The firing lives in the `task(id:)` below.
            .onChange(of: sleepMinutes) { _, newValue in
                if newValue > 0 {
                    sleepDeadline = Date().addingTimeInterval(Double(newValue) * 60)
                    controller.setStatusKey("status.sleepSet", args: [newValue], locale: language)
                } else {
                    sleepDeadline = nil
                    // Plano item 33: a escolha volta a ficar VISÍVEL — desligar
                    // manda recado, o estado não vira surpresa na hora da parada.
                    controller.setStatusKey("status.sleepOff", locale: language)
                }
            }
            // Cancelable countdown: the `id` restarts the task on each new deadline
            // and cancels the previous one, with no Timer and no reference leak. When the
            // deadline arrives, it stops the reading and resets the menu.
            // Body extracted: the modifier chain is already at the compiler's
            // type-check limit (adding the navigation title overflowed it).
            .task(id: sleepDeadline) { await runSleepCountdown() }
    }

    /// Sleep countdown: waits out the remaining time, then stops the reading.
    /// A new deadline restarts it via `task(id:)`, which cancels the prior run —
    /// hence the `isCancelled`/identity guard after the await.
    private func runSleepCountdown() async {
        guard let target = sleepDeadline else { return }
        let remaining = target.timeIntervalSinceNow
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        guard !Task.isCancelled, sleepDeadline == target else { return }
        sleepDeadline = nil
        sleepMinutes = 0
        controller.stopPlayback()
    }

    @State private var isDropTarget = false

    // MARK: - Text area

    /// Empty with affordance: icon + instruction + action, not looking stuck.
    private var emptyPlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                // Plano item 22: a imagem é decorativa — falava ANTES da
                // instrução real (a voz do VoiceOver repetia "waveform.circle"
                // antes do convite). Padrão já usado na PlayerBar.
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(L.get("ui.emptyPlaceholder", locale: language))
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(L.get("ui.emptyPlaceholderHint", locale: language))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showingImporter = true
            } label: {
                Label(L.get("ui.openFile", locale: language), systemImage: "doc")
            }
            .buttonStyle(.borderedProminent)
            .help(L.get("help.importFile", locale: language))
            .accessibilityLabel(Text(L.get("ui.openFile", locale: language)))
            .accessibilityHint(Text(L.get("help.importFile", locale: language)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// PDF always as the main view; secondary "Text" view (panel) with
    /// the clickable text that jumps by index. No PDF: editor (still) or
    /// clickable text (reading). The text is read-only during reading:
    /// the highlight is rebuilt on every sentence, and editing midway would make
    /// the highlight inconsistent with the already-synthesized audio.
    ///
    /// Critério 2026-10-18 (a área do PDF é a prioridade): a página do PDF
    /// NÃO mora num cartão (era cartão-dentro-de-cartão com o padding da
    /// janela) e o painel "Text" deixou de ser faixa fixa — vira overlay
    /// sob demanda (botão na toolbar), como a PlayerBar.
    private var textArea: some View {
        Group {
            if isEmpty {
                emptyPlaceholder
            } else if let doc = pdfDocument {
                pdfArea(doc)
            } else if isReading || controller.isBusy {
                clickablePhrases
                    .modifier(TextCard(dragging: dragTargeted, active: controller.isBusy))
            } else {
                TextEditor(text: $text)
                    .font(textFont)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(controller.isBusy)
                    // Plano item 22: o editor não anunciava o que é — label +
                    // hint no catálogo bilíngue, como os outros controles.
                    .accessibilityLabel(Text(L.get("ui.editor.label", locale: language)))
                    .accessibilityHint(Text(L.get("ui.editor.hint", locale: language)))
                    .modifier(TextCard(dragging: dragTargeted, active: controller.isBusy || isReading))
            }
        }
    }

    /// O miolo do PDF num `func` próprio: inline no `body`, a chamada de
    /// `PDFDocumentView` media estourar o orçamento do type-checker.
    private func pdfArea(_ doc: PDFDocument) -> some View {
        VStack(spacing: 6) {
            PDFDocumentView(
                document: doc,
                page: (isReading || controller.isBusy)
                    ? pdfAnchorPhrase?.page : nil,
                rects: (isReading || controller.isBusy)
                    ? (pdfAnchorPhrase?.rects ?? []) : [],
                wordRect: (isReading || controller.isBusy)
                    ? currentWordBox?.rect : nil,
                wordPage: (isReading || controller.isBusy)
                    ? currentWordBox?.page : nil,
                follow: followReading,
                scrollHold: scrollHold,
                revealToken: revealToken,
                onUserScroll: { scrollHold = true },
                highlightMode: highlightMode,
                userHighlights: userHighlights,
                onHighlightAdded: { record in
                    // Persistência AVANÇA aqui; a anotação já foi
                    // desenhada pela casa (Coordinator).
                    highlighter?.add(record)
                    userHighlights.append(record)
                },
                onHighlightRemoved: { record in
                    highlighter?.remove(record.id)
                    userHighlights.removeAll { $0.id == record.id }
                },
                removeHighlightLabel: highlightRemoveLabel,
                onPageClick: { page, point in
                    guard let idx = PhraseLocator.phraseIndex(
                        near: point, on: page, among: activePhrases)
                    else {
                        // Plano item 35: clique perdido já não caía
                        // em silêncio total — recado curto de status.
                        controller.setStatusKey(
                            "status.clickOutsidePhrase", locale: language)
                        return
                    }
                    clickToPlay(index: idx)
                },
                onVisiblePageChange: { visiblePage = $0 },
                goToPage: goToPageTarget,
                goToPageToken: goToPageToken,
                findQuery: searchQuery,
                findAdvance: findAdvance,
                onFindCount: reportFindCount
            )
            // Manual scroll sets the transient brake (PDFDocumentView reports
            // via onUserScroll); the button appears with the master on
            // + brake, during the reading, and releases the brake by jumping
            // to the passage. One link line, and only while the brake exists.
            if (isReading || controller.isBusy) && followReading && scrollHold {
                HStack {
                    Spacer()
                    Button {
                        scrollHold = false
                        revealToken += 1
                    } label: {
                        Label(L.get("ui.goToPassage", locale: language), systemImage: "location.fill")
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Painel "Text" sob demanda (mesmo conteúdo que tinha faixa fixa).
    /// Sobe acima da PlayerBar e não cobra altura do PDF quando fechado.
    private var textPanelOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L.get("ui.textPanel", locale: language))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    showTextPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L.get("ui.textPanel", locale: language))
                .accessibilityLabel(Text(L.get("ui.textPanel", locale: language)))
            }
            clickablePhrases
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, PlayerBarMetrics.reserve)
        .frame(maxHeight: 300)
    }

    private func togglePlay() {
        if canPause {
            controller.pause()
            return
        }
        // (Re)starting the reading resumes following: without this, an old
        // shutdown (manual scroll, which persists) froze the view forever
        // and the highlight never crossed the page. Scrolling manually turns it
        // off again at the moment — the "Go to passage" button still works.
        followReading = true
        // Internal pause resume: the audio is already where it stopped — no seek.
        let wasPaused = controller.isPaused
        controller.play(phrases: playList(), voice: voice, rate: rate, readFootnotes: readFootnotes)
        guard !wasPaused else { return }
        resumeSavedPositionIfCovered()
    }

    /// Automatic resume: reopening and pressing play returns where it stopped, ONLY when the
    /// measured audio already covers the point — else it starts from scratch. The status says from
    /// where, reusing the bar's time format (no duplicated logic).
    /// Honors the Settings switch: with it off, the reading always starts
    /// from the beginning (the saved position stays stored, it is only not
    /// used). Before the fix the switch was an advertised control with no
    /// effect: it wrote a key nobody read and the resume was unconditional.
    /// The absent-key default is `AppSetting.resumeDefault` (true) — treating a
    /// missing key as "do not resume" would silently turn it off for everyone
    /// who never opened this tab.
    private func resumeSavedPositionIfCovered() {
        guard resumeFromLast else { return }
        guard let doc = currentDocumentID else { return }
        let saved = ReadingPositionStore.load(documentID: doc, voice: voice)
        guard ReadingPositionStore.shouldResume(saved: saved, knownDuration: controller.knownDuration),
              let ponto = saved else { return }
        controller.seek(to: ponto)
        controller.setStatusKey(
            "status.resumedFrom",
            args: [PlayerBar.formatTime(ponto)],
            locale: language)
    }

    /// Plano item 20: jump for neighbor phrase using the SAME click path
    /// (`clickToPlay`): PDF reveal, follow re-enabled, `jumpToSegment` and the
    /// pending-jump work are already there. Window shared by bar buttons,
    /// the panel's custom actions (VoiceOver) and ⌥↑/⌥↓ — one policy, one path.
    ///
    /// The neighbor lives in the PLAY list (`playList()`, which honors the
    /// footnote filter): jumping inside the audio list, not the display list.
    private func jumpToNeighboringSentence(_ direction: Int) {
        let indices = playList().map(\.index)
        guard let target = SentenceNeighborPolicy.target(
            from: indices, current: controller.highlightIndex, direction: direction)
        else { return }
        clickToPlay(index: target)
    }

    // MARK: - Navegação no PDF (itens 26/42) e busca (item 40) — lane 2026-10-17

    /// Item 26 (recolocado 2026-10-18): o informativo ANTES no cabeçalho do
    /// PDF (título • página • voz • modo destacar) agora é o SUBTÍTULO da
    /// janela — a barra de título não consome a área do PDF. Durante a
    /// leitura segue o trecho ancorado; sem leitura, a página VISÍVEL
    /// reportada pelo PDFView (o último relato fica quando a rolagem
    /// silencia). Sem documento, o subtítulo é vazio.
    private var windowSubtitle: String {
        guard pdfDocument != nil else { return "" }
        let anchor = (isReading || controller.isBusy) ? pdfAnchorPhrase?.page : nil
        let shown = (anchor ?? (visiblePage ?? 0)) + 1
        return DocumentHeaderInfo.subtitle(
            pageText: L.get("pdf.header.page", locale: language, args: shown),
            voiceText: AppSetting.label(for: voice, locale: language),
            // Modo destacar (spec §4): segmento novo no informativo existente.
            highlight: (highlightMode && !highlightPrompt.isEmpty) ? highlightPrompt : nil)
    }

    /// Plano item 42: índice do PDF aberto; vazio quando o arquivo não tem
    /// outline (a linha de navegação nem aparece). Re-montado por render:
    /// outlines reais têm poucas centenas de entradas e o caminho é barato.
    private var pageOutlineEntries: [OutlineListing.Entry] {
        guard let doc = pdfDocument else { return [] }
        return OutlineListing.entries(in: doc)
    }

    /// Plano item 42: "ir para página" — sanidade pura (`PageJump`), feedback
    /// fora da faixa pelo canal de status, navegação por token.
    private func submitPageJump(document: PDFDocument) {
        guard let target = PageJump.sanitize(
            goToPageField, pageCount: PageJump.pageCount(of: document))
        else {
            controller.setStatusKey("status.pageOutOfRange", locale: language)
            revealStatus()
            return
        }
        goToPageTarget = target
        goToPageToken += 1
    }

    private func goToOutline(_ entry: OutlineListing.Entry) {
        guard let page = entry.page else { return }
        goToPageField = ""
        goToPageTarget = page
        goToPageToken += 1
    }

    /// Plano S2: o botão/menu ⌘⇧H alterna o modo destacar; sem PDF não há o
    /// que destacar (o item de menu nem existe sem documento na cena —
    /// aqui a guarda é a mesma do Toggle do Options).
    private func toggleHighlightFromMenu() {
        guard pdfDocument != nil else { return }
        highlightMode.toggle()
    }

    /// Plano item 40 (revisão 2026-10-18): a contagem do Find mora na
    /// TOOLBAR, ao lado do campo — nada de faixa nem de cápsula flutuante
    /// cobrindo o topo do PDF. O texto completo continua no catálogo
    /// (aparece no `help`/`accessibilityLabel` do número).
    private func reportFindCount(_ count: Int) {
        findCount = count
    }

    private func findCountHelp(_ count: Int) -> String {
        count == 0
            ? L.get("status.findNoMatches", locale: language)
            : L.get("status.findMatches", locale: language, args: count)
    }

    /// Click that plays: jumps to the clicked sentence; when no audio covers the
    /// point, it (re)synthesizes FROM the clicked sentence — including while
    /// another synthesis is running, which gets canceled.
    ///
    /// Why the run in flight does not get to veto: the list handed to `play` is the
    /// suffix from the clicked sentence, so its key differs from the one in flight
    /// and `play` cancels the old run on its own (`!sameInput`). Waiting instead for
    /// the in-order synthesis to arrive at the click meant minutes of silence on a
    /// long text — exactly what made the click ahead look dead. The audio already
    /// synthesized dies with the canceled run (the disk cache only exists for a
    /// complete run), which is the price of reading from where the reader pointed.
    private func clickToPlay(index: Int) {
        // Debounce: rapid clicks on different passages (within 250 ms) thrash
        // the synthesis — each cancels the previous run. Keep the first, ignore
        // the rest. Clicking the SAME passage is always allowed (it's a no-op
        // when already covered, or re-applies the pending jump).
        let now = Date()
        if index != lastClickIndex,
           now.timeIntervalSince(lastClickTime) < 0.25 {
            return
        }
        lastClickTime = now
        lastClickIndex = index

        // The reveal token brings the PDF to the clicked passage at once — without
        // it the jump only changed the audio and the view stayed still (follow
        // off never scrolls by itself). It also re-enables following, for the
        // same reason as togglePlay.
        revealToken += 1
        scrollHold = false
        followReading = true
        if controller.jumpToSegment(index) { return }        // No `hasAudio` here on purpose: it stays true after Stop (the queue
        // empties but the flag does not drop — audit 2026-10-13) and would block play
        // forever, with no audio, no process and no error. Whoever covers the index
        // already returned via `jumpToSegment`; the rest needs synthesis, and the
        // suffix list is what makes `play` drop the run in flight.
        let list = playList()
        guard let position = list.firstIndex(where: { $0.index == index }) else { return }
        controller.play(phrases: Array(list[position...]), voice: voice, rate: rate, readFootnotes: readFootnotes)
        controller.jumpToSegment(index)
    }

    /// 2026-10-18 (dono: «seleciono a nova leitura ou novo agente de leitura
    /// … anular a leitura anterior e começar com ela»; «está cortando a
    /// leitura… e deveria ser direta»): troca de voz e «Gerar leitura nova»
    /// com leitura em curso refazem a leitura DA FRASE ATUAL — o mesmo
    /// caminho do clique numa frase (`clickToPlay`), e o run em voo cai
    /// sozinho (`decidePlay` → `cancelAndRestart`). A posição sai de
    /// `ReadingRestartPolicy`; sem lista, nada acontece.
    private func restartReadingFromCurrentPoint(usingVoice newVoice: String? = nil) {
        let list = playList()
        guard !list.isEmpty else { return }
        let offset = ReadingRestartPolicy.offset(
            highlightIndex: controller.highlightIndex,
            indices: list.map(\.index))
        controller.play(
            phrases: Array(list[offset...]),
            voice: newVoice ?? voice,
            rate: rate,
            readFootnotes: readFootnotes)
    }

    /// Mode switch (integral/filtered) discards the old transcription and, if
    /// a reading was in progress, restarts with the new list via the same path
    /// as the play button. Without a reading, it only discards: the next play already uses the
    /// new mode. There is no loop: neither the discard nor the play changes `integralMode`.
    private func handleIntegralModeChange() {
        let active = isReading || controller.isBusy
        // Active list changes (full↔filtered): invalidates the attribute cache
        // before playing, so the highlight does not land on the old mode's text.
        attrGeneration += 1
        controller.discardTranscription()
        if active {
            controller.play(phrases: playList(), voice: voice, rate: rate, readFootnotes: readFootnotes)
        }
    }

    // MARK: - Accessibility focus

/// Where the focus goes after the document changes (item 23 of the plan).
    ///
    /// `@AccessibilityFocusState` was absent, so after loading a PDF or
    /// dismissing the summary the focus fell on an element that is silent or
    /// undefined. The named target is the toolbar's Open button: it is
    /// guaranteed to exist, is never disabled right after a load, and announces
    /// the action the user most likely wants next.
    @AccessibilityFocusState private var focusOnOpenButton: Bool

    /// Moves the accessibility focus to the toolbar's Open button.
    ///
    /// Moving the focus IS the announcement here: VoiceOver speaks whatever
    /// element received it, so the user hears both the button and the fact that
    /// the screen changed. A `layoutChanged` post would be the belt to this
    /// pair of braces, but `AccessibilityNotification` in this SDK exposes only
    /// `Announcement` (probed against the Xcode 26 interface), and the AppKit
    /// spelling needs an element reference this helper does not have.
    private func moveAccessibilityFocusToOpen() {
        focusOnOpenButton = true
    }

    // MARK: - Status band

    @State private var statusVisible = false
    @State private var statusHideWork: DispatchWorkItem?

    private func revealStatus() {
        statusHideWork?.cancel()
        statusHideWork = nil
        if !statusVisible { statusVisible = true }
    }

    /// Shows the message and vanishes by itself — except during synthesis, when the
    /// message is the live progress and must not flicker. Plano item 18: FAILURE
    /// messages do not dismiss themselves — they persist while the failure
    /// breathes (the previous 4 s left the user without any message); the next
    /// non-failure status (progress, playing, cleared) naturally dismisses it.
    private func showStatusBriefly() {
        guard !controller.status.isEmpty else { return }
        revealStatus()
        // Plano item 18: failure stays until another status replaces it.
        guard !controller.statusIsFailure else { return }
        let work = DispatchWorkItem { statusVisible = false }
        statusHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Dismisses a persistent failure banner on click/tap.
    private func dismissStatus() {
        statusHideWork?.cancel()
        statusHideWork = nil
        statusVisible = false
    }

    /// Posts a VoiceOver announcement for the messages a screen-reader user
    /// cannot afford to miss.
    ///
    /// Uses SwiftUI's `AccessibilityNotification` (macOS 14+, the app's floor).
    /// The AppKit route (`NSAccessibility.post` with an announcement userInfo)
    /// does not expose the announcement key in this SDK — probed against
    /// Xcode 26 headers, which is why this is not the documented-in-headers
    /// AppKit call.
    ///
    /// Called ONLY on terminal events (a failure here) and never on a progress
    /// tick: announcing every 10 Hz update would bury the user in speech.
    private func announceToVoiceOver(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
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
                    // Plano item 18: falha merece ser LIDA — até 3 linhas
                    // enquanto o banner fica permanente (antes truncava em 1
                    // e sumia em 4 s). Selecionável: a causa sai copiável.
                    .lineLimit(controller.statusIsFailure ? 3 : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(controller.status))

                // Plano item 32: prazo VISÍVEL da importação em curso.
                if importActive, let seconds = importRemainder {
                    Text(L.get("ui.importRemaining", locale: language, args: seconds))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if controller.segments.isEmpty && controller.hasAudio {
                    Text(L.get("ui.noHighlight", locale: language))
                        .font(.caption)
                        // Plano item 25: .tertiary fica no limite/abaixo de
                        // 4,5:1 em legenda informativa; .secondary dá contraste
                        // nos dois modos (mesma régua desta barra).
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let fraction = synthesisFraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                // Plano item 32: cancelar a importação (o processo morre —
                // PdfWords.cancelActiveImport) direto de onde se espera.
                if importActive {
                    Button(L.get("ui.cancelImport", locale: language)) {
                        requestCancelImport()
                    }
                    .font(.caption)
                    .help(L.get("ui.cancelImport", locale: language))
                }

                // Plano item 15: o selo segue a voz ESCOLHIDA (a compartilha
                // com o próximo Play), não a «em uso» da síntese passada.
                if PiperTTS.isOfflineVoice(voice) {
                    Text(L.get("ui.offlineVoiceBadge", locale: language))
                        .font(.caption)
                        // Plano item 25: contraste (ver .noHighlight acima).
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            // A failure stays until dismissed; a transient message still
            // auto-hides, and a tap on it costs nothing.
            .contentShape(Capsule())
            .onTapGesture(perform: dismissStatus)
            // VoiceOver reads the banner as one unit, and a persistent failure
            // must say it is dismissible — the 4 s auto-hide it replaced was
            // the reason the message was missed.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(controller.statusIsFailure ? [.isStaticText] : [])
            .accessibilityHint(controller.statusIsFailure
                              ? Text(L.get("a11y.dismissStatusHint", locale: language))
                              : Text(""))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showingImporter = true
            } label: {
                Label(L.get("ui.open", locale: language), systemImage: "folder")
            }
            // Plano item 16: destravado durante a síntese — o `load` cancela
            // a leitura em curso sozinho; travarAbrir deixava o usuário
            // esperando minutos atrás de um arquivo novo.
            .help(L.get("help.importFile", locale: language))
            // Plano item 23: alvo do foco pós-sheet — o estado acima guarda a
            // âncora; o `.accessibilityFocused` liga o enum ao botão.
            .accessibilityFocused($toolbarAnchor, equals: ToolbarAnchor.openFile)
        }
        // 2026-10-18 (dono: "como os apps do Mac fazem"; verificado em
        // Finder/Mail/Preview): a voz é um popup de ajuste e anda com os
        // demais controles, ancorada à DIREITA — nada de `.principal` no
        // centro, que era o que deixava a fila parando no meio da barra.
        ToolbarItem(placement: .primaryAction) {
            voicePicker
        }
        // Critério 2026-10-18 (área do PDF é a prioridade): o Find (item 40)
        // mora na TOOLBAR — campo no mesmo `$searchQuery` do painel; Enter
        // avança a ocorrência do PDF. ⌘F chega por token e foca este campo.
        // Nenhum vazio permanente dentro do conteúdo.
        // 2026-10-18 — fecho do dono ("reordenar e reposicionar" + "como os
        // apps do Mac fazem" + "search and pdf page podem estar juntos"):
        // a barra segue o padrão do Finder/Mail — tudo que age no documento
        // ancora à DIREITA e, no fim, lado a lado, o par PÁGINA + BUSCA (a
        // busca no canto, como Finder/Mail). Sem item `.principal`: a fila
        // flutuava no meio da barra.
        // Critério 2026-10-18: o painel "Text" virou botão (overlay sob
        // demanda) — fechado, o PDF fica com a altura inteira.
        if pdfDocument != nil {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showTextPanel) {
                    Label(L.get("ui.textPanel", locale: language), systemImage: "text.alignleft")
                }
                .toggleStyle(.button)
                .help(L.get("ui.textPanelHint", locale: language))
                .accessibilityLabel(Text(L.get("ui.textPanel", locale: language)))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            optionsMenu
        }
        // Plano item 42: ir-para-página + índice na toolbar (não na coluna
        // do conteúdo); aparecem só com documento que os justifique e, na
        // versão do dono (2026-10-18), andam JUNTO da busca no canto.
        if let doc = pdfDocument,
           !pageOutlineEntries.isEmpty || PageJump.pageCount(of: doc) > 1 {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    // 2026-10-18 ("seja criativo"): o campo mostra a página
                    // VIVA ("22/33") como prompt — medidor e alvo no mesmo
                    // lugar; ao digitar, o prompt dá lugar ao número.
                    TextField(
                        L.get("ui.pageFieldPrompt", locale: language),
                        text: $goToPageField,
                        prompt: Text(verbatim: "\((visiblePage ?? 0) + 1)/\(PageJump.pageCount(of: doc))")
                            .monospacedDigit()
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .controlSize(.small)
                        .onSubmit { submitPageJump(document: doc) }
                    if !pageOutlineEntries.isEmpty {
                        Menu {
                            ForEach(pageOutlineEntries) { entry in
                                Button(entry.title) { goToOutline(entry) }
                            }
                        } label: {
                            Label(L.get("ui.outline", locale: language), systemImage: "list.bullet")
                        }
                        .controlSize(.small)
                        .accessibilityLabel(Text(L.get("ui.outline", locale: language)))
                    }
                }
            }
        }
        // Critério 2026-10-18 (área do PDF é a prioridade): o Find (item 40)
        // mora na TOOLBAR e é o ÚLTIMO item — busca no canto direito, como
        // Finder/Mail; campo no mesmo `$searchQuery` do painel, Enter avança
        // a ocorrência do PDF, ⌘F chega por token e foca este campo.
        // Nenhum vazio permanente dentro do conteúdo.
        if pdfDocument != nil {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    PDFFindBar(
                        query: $searchQuery,
                        focusToken: searchFocusToken,
                        onSubmitFind: { findAdvance += 1 },
                        language: language)
                    // A contagem anda JUNTO do campo (um só item de toolbar —
                    // sem vão invisível quando não há contagem), com o texto
                    // completo da frase no `help`.
                    if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty,
                       let findCount {
                        Text(findCount == 0 ? "0" : "\(findCount)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help(findCountHelp(findCount))
                            .accessibilityLabel(Text(findCountHelp(findCount)))
                    }
                }
            }
        }
    }

    /// Plano item 29: as três seções do picker vivem em `VoicePicker` (um
    /// lugar só, usado aqui e nos Ajustes); os ADEREÇOS de toolbar (largura,
    /// altura, dica) continuam aqui.
    private var voicePicker: some View {
        // 2026-10-18 ("seja criativo"): o alto-falante antes do popup diz de
        // imediato que este é o controle da VOZ; o picker segue um só
        // (VoicePicker), sem tocar na fonte compartilhada com os Ajustes.
        HStack(spacing: 5) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VoicePicker(voice: $voice, language: language)
        }
        // 2026-10-18 (dono, revisão da barra): a troca de voz AGORA vale na
        // hora — cancela e refaz da frase atual —, então o picker fica vivo
        // também durante a síntese. `.controlSize(.small)` alinha o popup
        // (27 px) à altura dos campos Page/busca (17 px), medida da analista.
        .controlSize(.small)
        .frame(maxWidth: 240)
        .help(L.get("help.voiceNextSynthesis", locale: language))
    }

    /// Only the moment's actions: cadence and text mode live in Settings (⌘,)
    /// "Follow reading" is here and there, but in both it points to the SAME
    /// key (`AppSetting.followKey`), so it never diverges.
    private var optionsMenu: some View {
        Menu {
            // Without `if pdfDocument`: in text-only mode the teleprompter also
            // scrolls by itself and the user needs to turn it off (found in the audit).
            Toggle(L.get("ui.followReading", locale: language), isOn: $followReading)
            // Modo destacar (⌘⇧H vem junto da fase de menus, no app frame):
            // momentâneo, sem PDF é inócuo — desabilitado, nunca ausente,
            // para a posição do menu não pular.
            Toggle(L.get("ui.highlightText", locale: language), isOn: $highlightMode)
                .disabled(pdfDocument == nil)
            Divider()
            // Exportar cópia com destaques (spec §5): nunca toca o PDF original;
            // as efêmeras de leitura saem antes do burn-in.
            Button {
                exportHighlightsCopy()
            } label: {
                Label(
                    L.get("pdf.highlight.export", locale: language),
                    systemImage: "square.and.arrow.up.on.square.fill")
            }
            .disabled(pdfDocument == nil)

            Divider()

            Button {
                adjustFont(by: -2)
            } label: {
                Label(L.get("ui.decreaseFont", locale: language), systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(fontSize <= AppSetting.minFontSize)

            Button {
                adjustFont(by: 2)
            } label: {
                Label(L.get("ui.increaseFont", locale: language), systemImage: "textformat.size.larger")
            }
            .keyboardShortcut("+", modifiers: .command)
            .keyboardShortcut("=", modifiers: .command)
            .disabled(fontSize >= AppSetting.maxFontSize)

            Button {
                fontSize = AppSetting.fontDefault
            } label: {
                Label(L.get("ui.defaultSize", locale: language), systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
            Button {
                // 2026-10-18 (dono: «seleciono a nova leitura… deveria anular
                // a leitura anterior e começar com ela… direta»): com leitura
                // em curso, refaz DA FRASE ATUAL — o corte-e-volta-ao-topo
                // (descarte + lista inteira) morre aqui. Parado, segue o
                // sentido original: descartar e sintetizar de novo.
                if isReading || controller.isBusy {
                    restartReadingFromCurrentPoint()
                } else {
                    controller.discardTranscription()
                    controller.play(phrases: playList(), voice: voice, rate: rate, readFootnotes: readFootnotes)
                }
            } label: {
                Label(L.get("ui.newReading", locale: language), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!controller.hasTranscription)
            .help(L.get("help.redoSynthesis", locale: language))

            Divider()
            // Sleep timer: turns itself off at the deadline. Lives as a
            // submenu because the Options menu already gathers the moment's actions.
            // Plano item 33: Picker (marca de escolha) + rótulo armado —
            // depois da mensagem de 4 s algo em tela lembra o prazo.
            Menu {
                Picker(L.get("ui.sleepTimer", locale: language), selection: $sleepMinutes) {
                    Text(L.get("ui.sleepOff", locale: language)).tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { minute in
                        Text(L.get("ui.sleepMinutes", locale: language, args: minute)).tag(minute)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } label: {
                Label(
                    sleepMinutes > 0
                        ? L.get("ui.sleepArmed", locale: language, args: sleepMinutes)
                        : L.get("ui.sleepTimer", locale: language),
                    systemImage: "moon.zzz")
            }

            Divider()
            // SettingsLink opens the `Settings` scene of EdgeSpeakApp; it is what
            // compiles cleanest here (no @Environment and no scene id).
            SettingsLink {
                Label(L.get("ui.settings", locale: language), systemImage: "gear")
            }
        } label: {
            Label(L.get("ui.options", locale: language), systemImage: "slider.horizontal.3")
        }
        .help(L.get("help.optionsMenu", locale: language))
    }

    // MARK: - Exportação da cópia com destaques (spec §5)

    /// "Exportar cópia com destaques…": NSSavePanel + burn-in, o PDF original
    /// NUNCA é tocado. As efêmeras de leitura (azul/amarelo do momento) saem
    /// antes do burn-in e voltam depois — dentro de um único turno da fila
    /// principal, o tick de leitura não entrelaça.
    private func exportHighlightsCopy() {
        guard let document = pdfDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stem = document.documentURL?.deletingPathExtension().lastPathComponent
            ?? "documento"
        panel.nameFieldStringValue = "\(stem)-destaques.pdf"
        panel.begin { [document] response in
            guard response == .OK, let target = panel.url else { return }
            guard let data = burnInData(document: document) else {
                controller.setStatusKey(
                    "pdf.exportFailed", args: [], locale: language)
                revealStatus()
                return
            }
            do {
                try data.write(to: target)
            } catch {
                controller.setStatusKey(
                    "pdf.exportFailed",
                    args: [error.localizedDescription],
                    locale: language)
                revealStatus()
            }
        }
    }

    /// Burn-in das anotações de POR uma passagem: tira as efêmeras sabidas
    /// pela marca (spec §5), gera os bytes da cópia e as devolve.
    private func burnInData(document: PDFDocument) -> Data? {
        var stripped: [(page: PDFPage, ephemeral: [PDFAnnotation])] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let ephemeral = page.annotations.filter {
                $0.userName == HighlightMarks.readingOwner
            }
            guard !ephemeral.isEmpty else { continue }
            ephemeral.forEach { page.removeAnnotation($0) }
            stripped.append((page, ephemeral))
        }
        defer {
            for holder in stripped {
                holder.ephemeral.forEach { holder.page.addAnnotation($0) }
            }
        }
        let burnIn: [PDFDocumentWriteOption: Any] = [
            .burnInAnnotationsOption: true,
        ]
        return document.dataRepresentation(options: burnIn)
    }

    // MARK: - Media keys (system) and the on-device summary

    /// Summary of the passage (menu ⌘⇧M), shown in a sheet.
    @State private var summaryText: String = ""
    @State private var showingSummary = false
    @State private var summaryInProgress = false

    /// Play/pause coming from outside the keyboard (system media keys, the
    /// headphones button). Exactly the space bar's rule: during synthesis
    /// without a pause the request is ignored (a new play would cancel and
    /// restart it), but PAUSED during synthesis it resumes — the audio already
    /// synthesized is resumable and `SpeechController.play` has that branch.
    private func requestTogglePlay() {
        if playWouldDoNothing { return }
        if canPlay || canPause { togglePlay() }
    }

    /// Stop requested by the system media keys: cancels during synthesis,
    /// stops the playback otherwise — the same rule as the bar's button.
    private func requestStop() {
        if controller.isBusy {
            controller.cancelSynthesis()
        } else {
            controller.stopPlayback()
        }
    }

    /// Summarizes the passage of the moment — the stretch being read, not the
    /// document's opening — with the on-device model and shows the result in a
    /// sheet. Fail-closed and explicit about which of the two failures happened:
    /// no model on this Mac, or the model did not answer. Never touches the
    /// reading.
    private func requestSummary() {
        guard !summaryInProgress else { return }
        let list = playList()
        let trecho = ArticleSummary.excerpt(
            sentences: list.map(\.text),
            at: summaryPosition ?? 0)
        guard !trecho.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controller.setStatusKey("summary.nothing", locale: language)
            revealStatus()
            return
        }
        guard ArticleSummary.isAvailable else {
            controller.setStatusKey("summary.requiresModel", locale: language)
            revealStatus()
            return
        }
        summaryInProgress = true
        controller.setStatusKey("summary.working", locale: language)
        revealStatus()
        Task {
            let resumo = await ArticleSummary.summarizeIfAvailable(text: trecho)
            summaryInProgress = false
            if let resumo {
                summaryText = resumo
                showingSummary = true
                // The band held the progress message; the sheet is the result
                // now, so the band goes back to empty (the banner is only drawn
                // with a non-empty status).
                controller.setStatus("")
            } else {
                controller.setStatusKey("summary.failed", locale: language)
            }
        }
    }

    // MARK: - Keyboard and mouse (local monitors)

    @State private var eventMonitors: [Any?] = []

    /// Plano item 23: ancorar o VoiceOver na toolbar depois da sheet do resumo
    /// fechar — antes, o foco caía em elemento mudo (audição seca). O alvo é o
    /// botão de Abrir (primeiro da toolbar); o gatilho mora no `WaveTwoFeedback`.
    private enum ToolbarAnchor: Hashable { case openFile }
    @AccessibilityFocusState private var toolbarAnchor: ToolbarAnchor?

    /// The window that hosts THIS ContentView, filled by `WindowProbe`.
    ///
    /// A local monitor sees every keyDown of the app, so with two windows
    /// open (⌘N) both monitors see the same event: identity of the hosting
    /// window is what tells them apart. `nil` means "not in a window yet"
    /// and the monitor then lets the event pass instead of guessing.
    @State private var hostWindow = WindowBox()

    /// Local keyboard event monitor.
    ///
    /// The `PDFView` is AppKit and swallows SwiftUI shortcuts: without the monitor,
    /// space would not toggle play/pause outside typing, nor would ⌥←/⌥→
    /// skip 15 s with the PDF focused.
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

    /// Space toggles play/pause outside typing and outside PDF reading; ⌥←/⌥→
    /// skip 15 s outside typing. Outside those cases the event goes on normally.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window ?? NSApp.keyWindow else { return event }
        let responder = window.firstResponder
        let editingText = responder is NSTextView || responder is NSTextField
        // Arrow keys arrive with `.numericPad`/`.function`; caps lock would shift
        // the comparison. Removes the three before requiring pure `.option`.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // Esc (keyCode 53): sai do modo destacar — SÓ quando ele está ligado
        // (spec §5). Fora do modo, Esc passa como sempre.
        if event.keyCode == 53 {
            guard highlightMode else { return event }
            guard let host = hostWindow.window,
                  window === host || window.sheetParent === host
            else { return event }
            highlightMode = false
            return nil
        }

        // ⌘V (keyCode 9), plano item 1: a tela vazia PROMETE colar
        // («…ou cole um texto») e nenhum caminho escrevia em `text`. Intercepta
        // apenas no estado vazio — com editor ou PDF no foco, cada um cola o
        // seu e o evento passa.
        if event.keyCode == 9, mods == .command, !editingText, isEmpty {
            guard let host = hostWindow.window,
                  window === host || window.sheetParent === host
            else { return event }
            pasteIntoEmptyEditor()
            return nil
        }

        // Space (keyCode 49). Plano item 19: o espaço é do CONTROLE focado —
        // botão, slider, picker (NSControl), editor (NSTextView) e PDF
        // (PDFView) consomem o próprio espaço e o evento PASSA. Só na
        // ausência de foco de controle (first responder = a janela) o espaço
        // é nosso: play/pause, o desvio documentado do gênero player
        // (audit-ui item 5).
        if event.keyCode == 49, mods.isEmpty {
            guard !SpaceKeyPolicy.belongsToFocusedControl(window.firstResponder)
            else { return event }
            // Two windows, two monitors, ONE event. Only the view hosted in
            // the event's window toggles, so the OTHER window's reading keeps
            // going. AppKit calls the monitors in unspecified order and stops
            // at the first nil (measured), so the non-host monitor must return
            // the event untouched: that way the host's nil is always reached —
            // exactly one toggle, event swallowed once.
            // Plano item 19: o espaço NÃO entra na sheet do resumo (janela
            // própria) — lá ele serve a sheet (texto, botões), não à leitura
            // principal (a queixa da audit-a11y).
            guard let host = hostWindow.window, window === host else { return event }
            requestTogglePlay()
            return nil
        }

        // ⌥← / ⌥→ (keyCode 123 / 124): ±15 s. In the editor, ⌥← navigates by word,
        // so there the event passes. Gated on `canSkip`, the same rule as the
        // ±15 s buttons — NOT on `isBusy`, which kept the shortcut dead through
        // the minutes of a synthesis and let the event fall through to the PDF,
        // scrolling the page instead of moving the reading.
        if mods == .option, event.keyCode == 123 || event.keyCode == 124 {
            if editingText { return event }
            guard controller.canSkip else { return event }
            // Same gate as space: with two windows both monitors see this
            // event, and only the one hosted in the event's window may skip
            // (±15 s in whichever window the monitors happened to call first
            // was the bug). The non-host monitor returns the event untouched,
            // so the host's `nil` is always reached — exactly one skip.
            guard let host = hostWindow.window,
                  window === host || window.sheetParent === host
            else { return event }
            controller.skip(event.keyCode == 123 ? -15 : 15)
            // Explicit navigation: brings the PDF to the passage even with "Follow
            // reading" off, like the track and the ±15 s buttons.
            if pdfDocument != nil { revealToken += 1 }
            return nil
        }

        // Plano item 20: ⌥↑ / ⌥↓ (keyCode 126 / 125) — frase anterior/próxima.
        // MESMA régua do ±15 s (passa no editor; `canSkip`) — teclado nunca
        // dispara síntese nova por conta própria; o clique-à-frente do
        // painel/PDF existe, mas é um gesto do usuário sobre a superfície.
        if mods == .option, event.keyCode == 125 || event.keyCode == 126 {
            if editingText { return event }
            guard controller.canSkip else { return event }
            guard let host = hostWindow.window,
                  window === host || window.sheetParent === host
            else { return event }
            jumpToNeighboringSentence(event.keyCode == 126 ? -1 : 1)
            return nil
        }

        return event
    }
}

/// Fixed-type container, just to give the window a root that does not change
/// identity when the content changes (empty → editor → PDF → panel).
///
/// Exists because of the toolbar: applied directly to the content that
/// changes shape, it was lost in the switch (proven: without PDF the bar
/// appeared, opening a PDF it vanished). Here the root is always the same.
private struct Container<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

/// Weak box for the NSWindow hosting a `ContentView`: written by
/// `WindowProbe`, read by the keyboard monitor. Weak, so a closed window is
/// never kept alive by the view state.
private final class WindowBox {
    weak var window: NSWindow?
}

/// Background AppKit view that reports the window its ContentView lives in.
///
/// `hitTest` returns nil: the probe only observes, and must never take a
/// click away from the content behind it.
private final class WindowProbeView: NSView {
    var box: WindowBox?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        box?.window = window
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct WindowProbe: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.box = box
        return view
    }

    // Attach/detach always arrive through `viewDidMoveToWindow`; nothing to
    // refresh when SwiftUI re-renders us.
    func updateNSView(_ nsView: WindowProbeView, context: Context) {}
}

/// Subscriptions that arrive from OUTSIDE the window: system media keys, the
/// menu's *Summarize Current Passage* (⌘⇧M, the stretch being read) and the
/// summary sheet itself.
///
/// Grouped in a modifier instead of inline in `ContentView.body`: with the
/// four `onReceive` and the `sheet` in the chain, the type checker gave up on
/// the body ("unable to type-check this expression in reasonable time").
/// Behavior is unchanged — the closures are the same ones the body calls.
/// Plano item 15 + item 32: o canal que Ouve o usuário durante o uso —
/// troca de voz com leitura em curso (reinício direto da frase atual,
/// 2026-10-18) e contador do prazo de
/// extração. Fora do `body` principal porque inline o type-checker
/// desistia da expressão inteira (mesmo sintoma que criou
/// `ExternalActions`).
private struct WaveTwoFeedback: ViewModifier {
    let controller: SpeechController
    @Binding var voice: String
    @Binding var importActive: Bool
    @Binding var importRemainder: Int?
    let loadGeneration: Int
    let language: L.Language
    /// Plano item 23: sheet do resumo fechou → voz söe na toolbar.
    @Binding var showingSummary: Bool
    let refocusToolbar: () -> Void
    /// 2026-10-18 (dono): trocar a voz com leitura em curso cancela e refaz a
    /// leitura da frase atual — quem decide ONDE reiniciar é a view
    /// (`ReadingRestartPolicy`); aqui, como o `refocusToolbar`, só o gatilho.
    let restartReading: (String) -> Void

    func body(content: Content) -> some View {
        content
            // Plano item 23: ao FECHAR a sheet, o foco volta ancorado no
            // botão de Abrir (`.accessibilityFocused` na toolbar) — antes
            // caía em elemento mudo. O `refocusToolbar` é a decisão da view
            // (marca a âncora); aqui só o gatilho.
            .onChange(of: showingSummary) { _, showing in
                guard !showing else { return }
                refocusToolbar()
            }
            // Plano item 15, revisto pelo dono em 2026-10-18 («o novo agente
            // de leitura deveria anular a leitura anterior e começar com
            // ela… direta» / «está cortando a leitura»): trocar a voz com
            // leitura em curso CANCELA o run atual e refaz a leitura DA FRASE
            // ATUAL com a voz nova — direto, sem Play extra. Sem leitura em
            // curso, a troca é só a escolha (nada a anular).
            .onChange(of: voice) { _, new in
                guard FeedbackPolicy.voiceChangeRestartsReading(
                    busy: controller.isBusy,
                    playing: controller.isPlaying,
                    paused: controller.isPaused)
                else { return }
                restartReading(new)
            }
            // Plano item 32: contador do prazo de extração — um re-render por
            // meio segundo SÓ durante a importação (o `id` muda a cada load e
            // cancela a task anterior; fora dela, custo zero).
            .task(id: loadGeneration) {
                guard importActive else { return }
                while importActive, !Task.isCancelled {
                    if let deadline = PdfWords.activeImportDeadline {
                        importRemainder = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                    } else {
                        // Prazo encerrado no processo (o resto do caminho segue
                        // sem prazo fixo): o número sai, o botão permanece.
                        importRemainder = nil
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
    }
}

/// Planos 1, 24 e 31: os canais de ENTRADA de arquivo/texto — painel de
/// seleção (⌘O da toolbar, botão do estado vazio), drop com retorno visual e
/// a mensagem de falha de abertura pelo `failureKey`. Fora do `body`
/// principal porque inline o type-checker desistia da expressão inteira.
private struct ImportChannels: ViewModifier {
    @Binding var showingImporter: Bool
    /// Plano item 31: `isTargeted` → a borda acende (o drop funciona DURANTE
    /// a síntese, quando tudo mais está travado).
    @Binding var dragTargeted: Bool
    let onFile: (URL) -> Void
    let onOpenFailed: (Error) -> Void
    let onDroppedText: (String) -> Void

    private static var importTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText]
        for ext in ["md", "markdown"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: Self.importTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    onFile(url)
                case .failure(let error):
                    // Plano item 24: a falha de abertura sai pelo failureKey
                    // (chave do catálogo → nada de idioma misturado). O
                    // cancelamento do painel NÃO é falha: silencioso
                    // (FeedbackPolicy decide, testado).
                    onOpenFailed(error)
                }
            }
            // Plano item 31: `isTargeted` ligado ao estado; plano item 1: texto
            // arrastado também cola — mas SÓ no estado vazio, nunca por cima
            // do que já está aberto (a decisão mora em onDroppedText).
            .onDrop(
                of: [UTType.fileURL, UTType.plainText],
                isTargeted: $dragTargeted
            ) { providers in
                guard let provider = providers.first else { return false }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in onFile(url) }
                    }
                    return true
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadDataRepresentation(for: .plainText) { data, _ in
                        guard let data,
                              let raw = String(data: data, encoding: .utf8)
                        else { return }
                        Task { @MainActor in onDroppedText(raw) }
                    }
                    return true
                }
                return false
            }
    }
}

/// Item 26 recolocado (2026-10-18, área do PDF é a prioridade): o
/// informativo do cabeçalho do PDF (título • página • voz • modo destacar)
/// virou o SUBTÍTULO da janela — política pura, testável sem instanciar a
/// view. A ordem é a de leitura e as partes vazias somem.
enum DocumentHeaderInfo {
    static func subtitle(
        pageText: String, voiceText: String, highlight: String?
    ) -> String {
        ([pageText, voiceText] + [highlight ?? ""])
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}

/// Cartão do texto (editor e painel quando são a vista principal) — a
/// página do PDF NÃO o usa mais (2026-10-18: era cartão-dentro-de-cartão
/// com o padding da janela, comendo a área do PDF).
private struct TextCard: ViewModifier {
    let dragging: Bool
    let active: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 200)
            .padding(8)
            // A frame instead of a loose background: visually separates the
            // text from the actions, with no heavy "box".
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Plano item 31: o drop de arquivo é o ÚNICO caminho que
                    // funciona durante a síntese — aberto o retorno visual,
                    // cursor e borda dizem onde soltar.
                    .strokeBorder(
                        dragging
                            ? Color.accentColor
                            : (active
                                ? Color.accentColor.opacity(0.45)
                                : Color.primary.opacity(0.12)),
                        lineWidth: dragging ? 2 : 1)
            )
    }
}

/// Itens 26/40 num modifier próprio — inline no body principal, o
/// type-checker não fechava a conta (como já aconteceu com
/// `ExternalActions`). Item 26 recolocado (2026-10-18, área do PDF é a
/// prioridade): o título da janela leva o nome decodificado do documento e
/// o SUBTÍTULO da barra de título leva página • voz (e o aviso do modo
/// destacar) — informação viva SEM faixa dentro do conteúdo.
private struct FindSurface: ViewModifier {
    let title: String
    let subtitle: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
    }
}

/// Plano item 40 (recolocado 2026-10-18: área do PDF é a prioridade) — o
/// campo de busca mora na TOOLBAR da janela; não há barra embutida acima do
/// PDF. `.searchFocused` é macOS 15+ (o piso do app é 14), então o foco do
/// ⌘F passa por um campo próprio (`@FocusState`), amarrado ao MESMO
/// `$searchQuery` que FILTRA o painel (via SearchPolicy): um estado, um
/// lugar — o Enter avança as ocorrências do Find do PDF (`findAdvance`) e
/// nada vira destaque de leitura.
private struct PDFFindBar: View {
    @Binding var query: String
    var focusToken: Int
    let onSubmitFind: () -> Void
    let language: L.Language
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L.get("ui.searchPrompt", locale: language), text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 170)
                .focused($focused)
                .onSubmit { onSubmitFind() }
                // Plano item 25 (contraste): o campo precisa de borda/fundo
                // próprios — sem estilo, ficava escuro sobre escuro no modo
                // escuro (relato do dono, 2026-10-18).
                .accessibilityLabel(Text(L.get("ui.searchPrompt", locale: language)))
        }
        .onChange(of: focusToken) { _, _ in focused = true }
    }
}

private struct ExternalActions: ViewModifier {    let togglePlay: () -> Void
    let stopReading: () -> Void
    let summarize: () -> Void
    /// UITests lane 2026-10-17: ⌘⇧H (modo destacar) e ⌘F (campo de busca),
    /// ambos vindos do menu "Leitura" (EdgeSpeakApp).
    let toggleHighlight: () -> Void
    let openFind: () -> Void
    @Binding var showingSummary: Bool
    let summaryText: String
    let language: L.Language

    func body(content: Content) -> some View {
        content
            // Media keys: play/pause/toggle resume or start, stop really stops.
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakTogglePlay)) { _ in
                togglePlay()
            }
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakStopReading)) { _ in
                stopReading()
            }
            // Menu ⌘⇧M: summarizes the passage with the on-device model.
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakSummarize)) { _ in
                summarize()
            }
            // Plano S2: toggles the highlight mode — the keyboard shortcut
            // (⌘⇧H) and the menu item share the single channel.
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakToggleHighlight)) { _ in
                toggleHighlight()
            }
            // Plano item 40: ⌘F — foca o campo de busca da TOOLBAR (filtra o
            // painel e navega as ocorrências do PDF).
            .onReceive(NotificationCenter.default.publisher(for: .edgeSpeakFind)) { _ in
                openFind()
            }
            .sheet(isPresented: $showingSummary) {
                SummarySheet(text: summaryText, language: language)
            }
    }
}

/// On-device summary of the passage (menu ⌘⇧M), in a sheet.
///
/// A sheet and not the status band: the band is one line, truncated, and it
/// hides itself in seconds — useless for three sentences of text. The text is
/// selectable and copyable, and the shell does not touch the reading.
private struct SummarySheet: View {
    let text: String
    let language: L.Language

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.get("summary.title", locale: language))
                .font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
            HStack {
                Spacer()
                Button(L.get("summary.copy", locale: language)) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                }
                .help(L.get("summary.copy", locale: language))
                Button(L.get("summary.close", locale: language)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 220, idealHeight: 300)
    }
}

/// Decisões puras da Onda 2 (feedback de uso, plano 2026-10-17): a fina camada
/// de `@State`/closures chama, os testes pinam a decisão sem instanciar a view.
enum FeedbackPolicy {
    /// Plano item 15, revisto em 2026-10-18: quando a TROCA de voz cancela e
    /// refaz a leitura — com leitura, pausa ou síntese no ar. Sem nada
    /// rodando, a troca é só a voz de sempre (não há o que anular).
    static func voiceChangeRestartsReading(busy: Bool, playing: Bool, paused: Bool) -> Bool {
        busy || playing || paused
    }

    /// Plano item 24: cancelar o painel de arquivo NÃO é falha (o `fileImporter`
    /// devolve erro para quase tudo): silêncio no cancelamento, failureKey no resto.
    static func isUserCancelled(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
    }
}

/// 2026-10-18 (dono): onde a leitura é REFEITA quando a voz troca ou o dono
/// pede leitura nova com um run em curso — a frase atual (`highlightIndex`)
/// quando ela existe na lista; senão o início. Pura de propósito: a view só
/// aplica o resultado, o teste prova a regra.
enum ReadingRestartPolicy {
    static func offset(highlightIndex: Int, indices: [Int]) -> Int {
        guard highlightIndex >= 0 else { return 0 }
        return indices.firstIndex(of: highlightIndex) ?? 0
    }
}

/// Plano item 1: quais payloads de colagem/arrasto servem ao ESTADO VAZIO.
/// Puro e testável: pasteboard e fluxo na própria view, o juízo aqui.
enum EmptyStatePaste {
    /// Texto aproveitável: devolvido inteiro (o usuário pode editar depois);
    /// nil significa «nada colável» (vazio ou só brancos) — colado em branco
    /// não gera leitura e a tela não vira editor fantasma.
    static func usable(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : raw
    }

    /// Pasteboard → `usable(_:)`: nada colável devolve nil.
    static func usable(from pasteboard: NSPasteboard) -> String? {
        let raw = pasteboard.string(forType: .string)
        return usable(raw ?? "")
    }
}

// MARK: - Lane UI 2026-10-17: políticas puras dos itens 26, 29, 36, 40, 42,
// 57b e S1 — sem app, sem PDF e sem controller nas provas.

/// Plano item 29: as três seções de voz em UM único lugar. Toolbar e Ajustes
/// instanciam este mesmo picker; adereços (largura, desabilitar durante a
/// síntese, dica) continuam no dono da superfície. Sem arquitetura nova.


/// Plano item 26: título legível da janela/cabeçalho a partir da identidade
/// guardada (a URL absoluta). Puro: `absoluteString` cru cortava o nome em
/// "A%20Conting%C3%AAncia.pdf"; aqui o componente final é decodificado.
enum DocumentTitle {
    static func name(fromDocumentID id: String?) -> String {
        guard let id, let url = URL(string: id) else { return "EdgeSpeak" }
        let raw = url.lastPathComponent
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.isEmpty ? "EdgeSpeak" : decoded
    }
}

/// Plano item 40: a busca FILTRA o painel e nunca vira destaque de leitura.
/// Puro: TextKit cuida da renderização; aqui só o recorte.
enum SearchPolicy {
    static func matches(_ text: String, by query: String) -> Bool {
        text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    /// Sem consulta (ou só brancos): a lista inteira, intacta.
    static func filter(_ sentences: [TextImport.Phrase], by query: String) -> [TextImport.Phrase] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sentences }
        return sentences.filter { matches($0.text, by: query) }
    }
}

/// Plano item 40: avanço ciclando pelo "Enter" (único gesto do campo de
/// busca). Puro: o Coordinator só executa o que daqui sai.
enum FindPolicy {
    static func next(shown: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (shown + 1) % count
    }
}

/// Plano item 42: sanidade do campo "ir para página" — a entrada é 1-based
/// (idioma do usuário) e a saída 0-based (o espaço do PDFKit).
enum PageJump {
    static func pageCount(of document: PDFDocument) -> Int {
        document.pageCount
    }

    /// Fora da faixa (ou entrada sem número) → nil: o chama do lado da UI
    /// avisa no status em vez de navegar até strangeland.
    static func sanitize(_ raw: String, pageCount: Int) -> Int? {
        guard pageCount > 0,
              let number = Int(raw.trimmingCharacters(in: .whitespaces)),
              number >= 1, number <= pageCount
        else { return nil }
        return number - 1
    }
}

/// Plano item 42: o índice clicável, só quando o arquivo tem outline.
/// Puro sobre `PDFOutline`; a profundidade vira ordem de leitura (DFS) —
/// um menu não tem recuo. Cabem 400 entradas; livro além disso corta
/// honestamente (o campo "ir para página" ainda serve).
enum OutlineListing: Equatable {
    struct Entry: Equatable, Identifiable {
        /// Índice da rota (títulos repetem; `Identifiable` precisa de outro).
        let id: Int
        let title: String
        /// 0-based; `nil` para entradas sem destino resolvível.
        let page: Int?
    }

    static func entries(in document: PDFDocument, max: Int = 400) -> [Entry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [Entry] = []
        // DFS com pilha que guarda o estado de avanço no irmão: práticas de
        // outline (livros) são profundas mas estreitas; a pilha direta evita
        // recursão sem lógica escondida.
        var positions: [(node: PDFOutline, child: Int)] = []
        if root.numberOfChildren > 0 { positions = [(root, 0)] }
        while !positions.isEmpty, result.count < max {
            let frame = positions[positions.count - 1]
            // PDFKit LEVANTA NSException em `childAtIndex:` fora dos limites
            // (não devolve nil): o esgotamento dos irmãos tem de ser
            // detectado por `numberOfChildren` e o quadro, desempilhado.
            guard frame.child < frame.node.numberOfChildren else {
                positions.removeLast() // esgotou os irmãos: sobe na árvore
                continue
            }
            positions[positions.count - 1].child += 1
            guard let child = frame.node.child(at: frame.child)
            else {
                positions.removeLast() // esgotou os irmãos: sobe na árvore
                continue
            }
            if child.numberOfChildren > 0 {
                positions.append((child, 0))
            }
            let title = child.label ?? ""
            guard !title.isEmpty else { continue }
            let page: Int?
            if let destination = child.destination,
               let targetPage = destination.page {
                page = document.index(for: targetPage)
            } else {
                page = nil
            }
            result.append(Entry(id: result.count, title: title, page: page))
        }
        return result
    }
}

/// Plano item 57b (S1): a DECISÃO de mostrar o aviso de idioma (a detecção
/// pura é `DocumentLanguage`, já testada; aqui só a política de superfície).
enum LanguageNotice: Equatable {
    /// Há voz compatível e ela NÃO é a escolhida — oferecer a troca.
    case compatible(languageName: String, voice: String)
    /// Idioma detectado sem voz nenhuma no app — recado honesto.
    case noVoice(languageName: String)

    static func decide(
        suggestion: DocumentLanguage.Suggestion?,
        currentVoice: String,
        languageNameFor: (NLLanguage) -> String
    ) -> LanguageNotice? {
        guard let suggestion else { return nil }
        guard let voice = suggestion.voice
        else { return .noVoice(languageName: languageNameFor(suggestion.language)) }
        // Voz compatível JÁ escolhida: silêncio — o recado só existe para
        // mover quem está com a voz errada.
        guard voice != currentVoice else { return nil }
        return .compatible(
            languageName: languageNameFor(suggestion.language), voice: voice)
    }

    /// Nome do idioma pelo catálogo (`lang.<rawValue>`); sem chave, o
    /// identificador cru — alocado, nunca inventado.
    static func languageName(for language: NLLanguage, locale: L.Language = .en) -> String {
        let key = "lang.\(language.rawValue)"
        let resolved = L.resolve(key, locale: locale)
        return resolved == key ? language.rawValue : resolved
    }
}


// MARK: - Onda 3 (acessibilidade): políticas puras dos itens 19 e 20

/// Plano item 19: a quem o ESPAÇO pertence com um controle focado.
///
/// Com Full Keyboard Access o espaço ativa o controle em foco (botão, slider,
/// picker), move-o como deve e o monitor de teclado NÃO pode engoli-lo. O
/// desvio da PlayerBar (espaço = play/pause) só vale na ausência de foco de
/// controle — o first responder é a própria janela (ou uma view não-controla).
/// Puro: recebe o first responder e decide; janela/monitor ficam fora.
enum SpaceKeyPolicy {
    /// True quando o first responder é de um controle que consome o espaço:
    /// `NSControl` (botão, slider, picker, campo), editor de texto (NSTextView,
    /// cobre o TextEditor) ou leitor de PDF (PDFView).
    static func belongsToFocusedControl(_ responder: AnyObject?) -> Bool {
        responder is NSControl || responder is NSTextView || responder is PDFView
    }
}

/// Plano item 20: a frase VIZINHA na lista de leitura, por POSIÇÃO na lista.
///
/// Botões da barra, ações customizadas (VoiceOver) do painel e ⌥↑/⌥↓ usam a
/// mesma decisão; `clickToPlay` executa (reveal do PDF, follow reativado,
/// `jumpToSegment` com pending já coberto lá). Puro e testável.
enum SentenceNeighborPolicy {
    /// `indices` são os índices globais da lista de leitura (`playList()`).
    /// Lista vazia → nil (nada para onde ir). Sem frase corrente
    /// (`current` fora da lista): para a frente → primeira frase; para
    /// trás → nil (nada antes de «nada lido»). Nas pontas, prende — a
    /// mesma régua do ±15 s (`skip`), sem beco silencioso novo.
    static func target(from indices: [Int], current: Int, direction: Int) -> Int? {
        guard !indices.isEmpty, direction != 0 else { return nil }
        guard let position = indices.firstIndex(of: current) else {
            return direction > 0 ? indices.first : nil
        }
        let clamped = max(0, min(indices.count - 1, position + direction))
        return indices[clamped]
    }
}
