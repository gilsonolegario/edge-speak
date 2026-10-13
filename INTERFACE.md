# EdgeSpeak — contrato de interfaces

Estado: 2026-10-13. Leitor de PDF/texto com leitura em voz alta em **fluxo**:
cada fatia sintetizada toca assim que fica pronta. Dois motores: edge-tts
online (vozes Microsoft neurais, devolve tempos por palavra) e Piper offline
(um WAV por frase, sem tempos de palavra).

UI no desenho do IINA: **toolbar no topo** (Abrir, Voz, Opções) +
conteúdo + **barra de controle flutuante na base, sempre visível**.

- Linguagem: Swift / SwiftUI, plataforma macOS 14+. Pacote SwiftPM, alvo
  `EdgeSpeak`, fontes em `Sources/EdgeSpeak/`.
- **Decisão de arquitetura:** o motor permanece interno (`StreamingPlayer` +
  `EdgeTTS`/`PiperTTS`). `edge-playback`/mpv foi descartado porque não devolve
  tempos por palavra nem permite pular por frase — perderia o destaque
  palavra a palavra, o cache em disco e a voz offline.
- Processo: o orquestrador define os contratos de fronteira entre arquivos; a
  implementação corre em subagentes com escopos disjuntos; a integração é
  verificada com `swift build`, `swift test` e reabertura do app.

---

## 1) `Sources/EdgeSpeak/EdgeTTS.swift` — motor online em fluxo

`enum EdgeTTS`, sem estado.

```swift
static let edgeTTSPath: String   // ~/.local/bin, /opt/homebrew/bin, /usr/local/bin; senão "edge-tts"
static let ffmpegPath: String?   // concatenação; nil → anexa bytes

static var pythonPath: String                    // interpretador com edge_tts
static func pythonForSynthesis(progress:) throws -> String  // prepara venv embutido; legado só em dev

static func timeout(forChars: Int) -> TimeInterval   // chars/10, clamp 60…600 (rede ruim não trava a UI)
static let maxConcurrentChunks = 3                   // acima disso o serviço estrangula a 1ª fatia
static let maxAttemptsPerChunk  = 3                  // retry por fatia

static func buildChunks(_ phrases: [TextImport.Phrase], maxChars: Int, firstChars: Int = 450) -> [[TextImport.Phrase]]
static func mapSegments(...)                       // tempos por frase derivados do script synth_timing.py
static func synthesizeStreaming(...)               // fatia por fatia; escreve chunk-%04d.mp3 + .json + .txt + .lines.txt
static func killRunningProcesses()
static func purgeStaleDirectories(keeping: URL)
```

`Segment` (frase lida) e `Word` (palavra) — codáveis, Sendable:

```swift
struct Segment: Codable, Sendable, Identifiable {
    struct Word: Codable, Sendable { let start: Double; let duration: Double; let text: String }
    let start: Double      // instante dentro do áudio final
    let duration: Double
    let text: String
    var words: [Word] = []      // vazio sem tempos de palavra (Piper)
    var index: Int = -1         // índice global da frase na lista ativa
    var page: Int?              // página de origem (nil sem PDF)
    var rects: [CGRect] = []    // caixas das linhas da frase de origem
}
```

Regras verificadas:

- O texto da fatia é montado com `ReadAloudFilter.forSpeech` por frase e
  junção `" "` — e **`"\n"` na fronteira de parágrafo** (`phrase.paragraphEnd`):
  é o respiro da pausa entre parágrafos. **Nunca duplicar pontuação terminal**
  ("Frase.."): o `_split_sentences` do script (modo sem `--lines-file`)
  deriva as frases do texto de entrada e casaria a pontuação sobrando como
  frase-extra, quebrando o emparelhamento 1:1 com `mapSegments`. `\n` não
  casa o regex de terminadores.
