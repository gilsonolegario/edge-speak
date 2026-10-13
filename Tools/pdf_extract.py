#!/usr/bin/env python3
"""Linhas de texto do PDF com caixas, via PyMuPDF (EdgeSpeak).

Por que existe: a camada de texto de alguns PDFs não tem os espaços entre
palavras ("disputesconductedwithinit...") — o `PDFPage.string` do PDFKit cola
tudo e o narrador engole pausas. O PyMuPDF segmenta em palavras com caixas
(`get_text("words")`), então os espaços voltam a existir. O Swift continua
dono da ordem de leitura (XY-cut), parágrafos, filtro, destaque e leitura;
daqui saem só linhas com caixas, já em coordenadas do PDFKit (origem no
canto inferior esquerdo).

Como funciona (guia em docs/pesquisas/pymupdf-pesquisa.md):
- `words` dá as caixas por palavra; `dict` (sem imagens) dá a estrutura de
  linha/bloco, tamanhos e flags de span — cruzados por (bloco, linha).
- Hífen de fim de linha é JUNTADO aqui, inclusive através da virada de
  página (número solto de página não bloqueia): a palavra junta leva a
  união das caixas. A decisão é do dicionário do sistema
  (`/usr/share/dict/words`, presente em todo macOS): quebra de linha some
  ("en-"+"larged"), composto verdadeiro mantém o hífen ("Wrinkled-Seed").
  Sem palavra no dicionário, minúscula cola e maiúscula mantém; elisão
  curta ("l’", "d’") cola sempre. Hífen no meio da linha
  ("state-of-the-art") nunca entra na regra. Soft hyphen invisível é
  removido sempre.
- Sobrescrito (`sup`): bit 1 das flags do span (detecção do MuPDF) ou
  tamanho <0.8×mediana com baseline elevada. Serve à detecção de marcadores
  de nota no Swift.

Uso:
    pdf_extract.py --pdf ARQUIVO --out SAIDA.json

JSON:
    {"pages": [{"index": 0, "lines":
        [{"text": "...", "box": [x0, y0, x1, y1],
          "words": [{"text": "...", "box": [x0, y0, x1, y1], "sup": false}]}]}]}
    Caixas em coordenadas do PDFKit (origem embaixo); `words` segue a ordem
    de leitura (esquerda→direita dentro da linha).
"""

import argparse
import json
import re
import statistics
import sys


def _span_de(palavra_box, spans_linha):
    """Span que contém a palavra (maior sobreposição); None sem span."""
    x0, y0, x1, y1 = palavra_box
    melhor, melhor_area = None, 0.0
    for s in spans_linha:
        sx0, sy0, sx1, sy1 = s["bbox"]
        ix0, iy0 = max(x0, sx0), max(y0, sy0)
        ix1, iy1 = min(x1, sx1), min(y1, sy1)
        area = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
        if area > melhor_area:
            melhor, melhor_area = s, area
    return melhor


# Dicionário do sistema para decidir o hífen de fim de linha (preguiçoso:
# `None` = ainda não carregado). `/usr/share/dict/words` existe em todo
# macOS; sem ele, o conjunto fica vazio e valem só as regras de caixa.
_DIC = None


def _dic():
    global _DIC
    if _DIC is None:
        try:
            with open("/usr/share/dict/words", encoding="utf-8") as fh:
                _DIC = {w.strip().lower() for w in fh if w.strip()}
        except OSError:
            _DIC = set()
    return _DIC


def _e_palavra(s):
    """A colagem é palavra conhecida? Só letras, minúsculas: "enlarged,"
    vira "enlarged" e acha; "motherin-law" vira "motherinlaw" e não acha
    (composto verdadeiro, mantém o hífen). Fora do inglês o dicionário
    não sabe — e as regras de caixa abaixo continuam valendo sozinhas.
    """
    chave = "".join(ch for ch in (s or "").lower() if ch.isalpha())
    return bool(chave) and chave in _dic()


