#!/bin/zsh
# Crea el certificado propio con el que se firman las versiones publicadas de Alero ("Halyon Team (Alero)") y lo deja
# en el Llavero de inicio de sesión. Es gratis y vale 10 años; no reemplaza al Developer ID de Apple (la primera vez
# igual hay que tocar "Abrir igual"), pero es siempre el mismo: macOS reconoce que cada versión nueva es la misma app y
# no pierde los permisos (Accesibilidad, Grabación de pantalla) al actualizar. La firma local cambia en cada versión.
# Uso, una sola vez: herramientas/crear-certificado.sh   (lo usa `publicar-version.sh`; ver docs/PUBLICAR.md)
# Si publicás tu propia copia de Alero, cambiá el nombre (y en publicar-version.sh).
set -euo pipefail

NOMBRE="Halyon Team (Alero)"
if security find-identity -p codesigning | grep -q "\"$NOMBRE\""; then
  echo "Ya está «$NOMBRE» en el Llavero: no hace falta crearlo de nuevo."
  exit 0
fi

# Todo en una carpeta temporal que se borra al salir: la llave privada solo queda en el Llavero.
CARPETA=$(mktemp -d)
trap 'rm -rf "$CARPETA"' EXIT
cat > "$CARPETA/certificado.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NOMBRE
O = Halyon Team
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
# El openssl de macOS (LibreSSL): el .p12 que arma lo entiende `security import` (el de Homebrew no siempre).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$CARPETA/certificado.cnf" \
  -keyout "$CARPETA/llave.pem" -out "$CARPETA/certificado.pem" 2>/dev/null
CLAVE=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$CARPETA/llave.pem" -in "$CARPETA/certificado.pem" -name "$NOMBRE" \
  -out "$CARPETA/identidad.p12" -passout "pass:$CLAVE"
# -T: codesign puede usar la llave sin preguntar cada vez (la primera, macOS puede pedir "Permitir siempre").
security import "$CARPETA/identidad.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$CLAVE" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

security find-identity -p codesigning | grep "\"$NOMBRE\""
echo "Listo: «$NOMBRE» quedó en tu Llavero. Guardá una copia (ver docs/PUBLICAR.md): sin ella, las copias ya"
echo "instaladas vuelven a pedir los permisos en la próxima actualización."
