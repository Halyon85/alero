#!/bin/zsh
# Publica una versión de Alero: sube el número, arma la app con la búsqueda de actualizaciones prendida, el .zip
# firmado con la clave de Sparkle y la lista de versiones (appcast.xml), y crea la versión en GitHub (pregunta antes).
# Uso: herramientas/publicar-version.sh 0.2.0
# Paso a paso y qué hacer la primera vez: docs/PUBLICAR.md.
set -euo pipefail
cd "$(dirname "$0")/.."

# Dónde viven las versiones publicadas: en las versiones (Releases) de GitHub. Cada una lleva su .zip y la lista
# (appcast.xml); "latest/download" siempre apunta a la de la última, así la app la encuentra sin otro servidor.
# Si publicás tu propia copia de Alero, cambiá estas líneas (y generá tu clave: ver docs/PUBLICAR.md).
REPO="Halyon85/alero"
LISTA="https://github.com/$REPO/releases/latest/download/appcast.xml"   # la lista de versiones que mira la app
CLAVE_PUBLICA="QSNQJeudUv5e9+77/4rHkP7Au3HOztmF40umYiQbANs="   # la pública: puede estar a la vista
CUENTA="team.halyon.alero"  # el nombre de la clave privada en el Llavero
CERTIFICADO="Halyon Team (Alero)"   # el certificado propio para firmar la app (herramientas/crear-certificado.sh)
SITIO="https://alero.halyon.app"
PERFIL_NOTARIO="alero"   # la clave de notarización en el Llavero (xcrun notarytool store-credentials, ver docs/PUBLICAR.md)

VERSION=${1:?"Uso: herramientas/publicar-version.sh <versión, por ejemplo 0.2.0>"}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "La versión tiene que ser como 0.2.0"; exit 1; }
# Lo que se publica tiene que ser exactamente lo que está guardado en git (así se puede saber qué código lleva).
[[ -z "$(git status --porcelain)" ]] || { echo "Hay cambios sin commit: guardalos antes de publicar."; exit 1; }

# Las novedades (Markdown) van en las notas de la versión de GitHub y en la ventana de Sparkle.
NOVEDADES=docs/novedades/$VERSION.md
[[ -f "$NOVEDADES" ]] || { echo "Falta $NOVEDADES: escribí las novedades antes de publicar (ver docs/PUBLICAR.md)."; exit 1; }
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && { echo "La versión v$VERSION ya existe en GitHub."; exit 1; }

# Sparkle compara el número de compilación (CFBundleVersion), que tiene que crecer siempre: sale de la versión
# (0.2.0 → 200, 1.4.12 → 10412), así no depende del historial de git (la copia pública tiene otro historial).
IFS=. read -r MAYOR MENOR ARREGLO <<< "$VERSION"
NUMERO=$(( MAYOR * 10000 + MENOR * 100 + ARREGLO ))

# Cada versión en su carpeta, sola: la lista lleva solo la última (alcanza para actualizar desde cualquiera anterior).
SALIDA=build/publicar/$VERSION
[[ -e "$SALIDA" ]] && { echo "Ya existe $SALIDA: esa versión ya se armó. Borrá la carpeta o usá otro número."; exit 1; }

# Sube el número en Recursos/Info.plist (así la copia de desarrollo muestra la misma versión) y lo guarda en git.
PB=/usr/libexec/PlistBuddy
if [[ "$($PB -c "Print :CFBundleShortVersionString" Recursos/Info.plist)" != "$VERSION" ]]; then
  $PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $NUMERO" Recursos/Info.plist
  git add Recursos/Info.plist
  git commit -q -m "chore(version): Alero $VERSION"
  echo "Número subido a $VERSION (compilación $NUMERO) y guardado en git."
fi

mkdir -p "$SALIDA"
ZIP="$SALIDA/Alero-$VERSION.zip"
DESCARGAS="https://github.com/$REPO/releases/download/v$VERSION/"

# El Info.plist de la versión publicada: el de siempre más la lista y la clave. Busca sola una vez por día y siempre
# pregunta antes de instalar: SUAllowsAutomaticUpdates en falso saca la opción de instalar sola.
INFO=build/Info-publicada.plist
cp Recursos/Info.plist "$INFO"
$PB -c "Add :SUFeedURL string $LISTA" -c "Add :SUPublicEDKey string $CLAVE_PUBLICA" \
    -c "Add :SUEnableAutomaticChecks bool true" -c "Add :SUScheduledCheckInterval integer 86400" \
    -c "Add :SUAllowsAutomaticUpdates bool false" "$INFO"

# Firma: con Developer ID si lo tenés (la cuenta paga de Apple); si no, con el certificado propio, que es siempre el
# mismo y así macOS no pierde los permisos de las copias instaladas al actualizar. Nunca con "Apple Development":
# lleva tu correo y es para probar en tus Macs, no para repartir. Sin ninguno de los dos, no se publica.
FIRMA=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
NOMBRE_FIRMA=$FIRMA
if [[ -z "$FIRMA" ]]; then
  # No es de Apple, así que macOS no lo da por "válido": se busca entre todos y se firma con su huella.
  FIRMA=$(security find-identity -p codesigning | awk -v nombre="\"$CERTIFICADO\"" 'index($0, nombre) {print $2; exit}')
  NOMBRE_FIRMA=$CERTIFICADO
