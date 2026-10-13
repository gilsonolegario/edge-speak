#!/usr/bin/env bash
# Monta o EdgeSpeak.app a partir do SwiftPM, com ambiente Python embutido.
#
# O bundle final funciona num Mac virgem (só macOS 14+ arm64 + rede): traz
# uma base Python 3.13 (`Resources/pythonbase`), os wheels para instalação
# SEM rede (`Resources/wheels`), duas vozes Piper (`Resources/voices`) e os
# scripts `Tools/*.py`. Na primeira execução o app cria um venv em
# ~/Library/Application Support/EdgeSpeak/venv — nada fora de ~/Projects é
# tocado pelo build, e nenhum daemon é instalado.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

STAGE="$ROOT/Build/staging"
APP="$ROOT/EdgeSpeak.app"

fail() { echo "build-app: $*" >&2; exit 1; }

# Há ao menos um wheel casando o padrão?
tem() { compgen -G "$1" > /dev/null; }

# 1. Base Python: cópia do standalone que o `uv` gerencia.
command -v uv >/dev/null 2>&1 \
    || fail "o 'uv' não está instalado — instale com 'brew install uv' e tente de novo."
BASE_PY="$(uv python find 3.13 2>/dev/null)" \
    || fail "não achei um Python 3.13 no 'uv' — rode 'uv python install 3.13' e tente de novo."
[ -x "$BASE_PY" ] || fail "o Python do 'uv' não é executável ($BASE_PY)."
SRC_DIR="$(dirname "$(dirname "$BASE_PY")")"
rm -rf "$STAGE/pythonbase"
mkdir -p "$STAGE"
cp -a "$SRC_DIR/" "$STAGE/pythonbase"
BASE="$STAGE/pythonbase/bin/python3"
[ -x "$BASE" ] || BASE="$STAGE/pythonbase/bin/python3.13"
[ -x "$BASE" ] || fail "a base copiada não tem bin/python3 ($STAGE/pythonbase)."
echo "base: $BASE ($("$BASE" -c 'import sys; print(sys.version.split()[0])'))"

# 2. Wheels (instalação offline no primeiro uso; pula o que já existe).
WHEELS="$STAGE/wheels"
mkdir -p "$WHEELS"
if ! tem "$WHEELS/edge_tts-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" edge-tts \
        || fail "não baixei o edge-tts — verifique a rede e tente de novo."
fi
if ! tem "$WHEELS/PyMuPDF-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" pymupdf \
        || fail "não baixei o pymupdf — verifique a rede e tente de novo."
fi
# Dependências do wheel do Piper (o wheel em si vem por URL abaixo).
if ! tem "$WHEELS/onnxruntime-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" onnxruntime \
        || fail "não baixei o onnxruntime — verifique a rede e tente de novo."
fi
if ! tem "$WHEELS/pathvalidate-*.whl"; then
    "$BASE" -m pip download --only-binary=:all: --dest "$WHEELS" pathvalidate \
        || fail "não baixei o pathvalidate — verifique a rede e tente de novo."
fi
# Wheel do Piper para a arquitetura do build (mesma regra do PiperTTS.wheelURL).
ARCH="$(uname -m)"
TAG="macosx_11_0_arm64"
[ "$ARCH" = "x86_64" ] && TAG="macosx_10_9_x86_64"
PIPER_URL="https://github.com/OHF-Voice/piper1-gpl/releases/download/v1.8.0/piper_tts-1.8.0-cp39-abi3-${TAG}.whl"
PIPER_FILE="$(basename "$PIPER_URL")"
if [ ! -f "$WHEELS/$PIPER_FILE" ]; then
    curl -fL --retry 3 -o "$WHEELS/$PIPER_FILE" "$PIPER_URL" \
        || fail "não baixei o wheel do Piper — verifique a rede e tente de novo."
fi
echo "wheels: $(tem "$WHEELS/*.whl" && ls "$WHEELS"/*.whl | wc -l | tr -d ' ') arquivos"

# 3. Vozes Piper embutidas (baixa as ausentes; ~60 MB cada par).
VOICES="$STAGE/voices"
mkdir -p "$VOICES"
HF="https://huggingface.co/rhasspy/piper-voices/resolve/main"
voz() { # $1 = prefixo remoto, $2 = base do arquivo
    local ext
    for ext in .onnx .onnx.json; do
        if [ ! -f "$VOICES/$2$ext" ]; then
            curl -fL --retry 3 -o "$VOICES/$2$ext" "$HF/$1$2$ext" \
                || fail "não baixei a voz $2$ext — verifique a rede e tente de novo."
        fi
    done
}
voz "pt/pt_BR/faber/medium/" "pt_BR-faber-medium"
voz "en/en_US/lessac/medium/" "en_US-lessac-medium"

# 4. Compila e monta o .app.
swift build -c release --product EdgeSpeak
BIN="$(swift build -c release --show-bin-path)/EdgeSpeak"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EdgeSpeak"
# Os scripts entram no bundle: o app os procura em Resources antes de
# recorrer ao caminho do repositório (inclui o remendo do edge-tts).
cp "$ROOT"/Tools/*.py "$APP/Contents/Resources/"
cp -a "$STAGE/pythonbase" "$APP/Contents/Resources/pythonbase"
cp -a "$STAGE/wheels" "$APP/Contents/Resources/wheels"
cp -a "$STAGE/voices" "$APP/Contents/Resources/voices"
# Ícone próprio (onda de voz); o Info.plist o declara abaixo.
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
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
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

# --deep: o venv copiado para dentro do bundle tem binários próprios.
codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || true
echo "OK: $APP ($(du -sh "$APP" | cut -f1))"
