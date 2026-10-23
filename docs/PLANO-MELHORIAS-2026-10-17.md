# Plano de melhorias — 2026-10-17

## O que este plano é

Consolidação, em uma lista única e priorizada, de seis auditorias independentes rodadas em 2026-10-17, todas somente-leitura, sobre o app EdgeSpeak (leitor de PDF e de texto em voz alta, macOS 14+, SwiftUI + AppKit):

* `.scratch/auditorias/audit-ux/auditoria.md` — uso;
* `.scratch/auditorias/audit-a11y/auditoria.md` — acessibilidade;
* `.scratch/auditorias/audit-ui/auditoria.md` — UI/HIG;
* `.scratch/auditorias/audit-robustez/auditoria.md` — robustez/recursos;
* `.scratch/auditorias/audit-leitura/auditoria.md` — qualidade da leitura;
* `.scratch/auditorias/audit-capacidades/auditoria.md` — capacidades.

O que este plano NÃO é: não é compromisso de entrega, não é execução, não substitui o `BACKLOG.md` (que continua sendo o registro de estado verificado). Cada item rastreia ao menos um relatório de origem, com o `arquivo:linha` que a auditoria deu. Nenhum conserto proposto aqui exige reescrita de arquitetura; todos são localizados, como os relatórios os propuseram. Estado da árvore no fechamento deste plano: `swift build` limpo, 225 testes em 33 suítes verdes; quatro lanes fecharam itens do BACKLOG nesta rodada (detalhe no fim da lista) e a lane de Now Playing ainda escrevia — itens desses arquivos pedem reverificação antes de qualquer execução.

Os seis relatórios discordam em poucos pontos; quando discordam, as duas versões aparecem separadas e marcadas como divergência, sem escolha do consolidador.

## Lista única de itens

Campos por item: fonte (relatório, item, `arquivo:linha`) · sintoma · conserto · custo P/M/G · risco · exige verificação ao vivo (sim/não) · arquivos.

### 1. Colar texto no estado vazio

Fonte: audit-ux item 1 (`ContentView.swift:581`, `:545-572`, `:640-648`, `:438`; `L10n.swift:86-87`). Sintoma: a primeira tela promete colar texto, mas a única escrita em `text` vem de abrir arquivo e não há leitor de pasteboard. Conserto: mostrar o editor sempre que não houver PDF, ou tratar colar (⌘V/drop de texto) no estado vazio — escolha entre as duas fechada na execução. Custo P. Risco baixo. Ao vivo: sim (arrastar texto selecionado de outro app, hipótese da auditoria). Arquivos: `ContentView.swift`, `L10n.swift`.

### 2. Barra de menu sem "Abrir ⌘O", sem menu próprio e sem atalho de abrir arquivo

Fonte: audit-ui itens 1 e 4 (`EdgeSpeakApp.swift:151-160`, `:154-158`; `ContentView.swift:834-842`, `:449-452`, `:422-445`), audit-ux item 2 (`README.md:120-129` — a tabela de atalhos não lista nenhum caminho de abrir) e audit-a11y item 6 (grep de `keyboardShortcut` = 8 ocorrências, nenhuma de abrir). Sintoma: quem usa Mac procura Abrir primeiro no menu bar e não encontra; o único caminho de teclado puro é tabular até a toolbar, e "Resumir o trecho" mora no menu Edit (ação de app em menu de edição). Conserto: `CommandGroup`/`CommandMenu` próprios em `EdgeSpeakApp` — "Open…" ⌘O postando notificação pelo padrão `.edgeSpeakOpenFile` que já existe, e menu "Leitura" (ou equivalente) para resumo e transporte, sem trocar lógica. Custo P. Risco baixo. Ao vivo: sim (se a ausência confunde em uso real — hipótese da audit-ux). Arquivos: `EdgeSpeakApp.swift`, `ContentView.swift`. Este item toca arquivo em escrita pela lane de Now Playing — reverificar estado.

### 3. Fatiar frases: ponto seguido de aspas/parêntese não fecha

Fonte: audit-leitura item 2 (`TextImport.swift:684`; contraste com `Tools/synth_timing.py:50`). Sintoma: `"the end." Then` vira uma frase — sem pausa, índice de destaque e faixa azul cobrindo os dois períodos. Conserto: aceitar fechamentos `)"'”’\]` entre a pontuação e o espaço, como o `.py` já faz. Custo P. Risco baixo. Ao vivo: não. Arquivos: `TextImport.swift`.

### 4. Abreviações `al`/`no` e inicial solta fundem frases, com comentário defasado

Fonte: audit-leitura item 3 (`TextImport.swift:715-728`, `:734-747`). Sintoma: "et al." funde uma frase que deveria cortar, "was no. The" nunca corta, "plan B. The" idem — e o comentário do código sustenta o contrário do que a lista faz. Conserto: tirar `"no"`, decidir `"al"` com escuta (a auditoria admite que removê-lo reabre o caso "et al. (1944)" já medido no BACKLOG) e restringir a inicial solta a linhas de citação; sincronizar o comentário. Custo P. Risco baixo-médio (o "al" precisa de escuta). Ao vivo: sim (o caso "et al."). Arquivos: `TextImport.swift` + `SentenceBoundaryTests`.

### 5. `p. 37` some e deixa preposição órfã; no integral sai sem expansão

Fonte: audit-leitura item 4 (`ReadAloudFilter.swift:33`, `:103`, `:59`, `:562`, contraste `:820-822`). Sintoma: "The proof is on p. 47" é lido "The proof is on of the book", e no integral sai "pê ponto quarenta e sete". Conserto: consumir a preposição antes da notação (padrão que já existe para `§`) e expandir `p.`/`pp.` na tabela de abreviações do modo integral. Custo P. Risco baixo. Ao vivo: sim para a pronúncia do integral. Arquivos: `ReadAloudFilter.swift`.

### 6. Anúncio de nota aceita um dígito

Fonte: audit-leitura item 5 (`ReadAloudFilter.swift:271`, comentário `:232-233`). Sintoma: "chapter12"/"version2" são lidos "chapter, nota de rodapé 12" — uma referência cruzada anunciada como nota inexistente. Conserto: exigir dois dígitos na terceira regra, como o próprio comentário descreve. Custo P. Risco baixo. Ao vivo: não. Arquivos: `ReadAloudFilter.swift`.

### 7. Tabela de expansões monolíngue

Fonte: audit-leitura itens 8 e 17 (`ReadAloudFilter.swift:200`, `:562-575`). Sintoma: `etc.` sai "etcétera" em voz inglesa e não há expansão de `e.g.`/`i.e.`/`cf.`/`et al.`/`ibid.` no modo integral — texto inglês e português saem pela mesma tabela. Conserto: duas tabelas ou cada entrada marcada com idioma, passando `pt`/`en` na chamada (padrão já usado por `expandLogic`). Custo P. Risco baixo. Ao vivo: sim (pronúncia das siglas nos dois idiomas). Arquivos: `ReadAloudFilter.swift`.

### 8. Ano 2100 soletrado errado

