# EdgeSpeak — contrato de interfaces

Estado: 2026-10-13. Leitor de PDF/texto com leitura em voz alta em
**fluxo**: cada fatia sintetizada toca assim que fica pronta. Dois
motores: edge-tts online (vozes Microsoft neurais, devolve tempos
por palavra) e Piper offline (um WAV por frase, sem tempos de
palavra). Árvore verde: **88 testes em 10 suítes** (`swift test`),
build limpo.

UI no desenho do IINA: **toolbar no topo** (Abrir, Voz, Opções) +
conteúdo + **barra de controle flutuante na base, sempre visível**.

- Linguagem: Swift / SwiftUI, plataforma macOS 14+. Pacote SwiftPM
  (Swift 6, modo de linguagem v5), alvo `EdgeSpeak`, fontes em
  `Sources/EdgeSpeak/` (21 arquivos), testes em
  `Tests/EdgeSpeakTests/` (10 suítes, swift-testing: `@Test`/
  `#expect`, não XCTest).
- **Decisão de arquitetura:** o motor permanece interno
  (`StreamingPlayer` + `EdgeTTS`/`PiperTTS`). `edge-playback`/mpv
  foi descartado porque não devolve tempos por palavra nem permite
  pular por frase — perderia o destaque palavra a palavra, o cache
  em disco e a voz offline.
- Processo: o orquestrador define os contratos de fronteira entre
  arquivos; a implementação corre em subagentes com escopos
  disjuntos; a integração é verificada com `swift build`, `swift
  test` e reabertura do app.
- Contexto de pesquisa (citado, não copiado): as regras de
  verbalização de fórmulas seguem o levantamento em
  `docs/pesquisas/logica-leitura.md` (forallx Calgary, SEP,
  MathSpeak/ClearSpeak/SRE, manuais PT-BR — UFS/UFR/UFSC), com
  selo de status por regra ([P]/[S]/[I]/[?]); o mapa de OSS e
  licenças está em `docs/pesquisas/oss-mapa.md` (MFA, SRE,
  pdfminer.six, AVAudioPlayerNode, EPUBKit… — o que adaptar, o que
  evitar e por quê).

---

## 1) `Sources/EdgeSpeak/EdgeTTS.swift` — motor online em fluxo

`enum EdgeTTS`, sem estado.

```swift
static let edgeTTSPath: String   // ~/.local/bin, /opt/homebrew/bin, /usr/local/bin; senão "edge-tts"
static let ffmpegPath: String?   // concatenação; nil → anexa bytes

static var pythonPath: String                    // venv de suporte (BundledEnv) quando pronto; senão probe legado
static func pythonForSynthesis(progress:) throws -> String  // prepara o venv embutido; legado só em dev

static func timeout(forChars: Int) -> TimeInterval   // chars/10, clamp 60…600 (rede ruim não trava a UI)
static let maxConcurrentChunks = 3                   // acima disso o serviço estrangula a 1ª fatia
static let maxAttemptsPerChunk  = 3                  // retry por fatia (403 não retenta: é bloqueio, não instabilidade)

static func buildChunks(_ phrases: [TextImport.Phrase], maxChars: Int, firstChars: Int = 450) -> [[TextImport.Phrase]]
static func mapSegments(_ script: [Segment], _ phrases: [TextImport.Phrase]) -> [Segment]
static func synthesizeStreaming(...) -> AsyncThrowingStream<ChunkDelivery, Error>
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
    var id: Int { index >= 0 ? index : Int(start * 1000) }
}
enum ChunkDelivery: Sendable { case chunk(index: Int, url: URL, segments: [Segment]); case final(Result) }
```

Regras e decisões verificadas:

- **Por que `AsyncStream` e não `TaskGroup` de janela fixa:** com
  o grupo, o consumidor só é resumido quando uma tarefa retorna —
  medido: a fatia 0 pronta aos 38 s era entregue só aos 100 s. O
  stream entrega no instante. As fatias são sintetizadas em
  paralelo (3 em voo, cano cheio desde t=0 — antes a fila
  esvaziava aos ~30 s) mas **entregues em ordem** por
  `OrderedPublisher` (classe com `NSLock`: o emissor roda dentro do
  consumidor do grupo e o índice precisa de leitura atômica; interna
  para o harness headless cobrir a ordem).
- **Por que a primeira fatia é curta (~450 chars):** o áudio entra
  em cerca de 1 s; as demais vão atrás em ordem de índice.
- O texto da fatia é montado com `ReadAloudFilter.forSpeech` por
  frase e junção `" "` — e **`"\n"` na fronteira de parágrafo**
  (`phrase.paragraphEnd`): é o respiro da pausa entre parágrafos.
  **Nunca duplicar pontuação terminal** ("Frase.."): o `_split_sentences`
  do script (modo sem `--lines-file`) deriva as frases do texto de
  entrada e casaria a pontuação sobrando como frase-extra, quebrando
  o emparelhamento 1:1 com `mapSegments`. `\n` não casa o regex de
  terminadores.
- **Fronteira com o script em 1:1 por construção:** além do texto
  da fatia (`chunk-%04d.txt`), cada fatia escreve `chunk-%04d.lines.txt`
  com UMA frase de fala por linha (o mesmo texto `forSpeech`, na
  ordem) e passa `--lines-file`. O script trata cada linha como um
  trecho — 1 segmento por linha, na ordem — sem derivar frases por
  regex próprio (antes, dois regex diferentes, um no Swift e outro
  no Python, podiam desalinhar os tempos). O modo antigo por regex
  segue disponível sem `--lines-file`, só para compatibilidade.
- `mapSegments` emparelha por ordem: o texto publicado é o da
  frase (lista ativa); do script vêm só os tempos. Eventos extras
  são ignorados; frases sem evento herdam o fim da anterior —
  nunca se inventa tempo, só índice, página e caixas.
- **Por que ler a duração do arquivo (`AVURLAsset.load(.duration)`)
  em vez de somar os tempos das frases:** há silêncio no fim de
  cada fatia, e é esse silêncio que precisa entrar na conta para o
  destaque das fatias seguintes não adiantar nem atrasar.
- Retry com espera progressiva (0,8 s × tentativa); `403` no stderr
  quebra o loop (bloqueio do serviço — repetir não adianta).
- **Por que `stderr` vai para arquivo temporário:** pipe cheio
  causaria deadlock em processo longo. Timeout encerra (SIGTERM,
  2 s de graça, depois SIGKILL).
- Concatenação: ffmpeg quando há (`-f concat -c copy`), senão
  anexação de bytes. Falha em qualquer etapa apaga o diretório da
  síntese.
- `loadSegments` degrada em silêncio: JSON de tempos ilegível
  devolve `[]` — sem destaque, mas o áudio continua válido.
- `purgeStaleDirectories(keeping:)` remove `EdgeSpeak-*` do
  temporário **exceto** o da leitura corrente e o registrado em
  `protectedDir` (o MP3 fica em disco porque o `AVAudioPlayer`
  precisa dele enquanto toca; sem essa proteção, a próxima síntese
  apagaria o áudio em playback e o `restart` caía no guarda
  silencioso com `hasAudio` verdadeiro).
- `killRunningProcesses` encerra os processos registrados (só os
  cujo primeiro argumento termina em `synth_timing.py`) e faz
  `pkill -f synth_timing.py` — **nunca** por "python" solto, para
  não atingir processos alheios.
- Caminhos do Python: `pythonPath` prefere o venv de suporte
  (`BundledEnv.readyPython()`); o legado sonda pipx,
  `~/.local/share/edge-tts-venv`, homebrew e `/usr/bin/python3`,
  **aceitando só o que importa `edge_tts`** (probe `-c "import
  edge_tts"`), com cache. `pythonForSynthesis` prepara o
  ambiente embutido; se o preparo falhar E o legado importar, o
  legado vale (dev); senão o erro legível do preparo é o que a UI
  mostra.
- `synthTimingScript`: bundle primeiro (`Bundle.main`), senão
  `Tools/` do repositório (dev).

## 2) `Sources/EdgeSpeak/PiperTTS.swift` — motor offline (um WAV por frase)

`enum PiperTTS`, sem estado. Cinco vozes (`offlineVoices`):
faber/edresson/cadu/jeff pt-BR e lessac en-US; `isOfflineVoice(_:)`
e `label(for:)` guiam a UI; `voiceFileBase(for:)` e
`voiceRemotePath(for:)` são puros (testáveis).

