import AppKit

// El estante: archivos que dejás un rato en el notch para llevarlos después a otro lado. Guarda una referencia
// (marcador) y no una copia: el archivo sigue donde estaba. Si lo movés o borrás, desaparece del estante solo.
// Queda guardado entre reinicios de Alero. Lo que viene de una carpeta temporal (una imagen arrastrada desde el
// navegador, un adjunto) sí se copia a la carpeta de Alero, porque macOS lo borra solo y se perdía del estante.

struct ItemEstante: Codable, Identifiable, Equatable {
    let id: UUID
    let nombre: String
    let marcador: Data
}

final class Estante: ObservableObject {
    static let shared = Estante()

    @Published private(set) var items: [ItemEstante] = []
    private let clave = "estante.items"

    private init() {
        if let datos = UserDefaults.standard.data(forKey: clave) {
            do { items = try JSONDecoder().decode([ItemEstante].self, from: datos) } catch {
                NSLog("Alero: no se pudo leer el estante guardado (se empieza vacío): \(error.localizedDescription)")
            }
        }
        limpiarPerdidos()
    }

    /// Suma los archivos que no estén ya. Devuelve cuántos sumó.
    @discardableResult
    func agregar(_ urls: [URL]) -> Int {
        let yaEstan = Set(items.compactMap { url(de: $0)?.standardizedFileURL })
        var sumados = 0
        for original in urls where original.isFileURL && !yaEstan.contains(original.standardizedFileURL) {
            do {
                let url = try Estante.esTemporal(original) ? copiarAlEstante(original) : original
                let marcador = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                items.append(ItemEstante(id: UUID(), nombre: url.lastPathComponent, marcador: marcador))
                sumados += 1
            } catch {
                NSLog("Alero: no se pudo guardar \(original.lastPathComponent) en el estante: \(error.localizedDescription)")
            }
        }
        if sumados > 0 { guardar() }
        return sumados
    }

    func quitar(_ item: ItemEstante) {
        borrarCopia(item)
        items.removeAll { $0.id == item.id }
        guardar()
    }

    func vaciar() {
        items.forEach(borrarCopia)
        items = []
        guardar()
    }

    /// Donde van las copias de lo temporal.
    private static let carpetaCopias = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Alero/Estante")

    /// Carpetas que macOS vacía solo: temporales del sistema y de cada app, y las cachés.
    static func esTemporal(_ url: URL) -> Bool {
        let ruta = url.resolvingSymlinksInPath().path
        let temporales = [NSTemporaryDirectory(), "/private/var/folders/", "/private/tmp/", "/tmp/", NSHomeDirectory() + "/Library/Caches/"]
        return temporales.contains { !$0.isEmpty && ruta.hasPrefix(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
    }

    /// Copia un archivo temporal a la carpeta del estante (con un nombre que no pise otro).
    private func copiarAlEstante(_ url: URL) throws -> URL {
        let carpeta = Estante.carpetaCopias.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let destino = carpeta.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destino)
        return destino
    }

    /// Si el ítem es una copia propia (de algo temporal), la borra al sacarlo del estante. Lo de afuera no se toca nunca.
    private func borrarCopia(_ item: ItemEstante) {
        guard let url = url(de: item) else { return }
        let carpeta = url.deletingLastPathComponent()
        guard carpeta.deletingLastPathComponent().standardizedFileURL.path == Estante.carpetaCopias.standardizedFileURL.path else { return }
        do { try FileManager.default.removeItem(at: carpeta) } catch {
            NSLog("Alero: no se pudo borrar la copia del estante: \(error.localizedDescription)")
        }
    }

    /// Dónde está el archivo ahora (sigue al archivo si lo movieron), o nil si ya no existe.
    func url(de item: ItemEstante) -> URL? {
        var viejo = false
        guard let url = try? URL(resolvingBookmarkData: item.marcador, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &viejo),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func icono(de item: ItemEstante) -> NSImage {
        guard let url = url(de: item) else { return NSWorkspace.shared.icon(for: .data) }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func limpiarPerdidos() {
        let antes = items.count
        items.removeAll { url(de: $0) == nil }
        if items.count != antes { guardar() }
    }

    private func guardar() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(items), forKey: clave) } catch {
            NSLog("Alero: no se pudo guardar el estante: \(error.localizedDescription)")
        }
    }
}