Fonte: audit-leitura item 9 (`ReadAloudFilter.swift:592`, `:615-653`, `:629`). Sintoma: "em 2100" vira "dois mil e cento". Conserto: tratar `remainder == 100` como "cem" quando o total não é 100. Custo P. Risco baixo. Ao vivo: não. Arquivos: `ReadAloudFilter.swift`.

### 9. Todo número de 1500–2100 tratado como ano

Fonte: audit-leitura item 10 (`ReadAloudFilter.swift:591-607`; nudge em `StreamingPlayer.swift:553-630`). Sintoma: "run 1900 iterations" perde a leitura natural de quantidade, e o destaque rasteja sobre cada ano soletrado. Conserto: exigir contexto de data (`em|de|ano|in|since`, `d.C.`/`a.C.`) para soletrar. Custo P. Risco baixo. Ao vivo: sim. Arquivos: `ReadAloudFilter.swift`.

### 10. Hífen: quebra de linha em `.txt` e colagem cega

Fonte: audit-leitura itens 11 e 12 (`ReadAloudFilter.swift:143`, `:831-838`, `:835`, `:838`; `TextImport.swift:100-107`, `:749-750`; `PDFTextExtractor.swift:425-430`). Sintoma: "argu-\nment" sai "argu ment" em `.txt`/`.md`, e a regra colada transforma "the author - a philosopher - said" em "the authora philosopher said". Conserto: rodar as regras de hífen também em `isPDF == false`, separar "hífen colado à esquerda" de "hífen entre espaços" e aceitar `\u00AD`/`–`/`‐` no extractor. Custo P-M. Risco baixo-médio (texto real muda rápido). Ao vivo: sim. Arquivos: `ReadAloudFilter.swift`, `TextImport.swift`, `PDFTextExtractor.swift`.

### 11. `normalizeMarkdown` rodando em `.txt`

Fonte: audit-leitura item 18 (`TextImport.swift:100-105`, `:774`, `:764`). Sintoma: `user_id_count` vira "useridcount" e "1. " perde o número em arquivo de texto puro. Conserto: aplicar `normalizeMarkdown` só em `md`/`markdown`. Custo P. Risco baixo. Ao vivo: não. Arquivos: `TextImport.swift`.

### 12. Caixa alta: título apagado e título soletrado

Fonte: audit-leitura item 7 (`ReadAloudFilter.swift:521`, `:91`, `:849-856`). Sintoma: "THE PROBLEM" é apagado da leitura e "CARNAP AND THE AUFBAU" sai letra a letra ("NASA", "MAD" idem). Conserto: restringir a regra de espaço entre maiúsculas a sequência de sigla e limitar a regra de apagar linha a conteúdo sem letras. Custo P. Risco baixo-médio (ajuste fino de regex). Ao vivo: sim. Arquivos: `ReadAloudFilter.swift`.

### 13. Parágrafo entre aspas apagado (diálogo some)

Fonte: audit-leitura item 13 (`ReadAloudFilter.swift:670-677`, `:148`). Sintoma: um romance ou trecho com diálogo perde o parágrafo inteiro da voz — limite de desenho, não bug, mas a regra atual apaga sem distinção. Conserto (a decidir com o dono): exigir verbo dicendi ou vírgula fora das aspas para apagar, ou expor como opção ao lado de "notas"; veja "decisões do dono". Custo M. Risco médio. Ao vivo: sim. Arquivos: `ReadAloudFilter.swift`, `L10n.swift` (se sair opção).

### 14. Fatia sem tempos: destaque mente e deslocamento anda sem aviso

Fonte: audit-leitura item 6 (`EdgeTTS.swift:314-336`, `:500-515`, `:576-579`), audit-ux item 15 (`EdgeTTS.swift:768-777`) e `BACKLOG.md:300-302` (aberto). Sintoma: sem tempos, todas as frases da fatia entram com `start: 0` e o destaque trava na última frase da fatia durante todo o áudio, e a duração não medida devolve zero em silêncio deslocando o resto todo — nenhum aviso conta isso. Conserto: distribuir proporcionalmente quando `script.isEmpty` (ou manter o destaque anterior), e avisar no status quando a medição devolve zero. Custo M. Risco médio (dois parsers com fallback deliberado — avisar antes de mexer). Ao vivo: sim (precisa de arquivo que provoque a falha). Arquivos: `EdgeTTS.swift`, `StreamingPlayer.swift`.

### 15. Trocar de voz no meio: sem aviso, Play recomeça do zero

Fonte: audit-ux item 3 (`AppSettings.swift:131-133`, `ContentView.swift:693-704`, `:852-873`, `:814`; `SpeechController.swift:301-302`, `:380-410`). Sintoma: pausa, troca, Play — o áudio volta ao 0:00 ressintetizando tudo, sem uma palavra na tela; o selo "Voz offline: Piper" também segue a voz em uso, não a escolhida. Conserto: aviso no status quando trocar voz durante a leitura ou após troca (o aviso equivalente já existe para o ritmo); mapear posição entre vozes fica para depois (custo M, duração muda com voz). Custo P (aviso). Risco baixo. Ao vivo: sim (rota exata pausar→trocar→Play). Arquivos: `ContentView.swift`, `L10n.swift`.

### 16. Abrir e trocar voz travados durante a síntese — regra inconsistente entre os caminhos

Fonte: audit-ux item 6 (`ContentView.swift:840`, `:871`, `:76-84`, `:438-445`) e audit-ui item 10 (mesmo arquivo, mais a divergência com os Ajustes, que permitem trocar voz). Sintoma: o botão Abrir fica desabilitado em síntese de minutos enquanto arrastar funciona, e o seletor de voz da barra está morto enquanto os Ajustes permitem a mesma troca. Conserto: soltar o `.disabled(isBusy)` do Open (o `load` já cancela) e dar dica onde a escolha só vale na próxima síntese; conferir no estado final como o picker aplica a voz (hipótese da auditoria: mudar voz pelo picker pode disparar ressíntese). Custo P. Risco baixo. Ao vivo: sim (efeito da troca pelo picker). Arquivos: `ContentView.swift`.

### 17. Volume não persiste

Fonte: audit-ux item 10 (`SpeechController.swift:95`; `StreamingPlayer.swift:55`; `PlayerBar.swift:199-208`; `AppSettings.swift:10-42`) e audit-capacidades item 9 (mesma chave, mais a cadência por documento como lado opcional). Sintoma: o volume volta a 100% a cada abertura — única preferência fora de `AppSetting`. Conserto: chave nova em `AppSetting` + sincronização na criação, seguindo o padrão existente (cadência por documento é extensão, não parte do conserto). Custo P. Risco baixo. Ao vivo: não. Arquivos: `AppSettings.swift`, `SpeechController.swift`, `StreamingPlayer.swift`, `PlayerBar.swift`.

### 18. Banner de erro: truncado, some em 4 s e é mudo para VoiceOver

