# Proposta de melhoria e limpeza — EdgeSpeak (2026-10-18)

Este documento é uma proposta para o dono do projeto. Nada foi publicado e a árvore viva
não recebeu commit. O app continua rodando com a correção do destaque; o que está pronto,
o que foi medido e o que ficou aberto está separado por seção, cada afirmação com sua
evidência.

## 1. O que está pronto e verificado

O destaque (⌘⇧H) está corrigido: uma anotação por retângulo de linha, só `bounds`, sem
substituir a anotação inteira. A verificação foi por mutação — removendo
`lineRects(forQuads:)` de `HighlightStore`, quatro testes de `UserHighlightLinePaintTests`
falham exatamente como deviam; revertida a mutação, a suíte volta a 383/383 na árvore viva.
O app corrigido está em execução (pid 46910, `Neutrality_v93.pdf`); o teste final de
experiência é do dono.

A unificação das frentes está no ramo `reconciliacao-final`, sem tocar a main. As etapas
1–4 estão comitadas: fusão da base (`a451730`), Ondas 2/3/5 (`772ff5f`), GLM Onda 1
(`e23ddd4`), Big Pickle Onda 4 (`972694e`) e o-ideal (`f053be2`). A etapa 5 reconciliou
essas etapas com a árvore viva: o merge `4fa22cb` recebeu o fechamento `43ceef7` e o
resultado é build limpo e **400 testes em 52 suítes, todos verdes**, medidos em
2026-10-19. A flaky conhecida `StreamingProofTests.prebufferReleasesWhenProbeLands`
passou na suíte completa desta rodada.

O `BACKLOG.md` foi reescrito de 464 para 166 linhas, só com pendências (backup em
`.superpowers/backup-BACKLOG-2026-10-18.md`). O `README.md` passou a declarar a suíte real
(400 testes em 52 suítes) e o `INTERFACE.md` aponta para ele em vez de repetir a tabela.

## 2. Melhoria entregue, frente por frente

| Frente | Entrega | Verificação |
| --- | --- | --- |
| Fusion (`a259c05`) | Base do destaque e do anúncio de nota | Big Pickle conferiu 196/196; auditoria própria: `releasePrebufferIfReady` é guardado e idempotente (`StreamingPlayer.swift:179/240/483`) — não há duplo release |
| GLM, Onda 1 (`c868505`) | Fim de frase com fechamento de aspas; abreviações revisadas (`pág`/`sect`/`eq` dentro, `no`/`nos` fora); hifenização de fim de linha em `.txt`/`.md` e formas invisíveis (U+00AD, U+2010, U+2013) | 204/204 no ramo; conflitos revisados na unificação |
| OpenRouter, Onda 2 (`66c5d58`) | Itens 34/31/33/17 do plano | 5 itens pulados, declarados |
| Space Bunny, Onda 3 (`7c4acf7`) | Acessibilidade 18–25 | Itens 19/21/23 marcados `[NA MAIN]`; contraste (25) sem medição |
| Big Pickle, Onda 4 (`ff7ef79`) | UI/HIG: menu bar, título da janela, barra estável, aviso de cache nos ajustes | Cortes declarados: "página visível" (26) e "Parar" no menu |
| Beam, Onda 5 (`bd15207`) | Robustez | 196/196 |
| o-ideal (`7b232b0`) | Rastejo por slots (nudge multi-slot, 6 testes em `NudgeSlotsTests`) e geração na chave do cache do `WordAligner` (+1 teste) | 204 no ramo da frente; entrou na etapa 4 (`f053be2`, 214 testes/30 suítes) |

## 3. O que foi medido e não entrou

Subir o timer de destaque para 15 Hz não paga. O microbench headless em PDFKit mediu:
remove+add da anotação por palavra (o desenho atual) 23,9 µs; troca in-place só de `bounds`
11,2 µs; marcar `needsDisplay` 0,4 µs; in-place completo 12,2 µs; busca binária por tick
0,2 µs. O ganho teórico dos 5 ticks extras por segundo é da ordem de 1 µs/s — ruído. A
troca in-place já foi testada ao vivo, regrediu e foi revertida (`c64e13c`); reabrir sem
evidência nova seria repetir o erro. O mesmo vale para o realce por palavra no painel: há
um desenho (pré-computar os ranges por frase no `Coordinator` de `ClickableTextView`, uma
vez por frase, com chave `(highlightIndex, palavras filtradas, attrGeneration)`), mas ele
precisa de medição antes de sair; não foi implementado.

