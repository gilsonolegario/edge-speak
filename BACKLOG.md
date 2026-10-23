# BACKLOG — o que falta (estado verificado em 2026-10-18)

Registro do que resta no app: pendências abertas e parciais, verificações ao vivo
que ainda faltam, decisões do dono em aberto, limites honestos que continuam
verdadeiros e ideias sem dono. O que já foi feito saiu — vive no código e no
histórico dos documentos (`docs/PLANO-MELHORIAS-2026-10-17.md`,
`docs/SPEC-DESTAQUES-2026-10-17.md`).

Legenda: [ABERTO] não implementado · [PARCIAL] parte no código, parte pendente ·
[DECISÃO] depende de escolha do dono · [VERIFICAR] no código, falta observação ao
vivo · [MEDIR] depende de medição antes de qualquer conserto.

Método desta rodada: leitura do código da árvore (`Sources/`, `Tools/`,
`Tests/`) em 2026-10-18, com `arquivo:linha` em cada alegação. Suíte: 383 testes
em 51 suítes, verdes na última execução registrada (2026-10-18 16:20). Cópia do
BACKLOG anterior em `.superpowers/backup-BACKLOG-2026-10-18.md`.

## Pendências abertas — dependem de decisão do dono

- [DECISÃO] **Bloco entre aspas apagado da fala** (item 13 do plano; decisão 7).
  `ReadAloudFilter.stripQuotedBlocks` remove o parágrafo que abre e fecha entre
  aspas (`ReadAloudFilter.swift:765-776`, padrão em `:773`); a restrição do
  padrão ao próprio parágrafo parou o defeito grave (o `.` não cruza mais
  linhas do texto), mas um romance ou trecho com diálogo continua sem voz nesse
  parágrafo. As duas saídas seguem na mesa: exigir verbo dicendi ou vírgula
  fora das aspas, ou expor a opção ao lado de "notas". Exige escuta ao vivo
  antes de escolher.
- [DECISÃO] **⌘+/⌘−/⌘0 com PDF aberto** (decisão 5 do plano). Os três atalhos
  seguem mudando só o tamanho de fonte do app (`ContentView.swift:136-140`;
  menu em `:1462-1479`); nada decide o caso "PDF aberto" (aplicar zoom no
  `PDFView` × desabilitar com dica). O diagnóstico ao vivo — atalhos declarados
  dentro do `Menu` disparam fora dele? — vem antes da escolha.
- [DECISÃO] **Reprodução por streaming** (decisão 9 do plano). Só entra se a
  medição confirmar memória grande no `AVAudioPlayer` sobre o WAV único; ver a
  pendência de desempenho abaixo.
- [DECISÃO] **Formatos novos: EPUB, dicionário de pronúncia, fila de
  documentos** (item 59 do plano; decisão 6). Nada no código (`grep` por `epub`
  em `Sources/` vazio). A prioridade de 2026-10-17 deu a frente à leitura
  corrente; os três seguem sem execução e sem data. Custo M-G cada.

## Pendências abertas — engenharia e verificação

- [ABERTO] **Intervalo de leitura ("leia daqui até ali")** (item 58 do plano).
  Não existe estado de fim: `playList()` sempre entrega a lista inteira
  (`ContentView.swift:340-347`), e não há `endPhrase`/`stopAt` em `Sources/`.
  Custo M; mexe em índices, fatias e cache.
- [MEDIR] **Desempenho sem medição** (item 60 do plano). Nada mudou desde a
  auditoria e os números da lista "medir antes" seguem não colhidos:
  `displayModel()` reconstrói o texto e os ranges a cada render
  (`ContentView.swift:417-427`, chamado por `clickablePhrases`, `:516`);
  `fullText` do `play` concatena em laço O(n²)
  (`SpeechController.swift:570-575`); a sonda `AVAudioPlayer(contentsOf:)` e o
  lookup de cache seguem no main (`SpeechController.swift:618` e `:634`;
  `StreamingPlayer.swift:209`, `:453`, `:526`). Nada entra em execução sem
  esses números, e o teste de sono (o macOS já mantém a máquina acordada
  tocando áudio?) também falta.
- [PARCIAL] **`PiperTTS` e o stderr do filho.** A sessão persistente captura o
  stderr e a falha de voz/modelo tem causa (`PiperTTS.swift:669`); restam dois
  pontos com `nullDevice` fora do caminho da síntese — o `pkill` de sessões
  órfãs (`:630-631`) e a instalação do ambiente (`:1351`). Decidir se essas
  sobras importam ou se o silêncio aí fica documentado.
- [ABERTO] **Aviso de compilação no `onDrop` de texto.** O build termina, mas
  com um aviso: resultado de `provider.loadDataRepresentation(for:)` ignorado
  (`ContentView.swift:1973`; visto em `buildapp.log`, 2026-10-18 15:20).
  Limpar quando o `ContentView` for tocado de novo.