Fonte: audit-ux item 5 (`ContentView.swift:777-798`; `L10n.swift:191`; `Diagnostics.swift:52-63`), audit-a11y item 2 (grep zero de `NSAccessibility`/`.announcement`; `SpeechController.swift:18`; `ContentView.swift:786-828`) e audit-capacidades item 16 (mesmo banner; sem alerta em lugar nenhum). Sintoma: o único canal de erro é uma linha truncada que desaparece em 4 s; para VoiceOver nada é postado — o usuário cego nunca fica sabendo que a leitura falhou. Conserto: manter a última mensagem visível enquanto houver erro (ou popover completo ao clicar) e postar `NSAccessibility.post(.announcement)` nos eventos terminais (carregado, erro, concluído, cancelado — não por tick de progresso). Custo M. Risco baixo. Ao vivo: sim (calibrar o que anunciar; ver qual mensagem corta em falha real). Arquivos: `ContentView.swift`, `SpeechController.swift`, `SettingsView.swift` (diagnóstico).

### 19. Espaço engolido: teclado não ativa controle nenhum fora de editor e PDF

Fonte: audit-a11y item 1 (`ContentView.swift:1028-1029`, `:1056-1069`, `:1045-1047`, `:1064-1066`). Nota correlata (não é a mesma falha): audit-ui item 5 registra o desvio Espaço=play/pause como coerente com o gênero (IINA/mpv) e só pede documentar. Divergência: a audit-ui recomenda manter e documentar; a audit-a11y mostra que o espaço engolido quebra a ativação por teclado de todo controle focável (e na sheet do resumo o espaço dispara a leitura principal). Conserto comum: interceptar espaço só quando nenhum controle esteja focado — liberar para o controle focado — e documentar o desvio em item de menu ou Help. Custo P-M. Risco médio (monitor mexe em caminho de eventos). Ao vivo: sim, obrigatório (Full Keyboard Access ligado, VO+espaço). Arquivos: `ContentView.swift`.

### 20. Navegação por frase dependente de mouse

Fonte: audit-a11y item 3 (`ClickableTextView.swift:156-160`, `:463-489`, `:138-139`; `L10n.swift:92`; `PDFDocumentView.swift:56-70`) e audit-capacidades item 1 (`PlayerBar.swift:42-57`; `ContentView.swift:1038-1080`; `SpeechController.jumpToSegment` e `StreamingPlayer.seek(toSegment:)` já existem). Sintoma: repetir/próxima frase e o pulo para frase do painel só existem com ponteiro. Conserto: botões/atalhos de frase anterior/próxima sobre a API existente e acesso por teclado/VoiceOver à ação por frase (ação custom ou rotor; desenho fecha com VoiceOver ao vivo). Custo M. Risco baixo (não toca motores). Ao vivo: sim. Arquivos: `PlayerBar.swift`, `ContentView.swift`, `ClickableTextView.swift`.

### 21. Destaque (karaoke) invisível para VoiceOver

Fonte: audit-a11y item 5 (`ClickableTextView.swift:108-112`, `:294-324`; `PDFDocumentView.swift:352-363`, `:408-413`) e audit-capacidades item 17 (grep zero de acessibilidade em `PDFDocumentView`). Sintoma: destaque é só pintura; nada sinaliza a frase corrente a VoiceOver/Braille no painel nem no PDF. Conserto: no painel, mover a seleção do `NSTextView` para a frase durante o follow (VO em texto segue a seleção); no PDF, mantê-lo como recurso de baixa visão sem reescrita. Custo P-M. Risco baixo. Ao vivo: sim (leitura braille/por palavra com VoiceOver). Arquivos: `ClickableTextView.swift`.

### 22. Polimento de rótulos de acessibilidade

Fonte: audit-a11y itens 4, 8 e 12 (`ClickableTextView.swift:150-151`; `ContentView.swift:643-647`, `:547-549`). Sintoma: rótulos do painel hardcoded em inglês fora do catálogo bilíngue, o editor não tem `accessibilityLabel` e a imagem decorativa fala antes da instrução real. Conserto: mover os strings para `L10n.swift`, adicionar label do editor e `.accessibilityHidden(true)` na imagem (padrão já usado na `PlayerBar`). Custo P. Risco baixo. Ao vivo: sim (VoiceOver em PT/EN). Arquivos: `ClickableTextView.swift`, `ContentView.swift`, `L10n.swift`.

### 23. Foco de acessibilidade não gerenciado nas trocas de tela e sheets

Fonte: audit-a11y item 11 (grep `AccessibilityFocusState` = 0; `ContentView.swift:579-664`, `:1167-1169`, `:100-117`). Sintoma: após carregar o PDF ou fechar o resumo, o foco cai em elemento mudo ou indefinido. Conserto: `@AccessibilityFocusState` para o toolbar pós-sheet e `layoutChanged` pós-load (mesma struct do item 18). Custo M. Risco baixo-médio. Ao vivo: sim. Arquivos: `ContentView.swift`.

### 24. Erros de importação misturam idiomas

Fonte: audit-ux item 4 (`TextImport.swift:120-124`; `L10n.swift:42-45`; `ContentView.swift:118-126`, `:431-436`; `SpeechController.swift:217-227`). Sintoma: "Falha ao abrir: The PDF has no text layer; nothing to read." — a causa sai em inglês dentro de frase em português. Conserto: usar `failureKey(for:)` nos dois pontos que mostram falha de abertura. Custo P. Risco baixo. Ao vivo: não. Arquivos: `ContentView.swift`.

### 25. Texto informativo abaixo do limite de contraste e cabeçalho do PDF em fonte fixa 11 pt

Fonte: audit-a11y itens 9 e 10 (`ContentView.swift:800-803`, `:814-818`, `:794-797`; `PlayerBar.swift:183-186`; `PDFDocumentView.swift:140-147`). Sintoma: `tertiary` em caption informativo fica no limite/abaixo de 4,5:1 e o cabeçalho do PDF não acompanha nenhum aumento de fonte — e é o único resumo legível do estado. Conserto: trocar `.tertiary` por `.secondary` nos três casos e amarrar o cabeçalho ao `fontSize` do app ou ao Dynamic Type do macOS. Custo P. Risco baixo. Ao vivo: sim (medir contraste real em claro/escuro — ver seção "medir antes"). Arquivos: `ContentView.swift`, `PlayerBar.swift`, `PDFDocumentView.swift`.

### 26. Título da janela nunca muda e o cabeçalho do PDF fica impreciso

Fonte: audit-ui itens 6 e 7 (`EdgeSpeakApp.swift:145`; `ContentView.swift:13,109,605-607`; `AppSettings.swift:101-106`) e audit-ux item 12 (`PDFDocumentView.swift:240-247`, `:140-147`). Sintoma: a janela fica "EdgeSpeak" eterna (com ⌘N, todas iguais) e o cabeçalho interno mostra `A%20Conting%C3%AAncia.pdf`, voz como identificador cru e página errada/da frase ancorada. Conserto: `navigationTitle(documentName)` (getter de `currentDocumentID`) + no cabeçalho usar `url.lastPathComponent` e `AppSetting.label(for:locale:)`; ligar página visível do PDFView ao cabeçalho (parte de página avaliada na execução — custo M e vive junto ao acompanhamento de rolagem). Custo P-M. Risco baixo (página: médio). Ao vivo: sim (duplicação visual título × cabeçalho). Arquivos: `ContentView.swift`, `EdgeSpeakApp.swift`, `PDFDocumentView.swift`.

