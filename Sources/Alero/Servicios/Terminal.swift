import Foundation

// La terminal del notch: cada comando corre en zsh, en la carpeta actual, y su salida aparece de a poco. `cd` y `clear`
// se resuelven acá (un proceso nuevo por comando no puede cambiar la carpeta de los siguientes). No es una terminal
// completa: los programas que dibujan la pantalla (vim, top, ssh interactivo) no andan; para eso está Terminal.
// La lista guarda las últimas 400 líneas. Sin usar, no corre nada. Main thread (la salida llega por una cola propia).

struct LineaTerminal: Identifiable, Equatable {
    enum Tipo { case comando, salida, error, aviso }
    let id: Int
    let texto: String
    let tipo: Tipo
}

/// Lo que se puede probar sin procesos (`swift test`).
enum ReglasTerminal {
    /// Saca los códigos de color y de cursor (ANSI) que mandan muchos programas.
    static func sinColores(_ texto: String) -> String {
        texto.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// La carpeta de un `cd`: relativa a la actual, con `~`, o la casa si no hay argumento. Nil si no es un `cd`.
    static func destinoCd(_ comando: String, desde actual: String, casa: String) -> String? {
        let partes = comando.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        guard partes.first == "cd" else { return nil }
        var destino = partes.count > 1 ? partes[1].trimmingCharacters(in: .whitespaces) : "~"
        if destino.count >= 2, let primero = destino.first, primero == destino.last, primero == "\"" || primero == "'" {
            destino = String(destino.dropFirst().dropLast())
        }
        if destino == "~" || destino.hasPrefix("~/") { destino = casa + destino.dropFirst() }
        let ruta = destino.hasPrefix("/") ? destino : (actual as NSString).appendingPathComponent(destino)
        return (ruta as NSString).standardizingPath
    }

    /// La carpeta para mostrar en el prompt: con `~` en lugar de la casa.
    static func corta(_ carpeta: String, casa: String) -> String {
        carpeta == casa ? "~" : (carpeta.hasPrefix(casa + "/") ? "~" + carpeta.dropFirst(casa.count) : carpeta)
    }
}

final class Terminal: ObservableObject {
    static let shared = Terminal()

    @Published private(set) var lineas: [LineaTerminal] = []
    @Published private(set) var carpeta = NSHomeDirectory()
    @Published private(set) var corriendo = false
    private(set) var historial: [String] = []

    private var proceso: Process?
    private var siguienteId = 0
    /// Solo en `cola`: lo que llegó de cada caño (1 salida, 2 errores) sin salto de línea todavía.
    private var pendiente: [Int32: String] = [:]
    private let cola = DispatchQueue(label: "alero.terminal")
    /// El PATH del usuario (el de su shell con login), leído una vez al primer comando (tarda lo que tarde su .zshrc):
    /// sin eso no aparecen brew, node, etc.
    private lazy var camino: String = Terminal.leerCamino()

    func ejecutar(_ comando: String) {
        let limpio = comando.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, !corriendo else { return }
        if historial.last != limpio { historial.append(limpio) }
        if historial.count > 100 { historial.removeFirst(historial.count - 100) }
        agregar(ReglasTerminal.corta(carpeta, casa: NSHomeDirectory()) + " › " + limpio, .comando)
        if limpio == "clear" { lineas = []; return }
        if let destino = ReglasTerminal.destinoCd(limpio, desde: carpeta, casa: NSHomeDirectory()) {
            var esCarpeta: ObjCBool = false
            if FileManager.default.fileExists(atPath: destino, isDirectory: &esCarpeta), esCarpeta.boolValue {
                carpeta = destino
            } else {
                agregar(T("No existe esa carpeta.", "That folder doesn't exist."), .error)
            }
            return
        }
        correr(limpio)
    }

    /// Corta el comando que está corriendo (como Ctrl-C).
    func cortar() {
        guard let proceso, proceso.isRunning else { return }
        proceso.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if proceso.isRunning { proceso.terminate() } }
    }

    func limpiar() { lineas = [] }

    private func correr(_ comando: String) {
        let nuevo = Process()
        nuevo.executableURL = URL(fileURLWithPath: "/bin/zsh")
        nuevo.arguments = ["-c", comando]
        nuevo.currentDirectoryURL = URL(fileURLWithPath: carpeta)
        var entorno = ProcessInfo.processInfo.environment
        entorno["PATH"] = camino
        // Sin colores ni paginador: la salida va a una lista, no a una pantalla de terminal.
        entorno["TERM"] = "dumb"
        entorno["NO_COLOR"] = "1"
        entorno["PAGER"] = "cat"
        entorno["GIT_PAGER"] = "cat"
        nuevo.environment = entorno
        nuevo.standardInput = FileHandle.nullDevice
        let salida = Pipe()
        let errores = Pipe()
        nuevo.standardOutput = salida
        nuevo.standardError = errores
        leer(salida, tipo: .salida, clave: 1)
        leer(errores, tipo: .error, clave: 2)
        nuevo.terminationHandler = { [weak self] terminado in
            let codigo = terminado.terminationStatus
            // Se espera a que la cola termine de leer lo último antes de avisar.
            self?.cola.async {
                guard let self else { return }
                let restos = self.pendiente
                self.pendiente = [:]
                DispatchQueue.main.async {
                    for (clave, resto) in restos where !resto.isEmpty { self.agregar(resto, clave == 2 ? .error : .salida) }
                    if codigo != 0 { self.agregar(T("(terminó con código \(codigo))", "(exited with code \(codigo))"), .aviso) }
                    self.corriendo = false
                    self.proceso = nil
                }
            }
        }
        do {
            try nuevo.run()
            proceso = nuevo
            corriendo = true
        } catch {
            agregar(T("No se pudo correr: \(error.localizedDescription)", "Couldn't run it: \(error.localizedDescription)"), .error)
        }
    }

    /// Lee un caño a medida que llega y lo parte en líneas (lo que queda sin "\n" espera al próximo pedazo).
    private func leer(_ cano: Pipe, tipo: LineaTerminal.Tipo, clave: Int32) {
        cano.fileHandleForReading.readabilityHandler = { [weak self] archivo in
            let datos = archivo.availableData
            guard !datos.isEmpty else {
                archivo.readabilityHandler = nil
                return
            }
            let texto = ReglasTerminal.sinColores(String(decoding: datos, as: UTF8.self))
            self?.cola.async {
                guard let self else { return }
                var todo = (self.pendiente[clave] ?? "") + texto
                var completas: [String] = []
                while let corte = todo.firstIndex(of: "\n") {
                    completas.append(String(todo[..<corte]))
                    todo = String(todo[todo.index(after: corte)...])
                }
                self.pendiente[clave] = todo
                guard !completas.isEmpty else { return }
                DispatchQueue.main.async { completas.forEach { self.agregar($0, tipo) } }
            }
        }
    }

    private func agregar(_ texto: String, _ tipo: LineaTerminal.Tipo) {
        siguienteId += 1
        lineas.append(LineaTerminal(id: siguienteId, texto: texto, tipo: tipo))
        if lineas.count > 400 { lineas.removeFirst(lineas.count - 400) }
    }

    private static func leerCamino() -> String {
        let respaldo = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proceso.arguments = ["-lc", "printf %s \"$PATH\""]
        let salida = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = FileHandle.nullDevice
        do { try proceso.run() } catch { return respaldo }
        proceso.waitUntilExit()
        let camino = String(decoding: salida.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return camino.isEmpty ? respaldo : camino
    }
}
