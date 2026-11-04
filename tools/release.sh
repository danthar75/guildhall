#!/usr/bin/env bash
# Builds the release zip for Guildhall and prints its SHA-256.
#
#   tools/release.sh            -> dist/Guildhall-<version>.zip (+ .sha256)
#
# The zip contains a single top-level Guildhall/ folder with the Forever TOC and
# Lua files only. The Classic Era dev TOC (Guildhall_Vanilla.toc) is never shipped.
# Tests must pass first. The zip is built from committed files (git archive), so
# uncommitted edits can't sneak into a release.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain -- Guildhall)" ]; then
  echo "error: Guildhall/ has uncommitted changes; commit them first." >&2
  exit 1
fi

bash tools/check.sh

version="$(sed -n 's/^## Version:[[:space:]]*//p' Guildhall/Guildhall.toc | tr -d '\r')"
[ -n "$version" ] || { echo "error: no ## Version in Guildhall/Guildhall.toc" >&2; exit 1; }

bash tools/check-release.sh "$version"

mkdir -p dist
out="dist/Guildhall-${version}.zip"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

git archive --format=tar HEAD Guildhall | tar -x -C "$stage"
rm -f "$stage/Guildhall/Guildhall_Vanilla.toc"

# Only addon files belong in the zip: TOC, Lua, and (if ever added) XML/textures.
bad="$(cd "$stage" && find Guildhall -type f ! \( -name '*.toc' -o -name '*.lua' -o -name '*.xml' -o -name '*.tga' -o -name '*.blp' -o -name '*.md' \) )"
if [ -n "$bad" ]; then
  echo "error: unexpected files in addon folder:" >&2
  echo "$bad" >&2
  exit 1
fi

rm -f "$out"
(cd "$stage" && TZ=UTC find Guildhall -exec touch -t 202601010000 {} + && find Guildhall -type f | LC_ALL=C sort | zip -X -q "$OLDPWD/$out" -@)

(cd dist && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
sha="$(cut -d' ' -f1 "$out.sha256")"

# Fill in the release-page notes and the Discord announcement.
release_url="https://github.com/danthar75/guildhall/releases/tag/v${version}"
render() {
  sed -e "s|{{VERSION}}|${version}|g" -e "s|{{SHA256}}|${sha}|g" -e "s|{{RELEASE_URL}}|${release_url}|g" "$1" > "$2"
}
render docs/release/release-notes.template.md "dist/Guildhall-${version}-release-notes.md"
render docs/release/discord-post.template.md "dist/Guildhall-${version}-discord-post.md"

echo
echo "Built $out"
unzip -l "$out" | tail -n +1
echo
cat "$out.sha256"
echo
echo "Release notes: dist/Guildhall-${version}-release-notes.md"
echo "Discord post:  dist/Guildhall-${version}-discord-post.md"
