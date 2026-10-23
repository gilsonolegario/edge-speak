# Especificação — Destaques do usuário (PDF) — 2026-10-17

Especificação executável para implementação. Leitura prévia obrigatória:
`.scratch/feat-destaques/mapa.md` e `.scratch/feat-destaques/reuso.md` (reconhecimentos
de 2026-10-17; os `arquivo:linha` do mapa são a fonte dos números citados aqui).
Toda afirmação sobre o código existente é FATO verificado nelas ou leitura direta
desta passada; decisões do arquiteto estão marcadas [OPINIÃO-ESPEC].

**Garantia central, inegociável:** a interação de leitura não piora. Clique curto pula
a leitura, espaço alterna, setas e ⌥←/⌥→ mantêm função, rolagem e zoom continuam
nativos, e o realce de leitura (azul por frase α 0,28 — `PDFDocumentView.swift:354`;
amarelo por palavra α 0,55 — `:410`) segue igual e visualmente distinto do destaque
do usuário. Todo passo de implementação abaixo é medido contra essa garantia.

## 0. Escopo e não-escopo

Escopo da fase 1: destaque do usuário **somente no PDF** (PDFKit), persistido em
sidecar, modo explícito, remoção por menu de contexto, desfazer, exportação com
destaques embutidos.

Fora do escopo (fase 2 ou nunca):
- Destaque no painel de texto (`ClickableTextView` sobre `NSTextView`): o caminho
  "seleção→caixas" do painel não existe (mapa §9.7) e envolve mapear `NSRange`
  para caixas que o PDF não controla; fica para fase 2.
- Cores múltiplas, nota escrita no destaque, painel de listagem, busca em
  destaques, migração de destaques quando o PDF muda de conteúdo (re-ancoragem
  por texto), sincronização entre máquinas, páginas sem texto (imagem/OCR; não
  há seleção), destaques geométricos sem texto (triângulo/círculo).
- Anotações pré-existentes de terceiros no PDF: ficam intocadas e não são
  listadas nem removidas pelo app.

## 1. Modelo de dados e chave do sidecar

Novo arquivo-fonte: `Sources/EdgeSpeak/HighlightStore.swift` (modelo puro) e
`Sources/EdgeSpeak/HighlightDiskStore.swift` (disco). Nada disso importa UI.

```
struct StoredHighlight: Codable, Equatable {
    let id: String          // UUID string, estável no tempo
    let page: Int           // 0-based, page space
    let quads: [[CGPoint]]  // um por linha, 4 vértices cada (ver §3)
    let text: String        // texto literal da seleção (para revisão humana)
    let colorSlug: String   // fase 1: sempre "magenta" (campo já na versão 1)
    let createdAt: Date     // ISO-8601, fuso do sistema, codificado como Date
}
struct HighlightDocument: Codable {
    let formatVersion: Int              // 1
    let fingerprint: DocumentFingerprint
    let updatedAt: Date
    let highlights: [StoredHighlight]   // ordem: criação
}
struct DocumentFingerprint: Codable {
    let contentSHA256: String   // chave de associação (ver baixo)
    let byteCount: Int
    let lastKnownName: String   // só para depuração e lista de órfãos
    let lastKnownPath: String   // idem
    let bookmarkData: String    // base64 do bookmark do arquivo, opcional (ver baixo)
}
```

**Chave do sidecar — decisão [OPINIÃO-ESPEC]:** a associação documento↔sidecar é
o **SHA-256 do conteúdo completo do arquivo**, como nome do arquivo e como campo
`fingerprint.contentSHA256`. Calculado uma vez na abertura, em fila de fundo
(streaming, `CryptoKit` — precedente: `DiskCache.key` já usa `SHA256`,
`DiskCache.swift:23-31`). Custos e consequências declarados:
- PDF movido ou renomeado → mesmo hash → os destaques acompanham. (Impedimento
  técnico nulo: hash de 5–20 MB custa dezenas de ms, uma vez por abertura.)