- **Ambiente próprio:** `piper-venv` e `voices/` em
  `~/Library/Application Support/EdgeSpeak/`; `ensureVenv()` cria o
  venv legado com `/usr/bin/python3` e instala o wheel por URL
  (arquitetura via `utsname`: `macosx_11_0_arm64` ou
  `macosx_10_9_x86_64`, release v1.8.0 do OHF-Voice/piper1-gpl).
  `venvPython` prefere o venv de suporte embutido (`BundledEnv`) e
  cai para o legado.
- **Escolha do .onnx (`pickOnnx`, pura):** suporte existente vence
  o bundle; sem suporte, o bundle; sem nenhum, o suporte (alvo do
  download). Voz em cache só vale com `cachedVoiceValid`: tamanhos
  acima dos pisos (`onnxMinBytes` 1 MB, `jsonMinBytes` 512 B —
  hipótese de planejamento que rejeita truncados grosseiros) E
  `.onnx.json` parseável como JSON.
- Download atômico: grava em `<destino>.part` no mesmo volume,
  valida (`downloadComplete`: recebido ≥ piso e ≥ esperado quando
  o servidor informou; JSON validado) e só então renomeia — parcial
  nunca é aceito.
- `lengthScale(for:)` traduz a cadência (`EdgeTTS.Rate`) em
  `1/(1+percent/100)`.
- **Sessão persistente (`PiperSession`):** o app lança
  `piper_synth.py` como filho (a voz carrega UMA vez), espera a
  linha `{"ready": true}` (prazo 300 s) e fala JSON-linha por
  stdin: pedido `{"id", "text", "wav", "length_scale"}`, resposta
  `{"id", "duration"}` ou `{"id", "error"}` — o `id` casa o pedido
  (resposta de outro pedido é ignorada). Erro de uma frase não mata
  o processo. `stop()` fecha stdin, SIGTERM, 2 s, SIGKILL.
  `stopActiveSession`/`killRunningProcesses` (`pkill -f
  piper_synth.py`) encerram sessões órfãs.
- `runStreaming(...)`: sintetiza UMA frase por vez, **em ordem, sem
  paralelismo** (Piper é rápido; paralelismo não compra nada). O
  texto falado vem de `ReadAloudFilter.forSpeech`; quando
  `phrase.paragraphEnd`, **acrescenta `\n`** ao final (pausa do
  modelo; o vão entra na duração medida do WAV e o offset acumulado
  segue correto — **nunca deslocar offsets à mão, nunca inserir
  WAVs de silêncio**).
- **Duração:** `effectiveDuration(measured:declared:)` — usa a
  medida do WAV (`duration(of:)` lê o cabeçalho RIFF:
  `(bytes−44)/(taxa×canais×bits/8)`); só cai para a declarada
  quando a medida falta ou vem zero. A declarada acumula deriva no
  destaque das frases seguintes.
- Entrega imediata: cada frase vira `.chunk` com segmento local
  (`start: 0`), para a primeira tocar sem esperar o resto; os
  segmentos globais do `Result` trazem o offset acumulado.
- `concatWavs`: ffmpeg quando há; senão junção manual (cabeçalho do
  primeiro + PCM de todos, reescrita dos campos de tamanho).

## 3) `Sources/EdgeSpeak/StreamingPlayer.swift` — reprodução em fluxo

`@MainActor final class StreamingPlayer: NSObject, ObservableObject,
AVAudioPlayerDelegate`. É a **fonte da verdade** do estado de
reprodução (o controller espelha).

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

Regras e decisões:

- `durations` (opcional) vêm medidas **fora da thread principal**
  por quem sintetiza. Sem elas, o player sonda cada fatia em
  fundo (`Task.detached`, `AVAudioPlayer(contentsOf:)`) e preenche
  a duração na chegada, com guarda tripla: geração da sessão
  (`stop()`/`restart` invalidam), índice ainda válido com a mesma
  URL e duração ainda zerada, e `pendingProbes` evitando sonda
  duplicada. A duração também se completa no próprio `playChunk`
  (lê do player da reprodução, sem I/O extra na main).
- `pause()` invalida o tique de 10 Hz do destaque; `resume()` o
  reinstala. **Por que 10 Hz:** a palavra mais curta dura ~300 ms,
  e cada tique reconstrói o destaque — 20 Hz com texto longo
  saturava a main.
- **Por que publicar só quando muda:** sem a guarda, os 4 publicados
  (`currentSegmentText/Index/Page/WordIndex`) emitiam a cada tique
  e a vista reconstruía o texto inteiro (45k letras) 10×/s — a
  main saturava e o destaque parecia parado.
- O delegate (`audioPlayerDidFinishPlaying`) só age quando o player
  que terminou é o da sessão corrente (`player === current` e
  `currentGeneration == playbackGeneration`) — callback tardio de
  sessão morta é ignorado.
- **`isStarved`:** a fila esvaziou antes da síntese terminar. Sem a
  flag, as fatias que chegassem depois nunca voltavam a tocar (a
  leitura "pausava" sozinha no fim da primeira fatia). `enqueue`
  e `play()` retomam quando há áudio novo.
- **Decisão central — por que o salto por frase vai DIRETO à fatia:**
  no streaming as durações chegam atrasadas (sonda em fundo) e
  `knownDuration`/offsets ficam errados até medirem. O caminho
  antigo convertia frase→tempo global com offsets zerados e o
  `seek(to:)` grampeava no fim do áudio medido ou caía na fatia
  errada: o clique lia OUTRA parte. `seek(toSegment:)` procura a
  fatia que contém a frase (por `seg.index`) e usa `seg.start`
  (tempo LOCAL, sempre certo); o destaque usa os mesmos tempos
  locais. O relógio exibido (`elapsed`) continua aproximado até as
  sondas chegarem — só ele. Devolve `false` quando a frase ainda
  não tem áudio.
- `restart(audioURL:segments:)` (replay do MP3 completo ou cache):
  os tempos JÁ são globais, então a lista inteira vale como uma
  "fatia só" com offset zero.
- `playChunk` com fatia corrompida pula para a PRÓXIMA (antes
  repetia a MESMA url e queimava `nextIndex` — travamento
  permanente com as fatias seguintes já prontas no disco).
- Expostos para UI/testes: `currentChunkIndex`, `chunkStarts`,
  `currentGlobalTime`, `isQueueExhausted`, `pendingCount`.

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