def _junta_fim(t_ult, t_pri):
    """Um texto só juntando fim de linha + início da seguinte, ou None.
    Elisão curta ("l’", "d’") cola sempre; hífen final consulta o
    dicionário (quebra some, composto mantém); sem palavra no dicionário,
    minúscula cola e maiúscula mantém o hífen. Universal: nada aqui cita
    PDF, página ou artigo específico.
    """
    if not t_ult or not t_pri:
        return None
    nuc = t_ult.rstrip("’'")
    if t_ult != nuc and len(t_ult) <= 4 and 1 <= len(nuc) <= 3:
        return t_ult + t_pri
    if len(t_ult) >= 2 and t_ult.endswith("-"):
        base = t_ult[:-1]
        colado = base + t_pri
        if _e_palavra(colado):
            return colado
        if "-" in t_pri:
            return t_ult + t_pri
        if t_pri[0].islower():
            return colado
        return t_ult + t_pri
    return None


def _inicia_com_nota(texto):
    """Começa como chamada de nota: número (1–2 dígitos) colado ou seguido
    de pontuação, depois letra. Cobre "1The first edition...", "2Demopoulos",
    "3)." e "12. Smith" — a forma real dos corpos de nota em PDF acadêmico.
    """
    m = re.match(r"^\s*(\d{1,2})\s*[.):]?\s*(?=[A-Za-z])", texto)
    return bool(m)


