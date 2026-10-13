# PyMuPDF por tipo de PDF — largura para o EdgeSpeak

Contexto: complementa `/tmp/opencode/pymupdf-pesquisa.md` (que cobre as 6 dores do PDF acadêmico atual). Aqui a largura: como cada tipo de PDF se comporta na extração com PyMuPDF 1.28.2 e o que o app deve fazer. Pesquisa em 2026-10-13. Status: [estabelecido] = literal na doc oficial; [suportado] = doc + discussão de mantenedor; [inferência] = conclusão nossa, marcada.

## 1. Digitalizado (só imagem, sem camada de texto)

- Detecção [estabelecido/inferência]: `page.get_text().strip() == ""` com `page.get_images()` / `page.get_drawings()` não-vazios; critério documentado no guia OCR: "page is completely covered by an image", "no text exists on the page", "thousands of small vector graphics (indicating simulated text)" — https://pymupdf.readthedocs.io/en/latest/recipes-ocr.html
- O que quebra: `get_text("words")` devolve vazio; nada para narrar nem destacar.
- Receita [estabelecido]: `tp = page.get_textpage_ocr(...)` uma vez por página e reusar via parâmetro `textpage=tp` em extrações/buscas ("do OCR only once per page and store the result in a TextPage") — https://pymupdf.readthedocs.io/en/latest/recipes-ocr.html . Para PDF digitalizado completo: renderizar cada página a Pixmap (RGB, sem alpha), `Pixmap.pdfocr_save()/pdfocr_tobytes()` gera PDF de 1 pág. com camada oculta em `GlyphLessFont` — mesma página. Alternativa externa: OCRmyPDF gera PDF com camada pesquisável e o app extrai normal [inferência]. Para o EdgeSpeak [inferência]: acima de limiar (ex. pág. sem texto), marcar "página digitalizada", oferecer OCR sob demanda, nunca narrar vazio; texto OCR vem sem fonte/negrito/itálico reais (sempre GlyphLessFont regular preto) — calibrar detecção de notas por geometria, não por fonte.
- Fonte extra: requisitos (pixmap RGB sem alpha; Tesseract não reconhece vetores) — https://pymupdf.readthedocs.io/en/latest/recipes-ocr.html

## 2. Camada de texto parcial ou fora de ordem (content stream)

- Detecção [inferência sobre dado estabelecido]: comparar `page.get_text()` (ordem de criação) vs `page.get_text(sort=True)` (top-left→bottom-right); divergência grande + blocos esparsos = produtor bagunçado. A doc confirma a causa: "text may not appear in any particular reading order... responsibility of the PDF creator"; cabeçalho inserido depois aparece no fim da extração — https://pymupdf.readthedocs.io/en/latest/recipes-text.html
- O que quebra: narração fora de sequência; cabeçalho/rodapé inserido depois cai no fim do texto.
- Receita [estabelecido]: 1) `sort=True` ("sort the output from top-left to bottom-right"); 2) CLI `python -m pymupdf gettext` em modo layout-preserving; 3) extrair `"blocks"`/`"words"` com bbox e reordenar por área — https://pymupdf.readthedocs.io/en/latest/recipes-text.html ; detalhe do `sort` por forma — https://pymupdf.readthedocs.io/en/latest/textpage.html . Para o EdgeSpeak [inferência]: manter `sort=False` + `dict` (block_no/bbox) e deixar o XY-cut do Swift decidir; `sort=True` como fallback barato em 1 coluna.

## 3. PDF etiquetado / UA (árvore de estrutura)

