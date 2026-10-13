#!/usr/bin/env python3
"""Linhas de texto do PDF com caixas, via PyMuPDF (EdgeSpeak).

Por que existe: a camada de texto de alguns PDFs não tem os espaços entre
palavras ("disputesconductedwithinit...") — o `PDFPage.string` do PDFKit cola
tudo e o narrador engole pausas. O PyMuPDF segmenta em palavras com caixas
(`get_text("words")`), então os espaços voltam a existir. O Swift continua
donos da ordem de leitura (XY-cut), parágrafos, filtro, destaque e leitura;
daqui saem só linhas com caixas, já em coordenadas do PDFKit (origem no
canto inferior esquerdo).

Uso:
    pdf_extract.py --pdf ARQUIVO --out SAIDA.json

JSON:
    {"pages": [{"index": 0, "lines":
        [{"text": "...", "box": [x0, y0, x1, y1],
          "words": [{"text": "...", "box": [x0, y0, x1, y1]}]}]}]}
    Caixas em coordenadas do PDFKit (origem embaixo); `words` segue a ordem
    de leitura (esquerda→direita dentro da linha).
"""

import argparse
import json
import sys


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
        # Agrupa por (bloco, linha) do próprio layout; a ordem final é do Swift.
        groups = {}
        for w in page.get_text("words"):
            x0, y0, x1, y1, text, block, line, _ = w
            text = (text or "").strip()
            if not text:
                continue
            # Converte para coordenadas do PDFKit (origem embaixo).
            box = [x0, h - y1, x1, h - y0]
            groups.setdefault((block, line), []).append((x0, text, box))
        lines = []
        for key in sorted(groups):
            parts = sorted(groups[key], key=lambda p: p[0])
            words = [p[1] for p in parts]
            boxes = [p[2] for p in parts]
            lines.append({
                "text": " ".join(words),
                "box": [
                    min(b[0] for b in boxes),
                    min(b[1] for b in boxes),
                    max(b[2] for b in boxes),
                    max(b[3] for b in boxes),
                ],
                "words": [
                    {"text": p[1], "box": p[2]} for p in parts
                ],
            })
        pages.append({"index": index, "lines": lines})

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"pages": pages}, fh, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