def candidatas_ok(candidatos, altura_pagina):
    """Aceita o bloco só se ele tem cara de bloco de notas (SPIE 2015 / PKU).

    Duas condições, ambas para conter os falsos positivos medidos:
    - Várias linhas e ao menos uma abrindo com número de nota. Uma linha
      solta no rodapé é quase sempre marca d'água de impressão ("EBSCOhost
      - printed on ..."), que tem corpo menor e mora no rodapé como nota —
      e promovia uma régua falsa em TODAS as páginas de um artigo medido.
    - O bloco alcança a metade da margem inferior: nota de rodapé mora no
      pé da página, não no meio do texto.
    """
    if len(candidatos) < 2:
        return False
    if not any(_inicia_com_nota(l["text"]) for l in candidatos):
        return False
    # box = [x0, fundo, x1, topo] em coords PDFKit (origem embaixo): o bloco
    # de notas mora no PÉ da página, que é o topo MAIS BAIXO (box[3] menor).
    fundo_topo = min(l["box"][3] for l in candidatos)
    return fundo_topo < altura_pagina * 0.5


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    try:
        import pymupdf as fitz
    except ImportError:
        print("pdf_extract: PyMuPDF não instalado", file=sys.stderr)
        return 2

    try:
        doc = fitz.open(args.pdf)
    except Exception as exc:
        print(f"pdf_extract: não abriu o PDF: {exc}", file=sys.stderr)
        return 3

    pages = []
    for index, page in enumerate(doc):
        h = page.rect.height
        W = page.rect.width
        # Régua de nota: desenho horizontal fino, largura 1/10–1/2 da página,
        # na metade inferior (pesquisa §4: régua curta acima das notas).
        # Sai em coords PDFKit (topo da régua); None sem régua. O Swift usa
        # para decidir o que está ABAIXO dela (zona de notas).
        regra_y = None
        for r in page.get_drawings():
            x0, y0, x1, y1 = r["rect"]
            if abs(y1 - y0) < 3 and W * 0.1 < (x1 - x0) < W * 0.5 and y0 > h * 0.5:
                regra_y = h - y0
                break
        try:
            flags = fitz.TEXTFLAGS_DICT & ~fitz.TEXT_PRESERVE_IMAGES
            dd = page.get_text("dict", flags=flags)
        except Exception:
            dd = {"blocks": []}

        # Estrutura de linha/bloco: {(bno, lno): {"spans": [...], "ordem": n}}.
        # Os números de bloco/linha do "words" casam com os do "dict".
        estrutura = {}
        ordem = 0
        for bno, bloco in enumerate(dd.get("blocks", [])):
            if bloco.get("type", 0) != 0:
                continue
            for lno, linha in enumerate(bloco.get("lines", [])):
                estrutura[(bno, lno)] = {"spans": linha.get("spans", []), "ordem": ordem}
                ordem += 1
        tamanhos = [
            s["size"]
            for info in estrutura.values()
            for s in info["spans"]
            if s.get("size", 0) > 0
        ]
        mediana = statistics.median(tamanhos) if tamanhos else 0.0

        # Palavras por (bloco, linha), com caixa em coords PDFKit.
        grupos = {}
        for w in page.get_text("words"):
            x0, y0, x1, y1, text, bloco, linha, _ = w
            # Soft hyphen invisível (U+00AD) sai sempre; não é hífen de verdade.
            text = (text or "").replace("\u00ad", "").strip()
            if not text:
                continue
            box = [x0, h - y1, x1, h - y0]
            grupos.setdefault((bloco, linha), []).append(
                {"x0": x0, "text": text, "box": box}
            )

        # Une fim de linha hifenizado com a linha seguinte ADJACENTE (nunca
        # por bloco: aqui cada linha é seu próprio bloco). Adjacência = a
        # próxima começa abaixo, perto e com sobreposição horizontal. Hífen
        # no meio da linha ("state-of-the-art") nunca é candidato.
        if estrutura:
            ordem_de = {k: v["ordem"] for k, v in estrutura.items()}
            chaves = sorted(grupos, key=lambda k: ordem_de.get(k, 10**9))
        else:
            chaves = sorted(grupos)
        import statistics as _st

        def _caixa(ps):
            bs = [p["box"] for p in ps]
            return [min(b[0] for b in bs), min(b[1] for b in bs),
                    max(b[2] for b in bs), max(b[3] for b in bs)]

        alturas = []
        for chave in chaves:
            ps = sorted(grupos[chave], key=lambda p: p["x0"])
            if not ps:
                continue
            c = _caixa(ps)
            if c[3] > c[1]:
                alturas.append(c[3] - c[1])
        mediana_alt = _st.median(alturas) if alturas else 12.0
        for pos, chave in enumerate(chaves):
            partes = sorted(grupos[chave], key=lambda p: p["x0"])
            if not partes:
                continue
            ultima = partes[-1]
            texto_ult = ultima["text"]
            # Candidato a juncao: hifen final ou elisao curta. A decisao
            # (dicionario + caixa) sai em `_junta_fim`, apos a adjacencia.
            if texto_ult[-1:] not in ("-", "\u2019", "'"):
                continue
            if pos + 1 >= len(chaves):
                continue
            proxima = chaves[pos + 1]
            c0 = _caixa(partes)
            c1 = _caixa(sorted(grupos[proxima], key=lambda p: p["x0"]))
            # Coords PDFKit (origem embaixo): vão = fundo da atual menos
            # topo da próxima; vale 0..1,5 linha quando é continuação.
            vao = c0[1] - c1[3]
            if not (0 <= vao <= 1.5 * mediana_alt):
                continue
            sobre = min(c0[2], c1[2]) - max(c0[0], c1[0])
            if sobre < 0.5 * min(c0[2] - c0[0], c1[2] - c1[0]):
                continue
            seguintes = sorted(grupos[proxima], key=lambda p: p["x0"])
            if not seguintes:
                continue
            primeira = seguintes[0]["text"]
            junta = _junta_fim(texto_ult, primeira)
            if junta is None:
                continue
            b0 = ultima["box"]
            b1 = seguintes[0]["box"]
            uniao = [min(b0[0], b1[0]), min(b0[1], b1[1]),
                     max(b0[2], b1[2]), max(b0[3], b1[3])]
            partes[-1] = {"x0": ultima["x0"], "text": junta, "box": uniao,
                          "juntada": True}
            grupos[chave] = partes
            grupos[proxima] = seguintes[1:]

        lines = []
        for chave in chaves:
            partes = sorted(grupos[chave], key=lambda p: p["x0"])
            if not partes:
                continue
            info = estrutura.get(chave, {"spans": []})
            spans = info["spans"]
            topo_linha = min((s["bbox"][1] for s in spans), default=None)
            itens = []
            for p in partes:
                span = _span_de(
                    [p["box"][0], h - p["box"][3], p["box"][2], h - p["box"][1]],
                    spans,
                )
                tamanho = float(span.get("size", 0.0)) if span else 0.0
                flag = int(span.get("flags", 0)) if span else 0
                # Sobrescrito: bit do MuPDF, ou pequeno+elevado.
                elevado = False
                if span and topo_linha is not None and tamanho > 0:
                    elevado = (span["bbox"][1] - topo_linha) < -0.3 * tamanho
                sup = bool(flag & 1) or (
                    mediana > 0 and 0 < tamanho < 0.8 * mediana and elevado
                )
                itens.append({"text": p["text"], "box": p["box"], "sup": sup})
            caixas = [p["box"] for p in partes]
            # Fonte dominante da linha (maior span não-sobrescrito): notas
            # de rodapé são impressas em corpo menor que o texto corrido.
            tam_linha = max(
                (
                    float(s.get("size", 0.0))
                    for s in spans
                    if not (int(s.get("flags", 0)) & 1)
                ),
                default=0.0,
            )
            # Título de seção tem fonte MAIOR; não é nota, mesmo menor que o
            # título do documento. Medido contra a mediana da página.
            e_titulo = bool(spans) and mediana > 0 and tam_linha > mediana * 1.18
            # Heurística de nota (edgeparse-core): fonte menor que 0,85× da
            # dominante e texto corrido (>= 12 chars). O Swift cruza com a
            # posição (zona de notas / régua) antes de tratar como corpo.
            e_nota = (
                mediana > 0
                and 0 < tam_linha <= 0.85 * mediana
                and not e_titulo
                and len(caixas) >= 12
            )
            caixa_linha = [
                min(b[0] for b in caixas),
                min(b[1] for b in caixas),
                max(b[2] for b in caixas),
                max(b[3] for b in caixas),
            ]
            lines.append({
                "text": " ".join(p["text"] for p in partes),
                "box": caixa_linha,
                "words": itens,
                "note": e_nota,
            })

        # Zona de notas SINTÉTICA (edgeparse-core) quando não há régua
        # desenhada: a partir do topo do bloco contíguo de linhas "note" na
        # metade inferior. `box[3]` é o topo em coords PDFKit (origem embaixo),
        # então "metade inferior" é topo < metade da altura. Sai em coords
        # PDFKit (topo do bloco). Sem bloco, mantém None — as heurísticas
        # antigas continuam valendo.
        if regra_y is None and lines:
            metade = h * 0.5
            candidatos = [
                l for l in lines if l["note"] and l["box"][3] < metade
            ]
            if candidatas_ok(candidatos, h):
                regra_y = max(l["box"][3] for l in candidatos)
        pages.append({"index": index, "footnote_rule_y": regra_y, "lines": lines})

    # Junção através da virada de página: última linha de corpo hifenizada
    # (ou elisão curta) + primeira linha de corpo da página seguinte em
    # minúscula. Sem isso "en-" + "larged" vira dois fragmentos e o áudio
    # pica. Só corpo com corpo: abaixo da régua (zona de notas) nunca.
    for anterior, seguinte in zip(pages, pages[1:]):
        if not anterior["lines"] or not seguinte["lines"]:
            continue
        # Número de página solto ("9", "10") não é texto: ele mora depois
        # da última linha de corpo e antes da primeira, e bloquearia a
        # junção. Vale para qualquer PDF: só dígitos, até 4 caracteres.
        def so_numero(l):
            return l["words"] and l["text"].strip().isdigit() \
                and len(l["text"].strip()) <= 4
        ult = None
        for l in reversed(anterior["lines"]):
            if so_numero(l):
                continue
            ult = l
            break
        pri = None
        for l in seguinte["lines"]:
            if so_numero(l):
                continue
            pri = l
            break
        if ult is None or pri is None:
            continue
        if not ult["words"] or not pri["words"]:
            continue
        regra_ant = anterior["footnote_rule_y"]
        if regra_ant is not None and ult["box"][3] < regra_ant:
            continue
        if ult.get("note") or pri.get("note"):
            continue
        t_ult = ult["words"][-1]["text"]
        t_pri = pri["words"][0]["text"]
        junta = _junta_fim(t_ult, t_pri)
        if junta is None:
            continue
        w0, w1 = ult["words"][-1], pri["words"][0]
        b0, b1 = w0["box"], w1["box"]
        w0["text"] = junta
        w0["box"] = [min(b0[0], b1[0]), min(b0[1], b1[1]),
                     max(b0[2], b1[2]), max(b0[3], b1[3])]
        pri["words"] = pri["words"][1:]
        ult["text"] = " ".join(w["text"] for w in ult["words"])
        bs = [w["box"] for w in ult["words"]]
        ult["box"] = [min(b[0] for b in bs), min(b[1] for b in bs),
                      max(b[2] for b in bs), max(b[3] for b in bs)]
        if pri["words"]:
            pri["text"] = " ".join(w["text"] for w in pri["words"])
            cs = [w["box"] for w in pri["words"]]
            pri["box"] = [min(c[0] for c in cs), min(c[1] for c in cs),
                          max(c[2] for c in cs), max(c[3] for c in cs)]
        else:
            seguinte["lines"] = [l for l in seguinte["lines"] if l is not pri]

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"pages": pages}, fh, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
