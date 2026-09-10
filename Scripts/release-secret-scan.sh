#!/bin/bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <file-or-directory> [...]" >&2
    exit 2
fi

status=0

scan_file() {
    local file="$1"
    local name
    name=$(basename "$file")

    case "$name" in
        .env|.env.*|env.local|env.local.*|*.p8|*.p12|*.key|*.pem|*_ed25519*)
            echo "Secret scan blocked: credential-like file: $file" >&2
            status=1
            return
            ;;
    esac

    # Skip binary assets. Release credentials must never be embedded in a
    # text resource or source file, including files named as harmless examples.
    if ! LC_ALL=C grep -Iq . "$file" 2>/dev/null; then
        return
    fi

    if LC_ALL=C grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$file"; then
        echo "Secret scan blocked: private-key material: $file" >&2
        status=1
        return
    fi

    if LC_ALL=C grep -Eiq '(^|[[:space:]])(APPLE_APP_SPECIFIC_PASSWORD|SPARKLE_PRIVATE_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|AWS_SECRET_ACCESS_KEY|GITHUB_TOKEN|TELEGRAM_BOT_TOKEN|CRYPTOBOT_TOKEN|QSW_ADMIN_TOKEN|PRIVATE_KEY)[[:space:]]*[:=][[:space:]]*[^[:space:]#]+' "$file"; then
        echo "Secret scan blocked: credential assignment: $file" >&2
        status=1
    fi
}

for target in "$@"; do
    if [ -f "$target" ]; then
        scan_file "$target"
    elif [ -d "$target" ]; then
        while IFS= read -r -d '' file; do
            scan_file "$file"
        done < <(find "$target" -type f -print0)
    else
        echo "Secret scan blocked: missing target: $target" >&2
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo "Secret scan failed; release packaging stopped." >&2
    exit "$status"
fi

echo "Secret scan: clean"
