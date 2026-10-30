#!/bin/zsh
# Nova versão: ./scripts/release.sh 0.3.0 "o que mudou"
# Atualiza a versão, monta e assina o app, gera Hermes-<versão>.dmg, cria a tag e publica a release
# no repositório GitHub deste clone (gh usa o remote "origin").
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${1:?uso: release.sh <versão> [notas]}
NOTES=${2:-"Hermes $VERSION"}
[[ -z $(git status --porcelain) ]] || { echo "Há mudanças sem commit"; exit 1; }

BUILD=$(( $(git rev-list --count HEAD) + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist
git commit -qm "Version $VERSION" -- Resources/Info.plist

APP=$(./scripts/bundle.sh | tail -1)
OUT=~/Library/Caches/Hermes-build/dmg
rm -rf $OUT && mkdir -p $OUT/content
ditto "$APP" $OUT/content/Hermes.app
ln -s /Applications $OUT/content/Applications
DMG=$OUT/Hermes-$VERSION.dmg
hdiutil create -quiet -volname "Hermes $VERSION" -srcfolder $OUT/content -ov -format UDZO "$DMG"

git tag -a "v$VERSION" -m "$NOTES"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$DMG" --title "Hermes $VERSION" --notes "$NOTES"
echo "$DMG"
