#!/usr/bin/env python3
"""Sentence-by-sentence offline synthesis with Piper (EdgeSpeak).

Persistent process: loads the voice ONCE and serves requests on stdin.
The app launches it as a child and kills it along with the reading (no daemon).

Usage:
    piper_synth.py --onnx /path/to/voice.onnx [--length-scale 1.0]

Protocol (one JSON line per request/response):
    request:  {"id": 0, "text": "Hello world.", "wav": "/tmp/f0.wav"}
    response: {"id": 0, "wav": "/tmp/f0.wav", "duration": 1.23}

The duration is read from the WAV itself. An empty request answers duration 0.
Synthesis errors answer {"id": N, "error": "..."} and the process goes on.
"""
import argparse
import json
import sys
import wave


def load_voice(onnx_path):
    """Loads the Piper voice from the .onnx file (config comes from the .onnx.json)."""
    try:
        from piper.voice import PiperVoice
    except ImportError:
        from piper import PiperVoice
    return PiperVoice.load(onnx_path)


def wav_duration(path):
    """Duration in seconds read from the WAV header (no decoding)."""
    with wave.open(path, "rb") as fh:
        frames = fh.getnframes()
        rate = fh.getframerate() or 22050
        return frames / float(rate)


def synthesize(voice, text, wav_path, scale):
    """Generates one WAV per sentence from the voice's chunks."""
    import numpy as np

    try:
        from piper.config import SynthesisConfig

        chunks = voice.synthesize(text, syn_config=SynthesisConfig(length_scale=scale))
    except TypeError:
        # Version without the parameter: uses the voice's default pace.
        chunks = voice.synthesize(text)
    rate = None
    parts = []
    for chunk in chunks:
        rate = chunk.sample_rate
        parts.append(chunk.audio_int16_bytes)
    if rate is None or not parts:
        raise RuntimeError("the voice generated no audio for the text")
    pcm = b"".join(parts)
    samples = np.frombuffer(pcm, dtype=np.int16)
    with wave.open(wav_path, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(rate)
        fh.writeframes(samples.tobytes())
    return wav_duration(wav_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", required=True, help="path to the voice .onnx")
    # Default pace; each request can override with "length_scale".
    parser.add_argument("--length-scale", type=float, default=1.0)
    args = parser.parse_args()

    try:
        voice = load_voice(args.onnx)
    except Exception as exc:  # noqa: BLE001 - the error becomes a message for the UI
        print(f"piper: failed to load the voice: {exc}", file=sys.stderr)
        return 1

    # Ready: tells the app the (slow) load finished.
    print(json.dumps({"ready": True}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            print(json.dumps({"id": -1, "error": f"invalid request: {exc}"}), flush=True)
            continue
        pid = request.get("id", -1)
        text = (request.get("text") or "").strip()
        dest = request.get("wav") or ""
        scale = float(request.get("length_scale", args.length_scale))
        if not text or not dest:
            print(json.dumps({"id": pid, "wav": dest, "duration": 0.0}), flush=True)
            continue
        try:
            dur = synthesize(voice, text, dest, scale)
            print(json.dumps({"id": pid, "wav": dest, "duration": dur}), flush=True)
        except Exception as exc:  # noqa: BLE001 - one request does not kill the process
            print(json.dumps({"id": pid, "error": str(exc)[:300]}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