- Fronteira com o script em 1:1 **por construção**: além do texto da fatia
  (`chunk-%04d.txt`), cada fatia escreve `chunk-%04d.lines.txt` com UMA frase
  de fala por linha (o mesmo texto `forSpeech`, na ordem) e passa
  `--lines-file`. O script trata cada linha como um trecho — 1 segmento por
  linha, na ordem — sem derivar frases por regex próprio (antes, dois regex
  diferentes, um no Swift e outro no Python, podiam desalinhar os tempos).
  O modo antigo por regex segue disponível sem `--lines-file`, só para
  compatibilidade.
- `Phrase` não é cortada no meio; a primeira fatia é curta (~450 chars) para o
  áudio entrar em cerca de 1 s.

## 2) `Sources/EdgeSpeak/PiperTTS.swift` — motor offline (um WAV por frase)

`enum PiperTTS`, sem estado. Cinco vozes (`offlineVoices`): faber/edresson/cadu/
jeff pt-BR e lessac en-US; `isOfflineVoice(_:)` e `label(for:)` guiam a UI.

- Ambiente próprio: `piper-venv` e `voices/` em `~/Library/Application
  Support/EdgeSpeak/`; `ensureVenv()`/`ensureVoice(_:progress:)` baixam do HF.
- `lengthScale(for:)` traduz a cadência (`EdgeTTS.Rate`).
- `runStreaming(...)`: sintetiza UMA frase por vez com
  `session.synth(text:wav:lengthScale:)`. O texto falado vem de
  `ReadAloudFilter.forSpeech`; quando `phrase.paragraphEnd`, **acrescenta `\n`**
  ao final (pausa do modelo; o vão entra na duração medida do WAV e o offset
  acumulado segue correto — nunca deslocar offsets à mão, nunca inserir WAVs
  de silêncio).
- Sem tempos por palavra: `Segment.words` fica vazio. O karaokê por palavra
  (painel e PDF) só existe para vozes online.

## 3) `Sources/EdgeSpeak/StreamingPlayer.swift` — reprodução em fluxo

`final class StreamingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate`.
É a **fonte da verdade** do estado de reprodução (o controller espelha).

```swift
@Published private(set) var isPlaying / isPaused / isFinished / isStarved
@Published private(set) var elapsed: TimeInterval
@Published private(set) var knownDuration: TimeInterval
@Published private(set) var currentSegmentText: String?   // do segmento ativo
@Published private(set) var currentSegmentIndex: Int = -1  // índice global da frase
@Published private(set) var currentSegmentPage: Int?
@Published private(set) var currentWordIndex: Int = -1     // palavra ativa (busca binária por tempo)
@Published var volume: Float

func start(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments: [[EdgeTTS.Segment]])
func enqueue(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments: [[EdgeTTS.Segment]])
func markSynthesisComplete()
func seek(to globalTime: TimeInterval)
func seek(toSegment index: Int) -> Bool
func jumpToSegment(_ index: Int) -> Bool
func pause() / resume() / stop() / play() / restart(audioURL:segments:)
```

Regras:

- `durations` (opcional) vêm medidas **fora da thread principal**
  por quem sintetiza. Sem elas, o player sonda cada fatia em
  fundo (`Task.detached`, `AVAudioPlayer(contentsOf:)`) e preenche
  a duração na chegada, com guarda de geração: `stop()`/`restart`
  invalidam a geração e a sonda de uma sessão morta nunca escreve.
  A duração também se completa no próprio `playChunk`, sem I/O
  extra na main.
- `pause()` invalida o tique de 10 Hz do destaque; `resume()` o
  reinstala.
- O delegate (`audioPlayerDidFinishPlaying`) só age quando o
  player que terminou é o da sessão corrente — callback tardio
  de sessão morta é ignorado.

## 4) `Sources/EdgeSpeak/SpeechController.swift` — orquestrador

`@MainActor final class SpeechController: ObservableObject`.