- Detecção [inferência]: PyMuPDF não expõe API de estrutura lógica/Marked Content como tal; sinal indireto é `doc.get_toc()`, `page.get_links()`, ordem de `dict` já coerente. Não há "atalho pronto" de árvore Structure Tree na doc pública — ausência verificada nas páginas Document/Page/TextPage (nenhum método `get_struct_tree`) — https://pymupdf.readthedocs.io/en/latest/document.html ; https://pymupdf.readthedocs.io/en/latest/page.html
- O que quebra: sem atalho, a ordem lógica de leitura de PDF/UA não vem de graça; o app lê ordem geométrica.
- Receita [inferência, marcada]: tratar PDF/UA como PDF comum bem-formado (sort + blocos tende a acertar); se precisar da árvore real, ler `StructTreeRoot` via baixo nível (`doc.xref_*` / PDF dict — https://pymupdf.readthedocs.io/en/latest/document.html ) ou biblioteca paralela (pypdf/pdfminer extraem `/StructTreeRoot`), sem promessa de destaque por palavra a partir dela. Status honesto: sem atalho pronto no PyMuPDF até 1.28.2.

## 4. Formulários AcroForm e XFA

- Detecção [estabelecido]: `page.widgets()` (gerador de Widget) não-vazio; `doc.xref_get_key(-1,"AcroForm")` / checar XFA. Classe Widget e uso em formulários — https://pymupdf.readthedocs.io/en/latest/widget.html ; listagem de widgets por página no tutorial — https://pymupdf.readthedocs.io/en/latest/tutorial.html
- O que quebra: valores digitados em widgets **não** saem em `get_text` (são anotações/objetos à parte, como em §6 do guia anterior) — mesma família do fato "texto de anotação/widget não sai no get_text" — https://pymupdf.readthedocs.io/en/latest/page.html . XFA (XML dinâmico) não tem suporte de extração no PyMuPDF [inferência a partir da ausência na doc].
- Receita [estabelecido]: iterar `for w in page.widgets(): w.field_value`, `w.field_name`, `w.field_type`; após editar, `Document.reload_page` / `page.reload` antes de reler — https://pymupdf.readthedocs.io/en/latest/widget.html ; https://pymupdf.readthedocs.io/en/latest/page.html . Para o EdgeSpeak [inferência]: narrar "campo <nome>: <valor>" após o texto da página; XFA → avisar "formulário dinâmico sem texto extraível" e oferecer render+OCR.

## 5. PDF cifrado com senha

- Detecção [estabelecido]: `doc.needs_pass` (True = precisa senha), `doc.is_encrypted`; `doc.authenticate(pw)` devolve >0 se ok — https://pymupdf.readthedocs.io/en/latest/document.html ; visão geral em — https://pymupdf.readthedocs.io/en/latest/the-basics.html (seção de descriptografia, citada em busca oficial)
- O que quebra: sem autenticar, `get_text` falha/retorna vazio ou levanta; senha de dono vs usuário limitam subconjunto (imprimir/extrair) — discussão oficial de permissões existe no tracker do projeto [suportado].
- Receita [estabelecido]: `doc = pymupdf.open(path); if doc.needs_pass: rc = doc.authenticate(senha)`; se `rc<=0`, pedir senha de novo; para normalizar, salvar cópia descriptografada (`doc.tobytes(garbage=3, deflate=True)` após autenticar com senha de dono) — padrão na receita — https://pymupdf.readthedocs.io/en/latest/recipes-common-issues-and-their-solutions.html . Para o EdgeSpeak [inferência]: pedir senha uma vez, manter doc autenticado em memória, nunca persistir senha; marcar "trecho indisponível por permissão" se `authenticate` com senha de usuário negar extração.

## 6. Portfólio (collections) e anexos (embedded files)

- Detecção [estabelecido]: `doc.embfile_count()`, `doc.embfile_names()`, `doc.embfile_info(n)` — https://pymupdf.readthedocs.io/en/latest/document.html ; contexto (Embedded File Streams, collections do PDF 1.7; MuPDF largou suporte em 1.15 e o PyMuPDF mantém base própria desde 1.16.0) — https://pymupdf.readthedocs.io/en/latest/app2.html
- O que quebra: `get_text` da página capa do portfólio não contém o conteúdo dos anexos; cada anexo pode ser outro PDF com o texto real.
- Receita [estabelecido]: listar com `embfile_names()`, extrair com `embfile_get(n)` para buffer e abrir com `pymupdf.open(stream=buf)` — https://pymupdf.readthedocs.io/en/latest/document.html ; https://pymupdf.readthedocs.io/en/latest/app2.html . Para o EdgeSpeak [inferência]: anunciar "este PDF é um portfólio com N anexos: <nomes>" e extrair cada um como documento filho com destaque próprio; anexos dentro de anexos = recursão com limite.

## 7. PDF/A e fontes embutidas vs ausentes (ToUnicode)

- Detecção [estabelecido/inferência]: `doc.get_page_fonts(pno)` lista `(xref, ext, type, basefont, name, encoding, referencer)` — https://pymupdf.readthedocs.io/en/latest/page.html ; `doc.extract_font(xref)` mostra se há ToUnicode/stream embutido. Sintoma de fonte sem ToUnicode: `rawdict` com `c == "\ufffd"` ou CID conforme flags `TEXT_CID_FOR_UNKNOWN_UNICODE` etc. — https://pymupdf.readthedocs.io/en/latest/app1.html
- O que quebra: sem ToUnicode, o extrator devolve U+FFFD/CID — lixo para TTS; PDF/A (fontes embutidas por norma) tende a extrair melhor, mas PDF/A não garante camada textual [inferência].
- Receita [estabelecido]: checar metadado XMP via `doc.get_xml_metadata()` (PDF/A declara conformância no XMP) — https://pymupdf.readthedocs.io/en/latest/document.html ; medir proporção de `\ufffd` por página e, acima do limiar, mandar para OCR — https://pymupdf.readthedocs.io/en/latest/recipes-ocr.html . Para o EdgeSpeak [inferência]: página com >~5% de `\ufffd` = "texto corrompido por fonte", não narrar lixo.

## 8. CJK e scripts complexos (vertical, wmode)

- Detecção [estabelecido]: no `dict`, linha traz `wmode` (0 horizontal, 1 vertical) e `dir` (vetor unitário `(cos, -sin)` da rotação); spans de CJK vertical têm `wmode==1` — https://pymupdf.readthedocs.io/en/latest/textpage.html
- O que quebra: ordenação `sort` (vertical-depois-horizontal) e agrupamento por linha horizontal falham em texto vertical; destaque por palavra com bbox horizontal cobre glifos empilhados.
- Receita [estabelecido]: quando `line["dir"] != (1,0)` ou `wmode==1`, usar quads por caractere (`rawdict`/`xml` com quad/bbox por char) para marcação — a doc manda usar quads só quando o texto não é horizontal — https://pymupdf.readthedocs.io/en/latest/textpage.html . Para o EdgeSpeak [inferência]: segregar linhas verticais em fluxo próprio (coluna da direita para a esquerda em japonês tradicional), narrar na ordem de leitura vertical e destacar por caractere, não por palavra.

## 9. RTL (árabe/hebraico, ordem lógica vs visual)

- Detecção [inferência]: spans com caracteres U+0590–08FF e `line["dir"]` ainda `(1,0)` (linha armazenada em ordem lógica, exibida visualmente); a doc não promete normalização bidi na extração — changelog registra apenas que `get_text()` nunca mistura RTL/LTR sem tratamento (nota de versão na doc) [suportado].
- O que quebra: extração pode vir em ordem lógica (correta para TTS) mas com pontuação/números deslocados; destaque palavra-a-palavra pode parecer "saltar" visualmente.
- Receita [inferência, marcada]: para narração, usar a string lógica como está (TTS bidi resolve); para destaque, casar por `rawdict` por caractere e algoritmo bidi (ex. `python-bidi`) só na camada de apresentação; sem promessa oficial — validar por documento. Fontes: estrutura de linha/span — https://pymupdf.readthedocs.io/en/latest/textpage.html ; extração geral — https://pymupdf.readthedocs.io/en/latest/recipes-text.html

## 10. Matemática densa (símbolos, fontes Type3)

- Detecção [estabelecido/inferência]: `get_page_fonts()` com `type == "Type3"` (fonte de glifos vetoriais, comum em símbolos TeX); spans de símbolos sem unicode viram `\ufffd`/CID — mesmos flags do §7 — https://pymupdf.readthedocs.io/en/latest/app1.html ; lista de fontes — https://pymupdf.readthedocs.io/en/latest/page.html
- O que quebra: fórmulas viram sequência de letras gregas/símbolos sem estrutura (fração, expoente, matriz perdem relação espacial); TTS lê lixo ("less-than psi...").
- Receita [inferência, marcada]: detectar blocos densos em símbolos/Type3 e oferecer modo "pular matemática" ou "soletrar símbolos" + fallback render+descrição; sem extração semântica de fórmula no PyMuPDF até 1.28.2. Evitar narrar `rawdict` cru de Type3.

## 11. Revistas em 2–3 colunas com boxes atravessados

- Detecção [inferência sobre dado estabelecido]: blocos `dict` com sobreposição vertical forte e larguras ~1/2–1/3 da página = colunas; bloco largo acima cobrindo 2+ colunas = título/box atravessado. Base do `sort` (ordena blocos por `(y1,x0)`, words re-sintetizam linhas) — https://pymupdf.readthedocs.io/en/latest/textpage.html ; receita de ordem natural em 3 passos — https://pymupdf.readthedocs.io/en/latest/recipes-text.html
- O que quebra: `sort=True` lê atravessado linha a linha em vez de coluna a coluna (limite já catalogado no guia anterior).
- Receita [estabelecido + inferência]: não usar `sort` como decisor; XY-cut no Swift por sobreposição vertical de blocos; títulos largos (largura ≥1.5× coluna, acima) ler antes das colunas; boxes com fundo/borda (`get_drawings()` com `isrect`/fill) ler após o fluxo da coluna que atravessam ou como aparte nomeado [inferência]. Vetores baratos via blocos tipo 3 — https://pymupdf.readthedocs.io/en/latest/textpage.html

## 12. Tabelas (find_tables: quando usar, limites)

- Detecção/uso [estabelecido]: `tabs = page.find_tables(clip=None, strategy=...)`; `tabs.tables`, `t.extract()`, `t.to_markdown()`, `t.to_pandas()` — https://pymupdf.readthedocs.io/en/latest/page.html ; guia "How to Extract Table Content" — https://pymupdf.readthedocs.io/en/latest/recipes-text.html
- O que quebra [suportado]: tabelas sem régua (só espaçamento) exigem `strategy="text"` e precisão cai; células mescladas/quebra de linha interna embaralham `extract()`; discussão oficial de perda de texto com `horizontal_strategy="text"` (issue #3675) e guia de problemas comuns — https://github.com/pymupdf/PyMuPDF/issues/3675 ; https://medium.com/@pymupdf/solving-common-issues-with-table-detection-and-extraction-4df5de2b8d88
- Receita [estabelecido]: default (linhas vetoriais) primeiro; com `clip` na região suspeita; fallback `strategy="text"`; nunca narrar tabela pelo fluxo corrido — ler célula a célula linha por linha ("linha i, coluna <cabeçalho>: valor") [inferência para TTS]. Para o EdgeSpeak: detectar via `find_tables()` antes do XY-cut e excluir a área do fluxo de parágrafos.

## 13. Notas de fim vs notas de rodapé (posições variantes)

- Detecção [inferência sobre dados estabelecidos]: rodapé = blocos do terço inferior com número inicial + fonte menor + régua (`get_drawings()`), já catalogado; notas de fim = seção própria no fim do capítulo/documento ("Notes", "Endnotes") detectável via `doc.get_toc()` + busca de título de seção com `page.search_for("Endnotes|Notes")` — https://pymupdf.readthedocs.io/en/latest/document.html (get_toc) ; https://pymupdf.readthedocs.io/en/latest/textpage.html (search)
- O que quebra: marcador no corpo aponta para seção distante; sem link, a resolução número→texto é heurística.
- Receita [inferência]: resolver via links (`page.get_links()` — destino da nota de fim quando linkada) — https://pymupdf.readthedocs.io/en/latest/page.html ; sem link, casar número do marcador com item numerado da seção de endnotes e ler sob demanda ("nota 12: ..."), nunca injetar no meio da frase.

## 14. Cabeçalhos/rodapés repetidos e marcas d'água

- Detecção [inferência]: texto/posição que se repete nas primeiras/últimas linhas em N páginas (assinatura por `(texto normalizado, faixa-y)`); marca d'água = texto gigante diagonal (`line["dir"]` fora de `(1,0)`), cor clara (`span["color"]` alto/claro — receita de cor — https://pymupdf.readthedocs.io/en/latest/recipes-text.html ) ou XObject repetido (`get_drawings()`/imagens por página).
- O que quebra: número de página/título corrente narrado no meio de cada página; marca d'água ("DRAFT", "CONFIDENTIAL") lida como frase.
- Receita [inferência, compatível com doc]: amostrar 5+ páginas, excluir do fluxo o que repete em ≥80% com mesma faixa-y; marca d'água diagonal/clara vai para lista de exclusão por `dir`+tamanho+cor. Base geométrica — https://pymupdf.readthedocs.io/en/latest/textpage.html

## 15. Texto tarjado / redigido (redactions aplicadas ou não)

- Detecção [estabelecido]: `list(page.annots(types=(pymupdf.PDF_ANNOT_REDACT,)))` revela tarjas pendentes; após `apply_redactions` o texto some fisicamente — https://pymupdf.readthedocs.io/en/latest/page.html (add_redact_annot/apply_redactions/annots)
- O que quebra: (a) tarja **aplicada** = texto removido do content stream — `get_text` não o contém, correto não narrar; (b) tarja **pendente** (só anotação, sem apply) = `get_text` ainda contém o texto "secreto" — narrar vaza dado sensível; (c) retângulo preto desenhado sem anotação de redação não remove nada — texto segue extraível [suportado por discussão #1087 e #434].
- Receita [estabelecido]: antes de extrair, varrer annots de redação; se houver pendente, avisar "página contém tarjas não aplicadas" e (por padrão) suprimir o texto sob o retângulo via `clip` invertido ou aplicar em cópia (`apply_redactions` em cópia em memória) — https://pymupdf.readthedocs.io/en/latest/page.html ; fundo — https://pymupdf.readthedocs.io/en/latest/tutorial.html (seção de redações). Para o EdgeSpeak [inferência]: nunca narrar texto sob tarja pendente sem consentimento explícito.
- Discussões: remoção além do retângulo — https://github.com/pymupdf/PyMuPDF/discussions/1087 ; remoção física — https://github.com/pymupdf/PyMuPDF/issues/434

## 16. Linearizado / web (leitura parcial por página)

- Detecção [inferência]: linearizado ("fast web view") = flag `/Linearized` no cabeçalho + ordem de objetos otimizada; PyMuPDF abre normal, sem API de streaming parcial por HTTP — abertura documentada só via arquivo/stream completo — https://pymupdf.readthedocs.io/en/latest/how-to-open-a-file.html (abertura remota: baixar tudo via `requests` e `Document(stream=data)`)
- O que quebra: nada na extração local; a expectativa de "ler página 200 sem baixar o arquivo" não se cumpre via PyMuPDF [inferência].
- Receita [estabelecido]: baixar o stream completo e abrir em memória (`pymupdf.Document(stream=data)`) — https://pymupdf.readthedocs.io/en/latest/how-to-open-a-file.html ; snippets de cloud — https://github.com/pymupdf/PyMuPDF-Utilities/tree/master/cloud-interactions . Para o EdgeSpeak [inferência]: streaming por página = iterar `doc[i]` sob demanda (o parser é lazy por página), não pré-extrair 500 páginas; linearização só ajuda viewer web, não o extrator.

## 17. Camadas OCG (conteúdo oculto)

- Detecção/uso [estabelecido]: `doc.get_ocgs()`, `doc.get_layers()`, `doc.get_layer()`, `doc.set_layer_enabled()` / habilitar OCGs; `doc.get_oc(xref)` mostra OCG de imagem/form XObject — https://pymupdf.readthedocs.io/en/latest/document.html ; conceito e on/off programático — https://pymupdf.readthedocs.io/en/latest/recipes-optional-content.html
- O que quebra: `get_text` extrai também texto de camada DESLIGADA (oculta no viewer) — o extrator não filtra por visibilidade por padrão [inferência a partir do modelo OCG: visibilidade é decisão do viewer, não do content stream].
- Receita [estabelecido + inferência]: antes de extrair, ler `get_ocgs()`/`get_layers()`; decidir configuração (ex. só camada "print" ou idioma X); desabilitar o resto via API de layers e extrair; se `get_ocgs()` vazio, nada a fazer. Para o EdgeSpeak [inferência]: anunciar "documento com N camadas: <nomes>" e extrair só as visíveis por padrão; conteúdo oculto nunca narrado sem aviso. Notebook oficial de exemplo — https://github.com/pymupdf/PyMuPDF-Utilities/blob/master/jupyter-notebooks/optional-content.ipynb (linkado em — https://pymupdf.readthedocs.io/en/latest/recipes-optional-content.html )

## 18. Arquivos grandes 500+ páginas (streaming, custo, multiprocessing)

- Detecção [inferência]: `doc.page_count >= 500` ou RSS crescendo; custo medido na doc: sem imagens quase todo método ≈1.00 (RAWDICT 1.68), com imagens DICT 3.93×/RAWDICT 4.50×; 1310 págs. referência em <5 s, 2700 págs. mistas 160 s com imagens / 77 s sem — https://pymupdf.readthedocs.io/en/latest/app1.html
- O que quebra: pré-extrair `dict`/`rawdict` com imagens de 500+ págs. estoura memória/tempo; threads concorrentes no mesmo `Document` podem travar (GIL/MuPDF não thread-safe) [estabelecido abaixo].
- Receita [estabelecido]: (a) sem imagens por padrão (`flags = TEXTFLAGS_* & ~TEXT_PRESERVE_IMAGES`) — https://pymupdf.readthedocs.io/en/latest/app1.html ; (b) streaming: iterar `for page in doc`, extrair, descartar (`del page`/fechar doc), nunca acumular dicts; (c) multiprocessing por processos (cada processo abre o próprio handle — doc não é picklable; `Pool.map` por faixas de páginas, ~2×+ mais rápido) — https://pymupdf.readthedocs.io/en/latest/recipes-multiprocessing.html ; (d) "PyMuPDF does not support running on multiple threads" — mesma página. Para o EdgeSpeak [inferência]: pipeline em 2 fases — fase 1 `words` sem imagens em todas as páginas (barato, ~segundos em 300 págs.), fase 2 `dict`/`rawdict` só das páginas visíveis para destaque; `rawdict` com imagens ≈2–4× words (projeção do guia anterior).

## Fontes principais

1. OCR (quando usar, get_textpage_ocr, GlyphLessFont) — https://pymupdf.readthedocs.io/en/latest/recipes-ocr.html
2. Texto (ordem natural, sort, tabelas) — https://pymupdf.readthedocs.io/en/latest/recipes-text.html
3. TextPage (extract*, sort, wmode/dir, quads, clip) — https://pymupdf.readthedocs.io/en/latest/textpage.html
4. Page (widgets, links, rotation_matrix, drawings, find_tables, annots/redactions, get_page_fonts) — https://pymupdf.readthedocs.io/en/latest/page.html
5. Document (authenticate/needs_pass, embfile_*, get_toc, get_ocgs/get_layers, get_xml_metadata, xref) — https://pymupdf.readthedocs.io/en/latest/document.html
6. Appendix 1 (flags defaults, ToUnicode/CID, performance) — https://pymupdf.readthedocs.io/en/latest/app1.html
7. Appendix 2 (embedded files/portfólio) — https://pymupdf.readthedocs.io/en/latest/app2.html
8. Abertura (stream remoto, Document(stream)) — https://pymupdf.readthedocs.io/en/latest/how-to-open-a-file.html
9. Multiprocessing (processos, sem threads) — https://pymupdf.readthedocs.io/en/latest/recipes-multiprocessing.html
10. Optional Content (OCG on/off) — https://pymupdf.readthedocs.io/en/latest/recipes-optional-content.html
11. Widget — https://pymupdf.readthedocs.io/en/latest/widget.html
12. Tutorial (widgets, redações) — https://pymupdf.readthedocs.io/en/latest/tutorial.html
13. Issues/discussões: tabelas text-strategy — https://github.com/pymupdf/PyMuPDF/issues/3675 ; redação além do retângulo — https://github.com/pymupdf/PyMuPDF/discussions/1087 ; remoção física — https://github.com/pymupdf/PyMuPDF/issues/434
