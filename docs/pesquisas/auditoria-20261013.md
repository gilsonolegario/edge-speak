# Auditoria independente — edge-speak

Data: 2026-10-13 · Escopo: `/Users/issoeocio/Projects/edge-speak` (~9,1k linhas)
Método: leitura estática de todos os 20 fontes Swift, 9 suítes de teste, 4 scripts Python, `Package.swift`, `INTERFACE.md`, `README.md`, `CREDITS.md`.

## Limitações desta auditoria

- **Nenhum código foi compilado nem executado** (restrição da tarefa: `swift build/test/package` proibido). Achados `[P]` têm caminho de disparo provado no código, mas não foram reproduzidos em runtime.
- **PROVISÓRIO** = arquivo sob edição simultânea durante a auditoria (`ReadAloudFilter.swift`, `TextImport.swift`, `AppSettings.swift`, `SettingsView.swift`, `ContentView.swift`, `L10n.swift`, `WordAligner.swift` e os testes). Linhas podem ter mudado desde a leitura.
- Marcas: `[P]` provado no código · `[S]` suspeita · `[?]` depende de execução.
- Vereditos: **CUMPRE** / **CUMPRE PARCIAL** / **NÃO CUMPRE**.

---

## 1. Veredito por parâmetro

### P1 — Destaque amarelo por palavra · CUMPRE PARCIAL (PROVISÓRIO)

- PDF: amarelo `systemYellow` α0.55 em `PDFDocumentView.swift:338` — correto `[P]`.
- Painel de texto: usa `controlAccentColor` α0.65 sobre branco em `ContentView.swift:317-319` — **não é amarelo**; depende do acento do sistema (que pode ser roxo, verde etc.) `[P]`.
- Monotonia do highlight garantida: backtrace NW monotônico; cursor só avança (`ContentView.swift:294-305`) `[P]`.
- Suspeita: `WordAligner` compara as palavras da frase contra o parágrafo **inteiro** sem âncora de início (`Phrase.words` = palavras do parágrafo, `TextImport.swift:142`) — palavra repetida em outra frase do mesmo parágrafo pode casar a ocorrência errada `[S]` (PROVISÓRIO).

### P2 — Destaque azul por frase · CUMPRE PARCIAL (PROVISÓRIO)

- 1 anotação `.highlight` por caixa da frase (`PDFDocumentView.swift:276-294`) com cor de acento α0.28 — azul **apenas** se o acento do sistema for azul `[S]`.
- Fallback `rects: boxes.isEmpty ? seg.rects : boxes` (`TextImport.swift:142`) destaca o parágrafo **inteiro** na via PDFKit quando não há caixas por palavra — leitor perde a granularidade da frase `[P]` (PROVISÓRIO).

### P3 — Rolagem manual vence + "Ir para o trecho" · CUMPRE

- Detector de rolagem do usuário (`PDFDocumentView.swift:97-110`, `174-193`) e botão (`ContentView.swift:471`, `484-496`).
- Brecha: o botão só aparece com `isReading`; durante `isBusy` antes da 1ª fatia não há atalho `[P]`.

### P4 — Clique inicia/pula na frase · CUMPRE

- Clique no painel (`ContentView.swift:541-556`) e retry (`SpeechController.swift:509-537`, `retryPendingJump`).
- **Bug**: `ClickReportingTextView` não filtra arrasto (`ClickableTextView.swift:97-107`) — arrastar para selecionar texto no painel dispara salto de frase; o PDF tem filtro de 4 pt (`PDFDocumentView.swift:48-50`) `[P]` (PROVISÓRIO — `ContentView`/testes sob edição).

### P5 — Salto por frase direto à fatia · CUMPRE

- `StreamingPlayer.swift:257-274`; teste `StreamingProofTests.saltoPorFraseSemDuracoes`.

### P6 — Texto integral / "Gerar leitura nova" descartam e recomeçam · CUMPRE

- `ContentView.swift:423`, `562-568`, `716-722`; `SpeechController.swift:427-452`.

