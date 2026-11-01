import AppKit
import Combine

// El estado de "Limpiar la Mac": buscar (en segundo plano), lo que eligió la persona y el resultado de mandarlo a la
// Papelera. Vive mientras la ventana de Mantenimiento está abierta: al cerrarla se suelta la lista y se corta la
// búsqueda que esté en curso. Main thread.

final class ModeloLimpiador: ObservableObject {
    enum Estado: Equatable { case inicio, buscando(CategoriaLimpieza?), listo, moviendo }

    @Published private(set) var estado: Estado = .inicio
    @Published private(set) var candidatos: [CandidatoLimpieza] = []
    @Published var elegidos: Set<String> = []
    /// Lo que pasó la última vez que se mandó algo a la Papelera.
    @Published private(set) var resultado: Papelera.Resultado?

    private var cancelacion: Cancelacion?

    deinit { cancelacion?.cancelar() }

    var ocupado: Bool {
        switch estado {
        case .buscando, .moviendo: return true
        case .inicio, .listo: return false
        }
    }

    func de(_ categoria: CategoriaLimpieza) -> [CandidatoLimpieza] { candidatos.filter { $0.categoria == categoria } }

    func bytes(_ lista: [CandidatoLimpieza]) -> Int64 { lista.reduce(0) { $0 + $1.elemento.tamano } }

    var bytesElegidos: Int64 { bytes(candidatos.filter { elegidos.contains($0.id) }) }

    func buscar() {
        guard !ocupado else { return }
        cancelacion?.cancelar()
        let cancelacion = Cancelacion()
        self.cancelacion = cancelacion
        estado = .buscando(nil)
        resultado = nil
        let opciones = EscanerLimpieza.Opciones(home: ReglasBorrado.casa,
                                                abiertas: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
                                                carpetasCapturas: ModeloLimpiador.carpetasDeCapturas())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lista = EscanerLimpieza.escanear(opciones, cancelacion: cancelacion) { categoria in
                DispatchQueue.main.async { if self?.cancelacion === cancelacion { self?.estado = .buscando(categoria) } }
            }
            DispatchQueue.main.async {
                guard let self, self.cancelacion === cancelacion, !cancelacion.activa else { return }
                self.candidatos = lista
                self.elegidos = Set(lista.filter(\.elegido).map(\.id))
                self.estado = .listo
            }
        }
    }

    func alternar(_ candidato: CandidatoLimpieza) {
        if elegidos.contains(candidato.id) { elegidos.remove(candidato.id) } else { elegidos.insert(candidato.id) }
    }

    /// Tilda o destilda toda una categoría (si estaba toda tildada, la destilda).
    func alternar(_ categoria: CategoriaLimpieza) {
        let ids = de(categoria).map(\.id)
        if ids.allSatisfy(elegidos.contains) { elegidos.subtract(ids) } else { elegidos.formUnion(ids) }
    }

    /// Manda a la Papelera lo elegido. La confirmación la pide la pantalla antes de llamar acá.
    func mandarElegidos() {
        let lista = candidatos.filter { elegidos.contains($0.id) }.map(\.elemento)
        mover(lista) { Papelera.mandar($0) }
    }

    /// Lo que macOS no dejó mover se le pasa a Finder (pide la contraseña en su cartel si hace falta).
    func pasarAFinder() {
        guard let pendientes = resultado?.sinPermiso, !pendientes.isEmpty else { return }
        mover(pendientes, sumar: true) { Papelera.pasarAFinder($0) }
    }

    /// `sumar`: el resultado se junta con el anterior (lo que movió Finder se suma a lo que ya se había movido).
    private func mover(_ lista: [ElementoBorrable], sumar: Bool = false, con hacer: @escaping ([ElementoBorrable]) -> Papelera.Resultado) {
        guard !lista.isEmpty, !ocupado else { return }
        estado = .moviendo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hecho = hacer(lista)
            DispatchQueue.main.async {
                guard let self else { return }
                let movidos = Set(hecho.movidos.map(\.id))
                self.candidatos.removeAll { movidos.contains($0.id) }
                self.elegidos.subtract(movidos)
                if sumar, var total = self.resultado {
                    total.movidos += hecho.movidos
                    total.rechazados += hecho.rechazados
                    total.sinPermiso = hecho.sinPermiso
                    self.resultado = total
                } else {
                    self.resultado = hecho
                }
                self.estado = .listo
            }
        }
    }

    /// El Escritorio, la carpeta de capturas de macOS (si la persona la cambió) y la de Alero (si eligió una).
    private static func carpetasDeCapturas() -> [String] {
        let casa = ReglasBorrado.casa
        var carpetas = [casa + "/Desktop"]
        if let deMacOS = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !deMacOS.isEmpty {
            carpetas.append((deMacOS as NSString).expandingTildeInPath)
        }
        let deAlero = Ajustes.shared.capturaCarpeta
        if !deAlero.isEmpty { carpetas.append(deAlero) }
        // Solo carpetas de la persona: una captura guardada en un disco externo no se ofrece.
        return carpetas.filter { $0.hasPrefix(casa + "/") }
    }

    /// Para `--capturas`: una lista de ejemplo, sin tocar el disco.
    static func muestra() -> ModeloLimpiador {
        let modelo = ModeloLimpiador()
        let identidad = IdentidadArchivo(dispositivo: 1, inodo: 1, tipo: S_IFDIR, modificado: nil, tamano: nil)
        let base = "/Users/ejemplo/Library"
        let datos: [(CategoriaLimpieza, String, Int64, Bool, String?)] = [
            (.caches, "/Caches/com.google.Chrome", 812_000_000, true, nil),
            (.caches, "/Caches/com.tinyspeck.slackmacgap", 356_000_000, false, T("La app está abierta.", "The app is open.")),
            (.caches, "/Caches/pip", 214_000_000, true, nil),
            (.caches, "/Caches/ms-playwright", 1_400_000_000, false, T("Pesada de volver a bajar.", "Slow to download again.")),
            (.registros, "/Logs/DiagnosticReports/Safari-2026-09-12.ips", 2_300_000, true, nil),
            (.xcode, "/Developer/Xcode/DerivedData/Alero-gfhzkq", 2_900_000_000, true, nil),
            (.homebrew, "/Caches/Homebrew/downloads", 640_000_000, true, nil),
            (.instaladores, "/../Downloads/Figma-124.3.dmg", 290_000_000, false, nil),
            (.capturas, "/../Desktop/Captura de pantalla 2026-09-02 a la(s) 10.14.22.png", 3_100_000, false, nil),
        ]
        modelo.candidatos = datos.map { categoria, ruta, tamano, elegido, nota in
            let url = URL(fileURLWithPath: (base + ruta as NSString).standardizingPath)
            let elemento = ElementoBorrable(url: url, raiz: url.deletingLastPathComponent(), identidad: identidad, tamano: tamano)
            return CandidatoLimpieza(elemento: elemento, categoria: categoria, elegido: elegido, nota: nota)
        }
        modelo.elegidos = Set(modelo.candidatos.filter(\.elegido).map(\.id))
        modelo.estado = .listo
        return modelo
    }
}
