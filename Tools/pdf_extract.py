#!/usr/bin/env python3
"""PDF text lines with boxes, via PyMuPDF (EdgeSpeak).

Why it exists: the text layer of some PDFs has no spaces between
words ("disputesconductedwithinit...") - PDFKit's `PDFPage.string` glues
everything and the narrator swallows pauses. PyMuPDF segments into words with boxes
(`get_text("words")`), so spaces exist again. Swift still owns the
reading order (XY-cut), paragraphs, filter, highlight and reading;
only lines with boxes come out of here, already in PDFKit coordinates (origin at the
bottom-left corner).

How it works (guide in docs/pesquisas/pymupdf-pesquisa.md):
- `words` gives the per-word boxes; `dict` (no images) gives the
  line/block structure, span sizes and flags — crossed by (block, line).
- End-of-line hyphen is JOINED here, including across the page turn (a loose
  page number does not block it): the joined word carries the union of the
  boxes. The decision comes from the system dictionary
  (`/usr/share/dict/words`, present on every macOS): a line break disappears
  ("en-"+"larged"), a true compound keeps the hyphen ("Wrinkled-Seed").
  With no word in the dictionary, lowercase joins and uppercase keeps; a short
  elision ("l’", "d’") always joins. A hyphen mid-line
  ("state-of-the-art") never enters the rule. The invisible soft hyphen is
  always removed.
- Superscript (`sup`): bit 1 of the span flags (MuPDF detection) or
  size <0.8xmedian with baseline elevated above the line body's baseline.
  Counts per span crossing the word, not just the largest area: `words`
  glues the marker ("realist’s.1") and max area would inherit the body. Serves
  the note-marker detection in Swift.

Usage:
    pdf_extract.py --pdf FILE --out OUT.json

JSON:
    {"pages": [{"index": 0, "lines":
        [{"text": "...", "box": [x0, y0, x1, y1],
          "words": [{"text": "...", "box": [x0, y0, x1, y1], "sup": false}]}]}]}
    Boxes in PDFKit coords (origin at bottom); `words` follows the reading
    order (left to right within the line).
"""

import argparse
import json
import re
import statistics
import sys


def _span_of(word_box, spans_line):
    """Span containing the word (largest overlap); None with no span."""
    x0, y0, x1, y1 = word_box
    best, best_area = None, 0.0
    for s in spans_line:
        sx0, sy0, sx1, sy1 = s["bbox"]
        ix0, iy0 = max(x0, sx0), max(y0, sy0)
        ix1, iy1 = min(x1, sx1), min(y1, sy1)
        area = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
        if area > best_area:
            best, best_area = s, area
    return best


# System dictionary for end-of-line hyphen decisions (lazy:
# `None` = not loaded yet). `/usr/share/dict/words` exists on every
# macOS; without it, the set stays empty and only the box rules apply.
_DICT = None


def _dic():
    global _DICT
    if _DICT is None:
        try:
            with open("/usr/share/dict/words", encoding="utf-8") as fh:
                _DICT = {w.strip().lower() for w in fh if w.strip()}
        except OSError:
            _DICT = set()
    return _DICT


def _is_word(s):
    """Is the gluing a known word? Letters only, lowercase: "enlarged,"
    becomes "enlarged" and hits; "motherin-law" becomes "motherinlaw" and misses
    (true compound, keeps the hyphen). Outside English the dictionary
    does not know — and the box rules below still hold on their own.
    """
    group_key = "".join(ch for ch in (s or "").lower() if ch.isalpha())
    return bool(group_key) and group_key in _dic()


def _join_end(last_word, first_word):
    """One text only by joining line end + next start, or None.
    Short elision ("l’", "d’") always joins. Final hyphen, in this order:
    1. the document itself: the gluing occurs whole ahead ("enlarged")
       or the hyphenated form occurs ("wrinkled-seed") — holds for any
       language, no external dictionary (~breadbox's dehyphenate idea);
    2. the system dictionary (English): break disappears, compound keeps;
    3. no known word: lowercase joins, uppercase keeps the hyphen.
    """
    if not last_word or not first_word:
        return None
    nuc = last_word.rstrip("’'")
    if last_word != nuc and len(last_word) <= 4 and 1 <= len(nuc) <= 3:
        return last_word + first_word
    if len(last_word) >= 2 and last_word.endswith("-"):
        base = last_word[:-1]
        glued = base + first_word
        low = glued.lower()
        if low in _WHOLE:
            return glued
        if (last_word + first_word).lower() in _HYPHENATED:
            return last_word + first_word
        if _is_word(glued):
            return glued
        if "-" in first_word:
            return last_word + first_word
        if first_word[0].islower():
            return glued
        return last_word + first_word
    return None


