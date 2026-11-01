import Darwin
import Foundation

// La última defensa antes de mandar algo a la Papelera (la usan el limpiador y el desinstalador). Todo lo que se
// escanea se guarda con su identidad (disco + inodo; y fecha y tamaño si es un archivo). Antes de moverlo se vuelve
// a leer y, si cambió (otro archivo con el mismo nombre, un enlace puesto en el medio), no se toca. Nunca se siguen
// enlaces simbólicos y hay una lista de carpetas que nunca se mandan a la Papelera, ni ellas ni lo que tienen adentro.
// Sin AppKit: se prueba con carpetas temporales (`ReglasBorradoTests`).

/// Quién es un archivo en el disco, leído sin seguir enlaces (`lstat`).
struct IdentidadArchivo: Equatable {
    let dispositivo: UInt64
    let inodo: UInt64
    /// `S_IFDIR`, `S_IFREG`, `S_IFLNK`…
    let tipo: mode_t
    /// Solo en archivos comunes. En carpetas no se compara: una caché cambia de fecha cada vez que su app escribe.
    let modificado: Int64?
    let tamano: Int64?

    /// Nil si no existe o no se puede leer.
    static func leer(_ url: URL) -> IdentidadArchivo? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let tipo = info.st_mode & S_IFMT
        let archivo = tipo == S_IFREG
        let fecha = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return IdentidadArchivo(dispositivo: UInt64(UInt32(bitPattern: info.st_dev)), inodo: UInt64(info.st_ino), tipo: tipo,
                                modificado: archivo ? fecha : nil, tamano: archivo ? Int64(info.st_size) : nil)
    }

    var esEnlace: Bool { tipo == S_IFLNK }
    var esCarpeta: Bool { tipo == S_IFDIR }
    var esArchivo: Bool { tipo == S_IFREG }
}

/// Algo encontrado en un escaneo, listo para revisar y (si la persona lo elige) mandar a la Papelera.
struct ElementoBorrable: Identifiable, Equatable {
    /// La ruta, armada con la carpeta raíz y el nombre que dio el listado del disco (nunca con un nombre visible).
    let url: URL
    /// La carpeta donde se encontró, ya resuelta (sin enlaces). Lo que se mueve tiene que estar adentro.
    let raiz: URL
    let identidad: IdentidadArchivo
    let tamano: Int64

    var id: String { url.path }
}

enum ReglasBorrado {
    enum Rechazo: Equatable {
        case noExiste, cambio, enlace, enlaceEnElCamino, prohibida, fueraDeLugar, nombreRaro

        var explicacion: String {
            switch self {
            case .noExiste: return T("Ya no está.", "It's gone already.")
            case .cambio: return T("Cambió desde que se buscó: no se tocó.", "It changed since the scan: left alone.")
            case .enlace: return T("Es un enlace: no se siguen.", "It's a link: links aren't followed.")
            case .enlaceEnElCamino: return T("Hay un enlace en el camino: no se tocó.", "There's a link along the path: left alone.")
            case .prohibida: return T("Es una carpeta protegida.", "It's a protected folder.")
            case .fueraDeLugar: return T("Está fuera de las carpetas que se revisan.", "It's outside the scanned folders.")
            case .nombreRaro: return T("Tiene un nombre que no se toca.", "Its name is off-limits.")
            }
        }
    }

    /// La carpeta de la persona, resuelta. Las reglas reciben `home` para poder probarse con una carpeta temporal.
    static var casa: String { realpath(NSHomeDirectory()) ?? NSHomeDirectory() }