### 27. Barra do player: controles somem deslocando vizinhos, cinza arbitrário, sem hover

Fonte: audit-ui itens 8, 9 e 15 (`PlayerBar.swift:45-47`, `:52-56`, `:74-85`; `:128-132`; `:135`). Sintoma: os mesmos controles mudam de lugar conforme a leitura avança, o círculo do play desabilitado pinta cinza fora do sistema e o botão principal de 38×38 pt não reage ao hover. Conserto: manter os botões sempre presentes desabilitados; cor de sistema (`.quaternary`/`unemphasizedSelectedContentBackgroundColor`); `.borderless` + hover. Custo P. Risco baixo. Ao vivo: sim (hover real; contraste do cinza em dark mode). Arquivos: `PlayerBar.swift`.

### 28. Ajustes: "Limpar cache" sem retorno na própria janela, sem confirmação e janela de tamanho fixo

Fonte: audit-ux item 7 (`SettingsView.swift:145-153`; `ContentView.swift:457-459`; `SpeechController.swift:936-944`) e audit-ui itens 11, 12 e 13 (`SettingsView.swift:33`, `:145-151`, `:165-169`). Sintoma: a confirmação aparece na janela principal (ou nenhuma), a ação destrutiva dispara sem alerta e a aba Avançado pode cortar texto na janela 440×300 fixa. Conserto: estado ocupado/resultado dentro da aba (o texto "Cache limpo: X" já existe no catálogo), alerta de confirmação ou `role: .destructive` e `frame(minWidth:idealWidth:minHeight:)`. Custo P. Risco baixo. Ao vivo: não (layout da aba com diagnóstico longo confirmar visualmente). Arquivos: `SettingsView.swift`, `L10n.swift`.

### 29. Picker de voz duplicado entre toolbar e Ajustes

Fonte: audit-ui item 14 (`ContentView.swift:851-873`, `SettingsView.swift:40-56`). Sintoma: mesmas três seções copiadas em dois lugares. Conserto: extrair `VoicePicker` interno (sem arquitetura nova). Custo P. Risco baixo. Ao vivo: não. Arquivos: `ContentView.swift`, `SettingsView.swift`.

### 30. Reserva mágica 74/14 para a barra flutuante

Fonte: audit-ui item 16 (`ContentView.swift:398`, `:417`; `PlayerBar.swift:36-41`). Sintoma: 74 pt reservados versus padding de 14 pt da barra — se a barra crescer (progresso em duas linhas), ela cobre a última linha do texto. Conserto: constante compartilhada nos dois pontos. Custo P. Risco baixo. Ao vivo: não. Arquivos: `ContentView.swift`, `PlayerBar.swift`.

### 31. Drag de arquivo sem retorno visual

Fonte: audit-ux item 11 (`ContentView.swift:438`, `:656-663`). Sintoma: `onDrop` com `isTargeted: nil` — nada destaca onde soltar, no caminho que é o único que funciona durante a síntese. Conserto: `@State` de arrasto ligado à cor da borda existente. Custo P. Risco baixo. Ao vivo: sim (decidir se o cursor do sistema basta). Arquivos: `ContentView.swift`.

### 32. Importação "Lendo o PDF…" sem prazo visível, sem cancelamento, processo sobrevive à troca

Fonte: audit-ux item 14 (`ContentView.swift:85-95`, `:90-91`, `:101-102`; `PdfWords.swift:111-114`, `:115-128`; `PDFTextExtractor.swift:70`). Sintoma: espera bloqueante em laço até `min(180, 15 + 3 × páginas)` segundos, sem prazo na tela e sem cancelar; abrir outro arquivo descarta o resultado mas deixa o processo Python rodando até o limite. Conserto: caminho de cancelamento que mate o processo (o padrão SIGKILL + remoção de zumbi já existe em `PdfWords`), alcançado por um botão, e cancelar o processo da extração anterior na troca. Custo M. Risco médio (caminho de extração; arquivo em escrita paralela). Ao vivo: sim (tempo percebido em PDF grande, ver seção "medir antes"). Arquivos: `ContentView.swift`, `PDFTextExtractor.swift`, `PdfWords.swift`, `Tools/pdf_extract.py`.

### 33. Temporizador de sono invisível

Fonte: audit-ux item 9 (`ContentView.swift:52-55`, `:518-539`, `:922-932`; `L10n.swift:111`, `:69`). Sintoma: passados os 4 segundos da mensagem, nada na tela lembra que há um prazo armado, e o submenu não marca a escolha — a parada aparece como "Leitura concluída". Conserto: `Picker` dentro do menu marca a escolha, ou item mostrando "para em X min" enquanto houver prazo. Custo P. Risco baixo. Ao vivo: sim (a parada é percebida como falha?). Arquivos: `ContentView.swift`, `L10n.swift`.

### 34. Convite ao Enter após carregar arquivo

Fonte: audit-ux item 13 (`ContentView.swift:113-116`; `L10n.swift:64`, `:125`). Sintoma: "Arquivo carregado" não diz que Enter também começa a leitura. Conserto: um convite na própria mensagem de carregamento. Custo P. Risco baixo. Ao vivo: sim (primeira sessão de uso). Arquivos: `ContentView.swift`, `L10n.swift`.

### 35. Clique no PDF fora de frase não dá retorno

Fonte: audit-ux item 17 (`ContentView.swift:599-604`). Sintoma: clique perdido em silêncio. Conserto: mensagem curta de status (a pista de cursor é mais delicada — a área clicável segue as caixas da frase, e o cursor pode prometer mais do que existe). Custo P. Risco baixo. Ao vivo: sim (se a dúvida é real em uso). Arquivos: `ContentView.swift`, `L10n.swift`.

### 36. Documentos recentes

Fonte: audit-capacidades item 3 (grep zero de `NSDocumentController`/`recent`; `EdgeSpeakApp.swift:151-160`; `AppSettings.swift:122-172`). Sintoma: o app guarda a posição do PDF mas não o caminho dele — o usuário não consegue reabrir com um clique o arquivo cuja leitura o app lembra. Conserto: lista em `UserDefaults` + menu "Abrir recente" (ou `NSDocumentController.noteNewRecentDocumentURL`). Custo P. Risco baixo. Ao vivo: sim (fluxo de retomada). Arquivos: `EdgeSpeakApp.swift`, `ContentView.swift`.

### 37. Resumo do "trecho" resume sempre o começo do documento

