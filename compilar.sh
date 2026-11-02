#!/bin/zsh
# Compila Alero, arma Alero.app y la firma con el certificado de desarrollo (así macOS no pide los permisos de nuevo).
# Uso: ./compilar.sh            → deja la app en build/Alero.app
#      ./compilar.sh instalar   → además la copia a /Applications/Alero.app y la abre
# ALERO_SIN_MUSICA=1 saltea el adaptador de música (la app anda igual, sin reproductor en el notch).
# ALERO_FIRMA=- firma local. ALERO_FIRMA=<identidad o su huella> firma con esa identidad: `herramientas/publicar-version.sh`
# pasa el Developer ID si hay, o el certificado propio "Halyon Team (Alero)" (el "Apple Development" lleva tu correo
# y es para probar en tus Macs, no para repartir).
# ALERO_INFO=<archivo> usa ese Info.plist en vez de Recursos/Info.plist: `herramientas/publicar-version.sh` pasa uno con
# la versión, la lista de versiones y la clave de Sparkle (solo esas copias buscan actualizaciones, ver docs/PUBLICAR.md).
# ALERO_UNIVERSAL=1 la arma para Mac con Apple Silicon y con Intel a la vez (lo pasa `herramientas/publicar-version.sh`);
# sin eso, solo para Apple Silicon, que tarda la mitad.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -n "${ALERO_UNIVERSAL:-}" ]]; then
  ARQUITECTURAS=(--arch arm64 --arch x86_64)
  ARQUITECTURAS_CMAKE="arm64;x86_64"
else
  ARQUITECTURAS=(--arch arm64)
  ARQUITECTURAS_CMAKE=arm64
fi
swift build -c release "${ARQUITECTURAS[@]}"
CARPETA_BIN="$(swift build -c release "${ARQUITECTURAS[@]}" --show-bin-path)"
BIN="$CARPETA_BIN/Alero"
APP="build/Alero.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Alero"
cp "${ALERO_INFO:-Recursos/Info.plist}" "$APP/Contents/Info.plist"
# Sparkle (actualizaciones): va en Frameworks y el ejecutable la busca ahí. Alero no usa la caja de arena de macOS,
# así que los servicios XPC de Sparkle no hacen falta (son para apps en caja de arena) y se sacan.
ditto "$CARPETA_BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Alero"
[[ -f Recursos/AppIcon.icns ]] && cp Recursos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE NOTICE "$APP/Contents/Resources/"
strip -x "$APP/Contents/MacOS/Alero" 2>/dev/null || true

# Música: desde macOS 15.4 solo los programas de Apple pueden leer "lo que está sonando". El adaptador
# (BSD-3, Vendor/mediaremote-adapter) carga un framework chiquito dentro de /usr/bin/perl, que sí puede, y le pasa
# los datos a Alero en JSON. Se compila desde su código y no se enlaza con Alero: solo viaja en Resources.
IDENTIDAD=${ALERO_FIRMA:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
[[ "$IDENTIDAD" == "-" ]] && IDENTIDAD=
if [[ -z "${ALERO_SIN_MUSICA:-}" ]]; then
  cmake -S Vendor/mediaremote-adapter -B build/mra -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARQUITECTURAS_CMAKE" >/dev/null
  cmake --build build/mra --config Release --target MediaRemoteAdapter >/dev/null
  ditto build/mra/MediaRemoteAdapter.framework "$APP/Contents/Resources/MediaRemoteAdapter.framework"
  cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
  cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/LICENSE-mediaremote-adapter"
  codesign --force --timestamp=none --sign "${IDENTIDAD:--}" "$APP/Contents/Resources/MediaRemoteAdapter.framework"
fi

# Lo de adentro de Sparkle (de adentro hacia afuera) con la misma firma que la app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for pieza in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --options runtime --timestamp=none --sign "${IDENTIDAD:--}" "$pieza"
done
# macOS solo deja cargar bibliotecas del mismo equipo de Apple, y la firma local y el certificado propio no tienen
# equipo: sin este permiso Alero no arranca porque no puede abrir Sparkle. Con un certificado de Apple no hace falta.
PERMISOS=Recursos/Alero.entitlements
if [[ -z "$IDENTIDAD" || ( "$IDENTIDAD" != *"Developer ID"* && "$IDENTIDAD" != *"Apple Development"* ) ]]; then
  PERMISOS=build/Alero-firma-local.entitlements
  cp Recursos/Alero.entitlements "$PERMISOS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$PERMISOS"
fi
codesign --force --options runtime --timestamp=none \
  --entitlements "$PERMISOS" \
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
