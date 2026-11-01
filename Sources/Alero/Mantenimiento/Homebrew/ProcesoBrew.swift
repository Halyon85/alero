import Foundation

// Corre brew como un proceso aparte, con argumentos separados (nunca a través de un shell), sin teclado (stdin vacío:
// si brew pide contraseña, falla en vez de quedarse esperando) y con corte si se queda colgado. Dos formas:
// `leer` para los comandos de lectura (JSON, con tope de tiempo total) y `correr` para las operaciones, que mandan
// la salida línea por línea y se cortan si pasan 15 minutos sin escribir nada (una descarga grande es lenta pero no
// muda). Cancelar manda SIGTERM y, si a los 2 s sigue, SIGKILL.

final class ProcesoBrew {
    enum Fin: Equatable { case bien, fallo(Int32), colgado, cancelado, noArranco(String) }

    /// Los que están corriendo se retienen acá hasta que terminan: cerrar la ventana no deja un brew a medias.
    private static var corriendo: [ProcesoBrew] = []
    private static let candado = NSLock()

    private let proceso = Process()
    private let silencioMaximo: TimeInterval
    private let alLinea: (String) -> Void
    private let alTerminar: (Fin) -> Void
    private let cola = DispatchQueue(label: "alero.brew")
    // En `cola`.
    private var ultimaSalida = Date()
    private var resto = Data()
    private var cancelado = false
    private var colgado = false
    private var reloj: DispatchSourceTimer?

    /// `alLinea` y `alTerminar` llegan en el hilo principal.
    init(brew: URL, argumentos: [String], silencioMaximo: TimeInterval = 15 * 60,
         alLinea: @escaping (String) -> Void, alTerminar: @escaping (Fin) -> Void) {
        self.silencioMaximo = silencioMaximo
        self.alLinea = alLinea
        self.alTerminar = alTerminar
        proceso.executableURL = brew
        proceso.arguments = argumentos
        proceso.environment = ComandosBrew.entorno(base: ProcessInfo.processInfo.environment)
        proceso.standardInput = FileHandle.nullDevice
    }

    func empezar() {
        let salida = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = salida
        let terminado = DispatchGroup()
        terminado.enter()
        terminado.enter()
        salida.fileHandleForReading.readabilityHandler = { [weak self] manija in
            let datos = manija.availableData
            guard let self else { return }
            if datos.isEmpty {
                manija.readabilityHandler = nil
                self.cola.async { self.soltar(final: true); terminado.leave() }
            } else {
                self.cola.async { self.recibir(datos) }
            }
        }
        proceso.terminationHandler = { _ in terminado.leave() }
        do { try proceso.run() } catch {
            salida.fileHandleForReading.readabilityHandler = nil
            let mensaje = error.localizedDescription
            DispatchQueue.main.async { self.alTerminar(.noArranco(mensaje)) }
            return
        }
        ProcesoBrew.candado.lock(); ProcesoBrew.corriendo.append(self); ProcesoBrew.candado.unlock()
        vigilarSilencio()
        terminado.notify(queue: cola) { [self] in
            reloj?.cancel()
            reloj = nil
            let fin: Fin
            if cancelado { fin = .cancelado } else if colgado { fin = .colgado }
            else if proceso.terminationStatus == 0 { fin = .bien } else { fin = .fallo(proceso.terminationStatus) }
            DispatchQueue.main.async {
                self.alTerminar(fin)
                ProcesoBrew.candado.lock(); ProcesoBrew.corriendo.removeAll { $0 === self }; ProcesoBrew.candado.unlock()
            }
        }
    }

    func cancelar() {
        cola.async { [self] in
            guard proceso.isRunning else { return }
            cancelado = true
            cortar()
        }
    }