Fonte: audit-capacidades item 18 (`ContentView.swift:979-980` — confirmação na árvore nesta consolidação; `ArticleSummary.swift:19-23`; `L10n.swift:168-169`). Sintoma: o rótulo promete o trecho corrente e entrega os primeiros 3.000 caracteres. Conserto: partir da frase atual (a única escolha de desenho é a janela antes/depois) ou renomear o controle; veja "decisões do dono". Custo P. Risco baixo. Ao vivo: não. Arquivos: `ContentView.swift`, `ArticleSummary.swift`.

### 38. Módulo `CitationSkip` sem chamador (DOI sai em voz alta; sem alternância)

Fonte: audit-leitura item 1 (`CitationSkip.swift:70-83`; `EdgeTTS.swift:446`, `:461`; `PiperTTS.swift:796`; `ReadAloudFilter.swift:103`) e audit-capacidades item 7 (`CitationSkip.swift:11-30`, `isEnabled`, `setEnabled` sem chamada). Sintoma: um DOI solto atravessa o pipeline e sai "sopa de dígitos e barra", e o modo integral lê "(Smith, 2020)" com parênteses — o módulo documentado como configurável nenhuma tela alcança (verificado na árvore: segue sem chamador no fechamento deste plano). Conserto (decisão do dono): ligar `CitationSkip.forSpeech` junto de `ReadAloudFilter.forSpeech` + alternância nos Ajustes, ou apagar o módulo e documentar que a política vive em `clean`; veja "decisões do dono". Custo P (ligar) ou zero (apagar). Risco médio-baixo (invariante 18: `forSpeech` expande, `clean` exibe). Ao vivo: sim (pronúncia exata do DOI). Arquivos: `EdgeTTS.swift`, `PiperTTS.swift`, `CitationSkip.swift`, `SettingsView.swift`, `AppSettings.swift`.

### 39. README, INTERFACE e BACKLOG desatualizados

Fonte: audit-ux anexo (README.md:176 e dois itens do BACKLOG desatualizados) e audit-capacidades seção 4 (itens 1–3 de divergência), ambos confirmados na árvore nesta consolidação. Sintoma: `README.md:176` diz que não há suíte de testes enquanto `README.md:152-154` (o próprio README) conta o contrário — a árvore tem 225 testes verdes; `INTERFACE.md:1325-1333` idem; `BACKLOG.md` registra como aberto o que a árvore fechou (chaves de mídia, duas janelas, clique à frente, `hasSupport`, "Sect. 2", download do Piper, `thread.sleep`, régua em `pdf_extract.py`). Conserto: rodada de sincronização de documentos, sem mudar o comportamento descrito (o lado README×código do idioma padrão é decisão à parte, veja "decisões do dono"). Custo P. Risco baixo. Ao vivo: não. Arquivos: `README.md`, `INTERFACE.md`, `BACKLOG.md`.

### 40. Busca no documento (⌘F)

Fonte: audit-ui item 3 e audit-capacidades item 4 (grep: nenhum `searchable`/`performFindPanelAction`; `filteredSentences` já existe em `ContentView.swift:15`; `PDFDocument.findString` disponível). Sintoma: num leitor de PDF/texto, busca é comando padrão esperado e hoje não existe caminho nenhum. Conserto: `.searchable` filtrando o painel e garantir ⌘F no `PDFView` (o monitor de teclado não intercepta ⌘F; hipótese da auditoria a confirmar); a busca não pode virar destaque de leitura. Custo M. Risco médio-baixo. Ao vivo: sim (⌘F + Find do PDFKit no estado final). Arquivos: `ContentView.swift`, `PDFDocumentView.swift`.

### 41. Exportar os tempos junto do áudio (SRT/VTT/JSON)

Fonte: audit-capacidades item 2 (`INTERFACE.md:746-747`; `L10n.swift:177-178`; `Segment` com `start/duration/text/words` em `INTERFACE.md:445-455`). Sintoma: o áudio exportado vai sem marcadores; para ouvir fora do Mac não há acompanhamento nem retomada por frase. Conserto: serializar a lista de `Segment` junto do arquivo. Custo P. Risco baixo (aditivo). Ao vivo: não. Arquivos: `SpeechController.swift`, `L10n.swift`, `INTERFACE.md`.

### 42. Ir para página + índice do PDF

Fonte: audit-capacidades item 5 (grep zero de `PDFOutline`/`outlineRoot`; `PDFDocumentView.swift:140`, `:240`). Sintoma: em um livro de 300 páginas, chegar ao capítulo é rolar. Conserto: campo "ir para página" (pequeno) + outline clicável integrado a "Ir para o trecho" (médio), quando o arquivo tem outline. Custo M. Risco médio-baixo. Ao vivo: sim. Arquivos: `PDFDocumentView.swift`, `ContentView.swift`.

### 43. Presets de velocidade mais finos

Fonte: audit-capacidades item 15 (`EdgeTTS.swift:145` — `-20…+50%` de 10 em 10). Sintoma: 1,5× é o teto; quem estuda em 1,75× não alcança. Conserto: mais valores na lista (invalidar cache por ritmo é comportamento já esperado). Custo P. Risco baixo. Ao vivo: não. Arquivos: `EdgeTTS.swift`, `SettingsView.swift`.

### 44. Encerrar o app não cancela nem mata os filhos

Fonte: audit-robustez item 7 (grep zero de `applicationShouldTerminate`; cancelamento só em `onDisappear`, `EdgeSpeakApp.swift:9-12`, `ContentView.swift:496-502`). Sintoma: ⌘Q no meio de síntese deixa processo Python órfão até 600 s, consumindo rede e CPU, com temp órfão. Conserto: `applicationShouldTerminate` postando `.edgeSpeakStopReading` (canal e handler já existem e cancelam síntese em voo). Custo P. Risco baixo-médio. Ao vivo: sim (force-quit). Arquivos: `EdgeSpeakApp.swift` (em escrita pela lane de Now Playing — reverificar), `SpeechController.swift`.

### 45. Exportação copiando o áudio na mão da `@MainActor`

Fonte: audit-robustez item 2 (`SpeechController.swift:962-969`, comentário do `DiskCache.store` em `:564-566`). Sintoma: `try fm.copyItem(at:to:)` síncrono na thread principal — cópia de segundos a minutos trava a janela (o próprio código já documentou a travada para o mesmo caminho no cache). Conserto: mover a cópia para `Task.detached(priority: .utility)` e reportar `audioSaved`/`exportFailed` de volta via `MainActor.run`. Custo P. Risco baixo. Ao vivo: não. Arquivos: `SpeechController.swift`.

### 46. `concatWavs` sem ffmpeg carrega o PCM do livro inteiro na RAM (duas vezes)

Fonte: audit-robustez item 5 (`PiperTTS.swift:930-956`, `:934`, `:954`). Sintoma: leitura longa sem ffmpeg ≈ 1,6 GB em RAM no instante da concatenação → memory pressure no fim de horas, perdendo tudo. Conserto: escrever por `FileHandle` streaming (cabeçalho em memória, PCM em blocos), mantendo a matemática de `writeU32`. Custo M. Risco médio (caminho de saída do WAV). Ao vivo: sim (RSS — ver seção "medir antes"). Arquivos: `PiperTTS.swift`.

