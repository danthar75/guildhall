#!/usr/bin/env bash
# Fails unless Guildhearth/Core/WhatsNew.lua has an entry for the version (default: the TOC version).
#   tools/check-release.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-}"
if [ -z "$version" ]; then
  version="$(sed -n 's/^## Version:[[:space:]]*//p' Guildhearth/Guildhearth.toc | tr -d '\r')"
fi
[ -n "$version" ] || { echo "error: no version given and no ## Version in Guildhearth/Guildhearth.toc" >&2; exit 1; }
if ! grep -Eq "version[[:space:]]*=[[:space:]]*\"${version//./\\.}\"" Guildhearth/Core/WhatsNew.lua; then
  echo "error: Guildhearth/Core/WhatsNew.lua has no entry for version ${version}; add one (lines = {} if there is no news)." >&2
  exit 1
fi
