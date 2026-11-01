# Releases and updates / Publicar versiones

Alero updates itself with [Sparkle](https://sparkle-project.org), but **only builds published with `herramientas/publicar-version.sh`** look for updates. A copy you build yourself with `compilar.sh` never does (an update would replace your build with the published one): update it with `git pull && ./compilar.sh instalar`.

## How it works

- A published build carries two things in its `Info.plist`: the address of the version list (`SUFeedURL`, the *appcast*) and the public half of a signing key (`SUPublicEDKey`).
- Once a day it reads the list. If there's a newer version, it shows what's new and **asks before installing it**. It never installs on its own (`SUAllowsAutomaticUpdates` is off). **Settings → General → Updates → Check Now** checks right away.
- Every `.zip` is signed with the private half of the key, which never leaves the publisher's Keychain. Alero refuses any update that isn't signed with it, even if someone takes over the GitHub account or the download.
- Version 0.1.0 came out before Sparkle: whoever has it downloads the next one by hand once, and from then on Alero tells them about new versions.

## Signing without a paid Apple account

You don't need the Apple Developer Program (99 USD a year) to publish, but it changes how the app opens the first time:

| | Without it (local, ad-hoc signature) | With Developer ID + notarization |
|---|---|---|
| First open of the downloaded `.zip` | macOS blocks it: **System Settings → Privacy & Security → Open Anyway** | Opens normally |
| Updates through Sparkle | Install normally, checked with the Sparkle key | Install normally |
| Permissions after an update | macOS may ask again (Accessibility, Screen Recording) | Kept |

`publicar-version.sh` uses a “Developer ID Application” certificate if it finds one, and the local signature otherwise. It never uses “Apple Development”: that one carries your e-mail and is for testing on your own Macs, not for handing out (the script checks it and stops).

## The first time

1. **Create the key.** It's saved in your login Keychain and prints the public key:

   ```bash
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.alero
   ```

2. **Make a backup of the private key** and keep it somewhere safe, outside the repository (a password manager, an encrypted drive). Without it you can't publish updates for the copies already installed:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.alero -x alero-clave-privada.txt
   ```

   Once saved, delete that file from the disk.

3. **If you publish your own copy of Alero**, put your public key and your addresses in the first lines of `herramientas/publicar-version.sh`.

## Each version

1. Commit everything (the script refuses uncommitted changes).
2. Write what's new in `docs/novedades/<version>.md` (Markdown, English and Spanish like `0.1.0.md`). It becomes the GitHub release notes and the text of Sparkle's update window.
3. Run it:

   ```bash
   herramientas/publicar-version.sh 0.2.0
   ```

   It raises the version number in `Recursos/Info.plist` (and commits it), builds the app with the local signature, makes `Alero-0.2.0.zip` with `ditto`, signs it with the Sparkle key and writes `appcast.xml`. Then it stops and asks: push the code of that version, new number included, to `Halyon85/alero` (the release is tagged on its `main`) and answer `si` to create the GitHub release with both files. The app reads the list at `releases/latest/download/appcast.xml`, which always points to the newest release, so no other server is needed.

Each version is built in its own folder, `build/publicar/<version>/`, and its list has only that version: it's enough to update from any older one.

### Undoing a release

Delete the release on GitHub (`gh release delete v0.2.0 --repo Halyon85/alero --cleanup-tag`): `latest` goes back to the previous one and nobody else gets offered the bad version. Whoever already installed it gets the next fixed version as usual.

---

## En español

Alero se actualiza con [Sparkle](https://sparkle-project.org), pero **solo las versiones armadas con `herramientas/publicar-version.sh`** buscan actualizaciones. La que compila cada uno con `compilar.sh` no busca nunca, porque una actualización le cambiaría su app por la publicada. Se actualiza con `git pull && ./compilar.sh instalar`.

### Cómo funciona

- Una versión publicada lleva en su `Info.plist` la dirección de la lista de versiones (`SUFeedURL`, el *appcast*) y la mitad pública de una clave (`SUPublicEDKey`).
- Una vez por día mira la lista. Si hay una versión nueva, muestra las novedades y **pregunta antes de instalarla**. Nunca se instala sola (`SUAllowsAutomaticUpdates` está apagado). En **Ajustes → General → Actualizaciones → Buscar ahora** se busca en el momento.
- Cada `.zip` va firmado con la mitad privada de la clave, que nunca sale del Llavero de quien publica. Alero rechaza cualquier actualización que no esté firmada con ella, aunque alguien tome la cuenta de GitHub o la descarga.
- La 0.1.0 salió antes de Sparkle: quien la tiene baja la siguiente a mano una vez y, de ahí en adelante, Alero le avisa de las nuevas.

### Firmar sin la cuenta paga de Apple

Sin el Apple Developer Program (99 USD por año) se puede publicar igual, con estas diferencias:

- **La primera vez**, macOS bloquea la app bajada: hay que ir a **Ajustes del Sistema → Privacidad y seguridad → Abrir igual**.
- **Las actualizaciones** se instalan normal.
- **Después de cada actualización**, macOS puede volver a pedir los permisos (Accesibilidad, Grabación de pantalla).

Con Developer ID y la notarización de Apple, la app abre normal desde el principio y los permisos no se pierden.

`publicar-version.sh` firma con un certificado «Developer ID Application» si lo encuentra y, si no, con la firma local. Nunca usa «Apple Development»: ese lleva tu correo y es para probar en tus Macs, no para repartir (el script lo revisa y frena).

### La primera vez

1. **Crear la clave** (queda en tu Llavero):

   ```bash
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.alero
   ```

2. **Guardar una copia de la clave privada** fuera del repositorio (gestor de contraseñas, disco cifrado). Sin ella no se pueden publicar actualizaciones para las copias ya instaladas:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.alero -x alero-clave-privada.txt
   ```

   Después de guardarla, borrá ese archivo del disco.

3. **Si publicás tu propia copia de Alero**, poné tu clave pública y tus direcciones en las primeras líneas de `herramientas/publicar-version.sh`.

### Cada versión

1. Hacé commit de todo (el script no arranca con cambios sin guardar).
2. Escribí las novedades en `docs/novedades/<versión>.md` (Markdown, en inglés y en castellano como `0.1.0.md`). Van en las notas de GitHub y en la ventana de actualización de Sparkle.
3. Corré el script:

   ```bash
   herramientas/publicar-version.sh 0.2.0
   ```

   Sube el número en `Recursos/Info.plist` (y lo guarda en git), compila con la firma local, arma `Alero-0.2.0.zip` con `ditto`, lo firma con la clave de Sparkle y escribe `appcast.xml`. Ahí frena y pregunta: subí el código de esa versión, con el número nuevo, a `Halyon85/alero` (la versión se marca sobre su `main`) y contestá `si` para crear la versión en GitHub con los dos archivos. La app lee la lista en `releases/latest/download/appcast.xml`, que siempre apunta a la última versión, así que no hace falta otro servidor.

Cada versión se arma en su carpeta, `build/publicar/<versión>/`, y su lista lleva solo esa versión: alcanza para actualizar desde cualquiera anterior.

### Volver atrás

Borrá la versión en GitHub (`gh release delete v0.2.0 --repo Halyon85/alero --cleanup-tag`): `latest` vuelve a la anterior y a nadie más le aparece la versión con problemas. Quien ya la instaló recibe la siguiente versión arreglada como siempre.
