import Foundation

// Mandar a la Papelera lo que eligió la persona (limpiador y desinstalador). Nunca se borra nada para siempre: todo va
// a la Papelera y se puede sacar de ahí. Cada elemento pasa por `ReglasBorrado.revisar` justo antes de moverse.
// Lo que macOS no deja mover por permisos (por ejemplo una app instalada por el administrador) se junta aparte: la
// persona puede pasárselo a Finder, que muestra su propio cartel de contraseña. Alero nunca pide ni ve la contraseña.

/// Bandera para frenar un trabajo largo desde otro hilo (cerrar la ventana, buscar de nuevo).
final class Cancelacion {
    private let candado = NSLock()
    private var cancelado = false

    var activa: Bool { candado.lock(); defer { candado.unlock() }; return cancelado }

    func cancelar() { candado.lock(); cancelado = true; candado.unlock() }
}

enum Papelera {
    struct Resultado {
        var movidos: [ElementoBorrable] = []
        var rechazados: [(ElementoBorrable, String)] = []
        /// Los que macOS no dejó mover por permisos: se le pueden pasar a Finder.
        var sinPermiso: [ElementoBorrable] = []

        var bytes: Int64 { movidos.reduce(0) { $0 + $1.tamano } }
    }

    /// Fuera del hilo principal. `mover` es la Papelera de macOS; las pruebas pasan otra (una carpeta temporal) para
    /// no tocar la Papelera de verdad.
    static func mandar(_ elementos: [ElementoBorrable], home: String = ReglasBorrado.casa,
                       mover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Resultado {
        var resultado = Resultado()
        // Lo de afuera primero: si se eligió una carpeta y algo suyo, se mueve la carpeta (con todo) una sola vez.
        let ordenados = elementos.sorted { $0.url.path.count < $1.url.path.count }
        for elemento in ordenados {
            if resultado.movidos.contains(where: { elemento.url.path.hasPrefix($0.url.path + "/") }) { continue }
            if let rechazo = ReglasBorrado.revisar(elemento, home: home) {
                resultado.rechazados.append((elemento, rechazo.explicacion))
                continue
            }
            do {
                try mover(elemento.url)
                resultado.movidos.append(elemento)
            } catch {
                if MoverArchivos.esDePermiso(error) {
                    resultado.sinPermiso.append(elemento)
                } else {
                    NSLog("Alero: no se pudo mandar a la Papelera \(elemento.url.path): \(error.localizedDescription)")
                    resultado.rechazados.append((elemento, error.localizedDescription))
                }
            }
        }
        return resultado
    }

    /// Le pasa a Finder lo que macOS no dejó mover: Finder lo manda a la Papelera y, si hace falta, pide la contraseña
    /// en su propio cartel. Las rutas viajan como argumentos de `osascript` (nunca dentro del texto del script), así
    /// un nombre raro no puede cambiar lo que hace. Fuera del hilo principal: espera a que la persona conteste.
    static func pasarAFinder(_ elementos: [ElementoBorrable], home: String = ReglasBorrado.casa) -> Resultado {
        var resultado = Resultado()
        var aMover: [ElementoBorrable] = []
        for elemento in elementos {
            if let rechazo = ReglasBorrado.revisar(elemento, home: home) {
                resultado.rechazados.append((elemento, rechazo.explicacion))
            } else {
                aMover.append(elemento)
            }
        }
        guard !aMover.isEmpty else { return resultado }
        let script = ["on run argv", "set lista to {}",
                      "repeat with ruta in argv", "set end of lista to (POSIX file (contents of ruta))", "end repeat",
                      "tell application id \"com.apple.finder\" to delete lista", "end run"]
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proceso.arguments = script.flatMap { ["-e", $0] } + aMover.map(\.url.path)
        proceso.standardInput = FileHandle.nullDevice
        proceso.standardOutput = FileHandle.nullDevice
        let errores = Pipe()
        proceso.standardError = errores
        do { try proceso.run() } catch {
            aMover.forEach { resultado.rechazados.append(($0, error.localizedDescription)) }
            return resultado
        }
        let mensaje = String(data: errores.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proceso.waitUntilExit()
        if proceso.terminationStatus != 0 { NSLog("Alero: Finder no pudo mandar a la Papelera: \(mensaje)") }
        // Se confirma en el disco: algo que no se puede leer no cuenta como movido.
        for elemento in aMover {
            if noEsta(elemento.url) {
                resultado.movidos.append(elemento)
            } else {
                resultado.rechazados.append((elemento, T("Finder no lo movió.", "Finder didn't move it.")))
            }
        }
        return resultado
    }

    /// True solo si `lstat` dice que no existe (ENOENT). Un "no se puede leer" no cuenta como borrado.
    static func noEsta(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    /// Lo que ocupa en el disco un archivo o una carpeta con todo lo de adentro, sin seguir enlaces. Para en seco si
    /// se cancela (devuelve lo contado hasta ahí). Fuera del hilo principal.
    static func tamano(_ url: URL, cancelacion: Cancelacion? = nil) -> Int64 {
        guard let identidad = IdentidadArchivo.leer(url), !identidad.esEnlace else { return 0 }
        let claves: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        if !identidad.esCarpeta {
            let valores = try? url.resourceValues(forKeys: Set(claves))
            return Int64(valores?.totalFileAllocatedSize ?? valores?.fileAllocatedSize ?? Int(identidad.tamano ?? 0))
        }
        guard let recorrido = FileManager.default.enumerator(at: url, includingPropertiesForKeys: claves, options: [],
                                                             errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var vistos = 0
        for case let hijo as URL in recorrido {
            vistos += 1
            if vistos % 500 == 0, cancelacion?.activa == true { break }
            guard let valores = try? hijo.resourceValues(forKeys: Set(claves)), valores.isSymbolicLink != true else { continue }
            total += Int64(valores.totalFileAllocatedSize ?? valores.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// "1,2 GB", como Finder.
    static func texto(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
