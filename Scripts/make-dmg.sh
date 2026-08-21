#!/bin/bash
# Build Qwerty Switcher as a universal binary (arm64 + x86_64), sign it in
# either local-development or Developer ID mode, and package the result as DMG.
#
# NOTE: In Stage 1 (self-signed) the first launch on another Mac will be
# blocked by Gatekeeper. The bundled README.txt tells the recipient how to
# bypass it once (right-click → Open → Open).
#
# Usage:
#   ./Scripts/make-dmg.sh                       # local self-signed beta
#   ./Scripts/make-dmg.sh 0.3.0                 # beta with version override
#   ./Scripts/make-dmg.sh developerid           # public Developer ID candidate
#   ./Scripts/make-dmg.sh developerid 0.3.0     # public candidate + version override
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
PRODUCT_NAME="Qwerty Switcher"
BINARY_NAME="QwertySwitcher"
APP_BUNDLE="$BUILD_DIR/$PRODUCT_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/Resources/QwertySwitcher.entitlements"
ARM64_SCRATCH="$PROJECT_DIR/.build/universal-arm64"
X86_64_SCRATCH="$PROJECT_DIR/.build/universal-x86_64"

MODE="dev"
if [ "${1:-}" = "dev" ] || [ "${1:-}" = "developerid" ]; then
    MODE="$1"
    shift
fi

case "$MODE" in
    dev) SIGN_IDENTITY="SashaSwitcher Developer" ;;
    developerid) SIGN_IDENTITY="${DEVELOPER_ID_APP:-Developer ID Application}" ;;
    *) echo "Unknown mode: $MODE. Use dev | developerid"; exit 2 ;;
esac

AVAILABLE=""
if [ "$MODE" = "developerid" ]; then
    AVAILABLE=$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" | head -1 || true)
    if [ -z "$AVAILABLE" ]; then
        echo "✗ Developer ID identity '$SIGN_IDENTITY' not found or not valid."
        exit 3
    fi
fi

SWIFT_SDK_ARGS=()
DEVELOPER_PATH=$(xcode-select -p 2>/dev/null || true)
COMPATIBLE_CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ "$DEVELOPER_PATH" != *"Xcode.app/Contents/Developer"* ]] && [ -d "$COMPATIBLE_CLT_SDK" ]; then
    SWIFT_SDK_ARGS=(--sdk "$COMPATIBLE_CLT_SDK")
    echo "Using compatible CLT SDK: $COMPATIBLE_CLT_SDK"
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Resources/Info.plist" 2>/dev/null || echo "0.0")
fi

DMG_STAGE=$(mktemp -d /private/tmp/qwerty-switch-dmg.XXXXXX)
DMG_OUT="$BUILD_DIR/QwertySwitcher-$VERSION.dmg"
DMG_IDENTIFIER="tech.sasha.qwertyswitch.dmg"

echo "=== Building universal $PRODUCT_NAME (v$VERSION, mode: $MODE) ==="

cd "$PROJECT_DIR"
bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$PROJECT_DIR/Resources"

# ── 1. Compile both architectures ──
echo "[1/6] Compiling arm64..."
swift build --disable-sandbox --scratch-path "$ARM64_SCRATCH" ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c release --triple arm64-apple-macosx13.0 2>&1 | tail -3
BIN_ARM64=$(swift build --disable-sandbox --scratch-path "$ARM64_SCRATCH" ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c release --triple arm64-apple-macosx13.0 --show-bin-path)/$BINARY_NAME