- PDF editado por fora → **hash diferente → novo namespace vazio**. Os destaques
  antigos ficam dormentes no arquivo antigo e **nunca** são pintados sobre o
  conteúdo novo — mesma política do karaokê ("nunca um destaque errado",
  `INTERFACE.md`). Trade-off consciente: destaques "somem" se o usuário trocar a
  versão do PDF. Re-ancoragem por texto (`WordAligner`, `PhraseLocator`) é fase 2.
- Não se usa a chave do `ReadingPositionStore` (`"<documentID>##<voice>"`,
  `AppSettings.swift:131-133`, chaveada por `url.absoluteString`): posição é por
  coisa que o app controla por voz; destaque é pelo conteúdo físico. A
  divergência é intencional e documentada.
- `bookmarkData` entra no sidecar **apenas como pista de localização** (para
  podar órfãos e para a futura fase 2 de JOIN de versões). Nunca é chave.

**Se o PDF mudar:** abre-se sem destaques; nada é pintado; nada é perguntado
(fase 1). **Se o PDF sumir:** o sidecar fica; dois destinos: (a) órfãos com
`lastKnownPath` sem arquivo, removidos após 180 dias na poda (§2); (b) a ação
"abrir" reaproveita o sidecar no instante em que outro arquivo com o MESMO hash
aparecer de novo.

**Se o PDF for trocado enquanto aberto:** a sessão não revalida; a próxima abertura
re-hash e decide. Múltiplas abas/janelas do mesmo documento: gravação coordena
na fila principal (`DispatchQueue.main`); última gravação vence — único escritor
é este app, sem `NSFileCoordinator` (não é container iCloud; risco §9).

## 2. Formato do arquivo, local, escrita e leitura

**Local:** `~/Library/Application Support/EdgeSpeak/Highlights/<sha256>.json`
(... .json.tmp durante a gravação). Motivo (reuso §b): o `.cachesDirectory` que o
app usa (`DiskCache.swift:34`) é apagável pelo sistema e exclui dados do usuário.

**Escrita:** serialização JSON em `Data` (`.withoutEscapingSlashes`,
`.sortedKeys` para diffs legíveis), depois `data.write(to: url,
options: [.atomic])` — o mesmo uso de `DiskCache.swift:95`. Escrita sempre
após cada mutação
(criar/apagar/desfazer/refazer), na fila principal, silenciosa em falha
(precedente do cache: "fails silently", `DiskCache.swift:97`) — gravação que
falha não pode interromper a leitura. Throttle de 1 s para mutations em
sequência; na troca de documento ou no fechamento, flush imediato.

**Leitura tolerante (cada caso testável sem app):**
- `formatVersion` ausente ou não numérico → tratar como vazio, **não apagar o
  arquivo** (futuro migrador decide).
- `formatVersion > 1` → ignorar (não decodificar campos futuros); mesma política.
- JSON inválido, UTF-8 inválido, arquivo vazio, arquivo parcial (**garantia
  da escrita atômica**: `.tmp`+rename nunca deixa parcial) → `[]` (vazio).
- Campo de destaque com `quads` vazio, `page` negativo, `id` repetido,
  coordenada não-numérica (NaN/inf) ou coordenada nula → o destaque individual
  cai, os outros entram; função pura de validação no §7.
- Falha de disco na gravação → log `os_log` e continua; nenhum `throw` sobe à UI.
**Nunca um destaque derruba ou trava a leitura.**

**Poda de órfãos:** função pura `pruneDecision(lastKnownPath:bookmark:ageInDays:now:)
-> Bool` — apaga sidecar quando o documento-alvo não abriu há 180 dias e o
`lastKnownPath`/bookmark não resolve arquivo nenhum (fase 1: avaliação só na
abertura, nunca bloqueando).

