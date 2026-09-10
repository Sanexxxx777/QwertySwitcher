#!/bin/bash
# Локальный e2e-стенд апдейтера (10.09.2026): фиктивная версия из текущей build/, подпись k1, фид на 127.0.0.1.
# Использование: bash Scripts/e2e-local-feed.sh prepare | serve | stop | reset. Перед serve: удалить prefs updates.lastCheckAt и перезапустить приложение; после — reset + install.sh настоящей сборки + lastSeenBuild обратно.
set -euo pipefail
R=/Users/sasha/Projects/products/QwertySwitcher
E="${QSW_E2E_DIR:-${TMPDIR:-/tmp}/qsw-e2e}"
PORT=8642
case "${1:-}" in
prepare)
  mkdir -p "$E/next" "$E/serve/qwertyswitcher"
  [ -d "$R/build/Qwerty Switcher.app" ] || { echo "no build/Qwerty Switcher.app — run ./Scripts/build.sh"; exit 3; }
  rsync -a --delete "$R/build/Qwerty Switcher.app/" "$E/next/Qwerty Switcher.app/"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.11.1" -c "Set :CFBundleVersion 38" "$E/next/Qwerty Switcher.app/Contents/Info.plist"
  codesign --force --deep --options runtime --entitlements "$R/Resources/QwertySwitcher.entitlements" --sign "SashaSwitcher Developer" "$E/next/Qwerty Switcher.app"
  codesign --verify --deep --strict "$E/next/Qwerty Switcher.app" && echo "staged 0.11.1 signed ok"
  (cd "$E/next" && rm -f "$E/serve/QwertySwitcher-0.11.1.zip" && ditto -c -k --keepParent "Qwerty Switcher.app" "$E/serve/QwertySwitcher-0.11.1.zip")
  SHA=$(shasum -a 256 "$E/serve/QwertySwitcher-0.11.1.zip" | awk '{print $1}')
  SIZE=$(stat -f %z "$E/serve/QwertySwitcher-0.11.1.zip")
  cat > "$E/manifest.json" <<JSON
{"version":"0.11.1","build":38,"minSystemVersion":"13.0","archiveURL":"http://127.0.0.1:$PORT/QwertySwitcher-0.11.1.zip","size":$SIZE,"sha256":"$SHA","publishedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","validUntil":"2099-01-01T00:00:00Z","notes":"e2e test 0.11.1"}
JSON
  swift "$R/Scripts/sign-update.swift" sign --key ~/.claude/secrets/qsw_update_ed25519_k1.key --key-id k1 --manifest "$E/manifest.json" --out "$E/serve/qwertyswitcher/appcast.json"
  swift "$R/Scripts/sign-update.swift" verify --public "wNhEr2ENSrWFn3RSbBtRXV7/slD/YL+JU5P77oSZO8o=" --appcast "$E/serve/qwertyswitcher/appcast.json" && echo "appcast verifies with k1"
  ls -la "$E/serve" "$E/serve/qwertyswitcher"
  ;;
serve)
  cd "$E/serve" && (python3 -m http.server $PORT --bind 127.0.0.1 > "$E/http.log" 2>&1 & echo $! > "$E/http.pid") && sleep 1 && curl -s -o /dev/null -w "feed http %{http_code}\n" "http://127.0.0.1:$PORT/qwertyswitcher/appcast.json"
  defaults write tech.sasha.qwertyswitch tech.sasha.qwertyswitch.updates.feedURL "http://127.0.0.1:$PORT/qwertyswitcher/appcast.json"
  echo "feedURL override set"
  ;;
stop)
  [ -f "$E/http.pid" ] && kill "$(cat "$E/http.pid")" 2>/dev/null && rm -f "$E/http.pid" && echo "http.server stopped" || echo "no server"
  ;;
reset)
  defaults delete tech.sasha.qwertyswitch tech.sasha.qwertyswitch.updates.feedURL 2>/dev/null && echo "feedURL override removed" || echo "no override"
  ;;
*) echo "usage: $0 prepare|serve|stop|reset"; exit 2 ;;
esac
