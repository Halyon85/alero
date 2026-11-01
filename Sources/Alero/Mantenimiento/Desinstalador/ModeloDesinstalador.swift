import AppKit
import Combine

// El estado del desinstalador: la lista de apps, las elegidas (una o varias) con sus restos y el resultado. Antes de
// mover nada a la Papelera: vuelve a revisar que cada app sea la misma que se eligió, las cierra si están abiertas
// (después de preguntar una sola vez por todas) y saca sus LaunchAgents de launchd (`launchctl bootout`), así no
// siguen corriendo hasta cerrar sesión. Todo va a la Papelera; lo de `/Library` solo se muestra. Lo usan la página de
// Mantenimiento (su propio modelo) y el notch (`ModelosNotch.desinstalador`). Main thread.

final class ModeloDesinstalador: ObservableObject {
    struct AppDeLista: Identifiable, Equatable {
        let url: URL
        let nombre: String
        var id: String { url.path }
    }

    /// Una app elegida con lo que se encontró de ella. Mientras se busca, `tamano` es 0 y `restos` está vacío.
    struct AppPreparada: Identifiable, Equatable {
        var app: AppElegida
        var tamano: Int64
        var restos: [RestoApp]
        /// Recibos del instalador (.pkg): solo para informar.
        var recibos: [String]
        var id: String { app.url.path }
    }

    /// Algo que se eligió y no se aceptó, con el porqué.
    struct Rechazada: Equatable {
        let nombre: String
        let motivo: String
    }

    enum Estado: Equatable { case eligiendo, buscando, listo, cerrando, desinstalando, terminado }

    @Published private(set) var estado: Estado = .eligiendo
    @Published private(set) var apps: [AppDeLista] = []
    /// Las apps elegidas, en el orden en que se eligieron.
    @Published private(set) var lote: [AppPreparada] = []
    /// Los restos tildados (por ruta), de todas las apps del lote.
    @Published var elegidos: Set<String> = []
    /// Lo último que se eligió y no se aceptó.
    @Published private(set) var rechazos: [Rechazada] = []
    /// Apps abiertas que hay que cerrar antes de seguir (la pantalla pregunta una sola vez por todas).
    @Published var porCerrar: [String] = []
    @Published private(set) var resultado: Papelera.Resultado?
    /// Cuántas apps del lote llegaron a la Papelera ("3 apps a la Papelera").
    @Published private(set) var appsMovidas = 0
    @Published private(set) var error: String?

    private var cancelacion: Cancelacion?

    deinit { cancelacion?.cancelar() }

    /// La app cuando se eligió una sola (la página la muestra con el detalle de cada resto).
    var app: AppElegida? { lote.count == 1 ? lote[0].app : nil }
    var tamanoApp: Int64 { lote.reduce(0) { $0 + $1.tamano } }
    var restos: [RestoApp] { lote.flatMap(\.restos) }
    var recibos: [String] { lote.flatMap(\.recibos) }
    var rechazo: Rechazada? { rechazos.first }
    var trabajando: Bool { [.buscando, .cerrando, .desinstalando].contains(estado) }
    var bytesElegidos: Int64 { lote.reduce(0) { $0 + tamanoElegido($1) } }

    /// Lo que se va a la Papelera de una app: ella más sus restos tildados (nunca lo que pide administrador).
    func tamanoElegido(_ preparada: AppPreparada) -> Int64 {
        preparada.tamano + mandables(preparada).reduce(0) { $0 + $1.elemento.tamano }
    }

    private func mandables(_ preparada: AppPreparada) -> [RestoApp] {
        preparada.restos.filter { elegidos.contains($0.id) && !$0.pideAdministrador }
    }

    // MARK: - Lista de apps

