#!/usr/bin/env python3
"""Sintetiza um trecho e grava os tempos de cada frase (EdgeSpeak).

Uso:
    synth_timing.py --text-file T --voice V --out-mp3 A --out-json B

Por que existe: o CLI `edge-tts` só grava legendas por frase em SRT, e ler os
eventos direto permite ao app destacar a frase que está sendo lida.

Formato do JSON gerado:
    {"segments": [{"start": 0.05, "duration": 1.05, "text": "Hello world.",
                   "words": [{"start": 0.11, "duration": 0.26, "text": "Hello"}]}]}

Cada frase carrega suas palavras, por ordem. PASSE ÚNICO: a biblioteca só
emite UM tipo de fronteira por síntese, então pede-se só `WordBoundary` e as
frases são derivadas agrupando as palavras pelo texto de entrada — cada
palavra é localizada no texto por busca sequencial e cai na frase (trecho
terminado em `. ! ? … :`, com fecha-aspas) que contém sua posição. Medido: os
eventos de palavra NÃO trazem a pontuação (p. ex. `world`, não `world.`), por
isso agrupar pelo texto da palavra era impossível e o alinhamento usa o texto
de entrada. A palavra que fecha a frase pertence a ela; sobra vai para a
última; frase sem palavra sai com tempos zerados (nunca se inventa tempo) e o
Swift preenche o resto por ordem como antes.

Os tempos são em segundos (convertidos de centésimos de microssegundo, a
unidade que a biblioteca usa).

Modo `--lines-file` (preferido): o app passa UM ARQUIVO com uma frase de fala
por linha, na ordem publicada, e cada linha vira exatamente UM segmento, na
ordem — sem `_SENT_END`/regex. As palavras são agrupadas na frase
correspondente por busca sequencial no texto reconstruído
(`"\\n".join(linhas)`); frase sem palavra sai zerada. Uma linha, UMA saída,
mesmo vazia: descartar a vazia deslocaria todas as seguintes, que é o defeito
que este modo existe para eliminar. Sem `--lines-file`, vale o modo antigo por
regex, só para compatibilidade.
"""
import argparse
import asyncio
import json
import re
import sys

from edge_tts import Communicate

# A biblioteca reporta tempos em unidades de 100 ns (centésimos de microssegundo).
TICKS_PER_SECOND = 10_000_000

# Terminadores de frase + fecha-aspas/parênteses que podem segui-los.
_SENT_END = re.compile(r'[.!?…:]["\'»”’)\]]*')


def _event(chunk) -> dict:
    return {
        "start": chunk["offset"] / TICKS_PER_SECOND,
        "duration": chunk["duration"] / TICKS_PER_SECOND,
        "text": chunk.get("text", ""),
    }


async def synth(
    text: str, voice: str, out_mp3: str, out_json: str, rate: str = "+0%",
    lines: "list[str] | None" = None,
) -> int:
    words = []
    audio = bytearray()
    # `rate` é o controle de cadência do edge-tts: "+30%" fala mais rápido.
    # Como os tempos vêm do áudio já gerado, o highlight acompanha sozinho.
    # Passe único: áudio + palavras (fronteira de palavra); as frases são
    # derivadas das palavras (ver `_group_words`).
    communicate = Communicate(text, voice, rate=rate, boundary="WordBoundary")
    async for chunk in communicate.stream():
        kind = chunk.get("type")
        if kind == "audio":
            audio.extend(chunk["data"])
        elif kind == "WordBoundary":
            words.append(_event(chunk))
    print(
        f"edge_tts: 1 síntese (passe único, boundary=WordBoundary, "
        f"{len(words)} palavras)",
        file=sys.stderr,
    )

    if not audio:
        print("edge_tts: nenhum áudio recebido", file=sys.stderr)
        return 3

    segments = (
        _group_words_lines(lines, words)
        if lines is not None
        else _group_words(text, words)
    )

    with open(out_mp3, "wb") as fh:
        fh.write(audio)
    with open(out_json, "w", encoding="utf-8") as fh:
        json.dump({"segments": segments}, fh, ensure_ascii=False)
    return 0


