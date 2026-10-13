# BACKLOG — pedidos do dono, com estado da prova

Legenda: [NO AR] está no app aberto e é testável agora · [CÓDIGO] implementado
e verde, esperando rebuild+relaunch · [OBRA] agente trabalhando · [ABERTO]
não implementado · [SUGESTÃO] proposta da assessoria, não pedida.

Sessão de 2026-10-13. Build no ar: pacote `build-app-10` (pid 46492).
Repo público com histórico desde `0aa5658`.

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
- [ABERTO] Nota 4 no modo filtrado: o `clean`/`reflow` come o trecho
  inteiro do marcador na p9 ("witness would…stand or fall together" some
  da lista filtrada; na integral o marcador liga as 5 frases). Rastro
  pronto, correção pendente.
- [CÓDIGO] Transição entre fatias: corte prefere fim de parágrafo
  (`buildChunks` recua ao `paragraphEnd`) + aparo do silêncio final da
  fatia via ffmpeg (só troca se encolher >2 KB; tempos intactos, duração
  medida do aparado). Medido num MP3 real do Edge: 5,808 s → 5,602 s.
  Suíte 123 testes/14 suítes. Neste commit.
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
- [ABERTO] Marcador geométrico (bit de sobrescrito) e corpos onde existirem.
- [ABERTO] Aba Avançado vazia (preencher com limpeza de cache ou remover).
- [ABERTO] Trilho honesto no streaming (ainda grampeia no áudio medido).

## Limites honestos (não são bugs)

- O artigo de teste não tem corpo de nota na camada de texto (só números
  1–15): leitura de corpo só é demonstrável noutro PDF.
- Símbolo que chega como imagem não é lido; voz online depende do endpoint.

## Documentação e mapa (pedidos)

- [OBRA] Documentação completa (README/INTERFACE) — agente com rate limit,
  retomar; lista de ajustes editoriais com o principal.
- [PRONTO] Mapa funcionalidade→código (`docs/pesquisas/mapa-funcionalidades.md`).
- [PRONTO] Auditorias (`docs/pesquisas/auditoria-20261013.md`,
  `avaliacao-paralela.md`) e mapa OSS (`docs/pesquisas/oss-mapa.md`).
- [OBRA] Pesquisa PyMuPDF todos-os-tipos (agente em fundo).

## Infra (pedidos)

- [NO AR] Repo privado→público com GPL-3.0; `build-app.sh` aborta com app
  aberto (rebuild por cima corrompia o bundle — medido).
- [ABERTO] Próximo rebuild+relaunch (leva cache v3 + BACKLOG): precisa
  fechar o app (⌘Q).

## Sugestões da assessoria (NÃO pedidas — decidir)

- Retomar onde parou por documento; dicionário de pronúncia; modo ditado;
  exportação com tempos; fila de documentos; temporizador; sumário como
  capítulos; estatísticas; log diagnóstico para o amigo; IDs estáveis entre
  modos integral/filtrado.