- [VERIFICAR] **Amarelo em citação com ano e página** (item 55 do plano; era o
  `[ABERTO]` do BACKLOG anterior). A expansão e o casamento por palavra inteira
  estão no código e cobertos por teste; falta observar o destaque ao vivo com
  "et al. (1944)" expandido.
- [VERIFICAR] **Chaves de mídia e Now Playing.** Fiação pronta — comandos
  (`EdgeSpeakApp.swift:60-78`), dicionário e sink (`:102-162`) — e testada com
  sink falso (`LaneNowPlayingTests`). Falta conferir ao vivo que o macOS passa a
  rotear as teclas para o app.
- [VERIFICAR] **Destaques do usuário — fechar o roteiro ao vivo**
  (`docs/SPEC-DESTAQUES-2026-10-17.md` §7). A fase 1 está no código: modelo e
  sidecar (`HighlightStore.swift`, `HighlightDiskStore.swift`), criação no modo
  destacar, remoção por menu de contexto com undo, exportação com burn-in
  (`ContentView.swift:912-921`, `:1447`, `:1540-1588`), ⌘⇧H
  (`EdgeSpeakApp.swift:239-242`) e Esc (`ContentView.swift:1708-1716`). As seis
  suítes de `UserHighlightTests` entraram na conta verde de 16:20, inclusive
  depois da verificação por mutação. Falta o que só o app vivo decide: página
  rotacionada (a transformação de 90° é hipótese determinística fixada por
  teste, `HighlightStore.swift:233-249`), o PDF exportado conferido no Preview
  e a lista completa de "espaço, setas, rolagem e zoom iguais ao estado
  anterior".
- [VERIFICAR] **Acessibilidade assistida** (itens 18-23 e 25 do plano). As
  políticas puras estão testadas (`LaneAccessibilityTests`); sem registro de
  rechecagem ficam VoiceOver ao vivo (ordem de foco, anúncios terminais,
  karaoke em braille, espaço com Full Keyboard Access) e o contraste claro/
  escuro dos textos informativos.
- [VERIFICAR] **Robustez ao vivo.** Sem registro de rechecagem: ⌘Q no meio da
  síntese matando os filhos (item 44), e a frase gigante offline fatiada num
  PDF real junto do pico de memória da concatenação sem ffmpeg (itens 46-47) —
  este host tem ffmpeg, então o caminho manual de `concatWavs`
  (`PiperTTS.swift:1164`) não roda aqui; a medição do harness deu 20 MiB de PCM
  com pico de 44,6 MB (versão antiga) contra 0,9 MB (nova).