## 3. Criação: seleção → anotações

**Disparo:** modo destacar ativo (§4). No `mouseUp` com deslocamento ≥ 4 pt
(a seleção nativa do PDFKit termina dentro do `super.mouseUp`,
`PDFDocumentView.swift:60-70`), se `highlightMode` e
`view.currentSelection` não vazio → aplicar.

**Split (uma seleção = N linhas):** a conversão usa o caminho canônico
(`PDFTextExtractor.swift:122-124` já o faz com outra origem de seleção):
`selection.selectionsByLine()` → para cada linha, `lineSelection.bounds(for:
pdfPage)` (FATO do reuso: coordenadas de **page space**, independentes de zoom
e de `scaleFactor` — zoom não entra). Uma seleção que cruza páginas: agrupar
linhas por `document.index(for:)` de cada `lineSelection.pages.first` — uma
seleção multi-página vira **um registro `StoredHighlight` por página**.

**Anotação por página:** UMA `PDFAnnotation(.highlight, bounds: union das
caixas da página)`, com `quadrilateralPoints` preenchido: **4 pontos por caixa
de linha**, ordem topo-esquerda → topo-direita → baixo-esquerda → baixo-direita
(prática de fato Adobe; a norma diverge — reuso §a, issue 743; para highlight a
ordem importa menos, mas segue-se a ordem da prática de fato). A propriedade
pede os
pontos na **mesma página**; o app hoje cria anotação só com `bounds`
(`PDFDocumentView.swift:352-353, 408-409`) sem `quadPoints` — este slot corrige
para os destaques DO USUÁRIO; as anotações efêmeras de leitura ficam como estão
(não mexer nelas).

**Identificação:** `annot.userName = "EdgeSpeak"` e
`annot.setValue("EdgeSpeak", forAnnotationKey: .textLabel)`. As efêmeras nunca
têm `textLabel` criado — o teste de §7 confirma.

**Rotação de página:** página com `rotation != 0` é caso limítrofe documentado
(reuso §a: a Apple avisa explicitamente a necessidade de transformação em
`bounds(for:)`). Plano: função pura `quads(forLineRect:rotation:)` que aplica a
transformação de 90°/180°/270°; a fase 1 verifica com um PDF de teste
rotacionado; se PDFKit já entrega bounds já transformados, a função vira
identidade para rotação 0° e a derivada fica garantida por teste.
Se quebrar: destaque em página rotacionada segue o mesmo caminho, e o risco fica
registrado em §9.

**Zoom:** irrelevante para persistência (page space). `mouseUp` não depende de
zoom; a conversão `convert(_:to: page)` de tela (já usada no clique em
`PDFDocumentView.swift:67-69`) não entra no caminho de criação.

## 4. Interação

**Estado:** `@State highlightMode: Bool` em `ContentView` — **não persiste**
(modo momentâneo, como o `revealToken`); não vai para `AppSetting` (contrato de
chaves lá é para preferências). Sair do modo também ao trocar de documento.

**Ao entrar no modo (única mudança de tela):**
1. O cabeçalho do PDF (`headerText`, `PDFDocumentView.swift:240-247`) recebe
   um segmento "Destacar: selecione o texto" — atualização do texto do
   `NSTextField` já existente, sem nova view.
2. O app **deixa de zerar a seleção no PDF**. Os três
   `setCurrentSelection(nil, ...)` (`PDFDocumentView:315, 339, 350`) ganham a
   guarda `&& !highlightMode` — via nova prop `highlightMode: Bool` do
   `PDFDocumentView` (aplicará também no caminho `page == nil`).