```swift
@Published var isBusy: Bool; status: String; isPlaying: Bool; isPaused: Bool
@Published private(set) var hasAudio: Bool
@Published private(set) var completedChunks / totalChunks: Int
@Published private(set) var segments: [EdgeTTS.Segment]   // tempos + índices
@Published private(set) var phrases: [TextImport.Phrase]  // lista ativa
@Published private(set) var voiceInUse: String
@Published private(set) var highlightText: String?; highlightIndex: Int; highlightPage: Int?
@Published private(set) var highlightWordIndex: Int       // move o karaokê
@Published var volume: Float

func play(phrases: [TextImport.Phrase], voice: String, rate: EdgeTTS.Rate = .normal)
func pause() / resume() / stopPlayback()
func cancelSynthesis()        // por geração: invalida a geração; a tarefa velha não escreve mais nada
var hasTranscription: Bool    // há transcrição a descartar (áudio, síntese ou chave corrente)
func discardTranscription()   // descarta a corrente: áudio, segmentos, frases, chave e entrada de cache
func skip(_ seconds: TimeInterval)
func jumpToSegment(_ index: Int) -> Bool
func seek(to time: TimeInterval)
func seek(toSegmentAt index: Int)
func setStatus(_ message: String)
func exportMP3()          // NSSavePanel; copia o áudio com a extensão da voz
```

Regras:

- `fullText` (usado como **chave do cache** em `CacheDisco` e na estimativa de
  duração) junta as frases com `" "`, e com `"\n"` após `phrase.paragraphEnd`.
  Isso invalida os áudios antigos (sem pausa) **uma única vez**; o texto
  publicado de cada frase não muda.
- O motor é escolhido pela voz: `PiperTTS.isOfflineVoice(voice)` → offline.
- Cancelamento por **geração**: cada `play` incrementa
  `synthGeneration`; a tarefa confere `gen == synthGeneration`
  antes de cada efeito (streamer, `segments`, `status`, `isBusy`)
  e a tarefa velha — mesmo presa num `run` bloqueante — para sem
  escrever nada. `cancelSynthesis` invalida a geração, sinaliza a
  flag de cancelamento e encerra os processos dos dois motores.
- `discardTranscription` existe porque o `play` reaproveita o
  áudio quando a chave não muda: sem limpar áudio, segmentos,
  frases, chave corrente e a entrada de `CacheDisco`, trocar de
  modo de texto e apertar play retomaria a leitura antiga.
- `highlight*` são espelhados do `StreamingPlayer` (via combine) para a UI não
  parar na primeira frase.

## 5) Importação — `TextImport.swift`, `PdfWords.swift`, `PDFTextExtractor.swift`

`TextImport.Phrase` — `Hashable, Sendable`, com defaults nos campos novos:

```swift
struct Phrase: Hashable, Sendable {
    struct WordBox: Hashable, Sendable { let text: String; let rect: CGRect }
    let index: Int           // índice global estável na lista ativa
    let text: String
    let page: Int?           // 0-based; nil para texto sem PDF
    let rects: [CGRect]      // caixas das LINHAS da frase (não do parágrafo)
    let words: [WordBox]     // palavras do parágrafo inteiro (o karaokê casa por texto)
    let paragraphEnd: Bool   // true só na última frase de cada bloco/parágrafo
}
```

- `makePhrases` reparte cada segmento em frases **por bloco** (bloco separado
  por newline) e marca `paragraphEnd` na última frase de cada bloco.
- `rects` são as caixas das **linhas da frase**, calculadas a partir
  de `seg.words`: os tokens da frase são casados em ordem contra as
  palavras do parágrafo (cursor monotônico; token não achado é
  pulado sem deslocar o cursor) e as caixas casadas são agrupadas
  por linha (sobreposição vertical acima da metade da menor altura;
  minX/minY/maxX/maxY por linha, ordenadas). Sem nenhum casamento,
  a frase herda as caixas do parágrafo (`seg.rects`). `words`
  continua com as palavras do parágrafo — o karaokê casa por texto,
  não por índice.
- O texto integral e o filtrado derivam da MESMA lista (`filtered`/`integral`)
  e repassam `words` (o casamento do destaque é por texto, não por índice).
