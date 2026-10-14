# BACKLOG — pedidos do dono, com estado da prova

Legenda: [NO AR] está no app aberto e é testável agora · [CÓDIGO] implementado
e verde, esperando rebuild+relaunch · [OBRA] agente trabalhando · [ABERTO]
não implementado · [SUGESTÃO] proposta da assessoria, não pedida.

Sessão de 2026-10-13/14. Nenhum app no ar (fechado para rebuild limpo).
Repo público, histórico limpo (consolidado + tradução + fixes, empurrado);
tags `v0.1.0`/`v0.1.1` e releases preservados. Tradução EN integrada e verde
(133/18); release v0.1.1 publicado (bundle 103M).

Estado em 2026-10-14: auditoria bigpickle concluída e corrigida (literais
via L10n, trava do Piper sem bloquear main, SIGKILL no runSync); `edge-tts`
7.3.1 compatível provado (patch aplica/ok, sem pin — decisão do dono);
poda de comentários tolos delegada a 3 agentes em raias disjuntas;
`INTERFACE.md` completa em curso (docs); virada de página aguarda play
manual (ação do `ocu` não alcança a janela). Dieta dos wheels (82M,
`wheels/` → download sob demanda com progresso/erro/cache + testes)
autorizada pelo dono; entra APÓS as 3 raias (toca BundledEnv/ContentView
das raias 1–2); sem pin no edge-tts (7.3.1 compatível, fail-closed).

## Funcionalidade (pedidos)

- [NO AR] Clique toca a partir da frase clicada, mesmo sem play antes, e o
  PDF acompanha na hora (com seguimento desligado).
- [NO AR] Salto lê o ponto clicado (seek direto à fatia; sem grampear no
  áudio medido nem cair em fatia errada).
- [NO AR] Amarelo em palavra repetida com contexto ±3 (reproduzido p. 5).
- [NO AR] Fórmulas por extenso no idioma da voz, com pausas (⊢/⊨/∴/tal que)
  e ASCII (~, |-, /=, ^, / prosaico, ∼ inicial).
- [NO AR] Marcador de nota anunciado ("nota de rodapé 7"); número solto sem
  corpo em silêncio.
- [CÓDIGO] Corpo de nota lido direto após o anúncio + opção "Ler notas de
  rodapé" (default ligado; desligado vira pausa). Commit `5a4f6a5`.
- [CÓDIGO] Ligação em ordem crescente de número + posições rederivadas
  (não guarda posição após mover). Commit `9e45736`.
- [CÓDIGO] Régua horizontal como zona de notas + várias notas por página
  (sem marcador e abaixo da régua: sem número, marcada, no lugar).
  Commit `e0c5cdc`.
- [CÓDIGO] Régua perdida na decodificação + zona sintética por fonte:
  PageLines sem CodingKeys esperava footnoteRuleY e o JSON emite
  footnote_rule_y (a régua desenhada nunca chegava); bloco ≥2 linhas com
  número e fonte ≤0,85×mediana; continuações vão ao marcador.
  Commit `5dda99d`.
- [MEDIDO] Neutrality: 12 notas ligadas, zero frase de nota no fluxo da
  página; 2 falsos positivos contidos (marca d'água EBSCO, tabela de
  cabeçalhos); suíte 115 testes/13 suítes. Os "0 corpos" antigos eram a
  régua perdida, não ausência no arquivo.
- [CÓDIGO] Hífen de fim de linha com dicionário do sistema (`_junta_fim`:
  quebra some, composto mantém o hífen) + junção na virada de página +
  elisão curta; caixa do junto fica na página anterior (união entre
  páginas corrompia a ordem no Swift). Commit `f959d82` + correção da
  caixa neste commit.
- [CÓDIGO] Anúncio da nota pelo pipeline (`Phrase.notaMarcador`, do
  `resolveFootnotes` ao `forSpeech` nos 3 motores): anuncia mesmo quando
  o dígito vem em forma que a regex cala. Medido: 11/12 anunciadas no
  modo filtrado, voz inglesa. Neste commit.
- [FEITO] Nota 4 no modo filtrado: a regra de linha de fórmula só apaga linha
  sem minúscula ou com até 60 caracteres; prosa longa com símbolo sobrevive.
  Medido: 5 frases da nota 4 de volta, 12/12 anunciadas. Commit `650470f`
  (integra o worktree fluencia; teste de regressão em ReadAloudFilterTests).
- [CÓDIGO] Transição entre fatias: corte prefere fim de parágrafo
  (`buildChunks` recua ao `paragraphEnd`) + aparo do silêncio final da
  fatia via ffmpeg (só troca se encolher >2 KB; tempos intactos, duração
  medida do aparado). Medido num MP3 real do Edge: 5,808 s → 5,602 s.
  Suíte 123 testes/14 suítes. Neste commit.
- [CÓDIGO] Auditoria Big Pickle, onda 1+2 (conferência do orquestrador,
  suíte 128/16): M1 `isStarved` conta como tocando no salto; M5 inserção
  da nota contabiliza remoções; B1 espelho só republica em mudança; A2
  JSON de tempos ilegível avisa no status; A1 leitura de filho com poll
  + SIGKILL (via Muse); M2/B4/B6 higiene (fail, import, SIGKILL).
  Commits `34e13d4`…`259ef81`.