### 47. Frase gigante offline sem fatiamento nem retry

Fonte: audit-robustez item 8 (`PiperTTS.swift:789-830`, `:796`, `:651-653`, `:680`, `:838`; cap de fatia em `EdgeTTS.swift:288`, retry `:473-528`). Sintoma: uma sentença sem pontuação acima de ~30 mil caracteres mata a leitura inteira com "offlineTimeout", sem recuperação parcial — onde o caminho online tem fatiamento e 3 tentativas por fatia. Conserto: fatiar a frase com `EdgeTTS.buildChunks` quando passar do cap, sintetizando em sequência. Custo M. Risco médio. Ao vivo: sim (precisa de documento que provoque). Arquivos: `PiperTTS.swift`, `EdgeTTS.swift`.

### 48. Sem checagem de espaço livre antes de síntese longa ou download

Fonte: audit-robustez item 9 (grep zero de `volumeAvailableCapacity`; `EdgeTTS.swift:397-404`, `PiperTTS.swift:247-255`, `:763-767`). Sintoma: ENOSPC no meio do caminho, horas depois, com erro genérico ("chunkFailed"/"joinEmpty") em vez de "disco cheio". Conserto: checagem com piso no início dos `runStreaming` dos dois motores e antes do download da voz, abortando cedo com chave de erro nova e localizada. Custo P. Risco baixo. Ao vivo: não. Arquivos: `EdgeTTS.swift`, `PiperTTS.swift`, `L10n.swift`.

### 49. Três cópias do mesmo áudio em disco (offline)

Fonte: audit-robustez item 10 (`PiperTTS.swift:799-831`; `SpeechController.swift:569-573`). Sintoma: parciais de frase + WAV final + cache = ~2,4 GB simultâneos numa leitura de 5 h. Conserto: apagar cada `phrase-NNNNN.wav` após consumo e não copiar ao cache o WAV que já reside no temp protegido. Custo P. Risco baixo. Ao vivo: não. Arquivos: `PiperTTS.swift`, `SpeechController.swift`.

### 50. `.part` órfãos em `voices/` sem poda

Fonte: audit-robustez item 11 (`PiperTTS.swift:250-253`, `:216-244`). Sintoma: rede intermitente + app morto deixa ~63 MB órfãos para sempre, crescimento silencioso sem limite. Conserto: podar `*.part` com mtime > 1 semana antes de novo download. Custo P. Risco baixo. Ao vivo: não. Arquivos: `PiperTTS.swift`.

### 51. `try? BundledEnv.ensure` engole a causa-raiz do ambiente offline

Fonte: audit-robustez item 12 (`PiperTTS.swift:755-757`, `:758`; padrão `withStderr` em `:467`). Sintoma: se a criação do venv embutido fracassa, a mensagem que chega vem do caminho legacy — diagnóstico distorcido para suporte. Conserto: capturar o erro e anexar a causa original se os fallbacks também falharem. Custo P. Risco baixo. Ao vivo: não. Arquivos: `PiperTTS.swift`.

### 52. `ReadingPositionStore` cresce sem poda

Fonte: audit-robustez item 13 (`AppSettings.swift:146-154`). Sintoma: uma entrada por documento+voz em `UserDefaults` para sempre — 300 PDFs lidos em um ano, nada limpa por si. Conserto: em `load`, descartar entradas cujo `documentID` não resolve mais no disco. Custo P. Risco baixo. Ao vivo: não. Arquivos: `AppSettings.swift`.

### 53. `protectedOfflineDir` fantasma após erro de streaming

Fonte: audit-robustez item 14 (`EdgeTTS.swift:850-866`; `PiperTTS.swift:770`, `catch` em `:836-840`). Sintoma: falha de síntese offline deixa a proteção apontando para path que não existe — inócua hoje, nasce errada para o próximo `purge`. Conserto: no `catch` de `runStreaming` do Piper, chamar `EdgeTTS.clearOfflineDirectory()`. Custo P. Risco baixo. Ao vivo: não. Arquivos: `PiperTTS.swift`, `EdgeTTS.swift`.

### 54. `isMarginNoise` descarta rodapé curto verdadeiro

Fonte: `BACKLOG.md:328-330`, confirmado na árvore nesta consolidação (`PDFTextExtractor.swift:285`, `:298` — regra inalterada; os itens de `pdf_extract.py` e `hasSupport` listados juntos no BACKLOG foram fechados nesta rodada, ver fim da lista). Sintoma: linha de rodapé com `count <= 12` sem mistura de letra+dígito ("Baire 1911.") some em silêncio. Conserto: o BACKLOG registra que corrigir muda a extração e não há PDF de teste medindo — consertar com medição prévia. Custo M. Risco médio. Ao vivo: sim. Arquivos: `PDFTextExtractor.swift`.

### 55. Rechecagem ao vivo do amarelo em citação com ano e página

Fonte: `BACKLOG.md:284` (aberto). Sintoma: item verificado em código e testes, sem rechecagem ao vivo do destaque na presença de "et al. (1944)" expandido. Conserto: é verificação, não código — fechar no app ao vivo. Custo P. Risco: nenhum (só observação de comportamento). Ao vivo: sim. Arquivos: nenhum.

### 56. OCR de página escaneada: módulo escrito e sem chamador

Fonte: audit-capacidades item 6 (`PageOCR.swift:10-33`; `PageOCRTests.swift:9-32`; `TextImport.swift:86-88`; grep: nenhuma chamada em `Sources` — confirmado na árvore nesta consolidação). Sintoma: um PDF digitalizado como imagem recebe "PDF sem camada de texto; não há o que ler", com o motor de OCR já no binário. Conserto (decisão do dono): renderizar página, política de disparo (um OCR que roda quando não deve degrada abertura boa) e o que fazer com frases sem caixas — o destaque geométrico depende das caixas do extrator; veja "decisões do dono". Custo M. Risco médio-alto (toca `TextImport` e `PDFTextExtractor`, ambos em escrita nesta rodada). Ao vivo: sim. Arquivos: `PDFTextExtractor.swift`, `TextImport.swift`, `PageOCR.swift`.

### 57. Idioma: README promete português e o app abre em inglês/voz en-US; sem detecção nem vozes além de PT/EN

Fonte: audit-ux item 16 (`AppSettings.swift:12`; `L10n.swift:23-25`, `:523-526`; `README.md:147` — divergência confirmada na árvore) e audit-capacidades item 8 (`AppSettings.swift:45-96`; `PiperTTS.swift:16`; `L10n.swift:84` — bloqueio do serviço online registrado no catálogo). Sintoma: a interface abre onde a documentação promete outra coisa, um texto em português sai com voz inglesa até o usuário trocar, e um capítulo em alemão/francês não tem voz nenhuma. Conserto: duas peças distintas — (a) divergência README×código é a decisão 4 do dono; (b) detecção do idioma (`NLLanguageRecognizer`) para avisar e oferecer a voz compatível é custo P; ampliar catálogo offline é M-G (~63 MB baixados por voz). Ao vivo: sim (b). Arquivos: `L10n.swift`, `AppSettings.swift`, `PiperTTS.swift`.