func play(phrases: [TextImport.Phrase], voice: String, rate: EdgeTTS.Rate = .normal, lêNotas: Bool = true)
func pause() / resume() / stopPlayback()
func cancelSynthesis()
var hasTranscription: Bool
func discardTranscription()
func skip(_ seconds: TimeInterval)
func jumpToSegment(_ index: Int) -> Bool      // pendente sem áudio; retentado a cada fatia
func seek(to time: TimeInterval)
func seek(toSegmentAt index: Int)
func exportMP3()          // NSSavePanel; WAV offline, MP3 online
func setStatus(_ message: String)            // cru, sem chave
func setStatusKey(_ chave: String, args: [Any], locale: L.Idioma?)
func refreshLocale(_ locale: L.Idioma)       // re-resolve o status guardado
nonisolated static func parseProgress(_ message: String) -> (done: Int, total: Int)?
nonisolated static func failureMessage(for: Error, locale:) -> String
```

Regras e decisões:

- **Espelhamento do streamer (por que existe):** `currentSegmentText`
  vive no `StreamingPlayer`, e o `sink` de `objectWillChange` só
  republica o controller quando `isPlaying`/`isPaused`/`status`
  mudam — o destaque ficaria parado na primeira frase. Aqui cada
  campo do streamer tem seu próprio `sink` → `@Published` do
  controller. `volume` é `didSet` → `streamer.volume`.
- `fullText` (usado como **chave do cache** em `CacheDisco` e na
  estimativa de duração) junta as frases com `" "`, e com `"\n"`
  após `phrase.paragraphEnd`. Isso invalida os áudios antigos (sem
  pausa) **uma única vez**; o texto publicado de cada frase não muda.
- O motor é escolhido pela voz: `PiperTTS.isOfflineVoice(voice)` →
  offline. O fluxo é o mesmo (fatia por fatia, áudio único no fim).
- **Cancelamento por geração:** cada `play` incrementa
  `synthGeneration`; a tarefa confere `gen == synthGeneration` na
  main antes de cada efeito (streamer, `segments`, `status`,
  `isBusy`) e a tarefa velha — mesmo presa num `run` bloqueante —
  para sem escrever nada. `cancelSynthesis` invalida a geração,
  sinaliza a `CancelFlag` (instância por geração: a tarefa velha
  continua lendo `isCancelled == true` dentro do `run` bloqueante)
  e encerra os processos dos dois motores.
- **`play`, nesta ordem:** retoma pausa com a mesma chave
  (`status.playing`); pausa com a síntese da mesma leitura em voo
  (`synthKeyInFlight`) retoma o streamer e o resto engata ao
  chegar — `status.playingWhileSynthesizing` ou
  `status.generatingNext` (antes caía no no-op e o Play parecia
  morto; achado da auditoria); play repetido da mesma leitura em
  voo não inicia segunda síntese; síntese em curso com OUTRO texto
  cancela antes.
- **`pendingJumpIndex` (clique antes do áudio):** `jumpToSegment`
  sem áudio guarda o índice como pendente em vez de ignorar; cada
  fatia que chega tenta o pulo (`retryPendingJump`), então o clique
  "toca dali" assim que o trecho existe. O pendente morre com a
  síntese (cancelamento, fim ou erro) — sem isso, um clique
  anterior disparava sozinho numa leitura futura.
- **Clique sem áudio nenhum começa a síntese A PARTIR da frase
  clicada** (`ContentView.clickToPlay`): `Array(lista[pos...])` —
  com a lista inteira, o começo do documento tocava antes de a fatia
  do trecho clicado existir.
- `discardTranscription` existe porque o `play` reaproveita o áudio
  quando a chave não muda: sem limpar áudio, segmentos, frases,
  chave corrente e a entrada de `CacheDisco` (incluindo a chave em
  voo, se diferente), trocar de modo de texto e apertar play
  retomaria a leitura antiga.
- **Status re-resolvível:** mensagens do catálogo guardam
  `statusKey`+`statusArgs`; na troca de idioma, `refreshLocale`
  re-resolve. Progresso cru dos motores (`recebeProgresso`) limpa a
  chave — mensagem de motor segue no idioma de origem, e a troca não
  a sobrescreve.
- Estimativa de duração: `chars/700` (medido: 1391 chars/s em PT,
  26k chars; o pessimista evita que a espera real pareça travamento).
- `exportMP3`: o arquivo final já está junto — só copia com a
  extensão certa (WAV offline, MP3 online) via `NSSavePanel`.
- **Cache guardado fora da main** (`Task.detached(.utility)`):
  copiar o MP3/WAV final dentro do bloco `MainActor.run` congelava
  a UI no fim da síntese (achado da auditoria).
- `StatusRelay` (`@unchecked Sendable`, weak) leva o progresso da
  thread de fundo à main sem estender a vida do controller.

## 5) Importação — `TextImport.swift`, `PdfWords.swift`, `PDFTextExtractor.swift`

`TextImport.Phrase` — `Hashable, Sendable`:

```swift
struct Phrase: Hashable, Sendable {
    struct WordBox: Hashable, Sendable { let text: String; let rect: CGRect }
    let index: Int           // índice global estável na lista ativa
    let text: String
    let page: Int?           // 0-based; nil para texto sem PDF
    let rects: [CGRect]      // caixas das LINHAS da frase (não do parágrafo)
    let words: [WordBox]     // palavras do parágrafo inteiro (o karaokê casa por texto)
    let paragraphEnd: Bool   // true só na última frase de cada bloco/parágrafo
    let notaNumero: Int?     // corpo de nota de rodapé (nil em texto corrido)
}
```

- **Pipeline do PDF:** `PDFTextExtractor.extractSegments` (XY-cut,
  seção 6) → corte de bibliografia + `ReadAloudFilter.clean` por
  trecho (`filtered(_:isPDF:)`, preserva página/caixas/palavras) →
  `makePhrases` (reparte por bloco e frase, atribui caixas) →
  `resolveFootnotes` (liga corpos aos marcadores). Integral e
  filtrado derivam da MESMA extração (`frases`/`frasesFiltradas`).
- **`resolveFootnotes` — a decisão de índices como propriedade:**
  número solto de 1–2 dígitos com página (rótulo sem corpo, como os
  "1".."15" do artigo de teste) é **descartado** (lido, viraria
  "um"); corpo (1–2 dígitos iniciais + espaço + ≥12 caracteres) é
  movido para logo após a frase do marcador — marcador buscado na
  mesma página (em ordem) e, faltando, no documento para trás
  (cobre notas de fim); sem marcador, o corpo fica intacto (pode ser
  data ou enumeração: mexer seria corrupção). O corpo perde o número
  e ganha `notaNumero`. **Os índices das frases que ficam NÃO mudam**
  (são propriedade, não posição) — destaque e salto por índice
  continuam valendo após a resolução. A movimentação é de trás para
  frente para não deslocar posições ainda por tratar.
- `makePhrases` reparte cada segmento em frases **por bloco** (bloco
  separado por newline) e marca `paragraphEnd` na última frase de
  cada bloco.
- `rects` são as caixas das **linhas da frase**: os tokens da frase
  são casados em ordem contra as palavras do parágrafo (cursor
  monotônico em `boxesForSentence`; token não achado é pulado sem
  deslocar o cursor) e as caixas casadas são agrupadas por linha
  (`groupByLine`: sobreposição vertical acima da metade da menor
  altura; minX/minY/maxX/maxY por linha, ordenadas). Sem nenhum
  casamento, a frase herda as caixas do parágrafo (`seg.rects`).
  `words` continua com as palavras do parágrafo — o karaokê casa por
  texto, não por índice.
- `editorPhrases(_:integral:)`: texto digitado/colado, mesma UMA
  flag (integral ou `clean`).
- Entrada: `.pdf` (script PyMuPDF, com reserva PDFKit), `.md`/`.txt`
  (`normalizeMarkdown`: cercas, links, marcação de linha, inline).
  PDF sem camada de geometria cai para o texto bruto por página;
  sem texto nenhum, erro honesto ("PDF sem camada de texto").
- `splitSentences`: pontuação terminal seguida de maiúscula/dígito/
  abre-parêntese/aspa (regex com lookbehind).
- `PdfWords.lines(pdfURL:pageCount:)` roda `pdf_extract.py` e devolve
  por linha `[(texto, caixa, words: [(texto, caixa)])]` em
  **coordenadas de página PDFKit** (origem canto inferior esquerdo —
  o mesmo sistema dos `rects`; o script converte `[x0, h-y1, x1,
  h-y0]`). JSON antigo sem `words` continua decodificando (campo
  opcional); palavra com caixa inválida é descartada. Prazo:
  `min(180, 15 + 3×páginas)`. `pythonWithFitz` sonda (com cache) o
  venv de suporte, `EdgeTTS.pythonPath`, o venv do Piper, homebrew e
  `/usr/bin/python3`, aceitando só o que importa `fitz`; sem nenhum,
  devolve nil e o chamador usa a via PDFKit.
- `PDFTextExtractor.extractSegments` devolve
  `[(text, page, rects, words)]`; as `words` do parágrafo são a
  concatenação, na ordem de leitura, das palavras das linhas que
  estão na página da frase (`flush` filtra por `page == currentPage`).
  A via PDFKit (reserva) não tem palavras.

## 6) `Sources/EdgeSpeak/PDFTextExtractor.swift` — ordem de leitura (XY-cut)

- **Por que existe:** `PDFPage.string` devolve texto linha a linha na
  ordem de impressão — em páginas de **duas colunas** ela alterna
  esquerda/direita e embaralha o texto. Aqui cada linha vem com sua
  caixa e a ordem é reconstruída por **corte recursivo (XY-cut)**:
  separa pela maior calha **vertical primeiro** (colunas), depois
  horizontal (faixas), até não haver calha. A escolha pela vertical
  primeiro é o que faz uma página de duas colunas ser lida coluna
  inteira da esquerda, depois a da direita; um título de largura
  total "costura" a calha e força o corte horizontal antes.
- Corte vertical exige calha limpa (nenhuma linha a cruza), mínimo
  `max(12, leading)` e **≥3 linhas de cada lado** — uma heurística
  fraca não corta uma página de coluna única.
- Cabeçalhos/rodapés: `repeatedKeys` (mesmo texto normalizado —
  blocos de dígitos viram `#` — em ≥3 linhas de ≥3 páginas) e
  `isMarginNoise` (faixas 14% superior/86% inferior da página:
  número de página, data, URL, etiqueta ≤12 caracteres).
