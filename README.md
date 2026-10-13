# EdgeSpeak

Leitor de PDF e texto com leitura em voz alta em fluxo, para macOS (SwiftUI, macOS 14+). Cada fatia sintetizada começa a tocar assim que fica pronta, sem esperar o documento inteiro — num PDF de 300 páginas a voz entra em segundos. A frase em leitura fica destacada no PDF e no painel de texto; com voz online, a palavra em leitura também é destacada (karaokê).

Estado: em desenvolvimento ativo, com 88 testes em 10 suítes verdes. O contrato técnico entre camadas (arquivos, funções e regras) está no INTERFACE.md; créditos e licenças de terceiros, no CREDITS.md.

## Motores de voz

Duas vozes no mesmo transporte; a troca é pelo seletor na toolbar ou na aba Leitura dos Ajustes.

- **Online (edge-tts)**: vozes neurais da Microsoft, exige rede. Devolve tempos por palavra — por isso só aqui existe o destaque palavra a palavra. Se o serviço recusar (como no bloqueio global do endpoint antigo em 10/10/2026), o app diz isso com honestidade e sugere a voz offline, em vez de repetir em vão.
- **Offline (Piper)**: síntese local, uma frase por vez, sem tempos de palavra. Há destaque da frase, sem karaokê. As vozes embutidas (Faber em português, Lessac em inglês) aparecem em seção própria do seletor; crédito e licença (GPL-3.0) no CREDITS.md.

## Leitura e destaque

- **Azul por frase**: uma anotação de destaque por caixa de linha da frase — nunca o parágrafo. As caixas vêm do extrator, em ordem de leitura, com reserva para o parágrafo quando a frase não casa.
- **Amarelo por palavra** (só online): alinhamento global entre a sequência falada e a sequência do PDF. Onde o PDF põe símbolo e a voz põe frase ("∃uT (u,o)" vira "there exists u, such that, T of u"), a palavra de expansão fica **sem caixa** em vez de roubar a de prosa adiante — era isso que fazia o amarelo pular de lado a lado. Repetidas resolvem por contexto (±3), não pela primeira ocorrência.
- **Rolagem**: o seguimento automático pode ser desligado — a rolagem manual sempre vence. Com ele desligado, o botão "Ir para o trecho" volta ao ponto da leitura. Clicar numa frase **toca a partir dela**: sem áudio ainda, a síntese começa na frase clicada (não do início); com áudio, o salto vai direto à fatia, sem depender de durações ainda não medidas; o PDF acompanha na hora.
- **Transcrição**: modo filtrado (limpa cabeçalhos, hifenização, bibliografia) ou integral ("Texto integral" nos Ajustes). Trocar o modo descarta a transcrição e recomeça; "Gerar leitura nova" (menu Opções) força síntese nova. O áudio fica em cache em disco com chave por texto+voz+cadência: reabrir o mesmo documento reaproveita sem rede.
- **Notas de rodapé** (ligado por padrão): o marcador colado ("argumento.7") é anunciado ("nota de rodapé 7") e o corpo da nota é lido logo em seguida — o importador o move para depois da frase do marcador, sem mudar os índices das demais frases. A opção "Ler notas de rodapé" (Ajustes → Texto) desliga tudo: o marcador vira pausa e os corpos saem da leitura. Limite honesto: em PDF cuja camada de texto não traz o corpo da nota, só o marcador é anunciado — a ligação marcador↔corpo está pronta e coberta por testes, mas depende do que o extrator encontrar.

## Fórmulas lógicas

O filtro fala (`ReadAloudFilter`) expande a notação no idioma da voz, com as pausas que a leitura em aula usa — pausa curta antes/depois de ⊢/⊨, pausa antes de ∴/∵, vírgula prosódica após a variável do quantificador e no "tal que". Cobertura (EN/PT):

- Quantificadores ∀ ∃ ∃! com variável ("para todo x,", "existe x, tal que,"), modais □ ◇ ("necessariamente", "possivelmente"), turnos ⊢ ⊨ e negações ⊬ ⊭, ASCII `|-` `|=` `->` `=>` `<->`.
- Conjuntos ∈ ∉ ⊆ ∪ ∩ ∖ ∅ ℘, construtor `{x | φ}` / `{x : φ}` ("o conjunto de x, tal que,"), ferradura ⊃ por contexto (entre conjuntos é superconjunto, entre fórmulas é condicional).
- Gregas pelo nome (φ "fi", λ, Γ…), blackboard-bold ℕ ℤ ℚ ℝ ℂ, iota ℩ ("o x tal que"), cantos de Quine (silêncio com pausa de menção), primos p′ ("p linha"), §2 ("seção 2"), functores ("T de u, o"), R_H ("R H").
- Comparações `<=` `>=` `!=` `<>` `/=`, identidade, ⊥/⊤ ("falso"/"verdadeiro" em PT).
- **Silêncio deliberado**: `[]`/`<>` como modal, `x` de "3 x 4" como vezes, barra solta fora de construtor e chave de agrupamento nunca viram palavra — em prosa comum, verbalizar estragaria a frase.

