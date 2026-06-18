#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swift build -c debug
".build/debug/SashaSwitcher" --test