- Parágrafos (`paragraphs`): entrelinha mediano por página; continua
  enquanto a linha anterior NÃO fechou frase, encheu a coluna
  (≥82% da largura da coluna, não da página — `colLeft`/`colRight`
  do XY-cut), o vão é < 1,6×leading e a linha não é recuada
  (>0,8×leading); título (caixa >1,18× a altura mediana) fecha
  parágrafo; quebra de página continua se a frase não fechou; na
  virada de coluna (vano negativo) decide "linha cheia + fim de
  frase", que é o fluxo correto entre colunas. Hífen de fim de linha
  é consumido na junção.
- Vias de entrada: **PyMuPDF primeiro** (`PdfWords.lines`; contagem
  de páginas tem que bater, senão cai para PDFKit) — a camada de
  texto de alguns PDFs não tem espaços entre palavras e o PyMuPDF
  segmenta em palavras com caixas; **PDFKit como reserva** (sem
  Python ou sem PyMuPDF), ordenando linhas topo→base por geometria.
- Índice de nota em sobrescrito (`[⁰¹²³⁴⁵⁶⁷⁸⁹]+`) é tirado ANTES de
  tudo: colado no fim da linha, esconde a pontuação e a nota de
  rodapé seria emendada no parágrafo anterior.

## 7) `Sources/EdgeSpeak/ReadAloudFilter.swift` — o que a voz lê

O maior arquivo (45k). Duas vias que **nunca se misturam**:
`clean` (texto exibido/transcrito) e `forSpeech` (texto do
motor). Contrato travado por teste (`falaNaoAlteraExibicao`):
`forSpeech` expande notação; `clean` nunca insere palavra falada.

- `clean(_:isPDF:)`: NFKC → tira sobrescrito de nota →
  `stripPDFArtifacts` (cabeçalhos/rodapés repetidos, paginação,
  datas partidas, hifenização — **antes** do reflow, porque a
  quebra de linha é a evidência da hifenização) → `reflow` (reagrupa
  linhas quebradas) → `stripQuotedBlocks` (citação entre aspas — o
  `.` NÃO atravessa quebra de linha de propósito; versão antiga
  apagava seções inteiras; bibliografia na metade final; notas
  soltas de asterisco) → regras de apparatus em ordem (chamadas de
  nota, notas entre colchetes, "nota N", paginação em parênteses
  ANTES da solta — senão sobra `)` órfão, referências cruzadas com
  guarda de palavra isolada — "veremos" não é "ver", títulos de
  seção ficam de propósito, `ibid.`/`et al.`, `§N`, "Page N of M",
  citações autor-ano com ano de 4 dígitos, linhas de fórmula,
  fórmulas inteiras operando-símbolo-operando, `$…$`/`\(...\)`,
  URLs) → limpeza final (linhas só de pontuação, espaços duplos,
  pontuação órfã).
- **Por que o reflow critera pela LARGURA (85% do percentil 75) e
  não por "começa com minúscula":** numa frase justificada todas as
  linhas chegam perto da margem e só a última é curta; juntar por
  minúscula deixava solta toda quebra antes de nome próprio. A
  largura salva as quebras de página (linha curta no meio do
  parágrafo) e o "anterior cheia" salva a quebra antes de nome
  próprio.
- `forSpeech(_:voice:lêNotas:)` (o que o motor recebe): blackboard-
  bold **antes do NFKC** (`foldaveis`: o NFKC funde ℕ com N — a
  tabela de regex já os receberia mortos) → `expandAbbreviations` →
  `spellOutYears` (só PT: anos 1500–2100 por extenso; em inglês o
  motor já lê sozinho) → `expandLogic` → `expandFootnoteMarkers`
  (anuncia o marcador colado, a menos que `lêNotas == false`) →
  colapso de espaços/vírgulas duplicadas.
- **Decisões de verbalização (baseadas no levantamento em
  `docs/pesquisas/logica-leitura.md`):**
  - Quantificadores com variável e vírgula prosódica ("para todo
    x,"), modais □ ◇, turnos ⊢ ⊨ com pausa curta antes/depois,
    negações ⊬ ⊭, ASCII `|-` `|=` `->` `=>` `<->`.
  - Conjuntos ∈ ∉ ⊆ ∪ ∩ ∖ ∅ ℘, construtor `{x | φ}`/`{x : φ}`
    (`expandSetBuilder`: só entra o que tem marcador de "tal que"
    dentro das chaves; sem ele, `{…}` é agrupamento e vira
    silêncio; a chave que fecha é SILÊNCIO — pausa de fim de
    enumeração).
  - **Ferradura ⊃ por contexto** (`resolveHorseshoe`, janela de 12
    caracteres dos dois lados): perto de ∈/⊆/∪/∩/∅ é superconjunto;
    perto de ¬/∧/∨/⊢ (e por padrão) é condicional. Heurística por
    natureza — na dúvida o padrão histórico é "implica".
  - Gregas pelo nome (φ "fi", λ — cujo ponto vira PAUSA, nunca
    "dot" —, Γ…), iota ℩ ("o x tal que"), blackboard-bold, cantos de
    Quine (silêncio com pausa de menção), primos p′ ("p linha", só
    token isolado — "it's" e "O'Brien" não viram), §2 ("seção 2"),
    functores ("T de u, o" — só MAIÚSCULA sozinha), R_H ("R H").
  - **Silêncio deliberado** (nunca verbalizar em prosa comum):
    `[]`/`<>` como modal (colchete já vira pausa no `clean`; `<>`
    é o "diferente" ASCII), `x` de "3 x 4" como vezes (só × próprio
    lê "vezes"), barra solta fora de construtor (entre letras lê
    "ou", com guarda contra "and/or"), chave de agrupamento, `^`
    entre letras/dígitos (sobrescreve como espaço), `~` vs `∼`
    (no início ou após `)`/`,` é negação; entre termos, semelhança).
  - ⊥/⊤: "falso"/"verdadeiro" em PT (aula brasileira); EN mantém
    bottom/top.
- `expandFootnoteMarkers`: o marcador colado vira "nota de rodapé
  N"/"footnote N" (texto do catálogo `L`, fonte única nos dois
  idiomas). **Por que textual e não geométrico:** o `clean` já remove
  o sobrescrito Unicode antes de repartir as frases, então o que
  chega ao `forSpeech` é o dígito ASCII colado. Guardas fortes: só
  1–2 dígitos (nunca 4, para não morder anos 1500–2100 que
  `spellOutYears` trata), dígito seguinte não pode ser letra/dígito/
  ponto (protege "3.14", "3,14", "4.2.1", "7z"), ponto/vírgula
  exigem letra ou fecho antes (protegem "9 Oct", "Figura 7"); colado
  curto ("mp3") é sigla e fica como está. Com `lêNotas: false`, o
  marcador vira vírgula (pausa), sem anúncio.

## 8) `Sources/EdgeSpeak/WordAligner.swift` — karaokê palavra a palavra

`@MainActor final class WordAligner`. Alinha a sequência de palavras
**FALADAS** com a sequência de palavras do PDF e diz qual caixa
corresponde a cada palavra falada.

- **Por que alinhar e não procurar palavra a palavra:** a leitura em
  voz alta NUNCA tem a mesma sequência de palavras do PDF. Onde o
  PDF põe um símbolo, a voz põe uma frase — "∃uT (u,o)" vira "there
  exists u, such that, T of u" (11 palavras para 3 caixas). Procurar
  palavra a palavra obrigava as palavras de expansão a casar com
  alguma caixa, e como são palavras COMUNS ("and", "such", "there"),
  roubavam a caixa de uma palavra de prosa logo adiante: era o
  "amarelo pulando de lado a lado" que o dono viu.
- **Por que alinhamento global (Needleman–Wunsch) e não guloso:** o
  guloso resolve o caso comum mas quebra justamente onde o
  comprimento das sequências difere por construção. O global prefere
  deixar a palavra de expansão **SEM caixa** a distorcer o resto,
  porque distorcer custa mais caro.
- Custos: casar iguais = 0 **menos bônus de contexto** (±3 vizinhas
  iguais, até 3 por lado, só vizinha com letra ou dígito); pular =
  1; trocar (par diferente) = 3 — mais caro que pular porque trocar
  distorce a sequência. **Por que ±3 e não ±1:** a frase é lida
  contra as palavras do PARÁGRAFO inteiro e a frase seguinte pode
  repetir o mesmo bigrama; com ±1 o backtrace a partir do fim
  preferia a ocorrência tardia e o amarelo ia para a frase seguinte
  (caso medido no artigo de teste: "the laboratory" em duas frases).
  O bônus só vale para o par igual, então expansão continua sem
  caixa.
- Desempate do backtrace: empate vai para CASAR (mantém "the … the"
  na ocorrência certa), depois pular palavra falada (expansão),
  depois pular caixa do PDF.