    /// Las apps de /Applications (y una carpeta más adentro) y de ~/Applications, sin las de Apple ni Alero.
    func cargarLista() {
        guard apps.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lista = ModeloDesinstalador.appsInstaladas()
            DispatchQueue.main.async { self?.apps = lista }
        }
    }

    private static func appsInstaladas() -> [AppDeLista] {
        var vistas: [AppDeLista] = []
        func revisar(_ carpeta: String, hondo: Bool) {
            guard let nombres = try? FileManager.default.contentsOfDirectory(atPath: carpeta) else { return }
            for nombre in nombres where !nombre.hasPrefix(".") {
                let url = URL(fileURLWithPath: carpeta).appendingPathComponent(nombre)
                guard let identidad = IdentidadArchivo.leer(url), identidad.esCarpeta else { continue }
                if url.pathExtension.lowercased() == "app" {
                    if case .success(let app) = ReglasApp.validar(url) { vistas.append(AppDeLista(url: url, nombre: app.nombre)) }
                } else if hondo {
                    revisar(url.path, hondo: false)
                }
            }
        }
        revisar("/Applications", hondo: true)
        revisar(ReglasBorrado.casa + "/Applications", hondo: true)
        return vistas.sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }

    // MARK: - Elegir

    /// Una app arrastrada, elegida en la lista o en el cuadro de abrir.
    func elegir(_ url: URL) { elegir([url]) }

    /// Una o varias apps (arrastradas o del cuadro de abrir). Las que no se aceptan quedan en `rechazos`; si no se
    /// acepta ninguna, lo que estaba elegido sigue como estaba. Busca los restos de todas fuera del hilo principal.
    func elegir(_ urls: [URL]) {
        guard estado == .eligiendo || estado == .listo || estado == .terminado, !urls.isEmpty else { return }
        var aceptadas: [AppElegida] = []
        var rechazadas: [Rechazada] = []
        for url in urls {
            switch ReglasApp.validar(url) {
            case .failure(let motivo): rechazadas.append(Rechazada(nombre: url.lastPathComponent, motivo: motivo.explicacion))
            case .success(let elegida):
                if !aceptadas.contains(where: { $0.url.path == elegida.url.path }) { aceptadas.append(elegida) }
            }
        }
        rechazos = rechazadas
        guard !aceptadas.isEmpty else { return }
        cancelacion?.cancelar()
        resultado = nil
        error = nil
        appsMovidas = 0
        porCerrar = []
        lote = aceptadas.map { AppPreparada(app: $0, tamano: 0, restos: [], recibos: []) }
        elegidos = []
        estado = .buscando
        let cancelacion = Cancelacion()
        self.cancelacion = cancelacion
        // Otra copia instalada fuera de lo elegido (ni en la Papelera): sus restos son de las dos y van sin tildar.
        let rutas = Set(aceptadas.map(\.url.path))
        let otrasCopias = aceptadas.map { elegida in
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: elegida.identificador).contains { otra in
                !rutas.contains(otra.path) && !otra.path.contains("/.Trash/")
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var preparadas: [AppPreparada] = []
            var vistos = Set<String>()
            for (elegida, otraCopia) in zip(aceptadas, otrasCopias) {
                if cancelacion.activa { return }
                var preparada = ModeloDesinstalador.preparar(elegida, otraCopia: otraCopia, cancelacion: cancelacion)
                // Dos copias de la misma app elegidas juntas comparten restos: cada uno aparece una sola vez.
                preparada.restos.removeAll { vistos.contains($0.id) }
                vistos.formUnion(preparada.restos.map(\.id))
                preparadas.append(preparada)
            }
            DispatchQueue.main.async {
                guard let self, self.cancelacion === cancelacion, !cancelacion.activa else { return }
                self.lote = preparadas
                self.elegidos = Set(preparadas.flatMap(\.restos).filter { $0.elegido && !$0.pideAdministrador }.map(\.id))
                self.estado = .listo
            }
        }
    }

    /// Firma, tamaño, restos y recibos de una app. Fuera del hilo principal.
    private static func preparar(_ elegida: AppElegida, otraCopia: Bool, cancelacion: Cancelacion) -> AppPreparada {
        var app = elegida
        let firma = ReglasApp.firma(app.url)
        app.equipo = firma.equipo
        app.grupos = firma.grupos
        let tamano = Papelera.tamano(app.url, cancelacion: cancelacion)
        let restos = BuscadorRestos.buscar(app, home: ReglasBorrado.casa, otraCopia: otraCopia, cancelacion: cancelacion)
        return AppPreparada(app: app, tamano: tamano, restos: restos, recibos: BuscadorRestos.recibos(app))
    }

    /// Vuelve a elegir. No hace nada mientras se cierran o se mueven apps (ese trabajo termina igual).
    func volver() {
        guard estado != .cerrando, estado != .desinstalando else { return }
        cancelacion?.cancelar()
        lote = []
        elegidos = []
        rechazos = []
        porCerrar = []
        resultado = nil
        appsMovidas = 0
        error = nil
        estado = .eligiendo
    }

    func alternar(_ resto: RestoApp) {
        guard !resto.pideAdministrador else { return }
        if elegidos.contains(resto.id) { elegidos.remove(resto.id) } else { elegidos.insert(resto.id) }
    }

    // MARK: - Desinstalar

    /// Primer paso (después de que la persona confirmó): si alguna app está abierta, pregunta una vez por todas.
    func desinstalar() {
        guard estado == .listo, !lote.isEmpty else { return }
        // Cada app tiene que ser la misma que se eligió (no reemplazada ni cambiada por un enlace).
        if let cambiada = lote.first(where: { !ReglasApp.sigueIgual($0.app) }) {
            error = T("\(cambiada.app.nombre) cambió desde que la elegiste. Elegila de nuevo.",
                      "\(cambiada.app.nombre) changed since you picked it. Pick it again.")
            return
        }
        error = nil
        let abiertas = lote.flatMap { abiertas($0.app) }
        if abiertas.isEmpty { seguir() } else { porCerrar = nombres(abiertas) }
    }

    /// La persona dijo que sí: se cierran todas (como con ⌘Q, así pueden guardar) y se sigue cuando terminaron.
    func cerrarYSeguir() {
        guard estado == .listo, !lote.isEmpty else { return }
        porCerrar = []
        let abiertas = lote.flatMap { abiertas($0.app) }
        abiertas.forEach { $0.terminate() }
        estado = .cerrando
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Espera hasta 15 s (una app puede preguntar si guardar). Si alguna no cierra, no se sigue con ninguna.
            let limite = Date().addingTimeInterval(15)
            while Date() < limite, abiertas.contains(where: { !$0.isTerminated }) { usleep(200_000) }
            let sinCerrar = abiertas.filter { !$0.isTerminated }
            DispatchQueue.main.async {
                guard let self else { return }
                if sinCerrar.isEmpty {
                    self.seguir()
                } else {
                    let cuales = self.nombres(sinCerrar).joined(separator: ", ")
                    self.estado = .listo
                    self.error = T("\(cuales) no se cerró. Cerrala vos y probá de nuevo.", "\(cuales) didn't quit. Quit it yourself and try again.")
                }
            }
        }
    }

    private func abiertas(_ app: AppElegida) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { abierta in
            let id = abierta.bundleIdentifier ?? ""
            let ruta = abierta.bundleURL?.path ?? ""
            return app.identificadores.contains(id) || ruta == app.url.path || ruta.hasPrefix(app.url.path + "/")
        }
    }

    private func nombres(_ abiertas: [NSRunningApplication]) -> [String] {
        var lista: [String] = []
        for nombre in abiertas.compactMap(\.localizedName) where !lista.contains(nombre) { lista.append(nombre) }
        return lista
    }

    private func seguir() {
        estado = .desinstalando
        let lote = self.lote
        var elementos: [ElementoBorrable] = []
        var etiquetas: [String] = []
        for preparada in lote {
            let suyos = mandables(preparada)
            etiquetas += suyos.compactMap(\.etiquetaAgente)
            elementos += suyos.map(\.elemento)
            let carpeta = preparada.app.url.deletingLastPathComponent().path
            let raiz = URL(fileURLWithPath: ReglasBorrado.realpath(carpeta) ?? "/", isDirectory: true)
            elementos.append(ElementoBorrable(url: preparada.app.url, raiz: raiz, identidad: preparada.app.identidadApp, tamano: preparada.tamano))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Los agentes salen de launchd antes de ir a la Papelera (si no, siguen corriendo hasta cerrar sesión).
            for etiqueta in etiquetas { ModeloDesinstalador.sacarDeLaunchd(etiqueta) }
            let hecho = Papelera.mandar(elementos)
            DispatchQueue.main.async {
                guard let self else { return }
                self.resultado = hecho
                self.quitarMovidos(hecho.movidos)
                self.estado = .terminado
            }
        }
    }

    /// Saca de la lista lo que ya está en la Papelera y cuenta las apps que llegaron.
    private func quitarMovidos(_ movidos: [ElementoBorrable]) {
        let rutas = Set(movidos.map(\.id))
        lote = lote.map { preparada in
            var quedan = preparada
            quedan.restos.removeAll { rutas.contains($0.id) }
            return quedan
        }
        elegidos.subtract(rutas)
        let todas = Set((resultado?.movidos ?? []).map(\.id))
        appsMovidas = lote.filter { todas.contains($0.id) }.count
    }

    /// Lo que macOS no dejó mover (una app instalada por el administrador) se le pasa a Finder.
    func pasarAFinder() {
        guard let pendientes = resultado?.sinPermiso, !pendientes.isEmpty, estado == .terminado else { return }
        estado = .desinstalando
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hecho = Papelera.pasarAFinder(pendientes)
            DispatchQueue.main.async {
                guard let self else { return }
                var total = self.resultado ?? Papelera.Resultado()
                total.movidos += hecho.movidos
                total.rechazados += hecho.rechazados
                total.sinPermiso = hecho.sinPermiso
                self.resultado = total
                self.quitarMovidos(hecho.movidos)
                self.estado = .terminado
            }
        }
    }

    /// `launchctl bootout gui/<uid>/<etiqueta>`, con argumentos separados (nunca un texto de shell). Si no estaba
    /// cargado, launchctl falla y no pasa nada: el archivo va igual a la Papelera.
    static func sacarDeLaunchd(_ etiqueta: String) {
        guard ReglasApp.esEtiqueta(etiqueta) else { return }
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proceso.arguments = ["bootout", "gui/\(getuid())/\(etiqueta)"]
        proceso.standardInput = FileHandle.nullDevice
        proceso.standardOutput = FileHandle.nullDevice
        proceso.standardError = FileHandle.nullDevice
        do { try proceso.run() } catch {
            NSLog("Alero: no se pudo correr launchctl para \(etiqueta): \(error.localizedDescription)")
            return
        }
        let limite = Date().addingTimeInterval(10)
        while proceso.isRunning, Date() < limite { usleep(50_000) }
        if proceso.isRunning { proceso.terminate() }
        if proceso.terminationStatus != 0 {
            NSLog("Alero: launchctl bootout \(etiqueta) terminó con \(proceso.terminationStatus) (puede que no estuviera cargado)")
        }
    }

    // MARK: - Muestras para `--capturas` (sin tocar el disco)

    /// Una app de ejemplo con sus restos (uno en `/Library`, que pide administrador) y un recibo.
    static func muestra() -> ModeloDesinstalador {
        let modelo = ModeloDesinstalador()
        let lib = "/Users/ejemplo/Library/"
        let datos: [(CarpetaRestos, String, Int64, String?)] = [
            (.soporte, "com.ejemplo.NotasRapidas", 96_000_000, nil),
            (.caches, "com.ejemplo.NotasRapidas", 41_000_000, nil),
            (.contenedores, "com.ejemplo.NotasRapidas.Compartir", 2_400_000, nil),
            (.grupos, "AB12CD34EF.com.ejemplo.compartido", 8_100_000, nil),
            (.preferencias, "com.ejemplo.NotasRapidas.plist", 12_000, nil),
            (.agentes, "com.ejemplo.NotasRapidas.ayudante.plist", 1_000, "com.ejemplo.NotasRapidas.ayudante"),
        ]
        var restos = datos.map { carpetaRestos, nombre, tamano, etiqueta in
            let url = URL(fileURLWithPath: lib + carpetaRestos.ruta + "/" + nombre)
            return RestoApp(elemento: ElementoBorrable(url: url, raiz: url.deletingLastPathComponent(), identidad: carpetaDeMuestra, tamano: tamano),
                            carpeta: carpetaRestos, etiquetaAgente: etiqueta, elegido: true, nota: nil)
        }
        let demonio = URL(fileURLWithPath: "/Library/LaunchDaemons/com.ejemplo.NotasRapidas.ayudante.plist")
        restos.append(RestoApp(elemento: ElementoBorrable(url: demonio, raiz: demonio.deletingLastPathComponent(), identidad: carpetaDeMuestra,
                                                          tamano: 1_000),
                               carpeta: .demoniosSistema, etiquetaAgente: nil, elegido: false, nota: T("Pide administrador", "Needs admin"),
                               pideAdministrador: true))
        var preparada = appDeMuestra("Notas Rápidas", id: "com.ejemplo.NotasRapidas", tamano: 184_000_000)
        preparada.app.equipo = "AB12CD34EF"
        preparada.app.grupos = ["AB12CD34EF.com.ejemplo.compartido"]
        preparada.restos = restos
        preparada.recibos = ["com.ejemplo.NotasRapidas.pkg"]
        modelo.lote = [preparada]
        modelo.elegidos = Set(restos.filter { !$0.pideAdministrador }.map(\.id))
        modelo.estado = .listo
        return modelo
    }

    /// Varias apps elegidas juntas, listas para mandar (y una que no se aceptó).
    static func muestraVarias() -> ModeloDesinstalador {
        let modelo = ModeloDesinstalador()
        let datos: [(String, String, Int64, Int64)] = [
            ("Notas Rápidas", "com.ejemplo.NotasRapidas", 184_000_000, 137_000_000),
            ("Radio Viva", "com.ejemplo.RadioViva", 412_000_000, 58_000_000),
            ("Planilla Simple", "com.ejemplo.Planilla", 96_000_000, 3_200_000),
        ]
        modelo.lote = datos.map { nombre, id, tamano, restos in
            var preparada = appDeMuestra(nombre, id: id, tamano: tamano)
            let url = URL(fileURLWithPath: "/Users/ejemplo/Library/Application Support/" + id)
            preparada.restos = [RestoApp(elemento: ElementoBorrable(url: url, raiz: url.deletingLastPathComponent(), identidad: carpetaDeMuestra,
                                                                    tamano: restos),
                                         carpeta: .soporte, etiquetaAgente: nil, elegido: true, nota: nil)]
            return preparada
        }
        modelo.elegidos = Set(modelo.restos.map(\.id))
        modelo.rechazos = [Rechazada(nombre: "Safari.app", motivo: RechazoApp.deApple.explicacion)]
        modelo.estado = .listo
        return modelo
    }

    /// Las mismas apps, con dos abiertas: pregunta una vez por todas.
    static func muestraVariasAbiertas() -> ModeloDesinstalador {
        let modelo = muestraVarias()
        modelo.rechazos = []
        modelo.porCerrar = ["Notas Rápidas", "Radio Viva"]
        return modelo
    }

    /// Las mismas apps, ya en la Papelera.
    static func muestraVariasTerminado() -> ModeloDesinstalador {
        let modelo = muestraVarias()
        modelo.rechazos = []
        var resultado = Papelera.Resultado()
        for preparada in modelo.lote {
            let carpeta = preparada.app.url.deletingLastPathComponent()
            resultado.movidos.append(ElementoBorrable(url: preparada.app.url, raiz: carpeta, identidad: carpetaDeMuestra, tamano: preparada.tamano))
            resultado.movidos += preparada.restos.map(\.elemento)
        }
        modelo.resultado = resultado
        modelo.quitarMovidos(resultado.movidos)
        modelo.estado = .terminado
        return modelo
    }

    /// La lista para elegir, con una app que no se aceptó.
    static func muestraLista() -> ModeloDesinstalador {
        let modelo = ModeloDesinstalador()
        modelo.apps = ["Cuaderno", "Diseñador", "Notas Rápidas", "Planilla Simple", "Radio Viva"].map {
            AppDeLista(url: URL(fileURLWithPath: "/Applications/\($0).app"), nombre: $0)
        }
        modelo.rechazos = [Rechazada(nombre: "Safari.app", motivo: RechazoApp.deApple.explicacion)]
        return modelo
    }

    private static let carpetaDeMuestra = IdentidadArchivo(dispositivo: 1, inodo: 1, tipo: S_IFDIR, modificado: nil, tamano: nil)

    private static func appDeMuestra(_ nombre: String, id: String, tamano: Int64) -> AppPreparada {
        let url = URL(fileURLWithPath: "/Applications/\(nombre).app")
        let app = AppElegida(url: url, identificador: id, nombre: nombre, version: "3.2.1", identidadApp: carpetaDeMuestra,
                             identidadPlist: carpetaDeMuestra, identificadores: [id, id + ".Compartir"])
        return AppPreparada(app: app, tamano: tamano, restos: [], recibos: [])
    }
}