### P7 — Voz persiste + Ajustes + PT default · CUMPRE

- Persistência `ContentView.swift:392-400`; default PT `EdgeSpeakApp.swift:28-30`, `SettingsView.swift:66-69`, `L10n.swift:433-436` (PROVISÓRIO).
- Nota: catálogo `voice.*` (~100 chaves PT+EN em `L10n.swift:194-246`, `373-424`) é **código morto** — a UI usa `AppSetting.voiceLabels`.

### P8 — Fórmulas por extenso com pausas · CUMPRE

- `ReadAloudFilter.swift:180-459` (tabela de expansão + pausas); coberto por `ReadAloudFilterTests` (PROVISÓRIO).

### P9 — Notas de rodapé anunciadas · NÃO CUMPRE (em obra)

- O filtro só **remove** marcadores e notas, silenciosamente (`ReadAloudFilter.swift:27`, `53`, `58-64`). Não há anúncio "nota de rodapé N", nem ler/pular `[P]` (PROVISÓRIO).

### P10 — Sem daemon/segredo; licenças · CUMPRE PARCIAL

- Sem daemon (one-shots `python3` com wait, `EdgeTTS.swift:604-618`, `PiperTTS.swift:339-348`); grep de segredos limpo.
- `CREDITS.md` registra Piper GPL-3.0, vozes CC0, PDFVoice MIT — mas **não registra PyMuPDF (AGPL)** embutido no app, apesar do README apontar "ver CREDITS.md" `[P]`.
- Rede além da síntese: download de vozes HF (`PiperTTS.swift:68`, `257`) e `pip` do GitHub no venv legado (`PiperTTS.swift:155`, só dev).

---

## 2. Bugs por gravidade

### Grave

1. **[P] Pausa durante síntese + Play = no-op silencioso.** `currentKey` só é gravado no final da síntese (`SpeechController.swift:385`); em `togglePlayPause` `sameInput` fica falso e a linha 206 retorna cedo. O botão fica habilitado e não retoma até a síntese terminar (`SpeechController.swift:195-206`). Disparo: pausar logo após clicar em "Gerar leitura nova".
2. **[P] `CacheDisco.store` chamado na main.** Executado dentro de `await MainActor.run` (`SpeechController.swift:396`) — cópia sincronizada de MP3/WAV grandes ⇒ congelamento de UI por frames.
3. **[P] Cor da palavra no painel não é amarela** (`ContentView.swift:317-319`, ver P1) — viola o parâmetro 1 na via texto (PROVISÓRIO).
4. **[P] Cache `attributedPhrases` com chave só "índice#palavra"** (`ContentView.swift:254-260`) — após troca de modo (texto/PDF) pode servir `AttributedString` do modo anterior enquanto `highlight == -1` (PROVISÓRIO).
5. **[P] Modo só-texto sem override de rolagem** — sem `onUserScroll` no `ClickableTextView` e o Toggle "Seguir leitura" some sem PDF (`ContentView.swift:686`): o teleprompter auto-roda sempre, sem como parar (PROVISÓRIO).

### Médio

6. **[P] Clique com arrasto dispara salto** no painel (`ClickableTextView.swift:97-107`); ver P4.
7. **[P] Fallback de caixas destaca parágrafo inteiro** (`TextImport.swift:142`); ver P2 (PROVISÓRIO).
8. **[S] `mapSegments` emparelha por posição** (`EdgeTTS.swift:266-288`) — menos eventos que eventos do script ⇒ segmentos empilhados com duração 0.
9. **[S] Ambiguidade de âncora do WordAligner** no parágrafo; ver P1 (PROVISÓRIO).
10. **[?] Notas de rodapé descartadas** sem anúncio; ver P9 (PROVISÓRIO).

### Baixo

11. **[P] `pkill -f synth_timing.py` / `piper_synth.py`** (`EdgeTTS.swift:604-618`, `PiperTTS.swift:339-348`) — mataria execuções manuais do usuário com o mesmo nome.
12. **[P] Botão "Ir para o trecho" ausente durante `isBusy`** antes da 1ª fatia (`ContentView.swift:484-496`, PROVISÓRIO).