- `normalizada(_:)`: minúsculas, só letras e dígitos (mesma regra
  do karaokê do painel e do casamento de tokens).
- **Cache por frase** (`caixa(frase:alvo:faladas:pdf:)`): o
  alinhamento é O(n·m) e o destaque tica a 10 Hz — recomputa só
  quando a frase ou as contagens mudam; repetir o pedido devolve a
  mesma caixa.
- `caixa(alinhado:alvo:pdf:)` devolve a caixa do alvo; alvo fora da
  lista devolve nil (nunca uma caixa vizinha inventada).

## 9) `Sources/EdgeSpeak/PhraseLocator.swift` — clique → frase

Ideia de navegação por frase inspirada no PDFVoice (MIT) — só a
ideia, algoritmo reescrito do zero (CREDITS.md). Contenção vence;
senão o retângulo mais próximo até `maxDistance = 40` pt; frases
sem `rects` são ignoradas; só a mesma página; margem devolve nil.
Distância euclidiana ponto→retângulo (0 quando dentro).

## 10) `Sources/EdgeSpeak/BundledEnv.swift` — ambiente Python embutido

`enum BundledEnv`. O app funciona num Mac virgem (só macOS 14+ arm64
+ rede), sem o Python do sistema nem os venvs do dono.

- `ensure(progress:)`: idempotente e **serializado** (`setupLock` —
  duas chamadas juntas preparam uma vez só; re-checa após esperar).
  Passos: probe `importsOK` (`-c "import edge_tts, fitz, piper"`)
  → cria `venv` a partir da **base embutida** (`Resources/pythonbase`
  no bundle; reserva de dev: `Build/staging`, `Resources`) →
  `ensurepip` se a base vier sem pip (completa DENTRO do venv, sem
  tocar na base) → `pip install --no-index --find-links <wheels>`
  (edge-tts, pymupdf, piper-tts — instalação SEM rede) → aplica
  `patch_edge_tts.py` no site-packages → verifica de novo. Erros em
  pt-BR para a UI (`NSError` com `NSLocalizedDescriptionKey`).
- `readyPython()`: caminho quente sem probe — vale quando `ensure`
  já passou nesta execução (`readyCache` sob `stateLock`) E o
  binário é executável.
- `pickPython(support:supportValid:legacy:)`: pura (a ordem do
  probe num lugar só, testável).
- `sitePackages(in:)`: pura no sistema de arquivos (testável com
  diretório fake); descobre `lib/python*/site-packages`.
- `runSync`: processo bloqueante com timeout (300/900/120 s por
  etapa), stderr em arquivo temporário (sem risco de deadlock de
  pipe), encerra ao estourar o prazo.
- **Por que o `ContentView` pré-aquece em `onAppear`**
  (`Task.detached(.background)`): quando o usuário pedir a leitura,
  o `ensure` já passou (ou roda então, com progresso no status).

## 11) `Sources/EdgeSpeak/CacheDisco.swift` — cache em disco da síntese

`enum CacheDisco`, sem estado. Guarda o áudio final (MP3 online, WAV
offline — a extensão segue o arquivo real; `lookup` aceita qualquer
um dos dois) + os segmentos globais, em `Caches/EdgeSpeak/<chave>/`.

```swift
static func key(text: String, voice: String, rate: EdgeTTS.Rate, lêNotas: Bool = true) -> String
static func lookup(key: String) -> Hit?          // áudio + segmentos, ou nil
static func store(key: String, audioURL: URL, segments: [EdgeTTS.Segment])
static func remove(key: String)                  // apaga a entrada inteira
```

- Chave: SHA-256 de `"v2|<voz>|<percent>|[sem-notas|]<texto>"`. O
  prefixo `v2` invalida o cache anterior ao karaokê (aqueles
  segmentos não têm `words`). `lêNotas` entra na chave (áudio com e
  sem notas é diferente); com o default, a matéria-prima é idêntica
  à de antes — nenhum cache antigo é invalidado.
- Poda automática a cada `store` (no máximo 1×/min, em
  `Task.detached(.background)`): saem entradas com mais de 30 dias e,
  acima de 2 GB, as mais antigas primeiro. **Nunca** toca na chave
  em uso nem em entradas gravadas há menos de 60 s (margem que
  protege a leitura corrente). Falha em silêncio — cache é
  otimização, não pode quebrar a leitura. `store` com falha apaga a
  pasta que começou a escrever.

## 12) `Sources/EdgeSpeak/L10n.swift` — catálogo de textos PT/EN

`enum L`. Tabelas compiladas (`pt`, `en`), sem `Package.swift` novo
nem dependência nova.

- `resolve(_:locale:args:tabelas:)`: cadeia de fallback — idioma
  pedido → PT → a própria chave (nunca vazio). Interpolação
  **posicional** (`{0}`, `{1}…`); marcador sem argumento passa
  direto; argumento a mais não quebra a frase. `tabelas` é
  parâmetro para testes cobrirem o fallback sem mexer no catálogo.
- **`AppSetting.languageKey` ("appLanguage") e `languageDefault`
  ("pt") moram AQUI** (extensão de `AppSetting`, fim do arquivo),
  de propósito: a fase 1 do L10n não editava arquivo existente. É
  a única chave de preferência fora de `AppSettings.swift` — quem
  procurar todas as chaves em `AppSetting` deve lembrar desta.
- O `SpeechController` guarda `statusKey`+`statusArgs` e
  `refreshLocale` re-resolve na troca de idioma (o idioma é
  `@AppStorage` lido por `ContentView`, `PlayerBar`, `SettingsView`
  e pelo próprio controller via `UserDefaults`).
- Completude travada por testes: chaves iguais nos dois idiomas,
  marcadores `{n}` com mesma aridade, nenhum texto vazio, nenhum
  `\(` de interpolação Swift no catálogo.

## 13) `Sources/EdgeSpeak/AppSettings.swift` — preferências

`enum AppSetting` centraliza chaves e padrões, lidas por `@AppStorage`
tanto na janela de Ajustes quanto na `ContentView` — sempre a mesma
chave e o mesmo padrão, nunca uma string repetida à mão (salvo
`languageKey`, ver seção 12).

```swift
static let voiceKey = "voice"                // padrão "en-US-AndrewNeural"
static let rateKey = "readingRatePercent"    // padrão 0 (o `percent` de EdgeTTS.Rate)
static let followKey = "followReading"       // padrão true
static let integralKey = "integralText"      // padrão false
static let footnoteKey = "readFootnotes"     // padrão true (notas ligadas)
static let fontKey = "fontSize"              // padrão 17; limites 12…42

static let englishVoices / portugueseVoices   // catálogo online (verificado 2026-10-10)
static let voiceLabels: [String: String]      // "Nome (país, gênero)"
static func label(for voice: String) -> String  // offline via PiperTTS
static func isKnown(_ voice: String) -> Bool    // a voz guardada ainda existe?
```

- Limites de fonte documentados: abaixo de 12 o texto fica ilegível;
  acima de 42 a janela mínima deixa de caber.
- Migração na `ContentView`: "pt-BR-ThalitaNeural" (só havia a
  multilingual) é reescrita para "pt-BR-ThalitaMultilingualNeural";
  voz órfã no catálogo cai no padrão — sem isso o `Picker` ficava
  sem item selecionado e a síntese falharia.

## 14) UI — `EdgeSpeakApp.swift`, `ContentView.swift`, `PlayerBar.swift`, `PDFDocumentView.swift`, `ClickableTextView.swift`, `SettingsView.swift`

`EdgeSpeakApp`: `WindowGroup("EdgeSpeak") { ContentView() }` com
`AppDelegate` (abre PDFs/texto por duplo-clique ou arraste, posta
`.edgeSpeakOpenFile`) mais a cena `Settings { SettingsView() }`
(⌘,). A `ContentView` também aceita argumento de linha de comando e
arraste sobre a janela (`.onDrop`).

**Decisão de raiz — por que a janela é um `Container` de tipo
fixo:** aplicar `.toolbar` direto ao conteúdo que troca de forma
(vazio → editor → PDF → painel) recria a raiz da vista e a barra de
ferramentas se perdia na transição — medido: sem PDF a barra
aparecia (7 botões na árvore de acessibilidade), abrindo um PDF ela
sumia. O `Container` (struct privada, tipo nunca trocado) dá à
janela uma âncora de identidade estável; a barra sobrevive.

`ContentView` (layout B2, sem NavigationSplitView):

```
Toolbar (Abrir | Voz | menu Opções)
conteúdo (PDFDocumentView quando há PDF, senão editor ou painel de texto clicável)
PlayerBar  ← flutuante, sempre visível
```