- [FEITO] Auditoria, ondas 3–5 (suíte 133/18 verde): M4 purga protege o Piper
  (`keepOfflineDirectory`); B2 `EdgeTTS.run` virou async com `Task.sleep`
  cancelável; B3 duração do WAV varre os chunks até o `data`; M3 cache de
  atributos com geração do texto; B5 clique reatribuído em `updateNSView`.
  Commits `184f5c1` (motores), `84a6a21` (M3/B5). Tradução: rebase
  COMPLETO (branch `translate-en`, 12 commits sobre 81aead2, cabeça
  `ef4c479`); merge na main pendente (medido: 23 arquivos em conflito).
  Fluência (N4 + hífen com evidência interna): INTEGRADA no `650470f`.
- [MEDIDO] No artigo de teste: 12 marcadores distintos (1–12), 12
  ocorrências — todos anunciados; 0 corpos no arquivo (só números).
- [LIMITE] Corpos ausentes neste artigo (perícia: sem texto, anotação,
  imagem ou glifo — só números 1–15): anúncio sem corpo seguinte. Não
  inventar; documentado no código.
- [CÓDIGO] Cache v3 (geração do repartidor na chave). Commit `750a02a`.
- [NO AR] Barra com PDF aberto; tradução PT/EN com seletor; voz persistida;
  Ajustes em 3 abas; descarte de transcrição.
- [NO AR] Play retoma com síntese em curso; cache fora da main; pulo morre
  no erro; amarelo unificado painel/PDF; toggle sem PDF; arrasto não pula.
- [ABERTO] 15 s iniciais sem destaque (causa não isolada).
- [CÓDIGO] Hífen de fim de linha + virada de página no destaque
  (pesquisa em `docs/pesquisas/pymupdf-pesquisa.md`; 77→2 tokens partidos
  no artigo; frase parte por página sem atravessar caixa). Commit `23e9f27`.
- [FEITO] Marcador geométrico por span (`sup` no extrator; o Swift já o lê).
  Medido: 12/12 marcados, JSON idêntico à base ignorando `sup`. Limite: o
  `temSup` ainda exige miolo == N; sufixo colado fica como próximo passo.
  Commit `2b6e148` + dossiê `docs/pesquisas/pymupdf-tipos.md`.
- [FEITO] Aba Avançado: já tinha limpeza de cache (commit `052281e`); o item
  estava obsoleto. Agora tem também diagnóstico copiável (commit `66832a9`).
- [FEITO] Trilho honesto: `elapsed` lê `currentGlobalTime` (posição real do
  player). Teste `TrilhoHonestoTests` (falha sem a correção). Commit `7482b17`.

## Limites honestos (não são bugs)

- O artigo de teste não tem corpo de nota na camada de texto (só números
  1–15): leitura de corpo só é demonstrável noutro PDF.
- Símbolo que chega como imagem não é lido; voz online depende do endpoint.

## Sugestões não pedidas (triagem do orquestrador, 2026-10-14)

- [FEITO] Retomar por documento: já existe (ReadingPositionStore + retomada).
- [FEITO] Temporizador de parada: submenu em Opções (0/5/15/30/60 min),
  countdown por `task(id:)`, para e zera ao fim. Commit `66832a9`.
- [FEITO] Log diagnóstico copiável (versões, venv, último erro): `Diagnostics.swift`
  + botão na aba Avançado. Commit `66832a9`.
- [IDEIA] Dicionário de pronúncia, exportação com tempos, fila de
  documentos, sumário como capítulos: valor real, custo moderado; sem dono.
- [IDEIA] Sucessor do Piper (`sherpa-onnx`, mesmas vozes `.onnx`): avaliar
  (qualidade/latência/tamanho) SOMENTE se o Piper falhar; sem teste, sem menção.
- [NÃO] Modo ditado (fora do propósito do app), estatísticas (vaidade),
  IDs estáveis entre modos (sem consumidor que precise — YAGNI).

## Documentação e mapa (pedidos)

- [ABERTO] Documentação completa (README/INTERFACE) — agente de docs caiu
  2× (erro 400 do provedor); README recebeu badge+History 0.1.1 e remoção
  IINA/PDFVoice (`d271254`, `1faba28`); INTERFACE completa pendente.
- [PRONTO] Mapa funcionalidade→código (`docs/pesquisas/mapa-funcionalidades.md`).
- [PRONTO] Auditorias (`docs/pesquisas/auditoria-20261013.md`,
  `avaliacao-paralela.md`) e mapa OSS (`docs/pesquisas/oss-mapa.md`).
- [PRONTO] Pesquisa PyMuPDF todos-os-tipos + marcador geométrico
  (`docs/pesquisas/pymupdf-tipos.md`, commit `2b6e148`).

## Infra (pedidos)

- [NO AR] Repo privado→público com GPL-3.0; `build-app.sh` aborta com app
  aberto (rebuild por cima corrompia o bundle — medido).
- [FEITO] Rebuild+relaunch 0.1.1 (`EdgeSpeak.app` 130M, pid 89152, volume 0
  para verificação sem som). `build-app.sh` aborta com app aberto (rebuild
  por cima corrompia o bundle — medido).

## Sugestões da assessoria (NÃO pedidas — decidir)

- Retomar onde parou por documento; dicionário de pronúncia; modo ditado;
  exportação com tempos; fila de documentos; temporizador; sumário como
  capítulos; estatísticas; log diagnóstico para o amigo; IDs estáveis entre
  modos integral/filtrado.