Fato decisivo para a garantia: **nada mais muda**. O `mouseUp` (< 4 pt) continua
reportando clique → `onPageClick` → `PhraseLocator` → salto
(`ContentView.swift:599-604, 717-747`, `[reverificar no estado final]`) —
inclusive dentro do modo destacar; espaços, setas e ⌥→ do monitor
(`:1026-1085`) nem são tocados; o detector de rolagem
(`isUserScroll`, `:115-128`) é intocado; zoom continua via `autoScales`
(`:150`). Em particular, o highlight do modo NÃO captura o arrasto: o arrasto
continua sendo seleção nativa do PDFKit; só o **resultado** dela é consumido.

**Criar:** seleção aplicada (§3 — guardado e desenhado), depois
`view.setCurrentSelection(nil)` para dar feedback de que virou destaque. Modo
continua ligado até o usuário sair (⌘⇧H, Esc, ou mesmo toggle — comportamento
do Preview, reuso §d).

**Apagar:** control-click/right-click sobre o destaque abre menu de contexto
com "Remover destaque". Implementação: override de `menu(for:)` no
`ClickablePDFView` (precede: `ClickableTextView.swift:430-461`), mecânica:
localizar página e ponto (mesma conversão do mouseUp), `page.annotation(at:)`,
e só oferecer item quando `annotation.value(forAnnotationKey: .textLabel) ==
"EdgeSpeak"`; caso contrário, `super.menu(for:)`. A remoção tira a anotação
da página e o registro do store (**gravação imediata**, §2), com undo (§4).

**Desfazer:** `pdfView.window?.undoManager` — janelas do AppKit já têm um
(reuso §d, FATO). Cada criar/apagar registra `registerUndo` com a inversão;
`undoActionName` = "Destacar"/"Remover destaque"; ⌘Z/⇧⌘Z saem do menu de
Sistema de graça. Undo **também grava o sidecar** (a inversão de undo está sujeita à mesma fila e disco do §2 — mesmo caminho de função, sem lógica paralela). Se o gestor não existir (janela fechando), a mutação simplesmente não registra undo e continua válida.

**O que o clique no destaque faz:** nada de novo — clique é clique,
`PhraseLocator` trabalha com caixas do extrator, não das anotações (mapa §7),
então o clique curto sobre um destaque do usuário PULA A LEITURA como sempre.
`PDFViewAnnotationHitNotification` passa a disparar: o app decide
**ignorá-la** (sem observador, sem consumidor). Se o PDFKit mudar comportamento
default no hit (risco §9), o override do `mouseUp` não é afetado — é código
nosso que roda depois de `super`.

**Proibições (cada uma uma condição de teste do roteiro §7):** não capturar
espaço; não capturar setas; não roubar o foco do `NSTextView`; não mexer no
freio de rolagem nem no follow (`scrollHold`, `followReading`); não haver
nenhum código de destaque que roda no caminho de tick de leitura (o
`updateNSView` por frame só faz o que já faz, mais a guarda de seleção).

**Sair do modo** não apaga nada persistido; apenas volta a zerar a seleção.

## 5. Menus e atalhos

