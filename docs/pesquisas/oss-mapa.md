# OSS mapa — reaproveitar (adaptar, não copiar) no EdgeSpeak

Data: 2026-10-13. Projeto: /Users/issoeocio/Projects/edge-speak (SwiftUI macOS 14+, SwiftPM;
motores edge-tts online com tempos de palavra e Piper offline GPL-3.0 sem tempos; extração
PyMuPDF AGPL via processo Python + reserva PDFKit). Quadro de licenças hoje: GPL-3.0 (Piper) +
AGPL (PyMuPDF) + ffmpeg (LGPL/GPL conforme build) — todos via processo separado.
Regra: permissiva (MIT/Apache/BSD) = OK; copyleft = dizer o que obriga. Licenças verificadas via
API oficial do GitHub (api.github.com/repos/<repo>/license) em 2026-10-13, salvo nota.

## 1. Alinhamento forçado palavra↔áudio (tempos offline)

| Candidato | Licença (fonte oficial) | Veredito | Por quê / como adaptar |
|---|---|---|---|
| Montreal Forced Aligner (MFA) — MontrealCorpusTools/Montreal-Forced-Aligner | MIT (código); modelos mfa-models CC-BY-4.0 (atribuição, não copyleft) | **ADAPTAR (dependência)** | Melhor qualidade medida: WBE 18 ms no benchmark Aligner-SUPERB (vs 33 ms WhisperX). Tem modelo acústico PT (GlobalPhone) + G2P PT oficial. Roda em Mac arm64: conda-forge tem 91 builds osx-arm64 (kaldi também, 31 builds). Integração = processo Python/CLI separado, o mesmo padrão do app com PyMuPDF/edge-tts; entrada = texto da frase + WAV da frase do Piper → saída = tempos por palavra. CC-BY-4.0 dos modelos exige apenas atribuição (pôr no CREDITS.md). |
| whisper.cpp — ggml-org/whisper.cpp | MIT | **ADAPTAR (reserva)** | Word timestamps nativos (token-level, `-otw`); Metal/CoreML maduros em Apple Silicon (CoreML 2–3× mais rápido que Metal). É ASR, não alinhamento forçado: pode divergir do texto do PDF e a precisão de milissegundo é menor. Integração via CLI embutido ou C API (link estático MIT é trivial). Zero risco de licença. |
| WhisperX — m-bain/whisperX | BSD-2-Clause | **EVITAR** | Alinhamento por wav2vec2 (modelos PT comunitários existem, Apache-2.0, mas qualidade de alinhamento não verificada). Depende de PyTorch (centenas de MB) — pesado demais para o bundle (~280 MB já com tudo). BSD-2-Clause não seria problema; o peso é. |
| gentle — strob/gentle (antigo lowerquality/gentle) | MIT | **EVITAR** | Abandonado (sem manutenção), Docker-first, modelos só EN. |
| ReadAlong-Studio — ReadAlongs/Studio | MIT (com exceção declarada: modelo cmusphinx-en-us-5.2, FreeBSD, © Alpha Cephei); SoundSwallower (alinhador) = licença CMU tipo BSD | **ADAPTAR (referência)** | Pipeline completo g2p→alinhamento, mas focado em línguas indígenas; modelo embutido é en-us. Para PT precisaria de modelo/g2p pt próprios. Serve como referência de arquitetura, não como dependência para PT hoje. |

## 2. Verbalização de fórmulas matemáticas/lógicas

| Candidato | Licença | Veredito | Por quê / como adaptar |
|---|---|---|---|
| Speech Rule Engine (SRE) — Speech-Rule-Engine/speech-rule-engine | Apache-2.0 | **ADAPTAR (referência)** | Padrão ouro: MathSpeak + ClearSpeak completos, árvore semântica, saída SSML/Sable/VoiceXML, Braille Nemeth. **Não tem locale pt** (locales no repo: af, ca, da, de, en, es, fr, hi, it, ko, nb, nn, sv). A arquitetura de localização (sre-l10n, YAML) permite criar um locale pt, mas é portar as regras — esforço grande. O ReadAloudFilter do app já cobre EN/PT com testes; manter o próprio e usar o SRE como fonte semântica (cobertura de quantificadores, modais, turnos) é o caminho. Apache-2.0 não obriga nada em app fechado nem aberto. |
| MathJax-a11y / ClearSpeak — MathJax | Apache-2.0 | **ADAPTAR (referência)** | ClearSpeak é o mesmo rule set implementado no SRE (MathJax usa o SRE por baixo). Mesma limitação de idioma (docs v3: EN/FR/DE/ES; v4: "mais de uma dúzia", PT não confirmado). Browser-first; há build Node, mas roda no SRE direto. |