### 58. Intervalo de leitura "leia daqui até ali"

Fonte: audit-capacidades item 10. Sintoma: para ouvir só o capítulo 3, das páginas 45 a 72, não há fim — é mergulhar no trilho e vigiar. Conserto: seleção de fim + estado no controlador respeitando `Phrase.index` como propriedade. Custo M. Risco médio (índices, fatias e cache interagem, invariantes 3 e 13). Ao vivo: sim. Arquivos: `ContentView.swift`, `SpeechController.swift`, `PlayerBar.swift`.

### 59. EPUB, dicionário de pronúncia, fila de documentos

Fonte: audit-capacidades itens 11, 12 e 13. Itens grandes e de decisão: EPUB é formato novo (ZIP + HTML, capítulos; M-G), dicionário de pronúncia mexe em `forSpeech` com risco de corromper a fala (M-G), fila/abas é o item mais caro da auditoria (G) e o menos urgente. Comportamento padrão observado em tudo hoje: converter para texto fora do app, aceitar a pronúncia errada ou abrir/fechar sempre. Conserto: nenhum dos três entra em execução antes da escolha do dono (decisão 6); descrição, cenário e custo completos nos itens da auditoria. Custos M-G cada. Risco médio-alto. Ao vivo: sim. Arquivos: amplos — ver cada item na auditoria de capacidades.

### 60. Desempenho sem medição: `displayModel()`/`activeText`, `fullText` O(n²), lookup no main, memória de `AVAudioPlayer`/`concatWavs`

Fonte: audit-robustez itens 1, 3, 4 e 6 (`ContentView.swift:195-206`, `:138-143`, `:276-277`; `SpeechController.swift:296-301`, `:306`, `:344`, `:360`; `StreamingPlayer.swift:419-429`, `:494`, `:421`; `PiperTTS.swift:831`). As auditorias registraram o fato do código (trabalho colado na main, concatenação quadrática a cada `play`) e NÃO mediram o ganho de consertar — magnitude é hipótese lá onde consta. Nada disso entra em execução sem os números da seção "medir antes". Custo P-M cada (memoizar pela identidade, `joined()` uma vez, deslocar para `Task.detached`), o de reprodução por streaming é a decisão 9. Ao vivo: sim (obrigatório). Arquivos: `ContentView.swift`, `SpeechController.swift`, `StreamingPlayer.swift`, `PiperTTS.swift`.

### Feito nesta rodada (registro, sem execução)

Itens fechados pelas lanes entre as auditorias e o fechamento deste plano — a sincronização do item 39 (docs) declarando-os resolvidos é o único trabalho restante:

* **FEITO NESTA RODADA** Chaves de mídia/Now Playing ligadas: `EdgeSpeakApp.swift:74-134` + `SystemNowPlayingSink` e `SpeechController.publishNowPlaying` chamado (fonte: audit-capacidades §4.1, `BACKLOG.md:290-293`). A lane que escreve o par `EdgeSpeakApp`/`SpeechController` ainda estava ativa — reverificar na fusão antes de considerar fechado ao vivo.
* **FEITO NESTA RODADA** Duas janelas: o espaço só altera a janela hospedeira — `WindowProbe`/`hostWindow` na árvore (`ContentView.swift:1013`, `:1065`; fontes: audit-ux anexo, audit-capacidades §4.2, `BACKLOG.md:303-305`). Falta registrar ao vivo no BACKLOG.
* **FEITO NESTA RODADA** Clique à frente: cancela a síntese em curso e recomeça pelo trecho clicado (`ContentView.swift:717-747`; fontes: audit-ux anexo, `BACKLOG.md:369-373`).
* **FEITO NESTA RODADA** `hasSupport`: recall geométrico confinado à segunda passada, testado (`TextImport.swift:440-464`; fonte: `BACKLOG.md:316-322`).
* **FEITO NESTA RODADA** "Sect. 2" não fecha mais o resto da frase ("2 for a…") (`TextImport.swift:720-725`; fonte: `BACKLOG.md:285-289`).
* **FEITO NESTA RODADA** Download de voz em blocos, não byte a byte (`PiperTTS.swift:260`, `:295`; fonte: `BACKLOG.md:294-296`).
* **FEITO NESTA RODADA** Espera assíncrona cancelável no Piper, sem `Thread.sleep` de até 300 s no caminho assíncrono (`PiperTTS.swift:557`, `:619`; fonte: `BACKLOG.md:297-299`).
* **FEITO NESTA RODADA** `pdf_extract.py`: régua de nota conta caracteres, não palavras (`:448`, `:457`; fonte: `BACKLOG.md:323-327`).
* **PARCIALMENTE FEITO NESTA RODADA** stderr do Piper capturado na sessão (`PiperTTS.swift:552`, `:568`, `:610`, `:681`), mas restam chamadas com `nullDevice` em `:529-530` e `:1013` (fonte: `BACKLOG.md:306-308`) — decidir se as sobras importam e documentar no BACKLOG.

## Decisões do dono

Estes itens exigem escolha de produto/dono, e nenhuma das opções deve ser tomada por conta própria. Cada escolha implica o que está escrito à frente dela.

**Resolvidas em 2026-10-17:** (1) ligar `CitationSkip` com alternância nos Ajustes, default ligado; (2) OCR não liga agora — módulo fica documentado como capacidade futura; (3) o resumo passa a resumir o trecho corrente; (4) o app muda para PT-BR por padrão + detecção de idioma (em vez de corrigir o README); (6) leitura corrente primeiro — formatos depois. Seguem abertas: (5) ⌘+/⌘−/⌘0 com PDF aberto, (7) bloco entre aspas, (8) espaço = play/pause, (9) streaming condicionado à medição.