## 4. Limpeza: números e proposta

O bundle tem 131 MB: 3,1 MB de binário, 46 MB de `pythonbase` e 82 MB de `wheels`. Não
cortei nada porque o uso em runtime dos `wheels` não foi medido — o corte de 82 MB é
hipótese, não fato. A ação segura é medir se o app lê de `wheels` depois do primeiro
lançamento; se não lê, o corte é grande e barato.

| Item | Tamanho | Ação proposta | Situação |
| --- | --- | --- | --- |
| `.gitignore` incompleto | — | Incluir `.superpowers/`, `.scratch/`, `.build/`, `buildapp.log`, `Tools/__pycache__/` | Feito: todas as entradas presentes, `.superpowers/` inclusive |
| Worktrees ociosas (4 o-ideal + `fix-repeat-highlight`) | ≈1,36 GB (617+546+168+167+167+313 MB medidos; as 5 primeiras somam 1,36 GB sem contar a `mv9ucr7c`) | Remover as paradas, uma vez confirmado que os commits estão no ramo unificado | Aguardando ok do dono |
| `o-ideal-...-mv9ucr7c` | 617 MB | Etapa 4 verificada (`f053be2`); pode sair | Liberada, aguardando ok |
| Disco | 16 GiB livres | Abaixo da reserva operacional de 20 GiB; a limpeza acima devolve ≈2,0 GB | Alerta |

Sobre o relatório da Laguna: o "duplo release" do pré-buffer não procede — a função é
guardada e idempotente e a árvore viva está à frente da commit analisada. A consolidação
`HighlightStore`/`HighlightDiskStore` é sugestão de desenho (558 linhas referenciadas por
`ContentView` e `PDFDocumentView`), não dívida: os dois são usados e testados. O que vale
manter da limpeza é o `.gitignore`, a remoção de worktrees paradas e a medida do bundle.

## 5. O que ficou aberto (fatos, com âncora)

1. Filtro de bloco entre aspas: `ReadAloudFilter.swift:765-776` — depende da decisão do
   item 7 do plano.
2. Zoom ⌘+/−/0 não implementado — decisão do item 5.
3. Streaming só medido, não otimizado: `displayModel()` a cada render e o trecho O(n²) em
   `SpeechController.swift:570-575` — decisão do item 9.
4. `playList()` entrega a lista inteira de uma vez (`ContentView.swift:340-347`).
5. EPUB, dicionário e fila não têm código — decisão do item 59.
6. Aviso de build em `ContentView.swift:1973` (1 aviso, não bloqueia).
7. `nullDevice` remanescente em `PiperTTS.swift:630-631`.

Decisões do dono ainda em aberto: vozes do macOS ("faço"); sinal de "concluí, publica"
para o release; itens 5/7/9/57-lado-a/59 do plano; ok para a limpeza de disco acima.

## 6. Publicação (roteiro, quando autorizado)

Conferir a visibilidade do repositório (`gh repo view --json visibility`) antes de
qualquer coisa. O commit do fechamento sai no ramo próprio, nunca direto na main. O zip é
gerado a partir do app reconstruído; o comprador precisa remover a quarentena
(`xattr -dr com.apple.quarantine EdgeSpeak.app`) e abrir com clique-direito → Abrir,
porque o app não é notarizado. Nada disso acontece antes do sinal do dono.

## 7. Evidência

- Mutação do destaque: `/private/var/folders/ml/03lssd3n25n5bvvylrcrbfyc0000gn/T/opencode/{hlt-baseline,hlt-mutation,hlt-restore}.log` — 383/383 no `hlt-restore.log`.
- Unificação: `reconciliacao-final` — `f053be2` (etapas 1–4), `4fa22cb` (merge do snapshot da árvore viva) e `43ceef7` (fechamento); suíte final 400 testes/52 suítes, toda verde.
- Etapas 3 e 4: 206/29 (1 flaky isolada em 0,07 s) e 214/30, verdes na época.
- BACKLOG: 166 linhas; backup em `.superpowers/backup-BACKLOG-2026-10-18.md`.
- Bundle: `du -sh EdgeSpeak.app` = 131 MB (pythonbase 46 MB, wheels 82 MB).
- Worktrees: `du -sh` no diretório de worktrees do OpenCode, medido em 2026-10-18.