    /// Carpetas que nunca se mandan a la Papelera (solo ellas: lo de adentro puede ir, si lo eligió la persona).
    static func prohibidas(home: String) -> Set<String> {
        let sistema = ["/", "/System", "/Library", "/Applications", "/Users", "/Users/Shared", "/private", "/private/var",
                       "/private/tmp", "/private/etc", "/usr", "/usr/local", "/bin", "/sbin", "/etc", "/var", "/tmp",
                       "/opt", "/opt/homebrew", "/Volumes", "/cores", "/Network", "/Library/Application Support",
                       "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Caches", "/Library/Preferences"]
        let deLaPersona = ["", "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
                           "Applications", ".Trash", ".config", ".cache", ".local", "Library/Caches",
                           "Library/Caches/Homebrew", "Library/Application Support", "Library/Preferences",
                           "Library/Preferences/ByHost", "Library/Containers", "Library/Group Containers",
                           "Library/LaunchAgents", "Library/Logs", "Library/Logs/DiagnosticReports", "Library/Developer",
                           "Library/Developer/Xcode", "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator",
                           "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies",
                           "Library/Application Scripts"]
        return Set(sistema).union(deLaPersona.map { $0.isEmpty ? home : home + "/" + $0 })
    }

    /// Carpetas de las que no se toca nada, ni lo de adentro: del sistema, llaveros, mail, mensajes y lo que se
    /// sincroniza con la nube (borrar ahí borra también en los otros aparatos).
    static func nuncaDentro(home: String) -> [String] {
        let sistema = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple"]
        let deLaPersona = [".ssh", ".gnupg", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage",
                           "Library/Mail", "Library/Messages", "Library/Accounts", "Library/Calendars",
                           "Library/Safari", "Library/Photos", "Pictures/Photos Library.photoslibrary"]
        return sistema + deLaPersona.map { home + "/" + $0 }
    }

    /// Revisa `elemento` justo antes de moverlo. Nil = se puede mover. Lee el disco (lstat), sin seguir enlaces.
    static func revisar(_ elemento: ElementoBorrable, home: String = casa) -> Rechazo? {
        // A propósito sin `standardizedFileURL`: le saca el "/private" a las rutas. Las rutas salen de listar el
        // disco, así que un "." o ".." en el medio solo puede ser una trampa.
        let ruta = elemento.url.path
        let raiz = elemento.raiz.path
        let partesRuta = (ruta as NSString).pathComponents
        if partesRuta.contains(".") || partesRuta.contains("..") || (raiz as NSString).pathComponents.contains("..") {
            return .fueraDeLugar
        }
        guard ruta.hasPrefix(raiz + "/") else { return .fueraDeLugar }
        let nombre = (ruta as NSString).lastPathComponent
        if nombre.isEmpty || nombre == "." || nombre == ".." || nombre == ".localized" { return .nombreRaro }
        if prohibidas(home: home).contains(ruta) { return .prohibida }
        if nuncaDentro(home: home).contains(where: { ruta == $0 || ruta.hasPrefix($0 + "/") }) { return .prohibida }
        // Lo más corto que se acepta es /Applications/App.app (tres partes).
        if partesRuta.count < 3 { return .prohibida }
        // La raíz tiene que ser una carpeta de verdad y estar ya resuelta (si no, alguien cambió un enlace del camino).
        guard let raizReal = realpath(raiz), raizReal == raiz, IdentidadArchivo.leer(elemento.raiz)?.esCarpeta == true else {
            return .enlaceEnElCamino
        }
        // Cada parte entre la raíz y el elemento: que exista y no sea un enlace.
        var camino = raiz
        let partes = String(ruta.dropFirst(raiz.count + 1)).split(separator: "/").map(String.init)
        for (i, parte) in partes.enumerated() {
            camino += "/" + parte
            guard let actual = IdentidadArchivo.leer(URL(fileURLWithPath: camino)) else { return .noExiste }
            if actual.esEnlace { return i == partes.count - 1 ? .enlace : .enlaceEnElCamino }
        }
        guard let ahora = IdentidadArchivo.leer(elemento.url) else { return .noExiste }
        return ahora == elemento.identidad ? nil : .cambio
    }

    /// `realpath` de Darwin. A propósito no se usa `resolvingSymlinksInPath`: le saca el "/private" a las rutas y
    /// la comparación con la raíz daría distinta.
    static func realpath(_ ruta: String) -> String? {
        guard let resuelta = Darwin.realpath(ruta, nil) else { return nil }
        defer { free(resuelta) }
        return String(cString: resuelta)
    }
}