Nenhuma opção pronta resolve PT-BR — o regex próprio do app continua sendo a melhor cobertura PT.
O SRE entra como referência de estrutura e para expandir regras (ex.: silêncio de Quine, iota).

## 3. Extração de PDF com caixas de palavra

| Candidato | Licença | Veredito | Por quê / como adaptar |
|---|---|---|---|
| PyMuPDF (atual) | AGPL-3.0 | **MANTER** | Qualidade superior de ordem de leitura e caixas (blocks/lines/words nativos). Já roda em processo Python separado; AGPL só se impõe ao abrir/redistribuir o app. |
| pdfminer.six (+ pdfplumber) — pdfminer/pdfminer.six, jsvine/pdfplumber | MIT (ambos) | **ADAPTAR (plano B)** | LTChar/LTTextLine com bbox; pdfplumber expõe `extract_words()` com x0/x1/top/bottom. Ordem de leitura boa, inferior ao PyMuPDF em PDFs complexos. É a saída se o AGPL for bloqueador ao abrir o código: integração fácil (Python, padrão do app). |
| Apache PDFBox | Apache-2.0 | **EVITAR** | Java (JVM obrigatória no bundle); TextPosition é por caractere (agrupamento por palavra manual). Peso e integração não compensam; nada melhor que PyMuPDF/pdfminer. |
| MuPDF nativo (C API) | AGPL-3.0 (ou comercial, Artifex) | **EVITAR** | Mesmo motor do PyMuPDF: mesma AGPL, nenhum ganho de licença; só faria sentido para sair do runtime Python, e ainda assim AGPL. |

## 4. Transporte de áudio com tempos (concatenação/gapless e duração)

| Candidato | Licença | Veredito | Por quê / como adaptar |
|---|---|---|---|
| AVAudioPlayerNode (AVAudioEngine) — Apple | Nativo (não OSS) | **ADAPTAR** | `scheduleBuffer`/`scheduleFile`/`scheduleSegment` com completion handlers: gapless real em tempo de áudio, callback de conclusão por fatia (marca de segmento) e seek por deslocamento — substitui concatenação de bytes + sonda de duração sem I/O extra. É framework, não dependência. |
| AudioToolbox (AudioFileGetProperty: kAudioFilePropertyEstimatedDuration) | Nativo | **ADAPTAR** | Mede duração do arquivo sem tocá-lo — elimina a sonda via AVAudioPlayer em fundo que o StreamingPlayer faz hoje. |
| ffmpeg | LGPL-2.1 (build padrão) / GPL (com x264 etc.) | **EVITAR (se migrar)** | Se a concatenação migrar para AVAudioPlayerNode, o ffmpeg sai do caminho crítico (menos dependência; LGPL/GPL < AGPL do PyMuPDF, não piora o quadro). Manter só para transcode de terceiros. |

Não há biblioteca OSS de terceiro que supere o nativo aqui; a recomendação é API nativa.

## 5. Voz neural local com marcas de palavra

