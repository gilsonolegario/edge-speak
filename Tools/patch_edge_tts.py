#!/usr/bin/env python3
"""Applies the edge-tts patches to the embedded environment (EdgeSpeak).

Usage:
    patch_edge_tts.py <site-packages>

What it does, inside <site-packages>/edge_tts:
  1. constants.py: checks that the package exposes WSS_URL and
     TRUSTED_CLIENT_TOKEN. It does NOT rewrite the endpoint: Microsoft
     moves it per release, and upstream tracks the move. This script
     used to force api.msedgeservices.com (older versions pointed at
     speech.platform.bing.com, then refused with 403); in Oct 2026 it
     inverted again — api.msedgeservices.com answered 429 and edge-tts
     7.3.x went back to speech.platform.bing.com with
     Sec-MS-GEC-Version "2-...". A URL pinned here goes stale; the
     version is pinned in the build instead (build-app.sh).
  2. drm.py: ensures parse_rfc2616_date uses
     email.utils.parsedate_to_datetime. Old versions used
     datetime.strptime with English day/month names, which breaks when
     the system is in another language (e.g. pt-BR).

Idempotent: running twice changes nothing the second time (exits 0 and
reports "ok"). Errors go to stderr in English, with exit code 1;
wrong usage, 2.
"""

import re
import sys
from pathlib import Path

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


def check_constants(path: Path) -> str:
    """Returns 'ok'. Upstream's endpoint is left alone."""
    text = path.read_text(encoding="utf-8")
    for needle in ("WSS_URL", "TRUSTED_CLIENT_TOKEN"):
        if needle not in text:
            raise RuntimeError(
                f"{path.name}: unknown format (no {needle}); update edge-tts."
            )
    return "ok"


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
        st_const = check_constants(package / "constants.py")
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
