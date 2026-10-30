#!/bin/zsh
# Monta, assina e troca o app em /Applications.
set -euo pipefail
APP=$("${0:A:h}/bundle.sh" | tail -1)
pkill -x Hermes || true
sleep 1
rm -rf /Applications/Hermes.app
ditto "$APP" /Applications/Hermes.app
open /Applications/Hermes.app