| Candidato | Licença | Veredito | Por quê / como adaptar |
|---|---|---|---|
| Piper + MFA (alinhamento forçado pós-síntese) | Piper GPL-3.0 (já no app) + MFA MIT | **ADAPTAR (via principal)** | O texto da frase é conhecido: alinhar o WAV da frase do Piper com o MFA (MIT) devolve tempos de palavra com voz neural, sem mudar o quadro de licenças. Frases curtas alinham rápido. É o caminho real para karaokê offline com voz neural. |
| espeak-ng — espeak-ng/espeak-ng | GPL-3.0 | **ADAPTAR (via barata, opcional)** | Único com word boundaries nativos: `espeak_SetSynthCallback` com `espeakEVENT_WORD` (timestamp de amostra no modo PLAYBACK). Voz formant (qualidade abaixo do neural) — serve como voz "precisa de baixa qualidade", não como substituto. GPL-3.0 = igual ao Piper, **não piora** o quadro. Binding python-espeak-ng também GPL-3.0. |
| sherpa-onnx — k2-fsa/sherpa-onnx | Apache-2.0 | **EVITAR (para este requisito)** | C API, roda em macOS arm64, tem Piper/Matcha/Kokoro — mas **não devolve tempos de palavra de TTS** (issue #3727 é feature request aberto). Útil como motor de reserva do Piper (já citado no CREDITS.md) e para ASR com timestamps; não resolve o karaokê offline sozinho. |
| Kokoro-82M / Matcha (via sherpa-onnx) | Apache-2.0 | **EVITAR (para este requisito)** | Vozes neurais locais sem word boundaries nativos; mesmo caso do sherpa-onnx. |

## 6. EPUB (parser Swift/SPM leve)

| Candidato | Licença | Veredito | Por quê / como adaptar |
|---|---|---|---|
| EPUBKit — witekbobrowski/EPUBKit | MIT | **ADAPTAR (dependência)** | Perfil exato: Swift 6, SPM, EPUB 2/3, Dublin Core, spine/ordem de leitura, TOC/NCX, thread-safe, testado. Esforço baixo; só falta o layer de fala (o app já tem TextImport/ReadAloudFilter para texto corrido). |
| FolioReaderKit — FolioReader/FolioReaderKit | BSD-3-Clause | **EVITAR** | Reader iOS completo (UIKit), UI acoplada; parser não é o foco. Pode servir de referência de parsing. |
| Readium Swift Toolkit — readium/swift-toolkit | BSD-3-Clause | **ADAPTAR (só se necessário)** | Robusto (OPDS, LCP/DRM, streaming) mas grande demais para ler EPUB local. Só se o app um dia quiser biblioteca OPDS. Alternativa DIY: ZIPFoundation (MIT) + XMLParser nativo — EPUB é ZIP + XML/XHTML; zero dependência, esforço médio. |

## 7. Notas de rodapé fim a fim (detecção geométrica + anúncio)

| Candidato | Licença | Veredito | Por quê / como adaptar |
|---|---|---|---|
| GROBID — grobidOrg/grobid | Apache-2.0 | **ADAPTAR (referência)** | O único que resolve o par chamada↔corpo: segmentação full-text com "head/foot notes" e feature que **liga o marcador de chamada à nota no texto** (#944), saída TEI XML com coordenadas PDF. Roda em macOS Intel e ARM. Mas: focado em artigos acadêmicos (não livros), JVM (OpenJDK 21) + modelos, e o próprio FAQ diz que referências de nota são mal extraídas (poucos dados de treino). Serve como referência do esquema de ligação marcador↔corpo, não como dependência. |
| Docling — docling-project/docling | MIT | **ADAPTAR (referência)** | Pipeline moderno de layout (reading order, figuras, tabelas) mas sem detecção específica de footnotes. Peso (PyTorch) descarta dependência; referência de abordagem de layout. |
| Heurística geomética (base da página + fonte menor + marcador numérico/superscript) | — | **IMPLEMENTAR DO ZERO (manter)** | Nenhuma OSS leve resolve "fim a fim" com qualidade geral fora de domínio acadêmico (pdf.js não resolve; leitores usam heurística ou metadados). O app já tem detecção geométrica + anúncio do marcador em obra — o ganho real é a ligação chamada↔corpo, cujo padrão (GROBID) é ML de domínio restrito. |

## Síntese do quadro de licenças

- **MANTÉM o quadro** (não piora): Piper+MFA (MIT+GPL-3.0 já presente), espeak-ng (GPL-3.0, igual ao Piper), pdfminer.six/pdfplumber (MIT, caminho de saída do AGPL), EPUBKit (MIT), AVAudioPlayerNode (nativo), SRE/ClearSpeak/MathJax (Apache-2.0, referência).
- **PIORA se adotado como dependência**: WhisperX (peso do PyTorch, não licença — BSD), PDFBox (JVM; licença é OK, peso não), MuPDF nativo (mesma AGPL, sem ganho).
- **Decisivos verificados**: MFA MIT com modelos CC-BY-4.0 e builds osx-arm64 no conda-forge; SRE Apache-2.0 sem locale pt; sherpa-onnx Apache-2.0 sem word timings de TTS (issue #3727 aberto); espeak-ng GPL-3.0 com eventos de palavra nativos; GROBID Apache-2.0 com ligação chamada↔corpo em domínio acadêmico.
- **Incertezas declaradas**: qualidade de alinhamento de modelos wav2vec2 PT comunitários (não verificada); suporte de PT no MathJax v4 (não confirmado); builds conda-forge do MFA 3.x para osx-arm64 (a listagem mostrou 2.2.4; o 3.x é via conda-forge/pip com docs "Linux/MacOSX").
