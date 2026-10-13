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
- Hífen de fim de linha é JUNTADO aqui (regra geométrica: última palavra da
  linha termina com `-`/U+00AD, próxima linha do mesmo bloco começa com
  minúscula): a palavra junta leva a união das caixas. Hífen no meio da
  linha ("state-of-the-art") nunca entra na regra. Soft hyphen invisível é
  removido sempre. Sem dicionário de propósito: o mesmo PDF tem de sair
  idêntico com ou sem pyphen instalado.
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    try:
        import fitz
    except ImportError:
        print("pdf_extract: PyMuPDF (fitz) não instalado", file=sys.stderr)
        return 2

    try:
        doc = fitz.open(args.pdf)
    except Exception as exc:
        print(f"pdf_extract: não abriu o PDF: {exc}", file=sys.stderr)
        return 3

    pages = []
    for index, page in enumerate(doc):
        h = page.rect.height
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
            if len(ultima["text"]) < 2 or not (
                ultima["text"].endswith("-") or ultima["text"].endswith("\u00ad")
            ):
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
            if not primeira or not primeira[0].islower():
                continue
            base = ultima["text"][:-1]
            junta = base + primeira
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
            lines.append({
                "text": " ".join(p["text"] for p in partes),
                "box": [
                    min(b[0] for b in caixas),
                    min(b[1] for b in caixas),
                    max(b[2] for b in caixas),
                    max(b[3] for b in caixas),
                ],
                "words": itens,
            })
        pages.append({"index": index, "lines": lines})

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"pages": pages}, fh, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
