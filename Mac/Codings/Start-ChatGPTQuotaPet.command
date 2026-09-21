#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/../.."
APP_DIR="$ROOT_DIR/Mac/Packages/ChatGPTQuotaPet.app"

if [[ ! -x "$APP_DIR/Contents/MacOS/ChatGPTQuotaPet" ]]; then
  "$ROOT_DIR/Mac/Codings/build-mac.sh"
fi

open "$APP_DIR"