def _split_sentences(text: str) -> list:
    """Corta o texto em (início, fim, trecho) nos terminadores de frase."""
    spans = []
    start = 0
    for match in _SENT_END.finditer(text):
        seg = text[start : match.end()]
        if seg.strip():
            spans.append((start, match.end(), seg))
        start = match.end()
    tail = text[start:]
    if tail.strip():
        spans.append((start, len(text), tail))
    return spans


def _group_words(text: str, words: list) -> list:
    """Agrupa palavras em frases pelo texto de entrada, por ordem.

    Modo antigo (compatibilidade): frases derivadas por regex.
    """
    return _group_words_with_spans(text, _split_sentences(text), words)


def _spans_from_lines(lines: list) -> tuple:
    """Uma linha = um trecho, 1:1 com o app (inclusive a linha vazia).

    O app escreve uma linha por frase publicada. Descartar a linha vazia
    encurtaria a lista de trechos e deslocaria todas as frases seguintes —
    exatamente o defeito que o modo por linhas elimina. A linha vazia vira
    trecho de comprimento zero e sai com tempos zerados.
    """
    text = "\n".join(lines)
    spans = []
    start = 0
    for line in lines:
        end = start + len(line)
        spans.append((start, end, line))
        start = end + 1  # pula o "\n" do join
    return text, spans


def _group_words_lines(lines: list, words: list) -> list:
    """Modo `--lines-file`: 1 segmento por linha não vazia, na ordem."""
    text, spans = _spans_from_lines(lines)
    if not spans:
        return []
    return _group_words_with_spans(text, spans, words)


def _group_words_with_spans(text: str, spans: list, words: list) -> list:
    """Núcleo comum: palavras caem na frase que contém sua posição."""
    if not spans:
        return []
    buckets: list = [[] for _ in spans]
    cursor = 0
    current = 0
    for word in words:
        pos = text.find(word["text"], cursor)
        if pos >= 0:
            cursor = pos + len(word["text"])
            # Última frase que já começou na posição da palavra.
            for i, (s, _e, _t) in enumerate(spans):
                if s <= pos:
                    current = i
                else:
                    break
        # Sem posição (normalização do serviço): mantém a frase atual, por
        # ordem, sem descartar nem inventar palavra.
        buckets[current].append(word)
    segments = []
    # Duração encosta no início da frase seguinte (como os SentenceBoundary
    # do modo antigo, cujos vãos se emendavam); só a última termina no fim
    # da última palavra. Tudo deriva de tempos medidos, nada é inventado.
    # Sem isso o vão de silêncio entre frases (0,3–0,5 s, medido) saía da
    # duração e o highlight piscava entre frases.
    starts = [bucket[0]["start"] if bucket else None for bucket in buckets]
    for i, ((_s, _e, trecho), bucket) in enumerate(zip(spans, buckets)):
        if bucket:
            end = max(w["start"] + w["duration"] for w in bucket)
            for nxt in starts[i + 1 :]:
                if nxt is not None and nxt > bucket[0]["start"]:
                    end = nxt
                    break
            segments.append(
                {
                    "start": bucket[0]["start"],
                    "duration": end - bucket[0]["start"],
                    "text": trecho.strip(),
                    "words": bucket,
                }
            )
        else:
            segments.append(
                {"start": 0.0, "duration": 0.0, "text": trecho.strip(),
                 "words": []}
            )
    return segments


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--text-file", required=True)
    parser.add_argument("--voice", required=True)
    parser.add_argument("--out-mp3", required=True)
    parser.add_argument("--out-json", required=True)
    # Ritmo da fala: "+25%" fala 25% mais rápido. O highlight continua
    # correto sozinho, porque os tempos vêm do áudio já sintetizado.
    parser.add_argument("--rate", default="+0%")
    parser.add_argument("--lines-file", default=None)
    args = parser.parse_args()

    with open(args.text_file, encoding="utf-8") as fh:
        text = fh.read()
    if not text.strip():
        print("edge_tts: texto vazio", file=sys.stderr)
        return 2
    lines = None
    if args.lines_file:
        with open(args.lines_file, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        if not any(line.strip() for line in lines):
            print("edge_tts: lines-file vazio", file=sys.stderr)
            return 2

    try:
        return asyncio.run(
            synth(text, args.voice, args.out_mp3, args.out_json, args.rate,
                  lines)
        )
    except Exception as exc:  # noqa: BLE001 - erro vira mensagem para a UI
        print(f"edge_tts: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
