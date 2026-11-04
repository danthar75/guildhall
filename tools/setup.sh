#!/usr/bin/env bash
# Idempotent: installs Lua 5.1 + luarocks + busted into .tools/ (git-ignored).
set -euo pipefail
HEREROCKS_TAG=0.25.1
cd "$(dirname "$0")/.."
mkdir -p .tools
if [ ! -x .tools/lua/bin/busted ]; then
  [ -f .tools/hererocks.py ] || curl -fsSL -o .tools/hererocks.py \
    "https://raw.githubusercontent.com/luarocks/hererocks/${HEREROCKS_TAG}/hererocks.py"
  python3 .tools/hererocks.py .tools/lua -l5.1 -rlatest --no-readline
  .tools/lua/bin/luarocks install busted
fi
.tools/lua/bin/busted --version
