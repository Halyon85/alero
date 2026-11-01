#!/bin/zsh
# Compila Alero, arma Alero.app y la firma con el certificado de desarrollo (así macOS no pide los permisos de nuevo).
# Uso: ./compilar.sh            → deja la app en build/Alero.app
#      ./compilar.sh instalar   → además la copia a /Applications/Alero.app y la abre
# ALERO_SIN_MUSICA=1 saltea el adaptador de música (la app anda igual, sin reproductor en el notch).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Alero"
APP="build/Alero.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Alero"
cp Recursos/Info.plist "$APP/Contents/Info.plist"
[[ -f Recursos/AppIcon.icns ]] && cp Recursos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE NOTICE "$APP/Contents/Resources/"
strip -x "$APP/Contents/MacOS/Alero" 2>/dev/null || true

# Música: desde macOS 15.4 solo los programas de Apple pueden leer "lo que está sonando". El adaptador
# (BSD-3, Vendor/mediaremote-adapter) carga un framework chiquito dentro de /usr/bin/perl, que sí puede, y le pasa
# los datos a Alero en JSON. Se compila desde su código y no se enlaza con Alero: solo viaja en Resources.
IDENTIDAD=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -z "${ALERO_SIN_MUSICA:-}" ]]; then
  cmake -S Vendor/mediaremote-adapter -B build/mra -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
  cmake --build build/mra --config Release --target MediaRemoteAdapter >/dev/null
  ditto build/mra/MediaRemoteAdapter.framework "$APP/Contents/Resources/MediaRemoteAdapter.framework"
  cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
  cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/LICENSE-mediaremote-adapter"
  codesign --force --timestamp=none --sign "${IDENTIDAD:--}" "$APP/Contents/Resources/MediaRemoteAdapter.framework"
fi

codesign --force --options runtime --timestamp=none \
  --entitlements Recursos/Alero.entitlements \
  --sign "${IDENTIDAD:--}" "$APP"
echo "Firmada con: ${IDENTIDAD:-firma local (ad-hoc)}"
du -sh "$APP"

if [[ "${1:-}" == "instalar" ]]; then
  pkill -x Alero 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Alero.app
  cp -R "$APP" /Applications/Alero.app
  open /Applications/Alero.app
  echo "Instalada en /Applications/Alero.app"
fi