---

## 3. Corridas main × fundo

- Estado de áudio e `currentKey` mutáveis fora da main com leituras na main — mitigações presentes (`MainActor.run` em pontos-chave), mas o `store` na main do item 2 inverte o custo (trava a UI).
- `sameInput`/`currentKey` no item 1 é corrida lógica clássica: leitura no início do fluxo, escrita só no fim.
- `pendingJump` tratado com retry (`SpeechController.swift:509-537`) — ok.

---

## 4. Código morto / duplicado

| Item | Local |
|---|---|
| `normalizedWord` | `ContentView.swift:176` (PROVISÓRIO) |
| `setStatus` | `SpeechController.swift:583` |
| `resume()` | `SpeechController.swift:547` |
| `seek(toSegmentAt:)` | `SpeechController.swift:495` |
| `highlightText` (escrito, nunca lido) | `SpeechController.swift:67` |
| `edgeTTSPath` | `EdgeTTS.swift:8` |
| `pendingCount`, `chunkStarts`, `currentGlobalTime` | `StreamingPlayer.swift:77`, `83`, `185` |
| `PDFTextExtractor.extract` | `PDFTextExtractor.swift:46` |
| retorno `integral` de `TextImport.readDocument` | `TextImport.swift` (PROVISÓRIO) |
| catálogo `voice.*` (~100 chaves) | `L10n.swift:194-246`, `373-424` (PROVISÓRIO) |
| indentação quebrada | `EdgeTTS.swift:78-147` (cosmético; compila — tipos aninhados por chaves) |

---

## 5. Deriva de documentação

- `INTERFACE.md` diz "37 testes em 6 suítes"; `README.md` diz 77 em 9; existem **9** arquivos de teste.
- `INTERFACE.md` lista `timeForSegment`, que **não existe**.
- `README.md` afirma "repetidas resolvem por contexto (±3)" — não há bônus de contexto no `WordAligner`.
- `CREDITS.md` omite PyMuPDF (AGPL); ver P10.

---

## 6. Testes faltantes (por garantia violada)

1. Clique/`pendingJumpIndex` — parâmetro 4 (PROVISÓRIO).
2. Pausa-retomada **durante** síntese — bug 1 (PROVISÓRIO).
3. Desalinhamento de `mapSegments` (menos eventos) — bug 8.
4. Cores efetivamente aplicadas (amarelo palavra / azul frase) — P1/P2 (PROVISÓRIO).
5. Notas de rodapé anunciadas — parâmetro 9 (PROVISÓRIO).
6. Poda do `CacheDisco`.
7. Ambiguidade de âncora do `WordAligner` no parágrafo — bug 9 (PROVISÓRIO).

Runner do projeto: `swift test` (Package.swift, tools 6.0) — **não executado** nesta auditoria.

---

## 7. Resumo dos vereditos

| Parâmetro | Veredito |
|---|---|
| P1 amarelo por palavra | CUMPRE PARCIAL |
| P2 azul por frase | CUMPRE PARCIAL |
| P3 rolagem manual + atalho | CUMPRE |
| P4 clique inicia/pula | CUMPRE |
| P5 salto por frase | CUMPRE |
| P6 gerar nova descarta | CUMPRE |
| P7 voz + ajustes + PT | CUMPRE |
| P8 fórmulas por extenso | CUMPRE |
| P9 notas de rodapé | NÃO CUMPRE |
| P10 licenças/sem daemon | CUMPRE PARCIAL |

**Totais**: 10 parâmetros — 6 CUMPRE, 3 CUMPRE PARCIAL, 1 NÃO CUMPRE.
**Achados**: 5 graves, 5 médios, 2 baixos (2 marcados `[S]`, 1 `[?]`, demais `[P]`; 9 de 12 em arquivos PROVISÓRIOS).