echo "[2/6] Compiling x86_64..."
swift build --disable-sandbox --scratch-path "$X86_64_SCRATCH" ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c release --triple x86_64-apple-macosx13.0 2>&1 | tail -3
BIN_X86=$(swift build --disable-sandbox --scratch-path "$X86_64_SCRATCH" ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/$BINARY_NAME

# ── 2. Assemble .app bundle with universal binary ──
echo "[3/6] Assembling .app bundle (lipo universal)..."
if [ -e "$APP_BUNDLE" ]; then
    # Keep exactly ONE previous copy inside build/previous (Spotlight-safe).
    PREVIOUS_APP="$BUILD_DIR/previous/$PRODUCT_NAME.app"
    mkdir -p "$BUILD_DIR/previous"
    rm -rf "$PREVIOUS_APP"
    mv "$APP_BUNDLE" "$PREVIOUS_APP"
    echo "  previous build preserved at: $PREVIOUS_APP"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Dictionaries"

lipo -create "$BIN_ARM64" "$BIN_X86" -output "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/"

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

bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$APP_BUNDLE"


# ── 3. Code sign ──
echo "[4/6] Code signing..."
if [ "$MODE" = "developerid" ]; then
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
else
    AVAILABLE=$(security find-identity -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" | head -1 || true)
    if [ -z "$AVAILABLE" ]; then
        echo "  ⚠ '$SIGN_IDENTITY' not found. Run ./Scripts/setup-signing.sh first."
        echo "  Falling back to ad-hoc (DMG will work but Gatekeeper will be stricter)."
        codesign --force --deep --sign - "$APP_BUNDLE"
    else
        codesign --force --deep --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$SIGN_IDENTITY" \
            "$APP_BUNDLE"
    fi
fi
xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# Verify
ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME")
echo "  archs: $ARCHS"
codesign --verify --deep --strict "$APP_BUNDLE"
echo "  signature: ok"

# ── 4. Prepare DMG staging folder ──
echo "[5/6] Staging DMG contents..."
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

# README for the recipient (Cyrillic)
cat > "$DMG_STAGE/ПРОЧТИ_МЕНЯ.txt" <<'README_EOF'
Qwerty Switcher — установка

1. Перетащи Qwerty Switcher.app в папку "Applications" (иконка справа).

2. ПЕРВЫЙ ЗАПУСК:
   Публичная версия с Developer ID и notarization открывается обычным двойным
   кликом. Для локальной self-signed beta macOS может показать сообщение
   «не удалось проверить разработчика».

   В self-signed beta разрешить запуск можно так:
     — открой папку Applications в Finder
     — правый клик (или Ctrl+клик) по Qwerty Switcher
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

4. ОБНОВЛЕНИЕ НА НОВУЮ ВЕРСИЮ:
   Замена приложения через Finder («Заменить» при перетаскивании) удаляет
   старую копию, и macOS считает это переустановкой — оба разрешения из п.3
   придётся выдать заново. Это нормально и не признак поломки.
   Окно «Добро пожаловать» откроется само; если нет — меню приложения
   в строке статуса → «Настройка разрешений…».

5. После этого в верхней строке меню появится индикатор раскладки (RU/EN).
   Горячие клавиши:
     — Single Shift       → сменить раскладку
     — Double Shift       → переконвертировать последнее слово (из русской
                             раскладки в английскую и наоборот; повторно — отменить)
     — Caps Lock          → сменить раскладку (если включить в настройках)
     — Left+Right Shift   → включить/выключить автопереключение
     — Cmd+Option+Z       → отменить автопереключение
     — Cmd+Shift+V        → вставить текст без форматирования

Приятного использования!
README_EOF

bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$DMG_STAGE"

# Window dressing: backdrop with the drag arrow, icons placed on it, no
# toolbar or sidebar. Generated from vectors on every build (Scripts/
# make-dmg-background.swift) so there is no bitmap in the repo to fall out of
# date. `.background` is hidden by the leading dot, which is why the recipient
# sees the artwork and not a folder.
mkdir -p "$DMG_STAGE/.background"
if swift "$PROJECT_DIR/Scripts/make-dmg-background.swift" "$DMG_STAGE/.background" >/dev/null 2>&1; then
    DMG_HAS_BACKGROUND=1
else
    echo "  note: background generation failed — building a plain DMG instead"
    DMG_HAS_BACKGROUND=0
fi

# ── 5. Build the DMG ──
echo "[6/6] Creating DMG..."
if [ -e "$DMG_OUT" ]; then
    # Keep exactly ONE previous DMG inside build/previous (Spotlight-safe).
    PREVIOUS_DMG="$BUILD_DIR/previous/$(basename "$DMG_OUT")"
    mkdir -p "$BUILD_DIR/previous"
    mv -f "$DMG_OUT" "$PREVIOUS_DMG"
    echo "  previous DMG preserved at: $PREVIOUS_DMG"
fi
VOLUME_NAME="Qwerty Switcher $VERSION"

if [ "$DMG_HAS_BACKGROUND" = "1" ]; then
    # Two-step: a writable image to dress the window in, then a compressed
    # read-only one to ship. The view settings live in the volume's .DS_Store,
    # so they can only be written while the image is mounted read-write —
    # building UDZO directly (the old path) is exactly why the window opened
    # as a bare icon list.
    TEMP_DMG="$BUILD_DIR/.dmg-staging-rw.dmg"
    rm -f "$TEMP_DMG"
    hdiutil create -volname "$VOLUME_NAME" -srcfolder "$DMG_STAGE" \
        -ov -format UDRW "$TEMP_DMG" >/dev/null
    MOUNT_POINT="$(hdiutil attach "$TEMP_DMG" -nobrowse -readwrite \
        | grep -o '/Volumes/.*' | tail -1)"

    if [ -n "$MOUNT_POINT" ]; then
        # Finder automation needs TCC approval the first time; a refusal must
        # not fail the build, it just costs the dressing.
        osascript >/dev/null 2>&1 <<APPLESCRIPT || echo "  note: Finder automation unavailable — window layout not applied"
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 840, 540}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:dmg-background.png"
        set position of item "Qwerty Switcher.app" of container window to {170, 182}
        set position of item "Applications" of container window to {470, 182}
        set position of item "ПРОЧТИ_МЕНЯ.txt" of container window to {320, 330}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT
        sync
        hdiutil detach "$MOUNT_POINT" -quiet || hdiutil detach "$MOUNT_POINT" -force -quiet
    fi

    rm -f "$DMG_OUT"
    hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
    rm -f "$TEMP_DMG"
elif ! diskutil image create from \
    --format UDZO \
    --volumeName "$VOLUME_NAME" \
    "$DMG_STAGE" \
    "$DMG_OUT" >/dev/null; then
    echo "  diskutil image create is unavailable; using the legacy hdiutil fallback."
    hdiutil create \
        -volname "$VOLUME_NAME" \
        -srcfolder "$DMG_STAGE" \
        -ov -format UDZO \
        "$DMG_OUT" >/dev/null
fi

case "$DMG_STAGE" in
    /private/tmp/qwerty-switch-dmg.*) rm -r "$DMG_STAGE" ;;
    *) echo "Refusing to remove unexpected staging path: $DMG_STAGE"; exit 7 ;;
esac

if [ "$MODE" = "developerid" ]; then
    echo "  signing final DMG with Developer ID..."
    codesign --force --timestamp --identifier "$DMG_IDENTIFIER" --sign "$SIGN_IDENTITY" "$DMG_OUT"
    codesign --verify --verbose=2 "$DMG_OUT"
fi

SIZE=$(du -sh "$DMG_OUT" | cut -f1)
echo ""
echo "✓ DMG ready: $DMG_OUT  ($SIZE)"
echo ""
if [ "$MODE" = "developerid" ]; then
    echo "Next: ./Scripts/notarize.sh dmg"
    echo "Do not distribute the DMG until notarization and stapling pass."
else
    echo "Local beta: the recipient may need the right-click → Open override."
fi
