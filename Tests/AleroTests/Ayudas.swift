import Foundation
@testable import Alero

// Ayudas compartidas de las pruebas de Mantenimiento: una carpeta temporal propia (ya resuelta, sin el enlace
// /var → /private/var) donde se arman archivos, carpetas, enlaces y fechas. Se borra entera al terminar la prueba.
// Nada de esto toca la carpeta de la persona ni la Papelera de verdad.

final class CarpetaPrueba {
    let raiz: String
    var url: URL { URL(fileURLWithPath: raiz, isDirectory: true) }

    init() throws {
        let temporal = FileManager.default.temporaryDirectory.appendingPathComponent("alero-pruebas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporal, withIntermediateDirectories: true)
        guard let real = ReglasBorrado.realpath(temporal.path) else { throw CocoaError(.fileNoSuchFile) }
        raiz = real
    }

    func borrar() { try? FileManager.default.removeItem(atPath: raiz) }

    func ruta(_ relativa: String) -> String { raiz + "/" + relativa }

    @discardableResult
    func archivo(_ relativa: String, _ texto: String = "hola", dias: Int? = nil) throws -> URL {
        let url = URL(fileURLWithPath: ruta(relativa))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(texto.utf8).write(to: url)
        if let dias { try fechar(relativa, dias: dias) }
        return url
    }

    @discardableResult
    func carpeta(_ relativa: String) throws -> URL {
        let url = URL(fileURLWithPath: ruta(relativa), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func enlace(_ relativa: String, a destino: String) throws {
        try FileManager.default.createDirectory(atPath: (ruta(relativa) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: ruta(relativa), withDestinationPath: destino)
    }

    /// Le pone fecha de hace `dias` días (modificación y creación).
    func fechar(_ relativa: String, dias: Int) throws {
        let fecha = Calendar.current.date(byAdding: .day, value: -dias, to: Date())!
        try FileManager.default.setAttributes([.modificationDate: fecha, .creationDate: fecha], ofItemAtPath: ruta(relativa))
    }

    func existe(_ relativa: String) -> Bool {
        var info = stat()
        return lstat(ruta(relativa), &info) == 0
    }

    /// Un elemento como lo arma un escaneo (identidad leída ahora).
    func elemento(_ relativa: String, raiz relativaRaiz: String) -> ElementoBorrable? {
        let url = URL(fileURLWithPath: ruta(relativa))
        guard let identidad = IdentidadArchivo.leer(url) else { return nil }
        return ElementoBorrable(url: url, raiz: URL(fileURLWithPath: ruta(relativaRaiz), isDirectory: true), identidad: identidad, tamano: 1)
    }

    /// Una "Papelera" de mentira dentro de la carpeta de prueba: mover ahí en vez de a la Papelera de macOS.
    func papelera() throws -> (URL) throws -> Void {
        let destino = try carpeta("_papelera")
        return { url in
            try FileManager.default.moveItem(at: url, to: destino.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }
}