- Entrada: `.pdf` (script PyMuPDF, com reserva PDFKit), `.md` e `.txt`.
- `PdfWords.lines(pdfURL:pageCount:)` devolve por linha
  `[(texto, caixa, words: [(texto, caixa)])]` em **coordenadas de página
  PDFKit** (origem canto inferior esquerdo — o mesmo sistema dos `rects`).
  JSON antigo sem `words` continua decodificando (campo opcional); palavra com
  caixa inválida é descartada.
- `PDFTextExtractor.extractSegments` devolve
  `[(text, page, rects, words)]`; as `words` do parágrafo são a concatenação,
  na ordem de leitura, das palavras das linhas que estão na página da frase
  (mesma regra do `rects`). A via PDFKit (reserva) não tem palavras.

## 6) UI — `ContentView.swift`, `PlayerBar.swift`, `PDFDocumentView.swift`, `EdgeSpeakApp.swift`

`EdgeSpeakApp`: `WindowGroup("EdgeSpeak") { ContentView() }` com
`AppDelegate` — abre PDFs/texto por duplo-clique ou arraste (posta
`.edgeSpeakOpenFile`) — mais a cena `Settings { SettingsView() }`
(janela de Ajustes, ⌘,).

`ContentView` (layout B2, sem NavigationSplitView):

```
Toolbar (Abrir | Voz | menu Opções)
conteúdo (PDFDocumentView quando há PDF, senão TextEditor clicável)
PlayerBar  ← flutuante, sempre visível
```

O menu Opções traz "Seguir leitura" (só com PDF), fonte
(±2, padrão; ⌘-, ⌘+, ⌘0), "Gerar leitura nova" e "Ajustes…".
Ritmo e modo de texto moram na janela de Ajustes (seção 8),
não no menu.

- Teclado por monitor `NSEvent.keyDown`: **Enter** = play/pausa sempre;
  **Espaço** só fora do editor/PDF e **nunca durante `isBusy`** (durante a
  síntese o espaço é ignorado — antes ele cancelava e reiniciava a síntese);
  **⌥← / ⌥→** = ±15 s. Espaço/⌥-setas são guardados por tipo de
  `firstResponder` e por `!controller.isBusy`.