fi
[[ -n "$FIRMA" ]] || { echo "Falta el certificado «$CERTIFICADO»: crealo con herramientas/crear-certificado.sh (ver docs/PUBLICAR.md)."; exit 1; }
ALERO_UNIVERSAL=1 ALERO_INFO="$INFO" ALERO_FIRMA="$FIRMA" ./compilar.sh

# Para Mac con Apple Silicon y con Intel: la app y el adaptador de música tienen que traer las dos.
for pieza in build/Alero.app/Contents/MacOS/Alero build/Alero.app/Contents/Resources/MediaRemoteAdapter.framework/MediaRemoteAdapter; do
  [[ "$(lipo -archs "$pieza")" == *x86_64* && "$(lipo -archs "$pieza")" == *arm64* ]] || {
    echo "$pieza no quedó universal ($(lipo -archs "$pieza")): no se publica."; exit 1; }
done

# Que la app armada no lleve el certificado de desarrollo (por si cambia algo en compilar.sh).
if codesign -dvv build/Alero.app 2>&1 | grep -q "Apple Development"; then
  echo "La app quedó firmada con Apple Development: no se publica."; exit 1
fi

# Con Developer ID, Apple revisa la app (notarización) y le pega su sello: así abre sin «Abrir igual», aun sin internet.
# Se manda un .zip aparte, se espera la respuesta (unos minutos) y el sello queda dentro de la app (stapler).
if [[ "$NOMBRE_FIRMA" == *"Developer ID"* ]]; then
  xcrun notarytool history --keychain-profile "$PERFIL_NOTARIO" >/dev/null 2>&1 || {
    echo "Falta la clave de notarización «$PERFIL_NOTARIO» en el Llavero: ver docs/PUBLICAR.md."; exit 1; }
  PARA_APPLE="$SALIDA/para-notarizar.zip"
  ditto -c -k --sequesterRsrc --keepParent build/Alero.app "$PARA_APPLE"
  xcrun notarytool submit "$PARA_APPLE" --keychain-profile "$PERFIL_NOTARIO" --wait --timeout 30m \
    | tee "$SALIDA/notarizacion.txt"
  grep -q "status: Accepted" "$SALIDA/notarizacion.txt" || {
    echo "Apple no aprobó la app: mirá el detalle con xcrun notarytool log <id> --keychain-profile $PERFIL_NOTARIO"; exit 1; }
  rm "$PARA_APPLE"
  xcrun stapler staple build/Alero.app
  spctl --assess --type execute build/Alero.app || { echo "macOS no acepta la app notarizada: no se publica."; exit 1; }
fi

# El .zip (ditto conserva los enlaces y permisos de adentro de la app, cosa que zip no siempre hace).
ditto -c -k --sequesterRsrc --keepParent build/Alero.app "$ZIP"

# Las mismas novedades en la ventana de Sparkle: generate_appcast las toma por tener el mismo nombre que el .zip y
# las mete dentro de la lista (--embed-release-notes), así no hace falta subir otro archivo.
cp "$NOVEDADES" "$SALIDA/Alero-$VERSION.md"

# Firma el .zip con la clave privada del Llavero y arma la lista.
HERRAMIENTAS=.build/artifacts/sparkle/Sparkle/bin
"$HERRAMIENTAS/generate_appcast" --account "$CUENTA" --download-url-prefix "$DESCARGAS" \
  --link "$SITIO" --maximum-deltas 0 --embed-release-notes -o "$SALIDA/appcast.xml" "$SALIDA"
grep -q "sparkle:edSignature" "$SALIDA/appcast.xml" || { echo "La lista salió sin firma: revisá la clave del Llavero."; exit 1; }

echo
echo "Listo: Alero $VERSION (compilación $NUMERO), firmada con $NOMBRE_FIRMA, en $SALIDA."
echo "Antes de seguir, subí el código de esta versión (con el número nuevo) a $REPO: la versión se marca sobre su main."
read "RESPUESTA?¿Crear la versión v$VERSION en GitHub ($REPO) con el .zip y la lista? Escribí «si» para seguir: "
[[ "$RESPUESTA" == "si" || "$RESPUESTA" == "sí" ]] || {
  echo "No se publicó nada. Para hacerlo a mano:"
  echo "  gh release create v$VERSION --repo $REPO --title \"Alero $VERSION\" --notes-file $NOVEDADES \\"
  echo "    \"$ZIP\" \"$SALIDA/appcast.xml\""
  exit 0
}
gh release create "v$VERSION" --repo "$REPO" --target main --title "Alero $VERSION" --notes-file "$NOVEDADES" \
  "$ZIP" "$SALIDA/appcast.xml"
echo "Publicada: https://github.com/$REPO/releases/tag/v$VERSION"
