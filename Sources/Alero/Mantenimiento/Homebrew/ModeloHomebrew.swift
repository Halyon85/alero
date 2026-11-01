import AppKit
import Combine

// El estado del gestor de Homebrew: lo instalado (con versión, actualización y tamaño), la operación en curso con su
// salida en vivo y cómo terminó. Una sola operación a la vez. Si brew pide contraseña, Alero no la maneja: ofrece
// abrir el mismo comando en la Terminal. Vive mientras la ventana de Mantenimiento está abierta (una operación que
// ya arrancó termina igual aunque se cierre). Main thread.

final class ModeloHomebrew: ObservableObject {
    enum Estado: Equatable { case sinLeer, leyendo, sinHomebrew, listo, errorLectura(String) }
    enum Vista: String, CaseIterable, Identifiable {
        case pedidos, actualizables, todos
        var id: String { rawValue }
        var nombre: String {
            switch self {
            case .pedidos: return T("Instalado por vos", "Installed by you")
            case .actualizables: return T("Con actualización", "Outdated")
            case .todos: return T("Todo", "Everything")
            }
        }
    }

    struct Terminada: Equatable {
        let operacion: OperacionBrew
        let fin: ProcesoBrew.Fin
        let pideContrasena: Bool
    }

    @Published private(set) var estado: Estado = .sinLeer
    @Published private(set) var version = ""
    @Published private(set) var paquetes: [PaqueteBrew] = []
    @Published var vista: Vista = .pedidos
    @Published var busqueda = ""
    @Published private(set) var enCurso: OperacionBrew?
    @Published private(set) var salida: [String] = []
    @Published private(set) var terminada: Terminada?

    private var brew: URL?
    private var proceso: ProcesoBrew?
    private var pideContrasena = false
    private var cancelacionTamanos: Cancelacion?
    /// Cuántas líneas de salida se guardan (las más nuevas).
    private let topeSalida = 2_000

    deinit { cancelacionTamanos?.cancelar() }

    var visibles: [PaqueteBrew] {
        paquetes.filter { paquete in
            let enVista: Bool
            switch vista {
            case .pedidos: enVista = paquete.pedido
            case .actualizables: enVista = paquete.nueva != nil
            case .todos: enVista = true
            }
            return enVista && (busqueda.isEmpty || paquete.nombre.localizedCaseInsensitiveContains(busqueda)
                || (paquete.descripcion?.localizedCaseInsensitiveContains(busqueda) ?? false))
        }
    }

    var actualizables: Int { paquetes.filter { $0.nueva != nil && !$0.fijado }.count }

    // MARK: - Leer

    func cargar() {
        guard estado != .leyendo else { return }
        guard let brew = ComandosBrew.ubicacion() else { estado = .sinHomebrew; return }
        self.brew = brew
        estado = .leyendo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A propósito: sin versión se muestra "Homebrew" a secas; no frena la lista.
            let version = (try? ProcesoBrew.leer(brew: brew, argumentos: ComandosBrew.leerVersion).get()).flatMap(ComandosBrew.version)
            let info = ProcesoBrew.leer(brew: brew, argumentos: ComandosBrew.leerInstalados)
            // Si falla, la lista sale igual pero sin actualizaciones (pendiente: decirlo en la pantalla). Por lo menos
            // queda en el registro, para no confundirlo con "todo al día".
            let desactualizados = ProcesoBrew.leer(brew: brew, argumentos: ComandosBrew.leerDesactualizados)
            if case .failure(let error) = desactualizados {
                NSLog("Alero: no se pudo leer qué tiene actualización en Homebrew: \(error.localizedDescription)")
            }
            let viejos = try? desactualizados.get()
            let resultado = info.flatMap { datos -> Result<[PaqueteBrew], ProcesoBrew.ErrorLectura> in
                do { return .success(try ComandosBrew.inventario(info: datos, desactualizados: viejos)) } catch {
                    return .failure(.fallo(0, T("no se entendió la lista de Homebrew", "couldn't read Homebrew's list")))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.version = version ?? "Homebrew"
                switch resultado {
                case .success(let lista):
                    self.paquetes = lista
                    self.estado = .listo
                    if self.vista == .pedidos, lista.contains(where: { $0.nueva != nil }) { self.vista = .actualizables }
                    self.calcularTamanos(brew: brew)
                case .failure(let error):
                    self.estado = .errorLectura(error.localizedDescription)
                }
            }
        }
    }