- Trilho, ±15 s e ⌥-setas chamam `onTransport` (barra) → incrementa
  `revealToken` (a `ContentView` leva o PDF ao trecho mesmo com o "Seguir
  leitura" desligado).
- `.onChange(of: integralMode)` → `handleIntegralModeChange()`:
  descarta a transcrição corrente (`discardTranscription`) e, se
  havia leitura em curso, reinicia a leitura com a lista nova;
  sem leitura, só descarta (o próximo play já usa o modo novo).
- Item "Gerar leitura nova" no menu Opções: descarta a transcrição
  e sintetiza de novo; habilitado enquanto `hasTranscription`.
- Barra: ícone central `play.fill`/`pause.fill` pelo estado (nunca
  `hourglass`); `.disabled(!canPause && (!canPlay || controller.isBusy))`;
  trilho arrastado não luta com o player (`dragValue` suspende o ponteiro).

`PlayerBar` — só o transporte, sem conhecer lista de frases nem voz:

```swift
struct PlayerBar: View {
    @ObservedObject var controller: SpeechController
    let textLength: Int
    let canPlay: Bool
    let onTogglePlay: () -> Void
    let onTransport: () -> Void      // trilho arrastado ou ±15 s (leva o PDF ao trecho)
}
```

`PDFDocumentView` — `NSViewRepresentable` sobre PDFKit, fiel ao original:

```swift
var page: Int? = nil          // página da frase; nil limpa
var rects: [CGRect] = []      // caixas das linhas da frase
var wordRect: CGRect? = nil   // caixa da palavra em leitura; nil limpa
var follow: Bool = true
var revealToken: Int = 0
var onUserScroll: (() -> Void)? = nil  // rolagem do usuário → o dono desliga o seguimento
var onPageClick: ...          // clique no PDF → frase correspondente
```

- Destaque da frase (azul): uma `PDFAnnotation` `.highlight` por
  caixa (cor de acento translúcida, α 0.28), adicionada à página
  da frase — geométrico, sem busca por texto (o filtrado nunca é
  idêntico ao do PDF); desenhadas pela página, rolam junto com o
  PDF. Deduplicação própria pela chave `key(page:rects:)`
  (página + caixas), separada do destaque da palavra: a troca de
  palavra só mexe na anotação amarela, e os tiques de 10 Hz não
  recriam nada (recriar a cada palavra fazia o parágrafo inteiro
  piscar). Removidas ao trocar de frase ou limpar (nunca anotação
  órfã).
- Destaque da palavra (amarelo): `PDFAnnotation` (`.highlight`,
  `systemYellow` α 0.55) com estado próprio no `Coordinator`
  (`wordAnnotation`/`wordPage`), trocada só quando a caixa ou a
  página mudam; removida ao trocar de palavra ou limpar (nunca
  órfã).
- Rolagem do usuário: o `Coordinator` observa os limites do
  `NSClipView` interno do `PDFView` e avisa `onUserScroll` somente
  quando o seguimento está ligado, passou a janela de silêncio de
  0,5 s após um `go(to:)` programático, a origem mudou e nem o
  tamanho nem a escala mudaram (zoom e redimensionamento mexem em
  tamanho/escala, nunca só na origem). O dono (`ContentView`)
  desliga o "Seguir leitura" no aviso — a rolagem manual sempre
  vence a automática.
- Karaokê do painel: casamento da palavra falada por texto com cursor
  sequencial. Karaokê do PDF (`currentWordRect` na `ContentView`): só com PDF,
  voz online (`!PiperTTS.isOfflineVoice`), índices válidos e caixa casada por
  texto normalizado (minúsculas, sem pontuação/hífen) — palavra não achada
  vira ausência de realce, nunca destaque errado; nunca casamento por índice.

## 7) `Sources/EdgeSpeak/CacheDisco.swift` — cache em disco da síntese

`enum CacheDisco`, sem estado. Guarda o áudio final (MP3 online,
WAV offline) + os segmentos globais, em `Caches/EdgeSpeak/<chave>/`.

```swift
static func key(text: String, voice: String, rate: EdgeTTS.Rate) -> String
static func lookup(key: String) -> Hit?          // áudio + segmentos, ou nil
static func store(key: String, audioURL: URL, segments: [EdgeTTS.Segment])
static func remove(key: String)                  // apaga a entrada inteira
```

- Chave: SHA-256 de `"v2|voz|cadência|texto"` (o prefixo `v2`
  invalida o cache anterior ao karaokê, cujos segmentos não têm
  tempos de palavra).
- Poda automática a cada `store` (no máximo 1×/min, em tarefa de
  fundo): saem entradas com mais de 30 dias e, acima de 2 GB, as
  mais antigas primeiro. Nunca toca na chave em uso nem em
  entradas gravadas há menos de 60 s (margem que protege a
  leitura corrente). Falha em silêncio — cache é otimização.

## 8) `AppSettings.swift` + `SettingsView.swift` — preferências e Ajustes

`enum AppSetting` centraliza chaves e padrões das preferências,
lidas por `@AppStorage` tanto na janela de Ajustes quanto na
`ContentView` — sempre a mesma chave e o mesmo padrão, nunca uma
string repetida à mão:

```swift
static let voiceKey = "voice"                // padrão "en-US-AndrewNeural"
static let rateKey = "readingRatePercent"    // padrão 0 (o `percent` de EdgeTTS.Rate)
static let followKey = "followReading"       // padrão true
static let integralKey = "integralText"      // padrão false
static let fontKey = "fontSize"              // padrão 17; limites 12…42

static let englishVoices / portugueseVoices   // catálogo online
static func label(for voice: String) -> String  // "Nome (país, gênero)"; offline via PiperTTS
static func isKnown(_ voice: String) -> Bool    // a voz guardada ainda existe?
```

`SettingsView` é a cena `Settings` do `EdgeSpeakApp` (⌘,), com
abas **Leitura** (voz, ritmo, "Seguir leitura"), **Texto**
(tamanho da fonte, "Texto integral" — com aviso de que a troca
descarta a transcrição) e **Avançado** (vazia por enquanto).
`voice` e `fontSize` mantêm os nomes já persistidos; ritmo,
seguimento e texto integral ganharam chaves novas (antes viviam
só como `@State` da sessão).

## Ferramentas (`Tools/`)

- `pdf_extract.py` — PyMuPDF; `--pdf/--out`; JSON `pages[].lines[]` com
  `text`, `box` e `words[]` (uma entrada por palavra, ordem de leitura,
  coordenadas convertidas para PDFKit: `[x0, h-y1, x1, h-y0]`).
- `synth_timing.py` — devolve o áudio e os tempos por frase. Modo
  preferido `--lines-file`: o app passa uma frase de fala por linha e
  cada linha vira EXATAMENTE um segmento, na ordem
  (`_group_words_lines`; linha vazia vira trecho de duração zero,
  nunca é descartada — descartá-la deslocaria as seguintes). Sem
  `--lines-file`, vale o modo antigo por regex
  (`_split_sentences`/`_group_words`), só para compatibilidade.
  **Restrição do modo antigo:** a entrada não pode ter pontuação
  terminal duplicada (gera frase-extra e quebra o emparelhamento).

## Regras transversais

- **Sem SSML** (sem evidência de suporte no serviço); a pausa entre parágrafos
  é feita com `\n` na junção do texto enviado ao motor.
- Cache em disco por `(texto completo + voz + cadência)`; a chave muda quando
  o texto muda (por isso a marca de parágrafo no `fullText` invalida uma vez).
  `CacheDisco.remove(key:)` apaga a entrada (usado ao descartar transcrição).
- Fronteira EdgeTTS ↔ `synth_timing.py` em 1:1 por construção
  (`--lines-file`): uma linha por frase, um segmento por linha, na ordem.
- Destaque palavra a palavra: só vozes online.
- Fonte da verdade do estado de reprodução: o `StreamingPlayer`.

## Testes (`Tests/EdgeSpeakTests/`)

Suítes em swift-testing (`@Test`/`#expect`, não XCTest).
`swift test` reporta **80 testes em 9 suítes** (conferido
em 2026-10-13; era 37/6 antes das fases de fórmulas, tradução e alinhamento):

- `ReadAloudFilterTests` (14) — `forSpeech` por símbolo e
  idioma, com a expansão de notação lógica (modal, conjuntos,
  gregas, ASCII de comparação, ⊤/⊥ em português) e garantia
  de que o exibido não muda.
- `BundledEnvTests` (8) — ordem de probe do Python, nomes
  de voz do Piper, site-packages e o remendo idempotente
  do edge_tts.
- `PDFFollowTests` (5) — detector de rolagem do usuário:
  rolagem programática, zoom e redimensionamento não
  desligam o seguimento; palavra visível não rola.
- `StreamingProofTests` (4) — entrega em ordem, fatia ruim
  não trava, retomada sem player corrente, tempos de
  palavra até a UI.
- `PdfClickLocatorTests` (3) — contenção vence, proximidade
  até 40 pt, margem devolve nil.
- `TranscriptionResetTests` (3) — modos integral/filtrado
  geram chaves diferentes, `CacheDisco.remove` apaga do
  cache, `discardTranscription` limpa o estado.

---

### Camadas
- Scaffold (este repo): `Package.swift`, `build-app.sh`, `README.md`, este
  `INTERFACE.md`, `Tools/`.
- Fonte: os arquivos listados acima. O orquestrador define os contratos de
  fronteira; cada subagente toca arquivos disjuntos; a integração é
  reverificada de forma independente.

## Pendências

- Aba "Avançado" dos Ajustes sem itens ("Nenhuma opção
  avançada disponível no momento"): o comentário no código
  cita limpeza de cache, mas `CacheDisco.remove(key:)` já
  existe — falta só o item de UI.
- `ReadAloudFilterTests` declara pendência própria: a
  extração de PDF pode entregar símbolos lógicos de outro
  jeito (entidade, LaTeX, imagem); sem PDF de fórmulas
  medido, os testes cobrem a função pura.