1. **Onde mora a política de citações (o `CitationSkip` inalcançável).** Ligar: ganha DOI limpo e "(Smith, 2020)" desembrulhado no modo integral; implica o modo integral falar diferente do que o texto mostra (a expansão entra no caminho de fala) e pagar o toggle nos Ajustes. Apagar: módulo sai do binário, a política vive em `clean`, e o modo integral continua lendo parênteses e DOI literal.
2. **OCR × nada (o módulo `PageOCR` sem chamador).** Ligar: PDFs escaneados viram legíveis, ao custo de o OCR disparar indevidamente degradando abertura boa e de a frase sem caixas perder destaque geométrico. Não ligar: o motor morto sai do binário ou fica documentado como futura capacidade — hoje o usuário de escaneado recebe erro honesto mas sem saída.
3. **O que o resumo resume (⌘⇧M).** Trocar para trecho corrente: o controle passa a responder "o argumento da seção onde estou", com a janela de frases antes/depois a escolher. Manter o comportamento: o rótulo precisa deixar de prometer o trecho (renomear controle e cabeçalhos no README/INTERFACE).
4. **O lado que muda na divergência de idioma (README × código).** Corrigir o README ("Portuguese by default" sai): o app continua abrindo em inglês/voz en-US, documentado. Corrigir o código (padrão PT-BR + detecção do item 57): o app abre no idioma prometido, ao custo de trocar o padrão de quem já usa.
5. **⌘+/⌘−/⌘0 quando há PDF aberto.** Aplicar zoom no PDFView: o atalho faz o que o usuário espera, mas o PDFKit tem zoom próprio e o gesto pode conflitar com o acompanhamento de rolagem (risco médio, audit-ux item 8). Desabilitar com dica: sem conflito, mas os três atalhos continuam anunciando algo que não faz nada com PDF aberto e painel fechado. Nota da audit-a11y item 7: os atalhos declarados dentro do `Menu` podem nem disparar fora dele — o diagnóstico ao vivo vem antes da escolha.
6. **Prioridade: mais formatos × leitura corrente.** A auditoria de capacidades (seção 5) deixa explícito: priorizar "ler mais formatos" (EPUB, OCR) usa o mesmo `TextImport` que "ler melhor o que já abre" (navegação por frase, busca, página/outline) — as duas frentes não devem rodar em paralelo. É a decisão que ordena a última metade da lista.
7. **Bloco entre aspas.** Regra mais conservadora (exigir verbo dicendi ou vírgula) preserva diálogo à custa de manter alguns blocos citados que hoje são apagados de propósito; opção ao lado de "notas" dá controle ao usuário e paga uma superfície nova de Ajustes.
8. **Espaço = play/pause.** A auditoria de UI registra o desvio de convenção como justificado pelo gênero do app e recomenda manter e documentar; a auditoria de acessibilidade pede liberar o espaço para controles focados. As duas posições podem conviver (manter na janela sem foco, liberar com foco) — o conserto da junção é do dono.
9. **Reprodução por streaming se a medição confirmar memória gigante** (robustez item 6). Se o `AVAudioPlayer` carrega o WAV de horas em memória (não medido), o replay por `AVAudioPlayerNode` é o único caminho — decisão de engenharia, não patch, como a auditoria colocou.

## Medir antes de consertar

Ganhos que nenhuma auditoria mediu; nenhum desses entra em execução sem o número e, onde há escolha estrutural, sem decisão do dono.

* **`displayModel()`/`activeText` por tick de palavra** (robustez item 1): o join O(n) + reconstrução de ranges por batida de karaoke em documento de ~500 mil caracteres. Medir no Time Profiler o custo por tick e a fração de CPU da main durante leitura longa.
* **`fullText` O(n²) no `play`** (robustez item 3): a concatenação quadrática está provada no código, sem pausa em ms medida. Medir press de Play em documento grande antes de priorizar em relação ao item anterior.
* **Lookup de cache + sonda `AVAudioPlayer(contentsOf:)` no main a cada Play** (robustez item 4): medir se a sonda lê só cabeçalho ou carrega mais — decide o conserto (deslocar para `Task.detached`) e o custo real.
* **RSS de `concatWavs` manual sem ffmpeg em leitura longa** (robustez item 5): o cenário de ~1,6 GB é inferência do tamanho do PCM, não medição. Medir footprint com leitura de 5 h sem ffmpeg antes de reescrever a escrita do WAV.
* **Memória do `AVAudioPlayer` sobre o WAV único offline** (robustez item 6): medir em Activity Monitor/footprint em sessão longa; a correção por streaming só existe se a medição confirmar (ver decisão 9).
* **Sono do sistema durante a leitura** (capacidades item 14): a auditoria não sabe se o macOS já mantém a máquina acordada reproduzindo áudio. Medir primeiro; a lacuna de assertion de energia só existe se a leitura morrer no sono.
* **Contraste real dos textos informativos** (a11y itens 9 e 10): medir com Accessibility Inspector em claro/escuro e "Increase Contrast"; a auditoria sabe o uso, não o número.
* **Tempo percebido de "Lendo o PDF…" em PDF grande** (ux item 14): os 180 s vêm do código; medir com documento pesado se a espera real exige cancelamento (a auditoria sugere que 30 páginas estouram o limite declarado).
* **Escuta (áudio ao vivo)**: fronteira de fatia e três fatias curtas de abertura (`EdgeTTS.swift:247-252`, `:271`, `:390-391`, `:701-717`), prosódia do anúncio de nota colado depois do ponto e risco de anúncio duplo (`ReadAloudFilter.swift:265-290`), separador de milhar "1,500" na voz PT, pronúncia do DOI e do "p." integral — nada disso se fecha lendo código.
* **VoiceOver ao vivo**: ordem de foco no overlay player/status, espaço com Full Keyboard Access, atalhos do menu com paleta fechada, efeito do karaoke em braille, foco pós-sheet — checklist completa em audit-a11y, "O que só o VoiceOver ao vivo decide".

## Ondas sugeridas

Cinco ondas, cada uma com critério de agrupamento e itens. Itens pendentes de decisão do dono (37, 38, 56, 57 lado (a), 59) não têm onda: entram depois da escolha correspondente — o critério de entrada é a decisão, não o custo. Itens de desempenho (60) têm medição como passo 0, não conserto.

* **Onda 1 — Coração da fala (arquivos `TextImport.swift`, `ReadAloudFilter.swift`, `EdgeTTS.swift`; critério: mesma natureza, transformação de texto antes do sintetizador).** Itens 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 e 14. Cada conserto pequeno e coberto por teste de frase; o risco agregado é do arquivo compartilhado, não dos itens. Começar sobre a árvore final da fusão (as lanes desta rodada mexeram nesses arquivos).
* **Onda 2 — Feedback de uso (arquivos `ContentView.swift`, `L10n.swift`, `AppSettings.swift`; critério: o que o usuário percebe na sessão, consertos pequenos no canal de status e nas preferências).** Itens 1, 15, 16, 17, 24, 31, 32, 33, 34, 35.
* **Onda 3 — Acessibilidade (arquivos `ContentView.swift`, `ClickableTextView.swift`, `SpeechController.swift`; critério: VoiceOver, teclado, foco — fecha com teste assistido ao vivo).** Itens 18, 19, 20, 21, 22, 23, 25. Depende de certas mudanças já terem se assentado na Onda 2 (mesmos arquivos de UI).
* **Onda 4 — Consistência de UI/HIG (arquivos `EdgeSpeakApp.swift`, `PDFDocumentView.swift`, `PlayerBar.swift`, `SettingsView.swift`; critério: barra de menu, títulos, controles nativos).** Itens 2, 26, 27, 28, 29, 30. O arquivo `EdgeSpeakApp.swift` estava em escrita pela lane de Now Playing — reverificar estado antes de abrir.
* **Onda 5 — Robustez e capacidades levas (arquivos `SpeechController.swift`, `PiperTTS.swift`, `EdgeTTS.swift`, `AppSettings.swift`, docs; critério: recurso, memória, falha e limpeza — típicos caminhos de falha rara com dano alto).** Itens 36, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55. Os itens com "medir antes" (46, 47 e 60) abrem a onda com diagnósticos em vez de conserto.
