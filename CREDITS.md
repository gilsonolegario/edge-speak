# Créditos — voz offline

A leitura offline do EdgeSpeak usa o sintetizador **Piper** e vozes abertas,
baixados sob demanda na primeira utilização (nada vem embutido no repositório).

- **Piper** — sintetizador neural de voz, licença **GPL-3.0**.
  Projeto original: <https://github.com/rhasspy/piper> ·
  distribuição usada no macOS (fork com wheel pronto):
  <https://github.com/OHF-Voice/piper1-gpl> (release v1.8.0).
- **Voz Faber (pt-BR)** — `pt_BR-faber-medium.onnx`, conjunto de dados em
  domínio público (**CC0**).
  Vozes: <https://huggingface.co/rhasspy/piper-voices>
  (`pt/pt_BR/faber/medium/`).
- **Voz Lessac (en-US)** — `en_US-lessac-medium.onnx`, mesma origem e licença
  das vozes Piper (`en/en_US/lessac/medium/`).

Alternativa futura avaliada: **sherpa-onnx**
(<https://github.com/k2-fsa/sherpa-onnx>) — motor offline de fala com
modelos próprios; fica como caminho de reserva caso o Piper deixe de
atender.

Nenhum código de terceiros foi copiado para este app: só a ideia geral
(PDF + voz offline) serviu de inspiração.

## Extração de PDF

- **PyMuPDF** — extração de texto com caixas de palavra (via
  `Tools/pdf_extract.py`, em processo Python separado), licença **AGPL-3.0**.
  Projeto: <https://github.com/pymupdf/PyMuPDF>