    /// Lo que ocupa cada fórmula en el Cellar, en segundo plano y una por una. Los casks no (sus apps están en
    /// /Applications y medirlas es caro).
    private func calcularTamanos(brew: URL) {
        cancelacionTamanos?.cancelar()
        let cancelacion = Cancelacion()
        cancelacionTamanos = cancelacion
        let cellar = brew.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Cellar", isDirectory: true)
        let formulas = paquetes.filter { $0.tipo == .formula }.map { ($0.id, $0.nombre, $0.version) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var tamanos: [String: Int64] = [:]
            for (id, nombre, version) in formulas {
                if cancelacion.activa { return }
                tamanos[id] = Papelera.tamano(cellar.appendingPathComponent(nombre).appendingPathComponent(version), cancelacion: cancelacion)
            }
            DispatchQueue.main.async {
                guard let self, !cancelacion.activa else { return }
                for i in self.paquetes.indices { if let t = tamanos[self.paquetes[i].id] { self.paquetes[i].tamano = t } }
            }
        }
    }

    // MARK: - Operaciones

    func correr(_ operacion: OperacionBrew) {
        guard enCurso == nil, let brew, let argumentos = operacion.argumentos else { return }
        enCurso = operacion
        terminada = nil
        pideContrasena = false
        salida = ["$ brew " + argumentos.joined(separator: " ")]
        let proceso = ProcesoBrew(brew: brew, argumentos: argumentos, alLinea: { [weak self] linea in
            guard let self else { return }
            if ComandosBrew.pideContrasena(linea) { self.pideContrasena = true }
            self.salida.append(linea)
            if self.salida.count > self.topeSalida { self.salida.removeFirst(self.salida.count - self.topeSalida) }
        }, alTerminar: { [weak self] fin in
            guard let self else { return }
            self.proceso = nil
            self.enCurso = nil
            self.terminada = Terminada(operacion: operacion, fin: fin, pideContrasena: self.pideContrasena && fin != .bien)
            // Aunque falle, brew puede haber hecho parte (actualizar todo): se vuelve a leer igual.
            if operacion.cambiaLaLista { self.cargar() }
        })
        self.proceso = proceso
        proceso.empezar()
    }

    func cancelar() { proceso?.cancelar() }

    /// Abre la última operación en la Terminal de la persona: ahí escribe la contraseña ella, no Alero. El archivo
    /// queda en la carpeta temporal de la persona, solo para ella (0700), y se borra al arrancar.
    func abrirEnTerminal() {
        guard let operacion = terminada?.operacion, let brew, let argumentos = operacion.argumentos else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alero-brew-\(UUID().uuidString).command")
        do {
            try Data(ComandosBrew.guion(brew: brew.path, argumentos: argumentos).utf8).write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            salida.append(T("No se pudo preparar la Terminal: \(error.localizedDescription)", "Couldn't prepare Terminal: \(error.localizedDescription)"))
            return
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Para `--capturas`: una lista de ejemplo con una operación terminada, sin correr brew.
    static func muestra() -> ModeloHomebrew {
        let modelo = ModeloHomebrew()
        modelo.version = "Homebrew 7.0.11"
        modelo.paquetes = [
            PaqueteBrew(nombre: "cmake", tipo: .formula, version: "4.4.4", nueva: "4.4.5", descripcion: "Cross-platform make",
                        pedido: true, fijado: false, tamano: 92_000_000),
            PaqueteBrew(nombre: "gh", tipo: .formula, version: "2.103.0", nueva: "2.103.3", descripcion: "GitHub command-line tool",
                        pedido: true, fijado: false, tamano: 38_000_000),
            PaqueteBrew(nombre: "ffmpeg", tipo: .formula, version: "8.0", nueva: nil, descripcion: "Play, record, convert, and stream audio and video",
                        pedido: true, fijado: false, tamano: 54_000_000),
            PaqueteBrew(nombre: "onyx", tipo: .cask, version: "5.1.0", nueva: "5.1.1", descripcion: "Verify system files structure",
                        pedido: true, fijado: false, tamano: nil),
            PaqueteBrew(nombre: "visual-studio-code", tipo: .cask, version: "1.106.0", nueva: nil, descripcion: "Open-source code editor",
                        pedido: true, fijado: false, tamano: nil),
        ]
        modelo.vista = .todos
        modelo.estado = .listo
        modelo.salida = ["$ brew upgrade --formula gh", "==> Upgrading gh", "  2.103.0 -> 2.103.3",
                         "==> Pouring gh--2.103.3.arm64_tahoe.bottle.tar.gz", "/opt/homebrew/Cellar/gh/2.103.3: 215 files, 38MB"]
        modelo.terminada = Terminada(operacion: .actualizar("gh", .formula), fin: .bien, pideContrasena: false)
        return modelo
    }
}