- [VERIFICAR] **UI nativa restante.** Barra do player, campo de página, busca,
  seletor de voz e barra inferior foram conferidos por screenshot em
  2026-10-18; fica sem registro a conferência do menu bar (⌘O e "Abrir
  recente", `EdgeSpeakApp.swift:186-215`).

- [ABERTO] **Síntese que para no meio sem erro visível** (observação de
  2026-10-16). A instância aberta às 12:47 escreveu a última fatia às 13:55 e
  às 17:07 ainda se declarava ocupada: mais de três horas sem uma fatia, sem
  cache gravado. Causa não investigada — conexão pendurada é a suspeita; a
  guarda de stall cobre o sintoma (cancela aos 300 s sem progresso,
  `SpeechController.swift:977`), o motivo da parada não.
- [ABERTO] **`Tools/synth_timing.py` casa palavra sem fronteira.** O
  `text.find(word["text"], cursor)` (`:158`) pode casar no meio de outra
  palavra e, quando não acha, joga a palavra no balde corrente com o tempo
  dela: tempos fora de ordem dentro da frase (o amarelo supõe ordem
  monotônica). Não verificado.
- [ABERTO] **`ReadAloudFilter`: linha de fórmula de até 60 caracteres some
  inteira.** A segunda alternativa da regra (`ReadAloudFilter.swift:99`,
  `(?m)^(?=.{0,60}$).*[símbolo].*$`) apaga uma linha de prosa que só mencione
  um símbolo ("This ∃ means existence in prose"). É compromisso documentado
  no código (a regra antiga apagava tudo o que tivesse símbolo); reduzi-lo
  pede medir contra os artigos do dono.
- [ABERTO] **Cobertura: `pause()` durante o pré-buffer.** O mecanismo
  (`StreamingPlayer.pauseIfHeld`, `StreamingPlayer.swift:546`) segura o som
  quando o Pause chega antes da primeira fatia, mas nenhum teste o exercita;
  o outro caso da época (timer de destaque no fim natural) ganhou teste em
  `StreamingProofTests`.
- [VERIFICAR] **Controles durante a síntese (±15 s, ⌥←/⌥→, play).** O gate
  passou de `isBusy` para `canSkip` (`SpeechController.swift:1074`) e o
  play retoma no meio da síntese; falta rechecar ao vivo — o defeito está
  provado pela árvore de acessibilidade da instância antiga (leitura pausada,
  áudio medido, os três controles indisponíveis).
- [ABERTO] **Sigla × nome próprio em caixa alta.** A regra de espaçar
  maiúsculas soletra "NASA"/"MAD" junto com "IBM"/"RHB" (auditoria de leitura,
  item 7, `.scratch/auditorias/audit-leitura/auditoria.md:131`). O conserto
  mínimo é exigir sequência de consoantes (3–5 letras sem vogal interna) para
  soletrar; muda o comportamento que o dono usa hoje, então fica para decisão
  dele.

## Decidido — não reabrir sem pedido do dono

- Citações (`CitationSkip`) ligadas no caminho de fala, com alternância nos
  Ajustes e default ligado (`SettingsView.swift:18-23`, `:121-123`; chamadas em
  `EdgeTTS.swift:502` e `PiperTTS.swift:973`).
- OCR (`PageOCR`) não liga agora: o motor fica no binário, documentado como
  capacidade futura, e o PDF escaneado segue com o erro honesto "sem camada de
  texto" (`PageOCR.swift`; nenhuma chamada em `Sources/`).
- O resumo (⌘⇧M) resume o trecho corrente, com a janela a partir da posição de
  leitura (`ArticleSummary.swift:28-67`; `ContentView.swift:1626-1629`).
- O app abre em PT-BR, com detecção local de idioma oferecendo a voz compatível
  (`L10n.swift:653`; `AppSettings.swift:149-176`).
- Espaço: liberado ao controle com foco (botão, slider, picker, editor, PDF);
  play/pause só sem foco de controle, e o desvio está no menu Ajuda
  (`ContentView.swift:1738-1752`; `SpaceKeyPolicy` em `:2393-2400`;
  `EdgeSpeakApp.swift:256-260`).
- Cancelar o painel de arquivo não é erro: o cancelamento é silencioso; só
  falha real vira mensagem.
- Documentos recentes: lista própria em `UserDefaults`, não
  `NSDocumentController` — o app não é baseado em `NSDocument` e o submenu do
  sistema ficaria invisível (`EdgeSpeakApp.swift:195-215`).
- Sem diretório de pesquisa nem andaime de sessão nos commits (decisão do dono,
  2026-10-15): os reconhecimentos e as auditorias vivem fora do repositório.

## Limites honestos (não são bugs)

- Corpo de nota que continua na página seguinte deixa a cauda no fluxo da
  página: a caminhada das continuações é só na mesma página
  (`TextImport.swift:287`, `:415`).
- Um dígito no meio de uma citação dentro do bloco de notas ainda pode ser
  lido como corpo novo (`inNoteBlock` cobre o resto, `TextImport.swift:479`).
- As palavras injetadas no anúncio ("nota de rodapé 5") não têm caixa: o painel
  pula essas palavras (`announcementIndices`, `ClickableTextView.swift:213`) e
  o amarelo de palavra do PDF fica desligado enquanto a nota é lida
  (`pdfAnchorPhrase`).
- Símbolo que chega como imagem não é lido; a voz online depende do endpoint da
  Microsoft.
- Sair antes dos 100% da síntese não deixa áudio em cache — o cache é escrito
  na conclusão (`SpeechController.swift:840-855`) — e reabrir sintetiza de
  novo desde o início.
- Clicar num trecho cujo áudio ainda não existe não toca agora: o salto fica
  pendente ("Gerando o áudio desse trecho…", `SpeechController.swift:1094`) e a
  leitura segue até a frente da síntese chegar. Tocar antes seria mudança de
  desenho: a fila é sequencial e as fatias são indexadas por posição.
- Destaques do usuário não re-ancoram: PDF editado por fora muda o hash e a
  versão antiga fica dormente, nunca pintada sobre conteúdo novo
  (`HighlightStore.swift:10-15`; spec §1).
- Destaque no painel de texto não existe — fase 2 da spec, junto com cores
  múltiplas, nota escrita, listagem, busca e sincronização.

## Ideias sem dono

- Dicionário de pronúncia e fila de documentos (detalhados no item 59 do
  plano, com EPUB).
- Sucessor do Piper (`sherpa-onnx`): avaliar somente se o Piper falhar.
- Assertion de energia para o sono do sistema durante a leitura: medir primeiro
  se o macOS já mantém a máquina acordada tocando áudio.

## Descartados

- Modo ditado, estatísticas, IDs estáveis entre modos (sem consumidor).
- Branch de tradução integral: divergida e obsoleta; a tradução corrente segue
  no código.
- Sondas temporárias de diagnóstico e autoplay sob variável de ambiente:
  andaime de sessão, fora dos commits.
