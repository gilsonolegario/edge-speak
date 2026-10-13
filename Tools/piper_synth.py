#!/usr/bin/env python3
"""Síntese offline por frase com Piper (EdgeSpeak).

Processo persistente: carrega a voz UMA vez e atende pedidos pelo stdin.
O app o lança como filho e o mata junto com a leitura (sem daemon).

Uso:
    piper_synth.py --onnx /caminho/voz.onnx [--length-scale 1.0]

Protocolo (uma linha JSON por pedido/resposta):
    pedido:   {"id": 0, "text": "Olá mundo.", "wav": "/tmp/f0.wav"}
    resposta: {"id": 0, "wav": "/tmp/f0.wav", "duration": 1.23}

A duração é lida do próprio WAV gravado. Pedido vazio responde duration 0.
Erros de síntese respondem {"id": N, "error": "..."} e o processo segue.
"""

import argparse
import json
import sys
import wave


def carregar_voz(onnx_path):
    """Carrega a voz Piper do arquivo .onnx (config vem do .onnx.json)."""
    try:
        from piper.voice import PiperVoice
    except ImportError:
        from piper import PiperVoice
    return PiperVoice.load(onnx_path)


def duracao_wav(caminho):
    """Duração em segundos lida do cabeçalho do WAV (sem decodificar)."""
    with wave.open(caminho, "rb") as fh:
        quadros = fh.getnframes()
        taxa = fh.getframerate() or 22050
        return quadros / float(taxa)


def sintetizar(voz, texto, caminho_wav, escala):
    """Gera um WAV por frase a partir dos chunks da voz."""
    import numpy as np

    try:
        from piper.config import SynthesisConfig

        blocos = voz.synthesize(texto, syn_config=SynthesisConfig(length_scale=escala))
    except TypeError:
        # Versão sem o parâmetro: usa o ritmo padrão da voz.
        blocos = voz.synthesize(texto)
    taxa = None
    partes = []
    for bloco in blocos:
        taxa = bloco.sample_rate
        partes.append(bloco.audio_int16_bytes)
    if taxa is None or not partes:
        raise RuntimeError("a voz não gerou áudio para o texto")
    pcm = b"".join(partes)
    amostras = np.frombuffer(pcm, dtype=np.int16)
    with wave.open(caminho_wav, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(taxa)
        fh.writeframes(amostras.tobytes())
    return duracao_wav(caminho_wav)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", required=True, help="caminho do .onnx da voz")
    # Ritmo padrão; cada pedido pode sobrescrever com "length_scale".
    parser.add_argument("--length-scale", type=float, default=1.0)
    args = parser.parse_args()

    try:
        voz = carregar_voz(args.onnx)
    except Exception as exc:  # noqa: BLE001 - erro vira mensagem para a UI
        print(f"piper: falha ao carregar a voz: {exc}", file=sys.stderr)
        return 1

    # Pronto: avisa o app que a (lenta) carga terminou.
    print(json.dumps({"ready": True}), flush=True)

    for linha in sys.stdin:
        linha = linha.strip()
        if not linha:
            continue
        try:
            pedido = json.loads(linha)
        except json.JSONDecodeError as exc:
            print(json.dumps({"id": -1, "error": f"pedido inválido: {exc}"}), flush=True)
            continue
        pid = pedido.get("id", -1)
        texto = (pedido.get("text") or "").strip()
        destino = pedido.get("wav") or ""
        escala = float(pedido.get("length_scale", args.length_scale))
        if not texto or not destino:
            print(json.dumps({"id": pid, "wav": destino, "duration": 0.0}), flush=True)
            continue
        try:
            dur = sintetizar(voz, texto, destino, escala)
            print(json.dumps({"id": pid, "wav": destino, "duration": dur}), flush=True)
        except Exception as exc:  # noqa: BLE001 - um pedido não mata o processo
            print(json.dumps({"id": pid, "error": str(exc)[:300]}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
