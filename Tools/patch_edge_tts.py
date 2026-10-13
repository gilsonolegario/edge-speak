#!/usr/bin/env python3
"""Aplica os remendos do edge-tts no ambiente embutido (EdgeSpeak).

Uso:
    patch_edge_tts.py <site-packages>

O que faz, dentro de <site-packages>/edge_tts:
  1. constants.py: garante que WSS_URL aponta para o endpoint v2
     (wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1
     com Ocp-Apim-Subscription-Key). Versoes antigas usavam o endpoint
     speech.platform.bing.com, que a Microsoft passou a recusar (403).
  2. drm.py: garante que parse_rfc2616_date usa
     email.utils.parsedate_to_datetime. Versoes antigas usavam
     datetime.strptime com nomes de dia/mes em ingles, que quebra quando
     o sistema esta em outro idioma (ex.: pt-BR).

Idempotente: rodar duas vezes nao muda nada na segunda (sai com 0 e
relata "ja estava remendado"). Erros saem em pt-BR no stderr, com
codigo de saida 1; uso errado, 2.
"""

import re
import sys
from pathlib import Path

WSS_HOST = "api.msedgeservices.com/tts/cognitiveservices/websocket/v1"
WSS_KEY_PARAM = "Ocp-Apim-Subscription-Key"

NOVO_WSS = (
    "WSS_URL = (\n"
    '    "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1"\n'
    "    f\"?Ocp-Apim-Subscription-Key={TRUSTED_CLIENT_TOKEN}\"\n"
    ")"
)

PARSE_IMPORT = "from email.utils import parsedate_to_datetime"

NOVO_PARSE = """    @staticmethod
    def parse_rfc2616_date(date: str) -> Optional[float]:
        # parsedate_to_datetime entende a data em qualquer idioma do
        # sistema; strptime com %a/%b so entende ingles.
        try:
            parsed = parsedate_to_datetime(date)
        except (TypeError, ValueError, IndexError):
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=tz.utc)
        return parsed.timestamp()
"""


def remenda_constants(path: Path) -> str:
    """Devolve 'ok' (ja estava) ou 'remendado'."""
    texto = path.read_text(encoding="utf-8")
    if WSS_HOST in texto and WSS_KEY_PARAM in texto:
        return "ok"
    if "TRUSTED_CLIENT_TOKEN" not in texto:
        raise RuntimeError(
            f"{path.name}: formato desconhecido "
            "(sem TRUSTED_CLIENT_TOKEN); atualize o edge-tts."
        )
    novo = re.sub(
        r"WSS_URL\s*=\s*\(.*?\)", NOVO_WSS, texto, count=1, flags=re.S
    )
    if WSS_HOST not in novo:
        # Variante de linha unica (sem parenteses).
        novo = re.sub(
            r"(?m)^WSS_URL\s*=.*$", NOVO_WSS, texto, count=1
        )
    if WSS_HOST not in novo or WSS_KEY_PARAM not in novo:
        raise RuntimeError(
            f"{path.name}: nao achei a definicao de WSS_URL; "
            "atualize o edge-tts."
        )
    compile(novo, str(path), "exec")
    path.write_text(novo, encoding="utf-8")
    return "remendado"


def remenda_drm(path: Path) -> str:
    """Devolve 'ok' (ja estava) ou 'remendado'."""
    texto = path.read_text(encoding="utf-8")
    if PARSE_IMPORT in texto and "parsedate_to_datetime(date)" in texto:
        return "ok"
    if "def parse_rfc2616_date" not in texto:
        raise RuntimeError(
            f"{path.name}: formato desconhecido "
            "(sem parse_rfc2616_date); atualize o edge-tts."
        )
    if "timezone as tz" not in texto or "Optional" not in texto:
        raise RuntimeError(
            f"{path.name}: formato desconhecido "
            "(sem timezone/Optional); atualize o edge-tts."
        )
    linhas = texto.splitlines(keepends=True)
    # Garante o import, logo apos o ultimo import/from do cabecalho.
    if PARSE_IMPORT not in texto:
        pos = 0
        for i, linha in enumerate(linhas):
            if linha.startswith("import ") or linha.startswith("from "):
                pos = i + 1
        linhas.insert(pos, PARSE_IMPORT + "\n")
        texto = "".join(linhas)
    # Troca a funcao inteira, do def (ou @staticmethod acima) ate o
    # proximo metodo/atributo no mesmo nivel de indentacao.
    inicio_m = re.search(
        r"(?m)^(?:    @staticmethod\n)?    def parse_rfc2616_date\(.*$",
        texto,
    )
    if inicio_m is None:
        raise RuntimeError(
            f"{path.name}: nao achei parse_rfc2616_date; "
            "atualize o edge-tts."
        )
    inicio = inicio_m.start()
    resto = texto[inicio_m.end():]
    fim_m = re.search(r"(?m)^    (?:@|def )", resto)
    fim = inicio_m.end() + (fim_m.start() if fim_m else len(resto))
    novo = texto[:inicio] + NOVO_PARSE + "\n" + texto[fim:].lstrip("\n")
    if "parsedate_to_datetime(date)" not in novo:
        raise RuntimeError(f"{path.name}: a troca falhou; nada foi gravado.")
    compile(novo, str(path), "exec")
    path.write_text(novo, encoding="utf-8")
    return "remendado"


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print("Uso: patch_edge_tts.py <site-packages>", file=sys.stderr)
        return 2
    pacote = Path(sys.argv[1]) / "edge_tts"
    if not pacote.is_dir():
        print(
            f"edge_tts nao encontrado em {sys.argv[1]}; "
            "a instalacao dos pacotes falhou?",
            file=sys.stderr,
        )
        return 1
    try:
        st_const = remenda_constants(pacote / "constants.py")
        st_drm = remenda_drm(pacote / "drm.py")
    except FileNotFoundError as exc:
        print(f"Arquivo ausente: {exc.filename}.", file=sys.stderr)
        return 1
    except (RuntimeError, SyntaxError) as exc:
        print(f"Nao foi possivel remendar o edge-tts: {exc}", file=sys.stderr)
        return 1
    print(f"constants.py: {st_const}; drm.py: {st_drm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
