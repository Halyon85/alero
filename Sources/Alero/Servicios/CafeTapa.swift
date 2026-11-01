import Foundation

// Café con la tapa cerrada: que la MacBook no se duerma al cerrarla (sin monitor externo ni cargador). macOS solo lo
// permite como administrador (`pmset disablesleep`). Para no pedir la contraseña cada vez (01/11/2026), la
// primera vez se guarda una regla en `/etc/sudoers.d/alero-cafe` que deja a este usuario correr SOLO estos dos
// comandos exactos sin contraseña: `pmset -a disablesleep 1` y `pmset -a disablesleep 0`. Nada más. Se quita desde
// Alero › Café (pide la contraseña otra vez).
//
// Cómo no queda prendido para siempre: un vigilante chico (del usuario, no administrador) pone `disablesleep 1`, mira
// cada 5 s que Alero siga abierto y que exista la marca `cafe-tapa`, y apenas falta cualquiera de las dos pone
// `disablesleep 0` y termina. Apagar el café borra la marca; si Alero se cierra (aunque sea de golpe), el vigilante
// sigue vivo y lo nota solo.

enum CafeTapa {
    private static let regla = "/etc/sudoers.d/alero-cafe"
    private static let marca = NSHomeDirectory() + "/Library/Application Support/Alero/cafe-tapa"
    private static var vigilante: Process?

    static var prendido: Bool { vigilante?.isRunning == true }

    /// Si ya está guardado el permiso (la regla existe).
    static var permisoGuardado: Bool { FileManager.default.fileExists(atPath: regla) }

    /// Prende la tapa cerrada: si falta el permiso lo pide (una vez) y arranca el vigilante. `alTerminar(false)`
    /// avisa, en el hilo principal, si se canceló la contraseña o algo falló.
    static func prender(alTerminar: @escaping (Bool) -> Void) {
        guard !prendido else { return }
        if permisoGuardado {
            arrancarVigilante(alTerminar: alTerminar)
            return
        }
        guardarPermiso { bien in
            if bien { arrancarVigilante(alTerminar: alTerminar) } else { alTerminar(false) }
        }
    }

    /// Borra la marca: el vigilante vuelve todo a la normalidad en menos de 5 s.
    static func apagar() {
        _ = try? FileManager.default.removeItem(atPath: marca)
    }

    /// Guarda la regla (pide la contraseña con el cartel de macOS). `alTerminar` en el hilo principal.
    static func guardarPermiso(alTerminar: @escaping (Bool) -> Void) {
        guard let usuario = usuarioSeguro else {
            alTerminar(false)
            return
        }
        // `visudo -c` revisa la regla antes de instalarla: una regla rota en sudoers deja a `sudo` sin andar.
        let linea = "\(usuario) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let guion = "t=$(/usr/bin/mktemp) && printf '%s\\n' '\(linea)' > $t && /usr/sbin/visudo -cf $t >/dev/null "
            + "&& /usr/bin/install -m 0440 -o root -g wheel $t \(regla); r=$?; /bin/rm -f $t; exit $r"
        comoAdministrador(guion) { bien in alTerminar(bien && permisoGuardado) }
    }

    /// Quita la regla (pide la contraseña). `alTerminar` en el hilo principal.
    static func quitarPermiso(alTerminar: @escaping (Bool) -> Void) {
        apagar()
        comoAdministrador("/bin/rm -f \(regla)") { bien in alTerminar(bien && !permisoGuardado) }
    }

    /// Lo que corre el vigilante (como el usuario; solo `sudo -n` con los dos comandos de la regla).
    static func guion(pid: Int32) -> String {
        "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1; while /bin/kill -0 \(pid) 2>/dev/null && [ -e '\(marca)' ]; "
            + "do /bin/sleep 5; done; /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"
    }

    // MARK: - Por dentro

    /// El nombre de usuario, solo si son letras, números, punto, guion o guion bajo (va dentro de la regla).
    private static var usuarioSeguro: String? {
        let usuario = NSUserName()
        let permitido = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !usuario.isEmpty, usuario.unicodeScalars.allSatisfy({ permitido.contains($0) && $0.isASCII }) else { return nil }
        return usuario
    }

    private static func arrancarVigilante(alTerminar: @escaping (Bool) -> Void) {
        do {
            try FileManager.default.createDirectory(atPath: (marca as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: marca))
        } catch {
            NSLog("Alero: no se pudo crear la marca del café con tapa: \(error.localizedDescription)")
            alTerminar(false)
            return
        }
        let nuevo = Process()
        nuevo.executableURL = URL(fileURLWithPath: "/bin/sh")
        nuevo.arguments = ["-c", guion(pid: getpid())]
        nuevo.standardOutput = FileHandle.nullDevice
        nuevo.standardError = FileHandle.nullDevice
        nuevo.terminationHandler = { _ in
            DispatchQueue.main.async {
                vigilante = nil
                // Si la marca sigue, nadie lo apagó: algo falló. Se borra y se avisa.
                guard FileManager.default.fileExists(atPath: marca) else { return }
                apagar()
                alTerminar(false)
            }
        }
        do {
            try nuevo.run()
            vigilante = nuevo
        } catch {
            NSLog("Alero: no se pudo arrancar el vigilante del café con tapa: \(error.localizedDescription)")
            apagar()
            alTerminar(false)
        }
    }

    /// Corre un comando como administrador con el cartel de contraseña de macOS. Sin comillas dobles adentro.
    private static func comoAdministrador(_ guion: String, alTerminar: @escaping (Bool) -> Void) {
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proceso.arguments = ["-e", "do shell script \"\(guion)\" with administrator privileges"]
        proceso.standardOutput = FileHandle.nullDevice
        proceso.standardError = FileHandle.nullDevice
        proceso.terminationHandler = { terminado in
            let bien = terminado.terminationStatus == 0
            DispatchQueue.main.async { alTerminar(bien) }
        }
        do { try proceso.run() } catch {
            NSLog("Alero: no se pudo pedir la contraseña: \(error.localizedDescription)")
            alTerminar(false)
        }
    }
}
