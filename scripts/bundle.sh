#!/bin/zsh
# Compila e monta Hermes.app em ~/Library/Caches/Hermes-build.
#   HERMES_BUNDLE_ID   bundle id do app (padrão io.github.hermes-voice)
#   HERMES_SIGN_ID     nome ou hash de um certificado de assinatura (ex.: "Apple Development: ..." ou um
#                      certificado próprio). Com um certificado fixo o macOS mantém as permissões de
#                      microfone/acessibilidade entre builds; sem ele a assinatura é ad-hoc e o macOS
#                      pode pedir as permissões de novo a cada build.
#   HERMES_KEYCHAIN    keychain onde está o certificado (opcional)
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "${0:A:h}/.."
swift build -c release
# Monta fora de pastas sincronizadas (iCloud/Dropbox põem atributos que o codesign recusa).
APP=~/Library/Caches/Hermes-build/Hermes.app
mkdir -p "${APP:h}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hermes "$APP/Contents/MacOS/Hermes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "${HERMES_BUNDLE_ID:-io.github.hermes-voice}" "$APP/Contents/Info.plist"
# Ícone desenhado em código (Logo.swift) → .icns
ICONSET=.build/AppIcon.iconset
rm -rf $ICONSET && .build/release/Hermes icon $ICONSET >/dev/null
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
if [[ -n "${HERMES_SIGN_ID:-}" ]]; then
  codesign --force --sign "$HERMES_SIGN_ID" ${HERMES_KEYCHAIN:+--keychain "$HERMES_KEYCHAIN"} \
    --entitlements Resources/Hermes.entitlements -o runtime "$APP"
else
  codesign --force --sign - --entitlements Resources/Hermes.entitlements -o runtime "$APP"
fi
codesign --verify --strict "$APP"
echo "$APP"