Limite conhecido: a qualidade depende da camada de texto do PDF; símbolo que chega como imagem não é lido.

## Interface

Desenho do IINA. Toolbar no topo (Abrir, seletor de voz, menu Opções com seguir-leitura, fonte, "Gerar leitura nova" e Ajustes). Conteúdo: o PDF, ou o painel de texto clicável. Na base, barra flutuante sempre visível: interromper/cancelar síntese, ±15 s, play/pausa, tempo + trilho arrastável, volume e exportação do áudio (WAV/MP3).

Atalhos: Enter alterna play/pausa; Espaço faz o mesmo fora do editor e do PDF; ⌥←/⌥→ pulam 15 s; ⌘. interrompe a síntese.

Ajustes (⌘,) em três abas: **Leitura** (voz, ritmo, seguir leitura, idioma PT/EN), **Texto** (fonte, texto integral, ler notas de rodapé) e **Avançado** (vazia por enquanto). Tudo persiste entre sessões. A interface existe nos dois idiomas com troca na hora (catálogo compilado, padrão PT); nomes de voz e mensagens de progresso dos motores seguem no idioma de origem.

Arquivos abrem pelo botão Abrir (PDF, Markdown, texto), por duplo-clique com "Abrir com o EdgeSpeak", por arraste ao ícone e por argumento de linha de comando.

## Compilar, testar, empacotar

Pré-requisito: macOS 14+ e SwiftPM (o app só é montado e testado em Mac moderno).

```sh
swift build
swift test
./build-app.sh   # gera EdgeSpeak.app (~280 MB) na raiz do projeto
```

O `build-app.sh` baixa a base Python, os wheels e as vozes **na hora do build** e monta o `.app` com tudo dentro (detalhes no cabeçalho do script); o venv é preparado no primeiro uso do app, em `Application Support/EdgeSpeak`, a partir do que viaja no bundle. O áudio em cache mora em `Caches/EdgeSpeak`. Nada é instalado como daemon e nada roda em fundo.

O que nunca entra no repositório (`.gitignore`): `.build/`, `Build/` (staging com base Python, wheels e vozes, ~490 MB), `EdgeSpeak.app/`, `DerivedData/`, `.swiftpm/`, venvs (`.venv/`, `venv/`, `__pycache__/`), `.DS_Store`, `.scratch/`, `NOTAS_SESSAO.md`, `PROXIMA_SESSAO.md`, `*.log` e metadados de editor (`xcuserdata/`, `.idea/`, `.vscode/`).

## Licenças de terceiros

Piper (voz offline, GPL-3.0) e PyMuPDF (extração, AGPL) viajam com o app — ver CREDITS.md. Enquanto o código for privado e de uso próprio, não há imposição; abrir publicamente exigirá redistribuir sob as mesmas licenças.

## Limites conhecidos (2026-10-13)

- Os primeiros segundos de áudio podem tocar sem destaque no PDF — causa ainda não isolada (a fatia chega e toca antes de o destaque assentar; reprodutível mas não explicada).
- Corpos de nota de rodapé em PDFs cuja camada de texto não os traz (como o artigo de teste): o marcador é anunciado, o corpo não existe para ser lido. O pipeline de ligação marcador↔corpo está pronto e testado com listas sintéticas.
- Aba Avançado dos Ajustes sem itens.
- Voz online depende do endpoint da Microsoft; indisponibilidade global aparece como mensagem, não como travamento.

## Melhorias futuras sugeridas

- Notas de rodapé por geometria: hoje a ligação marcador↔corpo é textual (regex sobre o texto); detectar o marcador pela caixa (superscript pequeno e elevado) distinguiria melhor o colado de "mp3".
- Dicionário de pronúncia do usuário (nomes próprios, siglas do orientador).
- Posições de leitura persistidas por documento (retomar onde parou).
- Fila de documentos e exportação com tempos (p. ex. legenda/WebVTT) para revisão.
- Gerenciador de vozes offline (baixar/apagar sem rebuild).
- Modo ditado (verbalizar parênteses) para revisão de fórmulas símbolo a símbolo.
- Restauração de sessão (reabrir o documento que estava aberto) e auditoria VoiceOver completa.
- Desempenho medido em PDFs de 300+ páginas (tempo até a primeira fatia por tamanho).
- Alinhamento forçado offline (Montreal Forced Aligner, MIT) para karaokê por palavra com voz Piper — caminho pesquisado, sem integração ainda.