- O menu Opções traz "Seguir leitura" (só com PDF), fonte (±2,
  padrão; ⌘-, ⌘+, ⌘0), "Gerar leitura nova" e "Ajustes…"
  (`SettingsLink`). Ritmo, modo de texto e notas moram na janela de
  Ajustes (seção 15), não no menu.
- **Carregamento de arquivo por geração (`loadGeneration`):** a
  extração do PDF roda em `Task.detached` (o processo Python espera
  com `Thread.sleep` até 180 s — na main a UI congelava), com
  escopo de segurança (`startAccessingSecurityScopedResource`) e
  descarte do resultado atrasado se outro arquivo passou na frente.
  Antes de trocar, `cancelSynthesis` + `stopPlayback` — o
  `stopPlayback` sozinho deixa a tarefa de síntese viva e ela
  voltaria a enfileirar áudio do documento velho.
- Teclado por monitor `NSEvent.keyDown` (o `PDFView` é AppKit e
  engole atalhos do SwiftUI): **Enter** = play/pausa sempre;
  **Espaço** só fora do editor/PDF e **nunca durante `isBusy`**
  (durante a síntese o espaço é ignorado — antes ele cancelava e
  reiniciava a síntese, seguindo a regra do botão desabilitado);
  **⌥← / ⌥→** = ±15 s. Modificadores são limpos de
  `.capsLock/.numericPad/.function` antes da comparação. Espaço/⌥-
  setas são guardados por tipo de `firstResponder` e por
  `!controller.isBusy`.
- Trilho, ±15 s e ⌥-setas chamam `onTransport` (barra) → incrementa
  `revealToken` (a `ContentView` leva o PDF ao trecho mesmo com o
  "Seguir leitura" desligado — navegação explícita).
- `.onChange(of: integralMode)` → `handleIntegralModeChange()`:
  descarta a transcrição corrente (`discardTranscription`) e, se
  havia leitura em curso, reinicia com a lista nova; sem leitura, só
  descarta (o próximo play já usa o modo novo). Não há laço: nem o
  descarte nem o play mudam `integralMode`.
- **Destaque do painel por índice global** (não por busca de texto):
  frases repetidas destacariam a ocorrência errada sem isso. O
  `AttributedString` usa **escopo AppKit de propósito**
  (`appKit.foregroundColor`/`appKit.backgroundColor`): atributos em
  escopo SwiftUI não têm par no `NSAttributedString` — o painel os
  descartava e nada destacava. Base em `labelColor` (escuro/claro).
  Karaokê palavra a palavra no painel: casamento por texto com cursor
  sequencial (o texto falado expande anos/abreviaturas — índice
  direto caía na palavra errada); palavra achada leva negrito +
  fundo amarelo (α 0,75) + texto escuro — o amarelo do PDF, não o
  azul do sistema: unifica o karaokê nas duas vistas (divergência
  apontada pela auditoria; o escuro sobre amarelo lê bem nos dois
  temas).
- **Cache do texto atribuído por (frase, palavra):** a vista é
  reavaliada a cada tique do progresso; reconstruir 45k letras do
  zero em cada um saturava a main. Fora da leitura calcula direto;
  durante a leitura escreve o cache assíncrono e devolve o valor.
- `currentWordRect` (karaokê do PDF): só com PDF, só voz online
  (`!PiperTTS.isOfflineVoice(controller.voiceInUse)`), índices
  válidos e caixa casada via `WordAligner` (por texto normalizado,
  nunca por índice) — palavra não achada vira ausência de realce,
  nunca destaque errado.
- `statusBanner`: faixa transitória (some em 4 s), permanente
  durante a síntese (é progresso vivo), com porcentagem da síntese,
  selo "sem destaque" (áudio sem segmentos) e selo de voz offline.
- **`clickToPlay`:** o token de revelação leva o PDF ao trecho
  clicado na hora; sem áudio nem síntese em curso, sintetiza A
  PARTIR da frase clicada (`Array(lista[pos...])`) e tenta o pulo
  (o controller guarda o pendente e retenta a cada fatia).
- O estado de `wordAligner` é `@State` para sobreviver aos ciclos de
  avaliação da vista — o amarelo não pode recomeçar do zero a cada
  tique.

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

- Botão central sempre `play.fill`/`pause.fill` (nunca `hourglass`):
  durante a síntese ele fica desabilitado (evita segundo clique que
  cancelaria e reiniciaria) mas mostra play, em vez de parecer
  travado. `.disabled(!canPause && (!canPlay || controller.isBusy))`.
- Botão esquerdo é **cancelar** a síntese (⌘.) durante `isBusy`,
  **parar** a leitura quando há áudio.
- Trilho: `dragValue` suspende o ponteiro durante o arrasto e é
  **devolvido a nil ao soltar** (`DragGesture.onEnded`) — sem isso o
  valor local ficava preso, `scrubPosition` (que prefere o ponteiro
  ao player) congelava o tempo e o trilho pelo resto da sessão.
- Volume 0…1 (aplicado ao player atual e aos seguintes, sem mexer no
  volume do sistema); exportação só com áudio e sem síntese.

`PDFDocumentView` — `NSViewRepresentable` sobre PDFKit:

```swift
var document: PDFDocument
var page: Int? = nil          // página da frase; nil limpa
var rects: [CGRect] = []      // caixas das linhas da frase
var wordRect: CGRect? = nil   // caixa da palavra em leitura; nil limpa
var follow: Bool = true
var revealToken: Int = 0
var onUserScroll: (() -> Void)? = nil  // rolagem do usuário → o dono desliga o seguimento
var onPageClick: ((Int, CGPoint) -> Void)?
```

- **Destaque da frase (azul):** uma `PDFAnnotation` `.highlight` por
  caixa (cor de acento translúcida, α 0.28), adicionada à página da
  frase — geométrico, sem busca por texto (o filtrado nunca é
  idêntico ao do PDF); desenhadas pela página, rolam junto com o
  PDF. Deduplicação própria pela chave `key(page:rects:)` (página +
  caixas), **separada do destaque da palavra**: a troca de palavra só
  mexe na anotação amarela, e os tiques de 10 Hz não recriam nada
  (recriar a cada palavra fazia o parágrafo inteiro piscar).
  Removidas ao trocar de frase ou limpar (nunca anotação órfã — o
  app nunca salva o documento). Troca de documento zera todo o
  estado do coordenador.
- **Destaque da palavra (amarelo):** `PDFAnnotation` (`.highlight`,
  `systemYellow` α 0.55) com estado próprio no `Coordinator`
  (`wordAnnotation`/`wordPage`), **reaproveitada** quando página e
  caixa são as mesmas (evita piscar quando só o token mudou); trocada
  só quando a caixa ou a página mudam; removida ao trocar de palavra
  ou limpar.
- **Rolagem da palavra:** `shouldScrollToWord` só rola quando o
  follow está ligado E a palavra está FORA da área visível — rolar a
  cada palavra engasga a fala.
- **Rolagem do usuário:** o `Coordinator` observa os limites do
  `NSClipView` interno do `PDFView` (encontrado em profundidade — o
  PDFKit não o expõe nesta versão do SDK) e avisa `onUserScroll`
  somente quando o seguimento está ligado, passou a janela de
  silêncio de 0,5 s após um `go(to:)` programático
  (`markProgrammaticScroll`), a origem mudou (>0,5 pt) e nem o
  tamanho nem a escala mudaram (zoom e redimensionamento mexem em
  tamanho/escala, nunca só na origem — decisão pura
  `isUserScroll`, testada). O dono (`ContentView`) desliga o
  "Seguir leitura" no aviso — a rolagem manual sempre vence a
  automática.
- **Clique no PDF (`ClickablePDFView`):** guarda o ponto no
  `mouseDown` e só reporta no `mouseUp` com deslocamento <4 pt —
  distingue clique de arrasto/seleção; o resto segue o PDFKit.
  `onPageClick` devolve (índice da página 0-based, ponto em
  coordenadas de página).

`ClickableTextView` — `NSViewRepresentable` sobre `NSTextView`:

- **Por que `NSTextView` e não `Text` do SwiftUI:** o `Text` renderiza
  o `AttributedString` mas devolve apenas "clicaram no texto", sem
  dizer ONDE; para pular a leitura até a frase é necessário o índice
  do caractere sob o cursor, e só o TextKit fornece isso de forma
  confiável (`glyphIndex(for:in:)` → `characterIndexForGlyph(at:)`,
  com conversão de coordenadas da janela para o container, que tem
  inset próprio).