# Span-level note call (research docs/pesquisas/pymupdf-tipos.md):
# PyMuPDF's `words` glues the marker to the word ("realist’s.1") and
# max-area matching inherits the body span — the marker span is lost.
# The span's text counts, not the word's: 1–2 digits with optional paren
# or `.)`, note symbol (* † ‡ § ¶) or superscript unicode digit.
# (Horizontal LTR text only: the suffix rule below uses the x axis.)
_RE_MARKER = re.compile(r"^[(\[]?(\d{1,2}|[*†‡§¶]|[¹²³⁴⁵⁶⁷⁸⁹⁰]{1,2})[.)\]]?$")


def _span_marker(span, median, body_bottom):
    """Does the span look like a note marker? MuPDF bit always wins;
    without it, small digit (<0.8xmedian, the measured 0.62–0.75x band)
    with baseline elevated above the line body's baseline (>0.25x font_size;
    below the PDFix 0.5x ceiling). Symbol (*†‡§¶) skips the smaller
    font_size — usually comes full-size, only elevated. Unicode
    superscript digit (¹²³) is signal by itself. `body_bottom` is the bottom (bbox[3],
    dict coords, y down) of the line body; None with no body.
    """
    text = (span.get("text") or "").strip()
    if not text or not _RE_MARKER.match(text):
        return False
    if int(span.get("flags", 0)) & 1:
        return True
    if text[0] in "*†‡§¶" or text[0] in "¹²³⁴⁵⁶⁷⁸⁹⁰":
        return body_bottom is not None and span["bbox"][3] < body_bottom
    font_size = float(span.get("size", 0.0))
    return (
        median > 0
        and 0 < font_size < 0.8 * median
        and body_bottom is not None
        and (body_bottom - span["bbox"][3]) > 0.25 * font_size
    )


def _crosses(a, b):
    """Interseção de boxes com área positiva (toque de borda não vale)."""
    return min(a[2], b[2]) > max(a[0], b[0]) and min(a[3], b[3]) > max(a[1], b[1])


# In-document evidence (pre-scan in main): whole words
# (lowercase, >=4 letters) and hyphenated forms. Before the dictionary.
_WHOLE = frozenset()
_HYPHENATED = frozenset()


def _starts_with_note(text):
    """Começa como chamada de nota: número (1–2 dígitos) glued ou seguido
    de pontuação, depois letra. Cobre "1The first edition...", "2Demopoulos",
    "3)." e "12. Smith" — a forma real dos corpos de nota em PDF acadêmico.
    """
    m = re.match(r"^\s*(\d{1,2})\s*[.):]?\s*(?=[A-Za-z])", text)
    return bool(m)


