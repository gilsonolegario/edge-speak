#!/usr/bin/env python3
"""Applies the edge-tts patches to the embedded environment (EdgeSpeak).

Usage:
    patch_edge_tts.py <site-packages>

What it does, inside <site-packages>/edge_tts:
  1. constants.py: ensures WSS_URL points at the v2 endpoint
     (wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1
     with Ocp-Apim-Subscription-Key). Old versions used the
     speech.platform.bing.com endpoint, which Microsoft started refusing (403).
  2. drm.py: ensures parse_rfc2616_date uses
     email.utils.parsedate_to_datetime. Old versions used
     datetime.strptime with English day/month names, which breaks when
     the system is in another language (e.g. pt-BR).

Idempotent: running twice changes nothing the second time (exits 0 and
reports "already patched"). Errors go to stderr in English, with
exit code 1; wrong usage, 2.
"""

import re
import sys
from pathlib import Path

WSS_HOST = "api.msedgeservices.com/tts/cognitiveservices/websocket/v1"
WSS_KEY_PARAM = "Ocp-Apim-Subscription-Key"

NEW_WSS = (
    "WSS_URL = (\n"
    '    "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1"\n'
    '    f"?Ocp-Apim-Subscription-Key={TRUSTED_CLIENT_TOKEN}"\n'
    ")"
)

PARSE_IMPORT = "from email.utils import parsedate_to_datetime"

NEW_PARSE = """    @staticmethod
    def parse_rfc2616_date(date: str) -> Optional[float]:
        # parsedate_to_datetime understands the date in any system
        # language; strptime with %a/%b only understands English.
        try:
            parsed = parsedate_to_datetime(date)
        except (TypeError, ValueError, IndexError):
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=tz.utc)
        return parsed.timestamp()
"""


def patch_constants(path: Path) -> str:
    """Returns 'ok' (already patched) or 'patched'."""
    text = path.read_text(encoding="utf-8")
    if WSS_HOST in text and WSS_KEY_PARAM in text:
        return "ok"
    if "TRUSTED_CLIENT_TOKEN" not in text:
        raise RuntimeError(
            f"{path.name}: unknown format "
            "(no TRUSTED_CLIENT_TOKEN); update edge-tts."
        )
    new = re.sub(
        r"WSS_URL\s*=\s*\(.*?\)", NEW_WSS, text, count=1, flags=re.S
    )
    if WSS_HOST not in new:
        # Single-line variant (no parentheses).
        new = re.sub(
            r"(?m)^WSS_URL\s*=.*$", NEW_WSS, text, count=1
        )
    if WSS_HOST not in new or WSS_KEY_PARAM not in new:
        raise RuntimeError(
            f"{path.name}: could not find the WSS_URL definition; "
            "update edge-tts."
        )
    compile(new, str(path), "exec")
    path.write_text(new, encoding="utf-8")
    return "patched"


def patch_drm(path: Path) -> str:
    """Returns 'ok' (already patched) or 'patched'."""
    text = path.read_text(encoding="utf-8")
    if PARSE_IMPORT in text and "parsedate_to_datetime(date)" in text:
        return "ok"
    if "def parse_rfc2616_date" not in text:
        raise RuntimeError(
            f"{path.name}: unknown format "
            "(no parse_rfc2616_date); update edge-tts."
        )
    if "timezone as tz" not in text or "Optional" not in text:
        raise RuntimeError(
            f"{path.name}: unknown format "
            "(no timezone/Optional); update edge-tts."
        )
    lines = text.splitlines(keepends=True)
    # Ensures the import, right after the header's last import/from.
    if PARSE_IMPORT not in text:
        pos = 0
        for i, line in enumerate(lines):
            if line.startswith("import ") or line.startswith("from "):
                pos = i + 1
        lines.insert(pos, PARSE_IMPORT + "\n")
        text = "".join(lines)
    # Replaces the whole function, from the def (or the @staticmethod above) to the
    # next method/attribute at the same indentation level.
    start_m = re.search(
        r"(?m)^(?:    @staticmethod\n)?    def parse_rfc2616_date\(.*$",
        text,
    )
    if start_m is None:
        raise RuntimeError(
            f"{path.name}: could not find parse_rfc2616_date; "
            "update edge-tts."
        )
    start = start_m.start()
    rest = text[start_m.end():]
    end_m = re.search(r"(?m)^    (?:@|def )", rest)
    end = start_m.end() + (end_m.start() if end_m else len(rest))
    new = text[:start] + NEW_PARSE + "\n" + text[end:].lstrip("\n")
    if "parsedate_to_datetime(date)" not in new:
        raise RuntimeError(f"{path.name}: the swap failed; nothing was written.")
    compile(new, str(path), "exec")
    path.write_text(new, encoding="utf-8")
    return "patched"


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print("Usage: patch_edge_tts.py <site-packages>", file=sys.stderr)
        return 2
    package = Path(sys.argv[1]) / "edge_tts"
    if not package.is_dir():
        print(
            f"edge_tts not found in {sys.argv[1]}; "
            "did the package installation fail?",
            file=sys.stderr,
        )
        return 1
    try:
        st_const = patch_constants(package / "constants.py")
        st_drm = patch_drm(package / "drm.py")
    except FileNotFoundError as exc:
        print(f"Missing file: {exc.filename}.", file=sys.stderr)
        return 1
    except (RuntimeError, SyntaxError) as exc:
        print(f"Could not patch edge-tts: {exc}", file=sys.stderr)
        return 1
    print(f"constants.py: {st_const}; drm.py: {st_drm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