- **Por que `NSScrollView` em volta:** o `NSTextView` não tem tamanho
  intrínseco; dar a ele a altura do texto inteiro faz o painel
  engolir a janela e esconder o PDF (defeito medido). Com rolagem
  interna o painel tem altura limitada (140…300 pt).
- `pointSize` é `CGFloat` (não `Font`): `Font` é invólucro opaco e
  o `NSTextView` precisa do valor em ponto.
- **Só o clique, não o arrasto (`ClickReportingTextView`):** o
  `mouseDown` guarda o ponto da janela e o caractere (conversão
  janela→view, independente da rolagem); o `mouseUp` só reporta
  com deslocamento <4 pt (`hypot`) — sem a guarda, arrastar para
  selecionar disparava o salto no ponto da pressão (achado da
  auditoria; o PDF já filtrava o mesmo limiar no
  `ClickablePDFView`).
- **Teleprompter:** `scrollTo` (UTF-16, como o TextKit conta) rola
  até a frase lida quando ela muda — não a cada palavra, para não
  tremer; com `follow` desligado, não toca na rolagem do usuário.

`SettingsView` — cena `Settings` (⌘,), abas **Leitura** (voz, ritmo,
seguimento, idioma), **Texto** (tamanho da fonte, "Texto integral",
"Ler notas de rodapé") e **Avançado** (vazia — pendência, seção
Pendências). Todo controle grava via `@AppStorage` nas chaves de
`AppSetting` — as mesmas que o `ContentView` usa. Nota honesta: a
cena de Ajustes não enxerga o controller da janela principal, então
não há como desabilitar controles durante a síntese (a cadência vale
para a próxima síntese de todo modo).

## 15) Ferramentas (`Tools/`) — fronteira 1:1 com o Swift

- **`pdf_extract.py`** (PyMuPDF, AGPL) — `--pdf/--out`; JSON
  `pages[].lines[]` com `text`, `box` e `words[]` (uma entrada por
  palavra, ordem de leitura, coordenadas **convertidas para PDFKit:
  `[x0, h-y1, x1, h-y0]`**). Agrupa por (bloco, linha) do próprio
  PyMuPDF; a ordem de leitura final é do Swift (XY-cut). Fronteira:
  `PdfWords.lines` decodifica exatamente este JSON (campo `words`
  opcional para compatibilidade).
- **`synth_timing.py`** — devolve o áudio e os tempos por frase.
  Modo preferido `--lines-file`: o app passa uma frase de fala por
  linha e cada linha vira EXATAMENTE um segmento, na ordem
  (`_group_words_lines`; linha vazia vira trecho de duração zero,
  nunca é descartada — descartá-la deslocaria as seguintes). As
  palavras caem na frase por **busca sequencial no texto
  reconstruído** (`"\n".join(linhas)`), porque os eventos de palavra
  NÃO trazem pontuação (medido: `world`, não `world.`). Duração da
  frase encosta no início da frase seguinte (como os
  SentenceBoundary do modo antigo) — o vão de silêncio entre frases
  (0,3–0,5 s, medido) entra na duração, senão o highlight piscava
  entre frases. Sem `--lines-file`, vale o modo antigo por regex
  (`_split_sentences`/`_group_words`), só para compatibilidade —
  **restrição: entrada sem pontuação terminal duplicada**. Passe
  único com `boundary="WordBoundary"` (a biblioteca só emite UM tipo
  de fronteira por síntese). Tempos em segundos (unidade da
  biblioteca: 100 ns). Fronteira: `EdgeTTS` escreve
  `chunk-%04d.txt` + `chunk-%04d.lines.txt` e lê o JSON
  `{"segments": [...]}` com `loadSegments`.
- **`piper_synth.py`** — processo persistente: carrega a voz UMA
  vez, avisa `{"ready": true}` e atende pedidos JSON por linha de
  stdin (`{"id", "text", "wav", "length_scale"}`), respondendo
  `{"id", "duration"}` (lida do cabeçalho do WAV gerado, 16-bit
  mono) ou `{"id", "error"}` — erro de um pedido não mata o processo.
  Fronteira: `PiperTTS.PiperSession` fala exatamente este protocolo
  (casamento por `id`, prazos de 300 s).
- **`patch_edge_tts.py`** — remendo aplicado por `BundledEnv.ensure`
  no site-packages do venv embutido (idempotente: segunda passada
  sai 0 sem mudar um byte; testado com diretório fake):
  1. `constants.py`: `WSS_URL` aponta para o endpoint v2
     (`wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1`
     com `Ocp-Apim-Subscription-Key`) — versões antigas usavam
     `speech.platform.bing.com`, que a Microsoft passou a recusar
     (403).
  2. `drm.py`: `parse_rfc2616_date` usa
     `email.utils.parsedate_to_datetime` — `strptime` com
     `%a`/`%b` só entende inglês e quebra com o sistema em pt-BR.
  Erros em pt-BR no stderr, saída 1 (falha) ou 2 (uso).

## Regras transversais

- **Sem SSML** (sem evidência de suporte no serviço); a pausa entre
  parágrafos é feita com `\n` na junção do texto enviado ao motor.
- Cache em disco por `(texto completo + voz + cadência + notas)`; a
  chave muda quando o texto muda (por isso a marca de parágrafo no
  `fullText` invalida uma vez). `CacheDisco.remove(key:)` apaga a
  entrada (usado ao descartar transcrição).
- Fronteira EdgeTTS ↔ `synth_timing.py` em 1:1 por construção
  (`--lines-file`): uma linha por frase, um segmento por linha, na
  ordem.
- Destaque palavra a palavra: só vozes online.
- Fonte da verdade do estado de reprodução: o `StreamingPlayer`.
- **Índice de frase é propriedade, não posição** — toda reordenação
  (notas de rodapé, filtros) preserva `Phrase.index`.
- Cancelamento/troca de sessão por **geração**, em todas as camadas
  (`synthGeneration`, `playbackGeneration`+`currentGeneration`,
  `CancelFlag` por instância, `loadGeneration`).
- Processos filhos são encerrados pelo **nome do script**, nunca por
  "python" solto.

## Invariantes — o que outro agente NÃO pode quebrar

1. Uma frase nunca é cortada no meio: `buildChunks` agrupa frases
   inteiras; a fronteira 1:1 com `--lines-file` depende disso.
2. O texto enviado ao motor nunca duplica pontuação terminal
   ("Frase..") — o `_SENT_END` do modo sem `--lines-file` criaria
   frase-extra e desalinharia o emparelhamento; `\n` de parágrafo
   não casa o regex.
3. `Phrase.index` é propriedade: `resolveFootnotes` e os filtros
   movem/removem frases SEM reindexar. Destaque, salto e karaokê
   casam por índice global.
4. `StreamingPlayer` é a única fonte da verdade de
   `isPlaying`/`isPaused`/`isFinished`/`isStarved`/elapsed; o
   controller só espelha. Nunca publicar estado de reprodução só no
   controller.
5. Toda escrita de estado de sessão confere a geração antes:
   `gen == synthGeneration` (síntese), `currentGeneration ==
   playbackGeneration` (delegate), `loadGeneration` (importação).
   Gereação só aumenta; nunca zerar.
6. Durações são medidas fora da main e preenchidas com guarda de
   geração/URL/índice; `playChunk` completa apenas o próprio índice.
   Nunca medir duração na thread principal.
7. O salto por frase vai DIRETO à fatia que contém a frase, com
   ponto `seg.start` local — nunca converter frase→tempo global com
   offsets ainda não medidos.
8. Karaokê por palavra só com voz online; o casamento é por texto
   normalizado (WordAligner no PDF, cursor no painel) — nunca por
   índice entre sequências de comprimentos diferentes.
9. Palavra de expansão de fórmula fica SEM caixa (alinhamento
   global, custo de troca 3 > 1 de pulo). Nunca forçar o casamento
   de "and"/"such"/"there" com caixa de prosa.
10. Anotações no PDF são geométricas (caixas do extrator), nunca por
    busca de texto; deduplicação por chave própria (frase: página+
    caixas; palavra: página+caixa) e remoção ao trocar/limpar —
    nunca deixar anotação órfã no documento (o app não salva).
11. Rolagem manual sempre vence: o detector só avisa com follow
    ligado, fora da janela de 0,5 s do `go(to:)`, com origem
    mudada e tamanho/escala iguais. Zoom e redimensionamento nunca
    desligam o seguimento.
