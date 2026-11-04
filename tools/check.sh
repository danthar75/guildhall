#!/usr/bin/env bash
# Syntax-check all addon Lua, then run the busted specs. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
LUAC=.tools/lua/bin/luac
while IFS= read -r f; do
  "$LUAC" -p "$f"
done < <(find Guildhall -name '*.lua' | sort)
if [ -n "$(find spec -name '*_spec.lua' 2>/dev/null)" ]; then
  .tools/lua/bin/busted
else
  echo "no specs found under spec/"
fi