def candidates_ok(candidates, page_height):
    """Accepts the block only if it looks like a note block (SPIE 2015 / PKU).

    Two conditions, both to contain the measured false positives:
    - Several lines and at least one opening with a note number. A lone
      line in the footer is almost always a print watermark ("EBSCOhost
      - printed on ..."), which sets smaller type and lives in the footer like a note —
      and it promoted a false ruler on EVERY page of one measured article.
    - The block reaches the lower margin half: footnotes live at the
      page foot, not in the middle of the text.
    """
    if len(candidates) < 2:
        return False
    if not any(_starts_with_note(l["text"]) for l in candidates):
        return False
    # box = [x0, bottom, x1, top] in PDFKit coords (origin at bottom): the note
    # block lives at the page FOOT, which is the LOWEST top (smaller box[3]).
    lowest_top = min(l["box"][3] for l in candidates)
    return lowest_top < page_height * 0.5


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    try:
        import pymupdf as fitz
    except ImportError:
        print("pdf_extract: PyMuPDF not installed", file=sys.stderr)
        return 2

    try:
        doc = fitz.open(args.pdf)
    except Exception as exc:
        print(f"pdf_extract: could not open the PDF: {exc}", file=sys.stderr)
        return 3

    pages = []
    # Pre-scan of the whole document (words only, ~0.1 s): in-document
    # evidence for hyphen joining — a join occurring whole further ahead or a
    # hyphenated form occurring count for any language, before the
    # system dictionary (which only knows English).
    global _WHOLE, _HYPHENATED
    whole, hyphenated = set(), set()
    for page in doc:
        for w in page.get_text("words"):
            txt = (w[4] or "").strip().replace("­", "")
            if not txt:
                continue
            low = txt.lower()
            if "-" in txt and len(txt) > 3:
                hyphenated.add(low)
            if txt.isalpha() and len(txt) >= 4:
                whole.add(low)
    _WHOLE, _HYPHENATED = frozenset(whole), frozenset(hyphenated)
    for index, page in enumerate(doc):
        h = page.rect.height
        W = page.rect.width
        # Note rule: thin horizontal drawing, width 1/10-1/2 of the page,
        # in the lower half (research §4: short rule above the notes).
        # Comes out in PDFKit coords (top of the rule); None with no rule. Swift uses it
        # to decide what is BELOW it (note zone).
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

        # Line/block structure: {(bno, lno): {"spans": [...], "order": n}}.
        # The block/line numbers of "words" match those of "dict".
        structure = {}
        order = 0
        for bno, block in enumerate(dd.get("blocks", [])):
            if block.get("type", 0) != 0:
                continue
            for lno, line in enumerate(block.get("lines", [])):
                structure[(bno, lno)] = {"spans": line.get("spans", []), "order": order}
                order += 1
        font_sizes = [
            s["size"]
            for info in structure.values()
            for s in info["spans"]
            if s.get("size", 0) > 0
        ]
        median = statistics.median(font_sizes) if font_sizes else 0.0

        # Words per (block, line), with box in PDFKit coords.
        groups = {}
        for w in page.get_text("words"):
            x0, y0, x1, y1, text, block, line, _ = w
            # Invisible soft hyphen (U+00AD) always leaves; it is not a real hyphen.
            text = (text or "").replace("\u00ad", "").strip()
            if not text:
                continue
            box = [x0, h - y1, x1, h - y0]
            groups.setdefault((block, line), []).append(
                {"x0": x0, "text": text, "box": box}
            )

        # Joins an end-of-line hyphen with the ADJACENT next line (never
        # across blocks: here each line is its own block). Adjacency = the
        # next one starts below, near, with horizontal overlap. A hyphen
        # mid-line ("state-of-the-art") is never a candidate.
        if structure:
            order_of = {k: v["order"] for k, v in structure.items()}
            group_keys = sorted(groups, key=lambda k: order_of.get(k, 10**9))
        else:
            group_keys = sorted(groups)

        def _box(ps):
            bs = [p["box"] for p in ps]
            return [min(b[0] for b in bs), min(b[1] for b in bs),
                    max(b[2] for b in bs), max(b[3] for b in bs)]

        alturas = []
        for group_key in group_keys:
            ps = sorted(groups[group_key], key=lambda p: p["x0"])
            if not ps:
                continue
            c = _box(ps)
            if c[3] > c[1]:
                alturas.append(c[3] - c[1])
        median_height = statistics.median(alturas) if alturas else 12.0
        for pos, group_key in enumerate(group_keys):
            parts = sorted(groups[group_key], key=lambda p: p["x0"])
            if not parts:
                continue
            last_part = parts[-1]
            last_text = last_part["text"]
            # Candidato a juncao: hifen final ou elisao curta. A decisao
            # (dicionario + caixa) sai em `_join_end`, apos a adjacencia.
            if last_text[-1:] not in ("-", "\u2019", "'"):
                continue
            if pos + 1 >= len(group_keys):
                continue
            next_key = group_keys[pos + 1]
            c0 = _box(parts)
            c1 = _box(sorted(groups[next_key], key=lambda p: p["x0"]))
            # PDFKit coords (origin at bottom): gap = bottom of the current minus
            # top of the next; 0..1.5 lines when it is a continuation. An
            # anomalous-box word (top too high) blows the gap without breaking
            # the bottom-to-bottom step — which is 0.5..1.7 lines. Either one
            # releases; horizontal overlap is still required.
            gap = c0[1] - c1[3]
            step = c0[1] - c1[1]
            if not (0 <= gap <= 1.5 * median_height
                    or 0.5 * median_height <= step <= 1.7 * median_height):
                continue
            overlap = min(c0[2], c1[2]) - max(c0[0], c1[0])
            if overlap < 0.5 * min(c0[2] - c0[0], c1[2] - c1[0]):
                continue
            next_parts = sorted(groups[next_key], key=lambda p: p["x0"])
            if not next_parts:
                continue
            first_text = next_parts[0]["text"]
            joined_text = _join_end(last_text, first_text)
            if joined_text is None:
                continue
            b0 = last_part["box"]
            b1 = next_parts[0]["box"]
            union_box = [min(b0[0], b1[0]), min(b0[1], b1[1]),
                     max(b0[2], b1[2]), max(b0[3], b1[3])]
            parts[-1] = {"x0": last_part["x0"], "text": joined_text, "box": union_box,
                          "joined": True}
            groups[group_key] = parts
            groups[next_key] = next_parts[1:]

        lines = []
        for group_key in group_keys:
            parts = sorted(groups[group_key], key=lambda p: p["x0"])
            if not parts:
                continue
            info = structure.get(group_key, {"spans": []})
            spans = info["spans"]
            line_top = min((s["bbox"][1] for s in spans), default=None)
            # Line body baseline (largest bottom among body spans, in
            # dict coords with y down): the superscript marker has its
            # baseline ABOVE it. The top is no use — the marker usually defines
            # the line top and the difference reads zero (measured 2026-10-14).
            body_bottom = max(
                (
                    s["bbox"][3]
                    for s in spans
                    if float(s.get("size", 0.0)) >= 0.8 * median
                ),
                default=None,
            ) if median > 0 else None
            items = []
            for p in parts:
                span = _span_of(
                    [p["box"][0], h - p["box"][3], p["box"][2], h - p["box"][1]],
                    spans,
                )
                font_size = float(span.get("size", 0.0)) if span else 0.0
                flag = int(span.get("flags", 0)) if span else 0
                # Superscript: MuPDF flag, or small+elevated.
                elevated = False
                if span and line_top is not None and font_size > 0:
                    elevated = (span["bbox"][1] - line_top) < -0.3 * font_size
                sup = bool(flag & 1) or (
                    median > 0 and 0 < font_size < 0.8 * median and elevated
                )
                # Glued marker ("realist’s.1"): `words` fuses marker and
                # word into a single token and area matching inherits the body
                # span. Every line span looking like a marker (bit or
                # elevated-baseline geometry) crossing the word marks it —
                # with a suffix rule on the glued token: a hyphen-joined word
                # has a wide union box and would cross the mid-line marker
                # ("reference", "departure" in the measured article). Counts
                # span center in the word's final 30%; a word that is already
                # just the marker ("7", "(1)") counts on any crossing.
                if not sup and spans:
                    box_dict = [p["box"][0], h - p["box"][3],
                                  p["box"][2], h - p["box"][1]]
                    sozinha = bool(_RE_MARKER.match(p["text"].strip()))
                    for s in spans:
                        if not _span_marker(s, median, body_bottom):
                            continue
                        if not _crosses(box_dict, s["bbox"]):
                            continue
                        if sozinha:
                            sup = True
                            break
                        meio = (s["bbox"][0] + s["bbox"][2]) / 2
                        larg = box_dict[2] - box_dict[0]
                        if larg > 0 and (meio - box_dict[0]) / larg >= 0.7:
                            sup = True
                            break
                items.append({"text": p["text"], "box": p["box"], "sup": sup})
            boxes = [p["box"] for p in parts]
            # Line's dominant font (largest non-superscript span): footnotes
            # print smaller than running text.
            line_size = max(
                (
                    float(s.get("size", 0.0))
                    for s in spans
                    if not (int(s.get("flags", 0)) & 1)
                ),
                default=0.0,
            )
            # Section titles set LARGER type; not a note, even when smaller than the
            # document title. Measured against the page median.
            is_title = bool(spans) and median > 0 and line_size > median * 1.18
            # Note heuristic (edgeparse-core): font smaller than 0.85x the
            # dominant one, and running text (>= 12 chars). Swift crosses with
            # position (note zone / ruler) before treating as body.
            is_note = (
                median > 0
                and 0 < line_size <= 0.85 * median
                and not is_title
                and len(boxes) >= 12
            )
            caixa_line = [
                min(b[0] for b in boxes),
                min(b[1] for b in boxes),
                max(b[2] for b in boxes),
                max(b[3] for b in boxes),
            ]
            lines.append({
                "text": " ".join(p["text"] for p in parts),
                "box": caixa_line,
                "words": items,
                "note": is_note,
            })

        # SYNTHETIC note zone (edgeparse-core) when no ruler is drawn:
        # from the top of the contiguous "note"-line block in the
        # lower half. `box[3]` is the top in PDFKit coords (origin at bottom),
        # so "lower half" is top < half the height. Outputs in PDFKit
        # coords (block top). Without a block, keeps None — the old
        # heuristics still apply.
        if regra_y is None and lines:
            half = h * 0.5
            candidates = [
                l for l in lines if l["note"] and l["box"][3] < half
            ]
            if candidates_ok(candidates, h):
                regra_y = max(l["box"][3] for l in candidates)
        pages.append({"index": index, "footnote_rule_y": regra_y, "lines": lines})

    # Joining across the page turn: hyphenated last body line
    # (or short elision) + first body line of the next page in
    # lowercase. Without this "en-" + "larged" becomes two fragments and the
    # audio stutters. Body with body only: below the ruler (note zone) never.
    for prev_page, next_page in zip(pages, pages[1:]):
        if not prev_page["lines"] or not next_page["lines"]:
            continue
        # A loose page number ("9", "10") is not text: it lives after
        # the last body line and before the first, and would block the
        # join. Holds for any PDF: digits only, up to 4 characters.
        def is_number_only(l):
            return l["words"] and l["text"].strip().isdigit() \
                and len(l["text"].strip()) <= 4
        last_line = None
        for l in reversed(prev_page["lines"]):
            if is_number_only(l):
                continue
            last_line = l
            break
        first_line = None
        for l in next_page["lines"]:
            if is_number_only(l):
                continue
            first_line = l
            break
        if last_line is None or first_line is None:
            continue
        if not last_line["words"] or not first_line["words"]:
            continue
        prev_rule = prev_page["footnote_rule_y"]
        if prev_rule is not None and last_line["box"][3] < prev_rule:
            continue
        if last_line.get("note") or first_line.get("note"):
            continue
        last_word = last_line["words"][-1]["text"]
        first_word = first_line["words"][0]["text"]
        joined_text = _join_end(last_word, first_word)
        if joined_text is None:
            continue
        w0 = last_line["words"][-1]
        # The joined box stays ONLY on the previous page: joining across the
        # turn would create a 600 pt box corrupting reading order
        # and margin ranges in Swift — a box never crosses pages.
        # The next page's fragment is consumed along.
        w0["text"] = joined_text
        first_line["words"] = first_line["words"][1:]
        last_line["text"] = " ".join(w["text"] for w in last_line["words"])
        bs = [w["box"] for w in last_line["words"]]
        last_line["box"] = [min(b[0] for b in bs), min(b[1] for b in bs),
                      max(b[2] for b in bs), max(b[3] for b in bs)]
        if first_line["words"]:
            first_line["text"] = " ".join(w["text"] for w in first_line["words"])
            cs = [w["box"] for w in first_line["words"]]
            first_line["box"] = [min(c[0] for c in cs), min(c[1] for c in cs),
                          max(c[2] for c in cs), max(c[3] for c in cs)]
        else:
            next_page["lines"] = [l for l in next_page["lines"] if l is not first_line]

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"pages": pages}, fh, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
