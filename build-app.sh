#!/usr/bin/env bash
# Builds EdgeSpeak.app from SwiftPM, with an embedded Python environment.
#
# The final bundle runs on a virgin Mac (only macOS 14+ arm64 + network): it carries
# a Python 3.13 base (`Resources/pythonbase`), wheels for installation
# WITHOUT network (`Resources/wheels`) and the `Tools/*.py` scripts. The base is pruned
# of clutter (Tcl/Tk, idle, headers, base pip, .pyc) — never of engine. Piper voices
# (~63 MB each) do NOT ship in the bundle: each user downloads theirs on demand on
# first use, to `~/Library/Application Support/EdgeSpeak/voices` (accounted
# in `docs/tamanho-bundle.md`). On first launch the app creates a venv in
# ~/Library/Application Support/EdgeSpeak/venv — nothing outside ~/Projects is
# touched by the build, and no daemon is installed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

fail() { echo "build-app: $*" >&2; exit 1; }

# Never rebuild the bundle with the app running: `rm -rf` + `cp -a` over
# open files (pythonbase, scripts) corrupts the copy with
# "Operation not permitted" midway and leaves an incomplete bundle on disk
# (measured 2026-10-13). Quit the app before packaging.
if pgrep -f "EdgeSpeak.app/Contents/MacOS/EdgeSpeak" >/dev/null 2>&1; then
    fail "EdgeSpeak is running — quit (⌘Q) before packaging."
fi

STAGE="$ROOT/Build/staging"
APP="$ROOT/EdgeSpeak.app"

# Is there at least one wheel matching the pattern?
has_match() { compgen -G "$1" > /dev/null; }

# 1. Python base: copy of the standalone that `uv` manages.
command -v uv >/dev/null 2>&1 \
    || fail "'uv' is not installed — install with 'brew install uv' and try again."
BASE_PY="$(uv python find 3.13 2>/dev/null)" \
    || fail "no Python 3.13 found in 'uv' — run 'uv python install 3.13' and try again."
[ -x "$BASE_PY" ] || fail "the 'uv' Python is not executable ($BASE_PY)."
SRC_DIR="$(dirname "$(dirname "$BASE_PY")")"
rm -rf "$STAGE/pythonbase"
mkdir -p "$STAGE"
cp -a "$SRC_DIR/" "$STAGE/pythonbase"
BASE="$STAGE/pythonbase/bin/python3"
[ -x "$BASE" ] || BASE="$STAGE/pythonbase/bin/python3.13"
[ -x "$BASE" ] || fail "the copied base has no bin/python3 ($STAGE/pythonbase)."
echo "base: $BASE ($("$BASE" -c 'import sys; print(sys.version.split()[0])'))"

# 2. Wheels (offline install on first use; skips what already exists).
WHEELS="$STAGE/wheels"
mkdir -p "$WHEELS"
if ! has_match "$WHEELS/edge_tts-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" edge-tts \
        || fail "could not download edge-tts — check the network and try again."
fi
if ! has_match "$WHEELS/PyMuPDF-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" pymupdf \
        || fail "could not download pymupdf — check the network and try again."
fi
# Piper wheel dependencies (the wheel itself comes via URL below).
if ! has_match "$WHEELS/onnxruntime-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" onnxruntime \
        || fail "could not download onnxruntime — check the network and try again."
fi
if ! has_match "$WHEELS/pathvalidate-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" pathvalidate \
        || fail "could not download pathvalidate — check the network and try again."
fi
# Piper wheel for the build architecture (same rule as PiperTTS.wheelURL).
ARCH="$(uname -m)"
TAG="macosx_11_0_arm64"
[ "$ARCH" = "x86_64" ] && TAG="macosx_10_9_x86_64"
PIPER_URL="https://github.com/OHF-Voice/piper1-gpl/releases/download/v1.8.0/piper_tts-1.8.0-cp39-abi3-${TAG}.whl"
PIPER_FILE="$(basename "$PIPER_URL")"
if [ ! -f "$WHEELS/$PIPER_FILE" ]; then
    curl -fL --retry 3 -o "$WHEELS/$PIPER_FILE" "$PIPER_URL" \
        || fail "could not download the Piper wheel — check the network and try again."
fi
echo "wheels: $(has_match "$WHEELS/*.whl" && ls "$WHEELS"/*.whl | wc -l | tr -d ' ') files"

# 2b. Base pruning (clutter only, never engine): the `uv` base ships Tcl/Tk,
# idle, headers, base pip and .pyc that the app never uses — the support venv
# is born via `base -m venv` (stdlib ensurepip, kept) and installs from the
# wheels. Measured 2026-10-13: ~33 MB off the bundle. Runs AFTER the
# downloads above, which use `$BASE -m pip`.
PB="$STAGE/pythonbase"
rm -rf "$PB/bin/idle3"* "$PB/bin/pydoc3"* "$PB/bin/pip"*
rm -rf "$PB/include"
rm -rf "$PB/lib/libtcl"* "$PB/lib/libtk"* "$PB/lib/tcl"* "$PB/lib/tk"* \
       "$PB/lib/itcl"* "$PB/lib/thread"*
rm -rf "$PB/lib/python3.13/tkinter" "$PB/lib/python3.13/idlelib" \
       "$PB/lib/python3.13/turtledemo" "$PB/lib/python3.13/pydoc_data" \
       "$PB/lib/python3.13/unittest" \
       "$PB/lib/python3.13/site-packages/pip"*
find "$PB" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$PB" -name '*.pyc' -delete
echo "pruned base: $(du -sh "$PB" | cut -f1)"

# 3. Piper voices: OUT of the bundle, on purpose. Each user downloads theirs on
# demand at first use (`PiperTTS.ensureVoice`, destination in Application
# Support; accounted in `docs/tamanho-bundle.md`). Nothing to download here — and
# `Build/staging/voices` stays as a dev reserve (`bundledVoicesDir` checks
# it before the network).

# 4. Compiles and assembles the .app.
swift build -c release --product EdgeSpeak
BIN="$(swift build -c release --show-bin-path)/EdgeSpeak"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EdgeSpeak"
# Scripts go into the bundle: the app looks in Resources before
# falling back to the repository path (includes the edge-tts patch).
cp "$ROOT"/Tools/*.py "$APP/Contents/Resources/"
cp -a "$STAGE/pythonbase" "$APP/Contents/Resources/pythonbase"
cp -a "$STAGE/wheels" "$APP/Contents/Resources/wheels"
# Own icon (voice wave); Info.plist declares it below.
cp "$ROOT/Resources/EdgeSpeak.icns" "$APP/Contents/Resources/EdgeSpeak.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>EdgeSpeak</string>
  <key>CFBundleDisplayName</key><string>EdgeSpeak</string>
  <key>CFBundleIdentifier</key><string>local.edgespeak</string>
  <key>CFBundleExecutable</key><string>EdgeSpeak</string>
  <key>CFBundleIconFile</key><string>EdgeSpeak</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>com.adobe.pdf</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Texto</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.plain-text</string><string>net.daringfireball.markdown</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# --deep: the venv copied into the bundle has its own binaries.
codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || true
echo "OK: $APP ($(du -sh "$APP" | cut -f1))"