    /// En `cola`.
    private func cortar() {
        proceso.terminate()
        let pid = proceso.processIdentifier
        cola.asyncAfter(deadline: .now() + 2) { [self] in
            if proceso.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Un reloj que mira cada 10 s si brew dejó de escribir. Existe solo mientras corre una operación.
    private func vigilarSilencio() {
        let reloj = DispatchSource.makeTimerSource(queue: cola)
        reloj.schedule(deadline: .now() + 10, repeating: 10)
        reloj.setEventHandler { [weak self] in
            guard let self, self.proceso.isRunning, !self.colgado else { return }
            if Date().timeIntervalSince(self.ultimaSalida) > self.silencioMaximo {
                self.colgado = true
                self.cortar()
            }
        }
        reloj.resume()
        self.reloj = reloj
    }

    /// En `cola`. Junta lo que llega y manda las líneas completas (también las que terminan con "\r", las de progreso).
    private func recibir(_ datos: Data) {
        ultimaSalida = Date()
        resto.append(datos)
        soltar(final: false)
    }

    private func soltar(final: Bool) {
        var lineas: [String] = []
        while let corte = resto.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lineas.append(String(decoding: resto[resto.startIndex..<corte], as: UTF8.self))
            resto.removeSubrange(resto.startIndex...corte)
        }
        if final, !resto.isEmpty {
            lineas.append(String(decoding: resto, as: UTF8.self))
            resto.removeAll()
        }
        let limpias = lineas.map(ComandosBrew.limpiarANSI).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !limpias.isEmpty else { return }
        DispatchQueue.main.async { limpias.forEach(self.alLinea) }
    }

    // MARK: - Lectura

    enum ErrorLectura: Error, LocalizedError {
        case noArranco(String), fallo(Int32, String), tardo

        var errorDescription: String? {
            switch self {
            case .noArranco(let m): return T("No se pudo abrir Homebrew: \(m)", "Couldn't run Homebrew: \(m)")
            case .fallo(let codigo, let m): return T("Homebrew falló (\(codigo)): \(m)", "Homebrew failed (\(codigo)): \(m)")
            case .tardo: return T("Homebrew tardó demasiado en contestar.", "Homebrew took too long to answer.")
            }
        }
    }

    /// Corre un comando de lectura y devuelve lo que escribió (hasta 32 MB). Fuera del hilo principal: espera.
    static func leer(brew: URL, argumentos: [String], tope: TimeInterval = 90) -> Result<Data, ErrorLectura> {
        let proceso = Process()
        proceso.executableURL = brew
        proceso.arguments = argumentos
        proceso.environment = ComandosBrew.entorno(base: ProcessInfo.processInfo.environment)
        proceso.standardInput = FileHandle.nullDevice
        let salida = Pipe()
        let errores = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = errores
        let candado = NSLock()
        var datos = Data()
        var mensajes = Data()
        let leido = DispatchGroup()
        for (pipe, esSalida) in [(salida, true), (errores, false)] {
            leido.enter()
            // Se sigue leyendo aunque pase el tope (y se tira): si no, brew se traba escribiendo.
            pipe.fileHandleForReading.readabilityHandler = { manija in
                let parte = manija.availableData
                if parte.isEmpty { manija.readabilityHandler = nil; leido.leave(); return }
                candado.lock()
                if esSalida, datos.count < 32_000_000 { datos.append(parte) }
                if !esSalida, mensajes.count < 64_000 { mensajes.append(parte) }
                candado.unlock()
            }
        }
        do { try proceso.run() } catch {
            salida.fileHandleForReading.readabilityHandler = nil
            errores.fileHandleForReading.readabilityHandler = nil
            return .failure(.noArranco(error.localizedDescription))
        }
        if leido.wait(timeout: .now() + tope) == .timedOut {
            proceso.terminate()
            return .failure(.tardo)
        }
        proceso.waitUntilExit()
        candado.lock(); defer { candado.unlock() }
        guard proceso.terminationStatus == 0 else {
            let texto = String(decoding: mensajes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.fallo(proceso.terminationStatus, String(texto.suffix(300))))
        }
        return .success(datos)
    }
}
