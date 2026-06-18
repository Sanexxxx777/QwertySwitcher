#!/bin/bash
# Build SashaSwitcher as a universal binary (arm64 + x86_64) and pack it
# into a distributable DMG with a drag-to-Applications affordance.
#
# NOTE: In Stage 1 (self-signed) the first launch on another Mac will be
# blocked by Gatekeeper. The bundled README.txt tells the recipient how to
# bypass it once (right-click → Open → Open).
#
# Usage:
#   ./Scripts/make-dmg.sh            # auto-detects version from Info.plist
#   ./Scripts/make-dmg.sh 0.2.1      # override version suffix
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="SashaSwitcher"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="SashaSwitcher Developer"
ENTITLEMENTS="$PROJECT_DIR/Resources/SashaSwitcher.entitlements"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Resources/Info.plist" 2>/dev/null || echo "0.0")
fi

DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG_OUT="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "=== Building universal $APP_NAME (v$VERSION) ==="

cd "$PROJECT_DIR"

# ── 1. Compile both architectures ──
echo "[1/6] Compiling arm64..."
swift build -c release --triple arm64-apple-macosx14.0 2>&1 | tail -3
BIN_ARM64=$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/$APP_NAME

echo "[2/6] Compiling x86_64..."
swift build -c release --triple x86_64-apple-macosx14.0 2>&1 | tail -3
BIN_X86=$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/$APP_NAME

# ── 2. Assemble .app bundle with universal binary ──
echo "[3/6] Assembling .app bundle (lipo universal)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Dictionaries"

lipo -create "$BIN_ARM64" "$BIN_X86" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

if [ -d "$PROJECT_DIR/Resources/Dictionaries" ]; then
    cp "$PROJECT_DIR/Resources/Dictionaries/"*.txt "$APP_BUNDLE/Contents/Resources/Dictionaries/" 2>/dev/null || true
fi
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi
if [ -d "$PROJECT_DIR/Resources/Fonts" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
    cp "$PROJECT_DIR/Resources/Fonts/"*.ttf "$APP_BUNDLE/Contents/Resources/Fonts/" 2>/dev/null || true
fi

# ── 3. Code sign ──
echo "[4/6] Code signing..."
AVAILABLE=$(security find-identity -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -1 || true)
if [ -z "$AVAILABLE" ]; then
    echo "  ⚠ '$SIGN_IDENTITY' not found. Run ./Scripts/setup-signing.sh first."
    echo "  Falling back to ad-hoc (DMG will work but Gatekeeper will be stricter)."
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
else
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE" 2>&1 \
        | grep -v 'replacing existing signature' || true
fi
xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# Verify
ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")
echo "  archs: $ARCHS"
codesign --verify --deep --strict "$APP_BUNDLE" && echo "  signature: ok" || echo "  signature: FAILED"

# ── 4. Prepare DMG staging folder ──
echo "[5/6] Staging DMG contents..."
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

# README for the recipient (Cyrillic)
cat > "$DMG_STAGE/ПРОЧТИ_МЕНЯ.txt" <<'README_EOF'
SashaSwitcher — установка

1. Перетащи SashaSwitcher.app в папку "Applications" (иконка справа).

2. ПЕРВЫЙ ЗАПУСК (важно!):
   Обычный двойной клик macOS заблокирует — «не удалось проверить разработчика».
   Это не ошибка приложения, это Gatekeeper (так работает macOS для программ
   не из App Store).

   Чтобы разрешить:
     — открой папку Applications в Finder
     — правый клик (или Ctrl+клик) по SashaSwitcher
     — выбери "Открыть" (Open)
     — в появившемся окне ещё раз нажми "Открыть"

   Этот шаг нужен один раз. Последующие запуски работают обычным двойным кликом.

3. РАЗРЕШЕНИЯ:
   При первом запуске откроется окно «Добро пожаловать».
   Приложению нужны два разрешения macOS:
     — Universal Access (Accessibility) — для перехвата нажатий клавиш
     — Input Monitoring                 — для чтения кодов клавиш

   Нажми кнопку "Открыть" напротив каждого разрешения и включи галочку
   в появившемся окне "Системные настройки". После выдачи обоих разрешений
   кнопка "Далее" в окне приложения станет активной — нажми её.

4. После этого в верхней строке меню появится индикатор раскладки (RU/EN).
   Горячие клавиши:
     — Single Shift       → сменить раскладку
     — Double Shift       → переконвертировать последнее слово (из русской
                             раскладки в английскую и наоборот)
     — Left+Right Shift   → включить/выключить автопереключение
     — Cmd+Option+Z       → отменить автопереключение
     — Cmd+Shift+V        → вставить текст без форматирования

Приятного использования!
README_EOF

# ── 5. Build the DMG ──
echo "[6/6] Creating DMG..."
rm -f "$DMG_OUT"
hdiutil create \
    -volname "SashaSwitcher $VERSION" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_OUT" >/dev/null

rm -rf "$DMG_STAGE"

SIZE=$(du -sh "$DMG_OUT" | cut -f1)
echo ""
echo "✓ DMG ready: $DMG_OUT  ($SIZE)"
echo ""
echo "Send this file to your friend along with the installation steps from"
echo "ПРОЧТИ_МЕНЯ.txt inside the DMG (the right-click → Open trick is crucial)."
