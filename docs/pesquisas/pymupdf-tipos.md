# Tipos de chamada de nota de rodapé e detecção no PyMuPDF

Data: 2026-10-13 (America/Sao_Paulo). Status: [F] fato na fonte · [M] medido no artigo de teste · [I] inferência.

## 1. As formas de chamada e o que cobre cada uma

| Forma | Exemplo | Sinal que denuncia | Cobertura no extrator |
|---|---|---|---|
| Sobrescrito com bit do MuPDF | `teoria⁷` (span pequeno, flags&1) | `span["flags"] & 1` no `dict` [F] | `sup=true` (já havia; §3 mostra que se perdia no colado) |
| Sobrescrito geométrico sem bit | dígito pequeno e elevado, bit ausente | tamanho <0,8×mediana + base elevada >0,25×tamanho (§2) | `sup=true` (novo, `_span_marcador`) |
| Colado após pontuação | `realist’s.1`, `true.2` [M] | span do marcador dentro do token do `words` | `sup=true` na palavra (novo, regra de sufixo) |
| Entre parênteses | `(1)` | forma `[(]?N[.)\]]?`; geometria só se elevado | forma aceita no regex; sem elevação não há sinal geométrico [I] |
| Símbolo/asterisco | `*` `†` `‡` `§` `¶` | bit ou elevação; tamanho cheio é normal | aceitos sem exigir tamanho menor [I] |
| Dígito unicode sobrescrito | `¹` `²` `³` | o próprio codepoint | aceito como forma; colado no meio do token não separa [I] |

## 2. Métodos OSS consultados (adaptar, não copiar)

- PyMuPDF oficial: `TEXT_FONT_SUPERSCRIPT = 1`, "computed by MuPDF and not part of any font information" [F] — https://pymupdf.readthedocs.io/en/latest/vars.html ; span = caracteres adjacentes de mesmas propriedades [F] — https://pymupdf.readthedocs.io/en/latest/app1.html ; detecção de sobrescrito no TextPage, não é propriedade de fonte [F] — https://pymupdf.readthedocs.io/en/latest/textpage.html . Mantenedor (discussão #3286): sobrescrito por `span["flags"]` em `dict`/`rawdict`; subscrito, não [F] — https://github.com/pymupdf/PyMuPDF/discussions/3286
- marker `FootnoteProcessor`: empurra notas ao fim da página; `assign_superscripts` casa por `re.match(r"^[0-9\W]+")` [F] — https://github.com/VikParuchuri/marker (posição por modelo de layout, não heurística; licença AGPL-3.0).
- pdfplumber: `extract_words()` expõe só bbox e tamanho por caractere, sem flag de sobrescrito — comparação geométrica manual seria o único caminho [I] — https://github.com/jsvine/pdfplumber (MIT).
- pymupdf4llm: converte a Markdown para RAG; sem tratamento de nota [I] — https://pymupdf.readthedocs.io/en/latest/pymupdf4llm/ (Apache-2.0).
- GROBID: único a ligar chamada↔corpo, mas com ML de domínio acadêmico e extração de nota reconhecidamente fraca [F, dossiê anterior] — https://github.com/grobidOrg/grobid (Apache-2.0).
- PDFix: teto de deslocamento de base `superscript_shift_ratio = 0.5` [F] — https://docs.pdfix.net/templates/settings/pagemap-thresholds ; scribe/edgeparse: corpo ≤0,85–0,92× da fonte dominante [F, dossiê anterior].

## 3. Decisão implementada (só `Tools/pdf_extract.py`, sem mudar o JSON)

Duas causas-raiz medidas no artigo de teste (mediana do corpo 11,96 pt): (a) o `words` cola o marcador (`realist’s.1`) e o casamento palavra→span por área máxima herda o span do corpo — o span do marcador (8,97 pt = 0,75×, flags=5, bit PRESENTE) se perdia, `sup=0` em 11102 palavras; (b) o reserva "pequeno+elevado" media o topo da linha, mas o marcador define o topo (diferença zero). Novo sinal, em adição ao antigo (nada do anterior foi removido): para cada span da linha com forma de marcador, `sup=true` na palavra que o cruze — pelo bit, ou por dígito <0,8×mediana com base acima da base do corpo (>0,25×tamanho, abaixo do teto PDFix de 0,5×); símbolo dispensa o tamanho menor. Palavra juntada por hífen (caixa-união larga) só vale se o centro do span cair nos 30% finais do token — sem isto, `reference`/`departure` viravam falsos positivos [M]. Resultado: 12/12 marcadores do corpo (1–12), zero falsos, textos/caixas/réguas idênticos à base.

## 4. Limitações declaradas (não inventar)

- O Swift (`indiceMarcador`/`temSup`) exige a palavra sobrescrita cujo miolo após aparar pontuação SEJA `N`; `realist’s.1` aparado continua `realist’s.1` — o elo marcador→corpo pede ajuste mínimo no Swift (casar sufixo numérico do token com `sup`), fora do escopo desta tarefa, que toca só Python.
- `(1)` não elevado, símbolo em corpo cheio não elevado e `¹` colado no meio do token não têm sinal geométrico — seguem sem `sup`.
- Sem padrão de teste Python no repo (só `Tests/EdgeSpeakTests` Swift): verificação por execução direta, sem teste novo (teto: 2).
