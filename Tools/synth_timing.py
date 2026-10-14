#!/usr/bin/env python3
"""Synthesize a passage and record each sentence's times (EdgeSpeak).

Usage:
    synth_timing.py --text-file T --voice V --out-mp3 A --out-json B

Why it exists: the `edge-tts` CLI only writes per-sentence SRT subtitles, and
reading the events directly lets the app highlight the sentence being read.

Generated JSON format:
    {"segments": [{"start": 0.05, "duration": 1.05, "text": "Hello world.",
                   "words": [{"start": 0.11, "duration": 0.26, "text": "Hello"}]}]}

Each sentence carries its words, in order. SINGLE PASS: the library only
emits ONE boundary type per synthesis, so only `WordBoundary` is requested and
the sentences are derived by grouping the words by the input text - each
word is located in the text by sequential search and lands in the sentence
(passage ending in `. ! ? ... :`, with closing quotes) that contains its
position. Measured: word events do NOT carry the punctuation (e.g. `world`,
not `world.`), hence grouping by the word's text was impossible and the
alignment uses the input text. The word that closes a sentence belongs to
it; leftover goes to the last one; a sentence with no word comes out with
zeroed times (time is never invented) and Swift fills the rest by order as
before.

Times are in seconds (converted from hundredths of a microsecond, the
unit the library uses).

`--lines-file` mode (preferred): the app passes ONE FILE with one speech
sentence per line, in the published order, and each line becomes exactly ONE
segment, in order - no `_SENT_END`/regex. Words are grouped into the
corresponding sentence by sequential search in the rebuilt text
(`"\\n".join(lines)`); a sentence with no word comes out zeroed. One line,
ONE output, even when empty: discarding the empty one would shift all the
following ones, which is the defect this mode exists to eliminate. Without
`--lines-file`, the old regex mode applies, only for compatibility.
"""
import argparse
import asyncio
import json
import re
import sys

from edge_tts import Communicate

# The library reports times in 100 ns units (hundredths of a microsecond).
TICKS_PER_SECOND = 10_000_000

# Sentence terminators + closing quotes/parens that may follow them.
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
    # `rate` is edge-tts's cadence control: "+30%" speaks faster.
    # Since the times come from the already-generated audio, the highlight keeps up by itself.
    # Single pass: audio + words (word boundary); sentences are
    # derived from the words (see `_group_words`).
    communicate = Communicate(text, voice, rate=rate, boundary="WordBoundary")
    async for chunk in communicate.stream():
        kind = chunk.get("type")
        if kind == "audio":
            audio.extend(chunk["data"])
        elif kind == "WordBoundary":
            words.append(_event(chunk))
    print(
        f"edge_tts: 1 synthesis (single pass, boundary=WordBoundary, "
        f"{len(words)} words)",
        file=sys.stderr,
    )

    if not audio:
        print("edge_tts: no audio received", file=sys.stderr)
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
    """Splits the text into (start, end, passage) at sentence terminators."""
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
    """Groups words into sentences by the input text, in order.

    Old mode (compatibility): sentences derived by regex.
    """
    return _group_words_with_spans(text, _split_sentences(text), words)


def _spans_from_lines(lines: list) -> tuple:
    """One line = one passage, 1:1 with the app (including the empty line).

    The app writes one line per published sentence. Discarding the empty line
    would shorten the passage list and shift all following sentences - exactly
    the defect the per-line mode eliminates. The empty line becomes a
    zero-length passage and comes out with zeroed times.
    """
    text = "\n".join(lines)
    spans = []
    start = 0
    for line in lines:
        end = start + len(line)
        spans.append((start, end, line))
        start = end + 1  # skips the join's "\n"
    return text, spans


def _group_words_lines(lines: list, words: list) -> list:
    """`--lines-file` mode: 1 segment per non-empty line, in order."""
    text, spans = _spans_from_lines(lines)
    if not spans:
        return []
    return _group_words_with_spans(text, spans, words)


def _group_words_with_spans(text: str, spans: list, words: list) -> list:
    """Common core: words land in the sentence containing their position."""
    if not spans:
        return []
    buckets: list = [[] for _ in spans]
    cursor = 0
    current = 0
    for word in words:
        pos = text.find(word["text"], cursor)
        if pos >= 0:
            cursor = pos + len(word["text"])
            # Last sentence that already started at the word's position.
            for i, (s, _e, _t) in enumerate(spans):
                if s <= pos:
                    current = i
                else:
                    break
        # No position (service normalization): keeps the current sentence, by
        # order, without discarding nor inventing a word.
        buckets[current].append(word)
    segments = []
    # Duration touches the start of the next sentence (like the old mode's
    # SentenceBoundary, whose gaps joined each other); only the last one ends at the end
    # of the last word. Everything derives from measured times, nothing is invented.
    # Without this the silence gap between sentences (0.3–0.5 s, measured) left the
    # duration and the highlight flickered between sentences.
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
    # Speech pace: "+25%" speaks 25% faster. The highlight stays
    # correct by itself, because the times come from the already-synthesized audio.
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