12. A raiz da janela é o `Container` de tipo fixo; `.toolbar` nunca
    é aplicado direto ao conteúdo que troca de forma (a barra some —
    defeito medido).
13. A chave de cache é SHA-256 de `"v2|<voz>|<percent>|[sem-notas|]
    <texto>"` com `\n` nas fronteiras de parágrafo do `fullText`.
    Trocar o prefixo ou a fórmula de junção invalida todo o cache de
    uma vez — só se fez com o `v2`; depois, nunca sem motivo.
14. `CacheDisco` falha em silêncio e nunca toca na chave corrente
    nem em entradas com <60 s; poda no máximo 1×/min em background.
15. Piper: nunca deslocar offsets à mão nem inserir WAVs de silêncio
    — o vão do `\n` de parágrafo entra na duração medida do WAV.
16. `BundledEnv.ensure` é idempotente e serializado; o venv só nasce
    da base embutida, e o pip instala `--no-index` a partir dos
    wheels embutidos. Nunca tocar no Python do sistema.
17. Processos de síntese são encerrados pelo nome do script
    (`synth_timing.py`, `piper_synth.py`), nunca por "python" solto.
18. `forSpeech` expande para a fala; `clean`/o texto exibido nunca
    muda (contrato travado por `falaNaoAlteraExibicao`).
19. Espaço e ⌥-setas são ignorados durante `isBusy` (regra do botão
    desabilitado); Enter sempre alterna play/pausa.
20. O status do controller guarda chave+args para re-resolver na
    troca de idioma; progresso cru de motor (`recebeProgresso`)
    limpa a chave para a troca não sobrescrevê-lo.
21. Preferências só via constantes (`AppSetting` + a extensão em
    `L10n`) — nunca repetir a string da chave `@AppStorage` à mão
    em dois arquivos.
22. Clique no PDF/texto sem áudio sintetiza A PARTIR da frase
    clicada (`Array(lista[pos...])`), não do início; o pulo pendente
    é retentado a cada fatia e morre com a síntese.
23. Troca de modo integral/filtrado (e "Gerar leitura nova")
    descarta a transcrição (`discardTranscription`) antes de qualquer
    replay — sem isso o play reaproveita áudio antigo pela chave.
24. O destaque do painel publica só quando o valor muda (45k letras
    reconstruídas 10×/s saturam a main), e o texto atribuído é
    cacheado por (frase, palavra) durante a leitura.

## Testes (`Tests/EdgeSpeakTests/`) — o que cada suíte trava

Suítes em swift-testing (`@Test`/`#expect`). `swift test` reporta
**88 testes em 10 suítes** (conferido em 2026-10-13 por contagem de
`@Test`; era 80/9 antes das fases de notas de rodapé, L10n e
alinhamento):

- `ReadAloudFilterTests` (32) — `forSpeech` por símbolo e idioma
  (texto exato EN+PT: quantificadores, modais, turnos, conjuntos,
  gregas, iota, cantos de Quine, primos, ASCII de comparação,
  ⊤/⊥ em português, construtor de conjuntos, ferradura por
  contexto), não-regressão de prosa comum ("3 x 4", datas,
  "movem-se"), o contrato fala-não-altera-exibição, e o marcador
  de nota colado (anuncia, não morde anos/decimais/figuras).
  Pendência própria declarada: a extração de PDF pode entregar
  símbolos de outro jeito (entidade, LaTeX, imagem); sem PDF de
  fórmulas medido, os testes cobrem a função pura.
- `WordAlignerTests` (11) — expansões não roubam caixa (caso do
  artigo: 11 palavras faladas para 3 caixas), repetidas com
  vizinhas diferentes vão cada uma à sua ocorrência, o caso real do
  artigo (80 caixas; "the laboratory" na caixa 52–53, não 63–64),
  a frase seguinte casa na SUA ocorrência (54–79), expansão antes
  de repetida continua sem caixa, cache por tique estável,
  normalização ignora pontuação/caixa/hífen.
- `BundledEnvTests` (8) — ordem de probe do Python, nomes de voz do
  Piper, site-packages em venv fake e o remendo idempotente do
  edge-tts (endpoint v2 entra, parse imune a idioma entra, segunda
  passada não muda um byte, sem pacote falha legível).
- `L10nResolverTests` (8) — padrão PT, EN quando há chave,
  interpolação posicional (um e vários args), fallback para PT,
  chave desconhecida devolve a chave, argumento extra não quebra,
  chave/default do idioma.
- `FootnoteTests` (8) — corpo vai para após o marcador (mesma
  página), nota de fim liga ao marcador anterior mais próximo,
  número solto cai só com página, sem marcador não move nem tira
  número, índices preservados, opção desligada cala o marcador,
  opção ligada anuncia nos dois idiomas, default lê notas.
- `PDFFollowTests` (5) — detector de rolagem do usuário: rolagem
  programática, zoom e redimensionamento não desligam o seguimento;
  palavra visível não rola.
- `StreamingProofTests` (5) — salto por frase SEM durações medidas
  (WAVs sintéticos com offsets zerados: vai direto à fatia 1),
  entrega em ordem sob chegada fora de ordem (`OrderedPublisher`),
  fatia ruim não trava (`isStarved`, não `isFinished`), `play()`
  retoma com a fila esvaziada, tempos de palavra até a UI
  (`mapSegments` preserva palavras e índices globais).
- `L10nCompletenessTests` (5) — chaves iguais nos dois idiomas,
  nenhum texto vazio, marcadores `{n}` com mesma aridade, nenhum
  `\(` no catálogo, amostra das chaves da fase 2 existe nos dois.
- `PdfClickLocatorTests` (3) — contenção vence, proximidade até
  40 pt, margem devolve nil (e frase sem rects é ignorada).
- `TranscriptionResetTests` (3) — modos integral/filtrado geram
  textos e chaves de cache diferentes, `CacheDisco.remove` apaga do
  cache, `discardTranscription` limpa o estado.

---

### Camadas
- Scaffold (este repo): `Package.swift`, `build-app.sh`, `README.md`,
  `CREDITS.md`, este `INTERFACE.md`, `Tools/`, `Resources/` (ícone).
- Fonte: os arquivos listados acima. O orquestrador define os
  contratos de fronteira; cada subagente toca arquivos disjuntos; a
  integração é reverificada de forma independente.
- **O que nunca entra no repositório** (`.gitignore`): `.build/`,
  `Build/` (staging: base Python, wheels, vozes — ~490 MB),
  `EdgeSpeak.app/`, `DerivedData/`, `.swiftpm/`, `.venv/`, `venv/`,
  `__pycache__/`, `*.pyc`, `.DS_Store`, `.scratch/`,
  `NOTAS_SESSAO.md`, `PROXIMA_SESSAO.md`, `*.log`, `*.xcuserstate`,
  `xcuserdata/`, `.idea/`, `.vscode/`.

## Pendências (com o estado da prova)

- **Aba "Avançado" dos Ajustes sem itens** ("Nenhuma opção avançada
  disponível no momento"): o comentário no código cita limpeza de
  cache, mas `CacheDisco.remove(key:)` já existe e é testada — falta
  só o item de UI em `SettingsView.advancedTab`.
- **Primeiros segundos de áudio sem destaque no PDF:** reprodutível
  (a fatia toca antes de o destaque assentar); **causa ainda não
  isolada** — não há hipótese confirmada. Aberta.
- **Corpos de nota de rodapé em PDFs cuja camada de texto não os
  traz** (como o artigo de teste): o pipeline de ligação
  marcador↔corpo está pronto e coberto por `FootnoteTests` com
  listas sintéticas, mas depende do que o extrator encontrar; sem
  corpo no PDF, só o marcador é anunciado. Melhoria mapeada:
  detecção geométrica do marcador (caixa de superscript pequeno e
  elevado em `Phrase.WordBox`) — hoje a ligação é textual
  (`expandFootnoteMarkers`), que não distingue "argumento.7" de
  "mp3" além das guardas de regex.
- `ReadAloudFilterTests` declara pendência própria: a extração de
  PDF pode entregar símbolos lógicos de outro jeito (entidade,
  LaTeX, imagem); sem PDF de fórmulas medido, os testes cobrem a
  função pura.
- Caminhos de melhoria pesquisados, sem integração (ver
  `docs/pesquisas/oss-mapa.md`): Montreal Forced Aligner (MIT) para
  karaokê offline com Piper; AVAudioPlayerNode (nativo) para
  concatenação gapless sem sonda de duração; pdfminer.six (MIT) como
  plano B se o AGPL do PyMuPDF for bloqueador ao abrir o app.