- **⌘⇧H — "Destacar texto" (toggle)** entra:
  (a) `optionsMenu` (`ContentView.swift:878-944`, `[reverificar no estado
  final]`) como `Toggle` ligado ao estado;
  (b) `CommandGroup` no `Scene` (precede: o "Summarize Passage" ⌘⇧M,
  `EdgeSpeakApp.swift:151-160`, `[reverificar no estado final]`), postando
  `.edgeSpeakToggleHighlight` (Notification.Name, no mesmo bloco de
  `:57-63`), consumida em `ExternalActions` (`ContentView.swift:1146-1171`,
  `[reverificar no estado final]`). ⌘⇧H não colide com nada do app atual
  (mapa §6: existem Space, ⌥←/→, ⌘−/+/**⌘0**, ⌘⇧M).
- **Esc — sair do modo destacar.** Via o monitor local já existente
  (`:1026-1032`), **só quando `highlightMode` está ligado**; Esc com seleção
  ativa permanece com o PDFKit (o roteiro §7 confirmará o comportamento e, se
  precisar, o consumo do evento se afina lá — sem inventar regra agora). Garantia
  fixa: Esc e ⌘⇧H não induzem nenhuma reação de leitura.
- **"Ocultar/mostrar destaques"** — toggle simples que itera páginas e liga/
  desliga `PDFPage.displaysAnnotations`; **fica fase 2** (tocaria em toda
  página e em toda troca de documento; desnecessário na fase 1).
- **"Exportar cópia com destaques…"** — botão no `optionsMenu` (sem atalho —
  reuso §d: Preview não documenta atalho para nada disso e não inventamos
  padrão). Fluxo: `NSSavePanel` (SwiftUI `fileExporter`) com nome default
  `"<nome>-destaques.pdf"`; em seguida
  `document.dataRepresentation(options: [.burnInAnnotationsOption: true])`
  (macOS 13+; piso é 14) escrevendo no destino escolhido. **Nunca toca o PDF
  original.** As anotações efêmeras de leitura já saem do documento entre
  frases (limpeza automática `:349`), mas se a exportação ocorrer durante a
  leitura, as efêmeras de momento presentes ficariam embutidas sem sentido —
  mitigação exigida: remover antes as anotações efêmeras (uma passagem de
  `page.annotations`, filtrando pelos objetos ainda vivos no `coordinator`)
  e depois exportar; detalhes de implementação, não do contrato.

## 6. Coexistência com o realce de leitura

**Cores (decisão [OPINIÃO-ESPEC]):** destaque do usuário = `systemMagenta`
α 0,33; frase lida = `controlAccentColor` α 0,28 (hoje, `:354`); palavra =
`systemYellow` α 0,55 (hoje, `:410`). Três matizes distintas, subjetivamente
separáveis mesmo com PDF colorido. O campo `colorSlug: "magenta"` sustenta a
fila de cores da fase 2 sem reescrever o formato. **Amarelo e azul continuam
sendo marcas exclusivas da leitura.**

separáveis mesmo com PDF colorido. O campo `colorSlug: "magenta"` sustenta a
fila de cores da fase 2 sem reescrever o formato. **Amarelo e azul continuam</think><tool_call>edit<arg_key>newString</arg_key><arg_value>**Ordem de camadas:** ordem de pintura é secundária entre highlights
translúcidos, mas há exigência: a anotação efêmera da palavra é adicionada/reciclada DEPOIS
dos
usuários (naturalmente é, pois nasce no ciclo de `updateNSView`), e o destaque
do usuário **nunca** entra nas listas `phraseAnnotations`/`wordAnnotation` do
Coordinator (`PDFDocumentView.swift:83-87`). Ele tem casa própria no
Coordinator: `[String: (PDFPage, PDFAnnotation)]` chaveado por `id`.

**Nenhum caminho de limpeza toca o destaque do usuário:**
`clearPhraseAnnotations` (`:371-379`) e `clearWordAnnotation` (`:383-390`)
continuam a remover SÓ o que estiver nas suas próprias listas — verificação
por teste de diff (§7). A troca de documento (`:288-296`) remove as anotações
de usuário do documento antigo (junto com o descarte do documento), repinta do
sidecar no novo na volta do `Task` de carregamento (§8, passo 3).

**`PDFViewAnnotationHitNotification`:** sem observador na fase 1 (§4). Também
é garantia: a criação da anotação não interessa ao `PhraseLocator` (trabalha com
caixas `rects` da extração, mapa §7), logo o salto por clique não é
perturbado por nenhum pedaço de código novo.

## 7. Testes

Padrão do projeto: função pura extraída do `NSViewRepresentable` para
decidir/computar sem app (`PDFDocumentView.isUserScroll`,
`PDFFollowTests.swift:1-56`) e persistência testável por injeção
(`ReadingPositionStore` com `UserDefaults` injetável,
`AppSettings.swift:137, 147, 159`). Segue-se o mesmo molde.

**Novas suítes (sem app vivo):**
1. `HighlightFormatTests` — ida e volta `StoredHighlight`/`HighlightDocument`
   (Codable round-trip, `createdAt` como `Date`, slug preservado);
   `formatVersion` futuro → `[]`; JSON maculado/UTF-8 inválido/vazio → `[]`;
   destaque inválido isolado descartado e demais preservados (validação pura
   `validate(_:pageCount:)`).
2. `HighlightQuadsTests` — função pura `quads(forLineRects:rotation:)`: 4
   vértices por
   caixa, ordem T-L, T-R, B-L, B-R; caixa degenerada (largura 0) descartada;
   seleção multi-página agrupada por página (uma entrada por página);
   rotação 0° é identidade; caso de 90° determinado e fixado por valor de
   referência no teste (ajustável após o roteiro de PDF rotacionado, §3).
3. `HighlightStoreTests` — chave: mesmo arquivo em caminhos distintos tem
   mesma chave; gravação→leitura round-trip em diretório temporário (precede:
   `DiskCacheTests.swift`, ciclo com `test-*` e cleanup); arquivo corrompido no
   disco → leitura vazia e NÃO apaga o arquivo; throttle/flush: duas mutações
   dentro de 1 s geram uma gravação (contador com fila própria injetável).
4. `UserHighlightCleanupTests` — a garantia do §6 em forma de teste: com a
   lista de anotações de usuário preenchida com sentinelas,
   `clearPhraseAnnotations`
   e `clearWordAnnotation` não os tocam (extração das funções para métodos
   estáticos ou passagem explícita do estado, conforme o precedente do
   `isUserScroll`).
5. `PruneTests` — decisão pura de órfão: path morto + arquivo ido há mais de
   180 dias → remove; documento vivo → mantém; idade curta → mantém.

**Roteiro de verificação com o app aberto (checklist dos implementadores):**
- ⌘⇧H liga o modo: cabeçalho mostra o selo; seleção sobrevive ao avanço da
  leitura (com leitura ativa seguindo).
- Selecionar e arrastar ≥ 4 pt cria destaque magenta; seleção sumiu após
  criar; um segundo arrasto cria outro destaque.
- Clique curto **sobre** um destaque pula a leitura para a frase que começa ali.
- Leitura ativa: azul por frase e amarelo por palavra prosseguem por cima do
  destaque magenta sem flicker.
- Control-click num destaque: menu "Remover destaque"; remover apaga da tela e
  do sidecar; control-click fora de destaque: menu nativo intacto.
- ⌘Z desfaz criar/remover; ⇧⌘Z refaz; undo atravessa reabertura do modo.
- Reabrir o PDF: destaques voltam. Mover/renomear o PDF: os destaques voltam.
  Editar o PDF por fora (remover página, re-exportar): destaque não pinta
  erroneamente; abre-se sem destaques.
- Espaço, setas, ⌥←/⌥→, rolagem com follow on/off, zoom ⌘+/⌘−: tudo igual ao
  estado antes da feature (comparação A/B no mesmo build de base).
- "Exportar cópia com destaques…" gera novo PDF; aberto no Preview, os
  destaques aparecem e o arquivo original está intocado (tamanho e mtime).
- PDF rotacionado de teste (`/Rotate 90`): criar destaque, conferir posição
  (§3, risco §9).
- Esc sai do modo sem efeito colateral no PDF/leitura.

## 8. Passos de implementação (ordem e critérios verificáveis)

1. **Modelo + funções puras** (`HighlightStore.swift`):
   structs, validação, `quads(forLineRects:rotation:)`,
   `groupLinesByPage(_)`, `pruneDecision`.
   Pronto: suítes 2 e 5 verdes (`swift test` passa no pacote todo); build limpo.
2. **Disco** (`HighlightDiskStore.swift`): local, chave por SHA-256,
   leitura tolerante, escrita atômica com throttle+flush, poda na abertura.
   Pronto: suítes 1 e 3 verdes; nenhum `throw` sobe (arquivo de log prova).
3. **Repaint ao abrir** — wiring mínimo no `PDFDocumentView` (props novas
   `userHighlights` + callbacks add/remove; casa própria no Coordinator;
   nenhum clear path os alcança). Carregado em `Task` ao abrir PDF
   (hash e leitura em fila de fundo; repaint na fila principal).
   Pronto: build limpo; suíte 4 verde; abrir um PDF cujo sidecar foi semeado à
   mão mostra destaques (roteiro manual curto); leitura intacta com destaque
   presente (click/leitura por cima).
4. **Modo destacar + criação**: estado em `ContentView`, prop `highlightMode`
   no `PDFDocumentView` com as três guardas de seleção, caminho de criação no
   `mouseUp` (§3 e §4). Pronto: roteiro "criar" verde; seleção sobrevive; nenhuma
   regressão do jump/leitura; suítes existentes 225+ verdes.
5. **Remoção + undo**: `menu(for:)` no `ClickablePDFView`, undo manager da
   janela, gravação após cada mutação. Pronto: roteiro "apagar"/"undo" verde.
6. **Menus e comandos**: toggle ⌘⇧H (Options + CommandGroup + notificação,
   precedente: Summarize), Esc; exportação com
   `.burnInAnnotationsOption`. Pronto: roteiro completo + 225+ testes verdes,
   nenhum arquivo compartilhado com a lane em escrita desacordado — a mudança
   em `EdgeSpeakApp.swift` é adição de CommandGroup/notificação, não
   reescrita (combinado com a lane antes do passo).

Fase 2 (não fazer agora): cores múltiplas (UI de picker), nota escrita
(`contents` na anotação + UI), listagem/painel, busca, re-ancoragem por texto
de destaques órfãos, destaque no painel de texto, sincronização iCloud.

## 9. Riscos e o que esta especificação NÃO resolve

- **Rotação de página**: comportamento do PDFKit ainda não provado ao vivo
  (reuso: "[INFERÊNCIA]"). Teste de PDF rotacionado decide; se quebrar, destaque
  em página rotacionada fica explicitado como limitação.
- **Renderização de anotação viva**: `rdar://34784917` (double-draw antigo,
  reuso §a) pode persistir em alguma forma; efeito esperado: apenas visual,
  nunca funcional. Verificar no roteiro.
- **`PDFViewAnnotationHitNotification`**: prometemos ignorá-la; se um futuro
  macOS fizer algo default no hit (ex.: balão), o override do `mouseUp` continua
  dono do clique — a garantia é do nosso código, não do PDFKit.
- **Edição do PDF por fora**: perdemos os destaques daquela versão (decisão
  declarada em §1); a re-ancoragem por texto é fase 2 e **esta especificação não
  a resolve**.
- **Escrita em iCloud Drive**: o app não coordena escrita no PDF (nunca o
  faz), e o sidecar não sincroniza entre máquinas. Se o app um dia for
  sandboxed, o caminho do sidecar passa a exigir entitlement e o
  `bookmarkData` deixa de ser "pista" e vira requisito de acesso (reuso §b).
- **Undo em janela sem `undoManager`** (raro): mutação aplicada sem desfazer;
  não é bloqueio do produto, é trilha conhecida.
- **Não resolve**: sincronização entre máquinas; destaque no painel de texto;
  PDFs escaneados; performance de hash em PDF de centenas de MB (hipótese de
  trabalho: hash em fila de fundo; medir antes de prometer).

Fontes de decisão gerais: `.scratch/feat-destaques/reuso.md` (Skim, Preview,
PDFKit: quadPoints, burnIn, UndoManager, hit notification, acesso 2026-10-17)
e `.scratch/feat-destaques/mapa.md` (estado do código 2026-10-17).
