# Credits — third-party components

No third-party code was copied into this app: only the general idea
(PDF + offline voice) served as inspiration.

## Offline voice

EdgeSpeak's offline reading uses the **Piper** synthesizer and open voices,
downloaded on demand at first use (nothing ships inside the repository).

- **Piper** — neural speech synthesizer, **GPL-3.0** license.
  Original project: <https://github.com/rhasspy/piper> ·
  macOS distribution used here (fork with a ready wheel):
  <https://github.com/OHF-Voice/piper1-gpl> (release v1.8.0).
- **Faber voice (pt-BR)** — `pt_BR-faber-medium.onnx`, public-domain dataset (**CC0**).
- **Edresson voice (pt-BR)** — `pt_BR-edresson-low.onnx`, same origin and license.
- **Cadu voice (pt-BR)** — `pt_BR-cadu-medium.onnx`, same origin and license.
- **Jeff voice (pt-BR)** — `pt_BR-jeff-medium.onnx`, same origin and license.
- **Lessac voice (en-US)** — `en_US-lessac-medium.onnx`, same origin and license.
  Voice files: <https://huggingface.co/rhasspy/piper-voices>.

  Note: `onnxruntime`, downloaded with the wheels, is the inference library
  Piper runs on — not a second engine.

## Online voice

- **edge-tts** — Microsoft Edge online TTS client, **LGPL-3.0** license
  (one file MIT, the rest LGPLv3).
  Project: <https://github.com/rany2/edge-tts>.
  Installed into the support venv at first use; `Tools/patch_edge_tts.py`
  applies small local patches (documented in the script header).

## PDF extraction

- **PyMuPDF** — text extraction with word boxes (via
  `Tools/pdf_extract.py`, in a separate Python process), **AGPL-3.0** license.
  Project: <https://github.com/pymupdf/PyMuPDF>

## Embedded runtime

- **CPython 3.13 base** (**PSF** license), via the standalone build managed
  by `uv` — packed into the `.app` so it runs on a virgin Mac; a private
  venv is created from it under `~/Library/Application Support/EdgeSpeak`
  at first launch.
