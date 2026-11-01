import AppKit
import Combine

// Acomodar ventanas (Herramientas › Ventanas). Con la llave prendida:
// - arrastrás una ventana contra un costado, una esquina o arriba y queda en esa mitad, ese cuarto o en toda la
//   pantalla (mientras la llevás, una vista previa muestra dónde va a quedar);
// - en lo que queda libre, Alero ofrece las otras ventanas abiertas: tocás una y va ahí (hasta cuatro);
// - al pasar el mouse por la unión entre dos ventanas acomodadas aparece una manija: arrastrándola, las dos (o
//   las cuatro) cambian de tamaño juntas.
// El mouse se mira con escuchas globales de AppKit, que solo leen: nunca frenan ni cambian un clic. Lo de
// Accesibilidad (encontrar la ventana, moverla) va en `AX.cola`; el resto, en el hilo principal. Las cuentas están
// en `ReglasMosaico` y las ventanitas (vista previa, "¿Qué va acá?" y la manija) en `PanelesMosaico`.
// Una ventana sale de su grupo si la movés o la cambiás de tamaño a mano, la cerrás, la minimizás o la ocultás.

final class Mosaico {
    static let shared = Mosaico()

    /// Una ventana acomodada por Alero.
    struct Miembro {
        let id: CGWindowID
        let pid: pid_t
        let ventana: AXUIElement
        var zona: ZonaMosaico
        /// Cómo quedó de verdad (algunas apps redondean el tamaño): sirve para notar si la movieron a mano.
        var quedo: CGRect
    }

    /// Las ventanas acomodadas en una pantalla y dónde están sus barras.
    struct Grupo {
        var pantalla: PantallaCG
        var divisiones = Divisiones()
        var miembros: [Miembro] = []
        var ocupadas: [ZonaMosaico] { miembros.map(\.zona) }
    }

    /// Una ventana que se está llevando con el mouse.
    private struct Arrastre {
        let id: CGWindowID
        let pid: pid_t
        let inicial: CGRect
        var actual: CGRect
        var moviendo = false
        var zona: ZonaMosaico?
        var pantalla: PantallaCG?
    }

    private var suscripciones = Set<AnyCancellable>()
    private var monitor: Any?
    private var arrastre: Arrastre?
    private var ultimaMirada: CFTimeInterval = 0
    private var grupos: [Grupo] = []
    private var revision: Timer?
    private let paneles = PanelesMosaico()
    // Mientras se arrastra una barra, se manda a mover una tanda por vez; si llegan más, queda la última.
    private var aplicando = false
    private var pendiente: PantallaCG?

    /// La llama `Delegado` al arrancar, una vez.
    func arrancar() {
        Pantallas.shared.arrancar()
        Ajustes.shared.$mosaico.removeDuplicates()
            .sink { [weak self] prender in self?.prender(prender) }
            .store(in: &suscripciones)
    }

    private func prender(_ prender: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard prender else {
            MosaicoDeMacOS.devolver()
            arrastre = nil
            grupos = []
            vigilar()
            paneles.cerrarTodo()
            return
        }
        MosaicoDeMacOS.apagar()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] evento in
            self?.recibir(evento)
        }
    }

    /// El puntero en coordenadas de eventos (origen arriba a la izquierda de la pantalla principal).
    static func puntero() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    private func recibir(_ evento: NSEvent) {
        let p = Mosaico.puntero()
        switch evento.type {
        case .leftMouseDown: empezar(en: p)
        case .leftMouseDragged: seguir(en: p)
        case .leftMouseUp: soltar()
        case .mouseMoved: mirarBarras(en: p)
        default: break
        }
    }

    // MARK: - Llevar una ventana a un borde

    /// Un clic en otra app: cierra "¿Qué va acá?" y, si fue en la barra de arriba de una ventana, puede ser el
    /// comienzo de un arrastre (se confirma en `seguir`, cuando la ventana se corre sin cambiar de tamaño).
    private func empezar(en p: CGPoint) {
        paneles.cerrarAsistente()
        arrastre = nil
        guard let v = VentanasVisibles.bajo(p), p.y - v.marco.minY <= 60 else { return }
        arrastre = Arrastre(id: v.id, pid: v.pid, inicial: v.marco, actual: v.marco)
    }

    private func seguir(en p: CGPoint) {
        guard var a = arrastre else { return }
        if !a.moviendo {
            // Preguntarle al servidor de ventanas en cada movimiento es caro: como mucho cada 50 ms.
            let ahora = CACurrentMediaTime()
            guard ahora - ultimaMirada > 0.05 else { return }
            ultimaMirada = ahora
            guard let marco = VentanasVisibles.marco(de: a.id) else { arrastre = nil; return }
            a.actual = marco
            let corrida = hypot(marco.minX - a.inicial.minX, marco.minY - a.inicial.minY) > 4
            let mismoTamano = abs(marco.width - a.inicial.width) < 2 && abs(marco.height - a.inicial.height) < 2
            guard corrida else { arrastre = a; return }
            // Se agranda desde un borde, no se mueve: no es para acá.
            guard mismoTamano else { arrastre = nil; return }
            a.moviendo = true
            sacar(a.id)
        }
        let pantalla = Pantallas.shared.actuales.first { $0.marco.insetBy(dx: -2, dy: -2).contains(p) }
        let zona = pantalla.flatMap { ReglasMosaico.zona(en: p, pantalla: $0) }
        if zona != a.zona || pantalla != a.pantalla {
            a.zona = zona
            a.pantalla = pantalla
            if let zona, let pantalla { paneles.mostrarVistaPrevia(marco(zona, en: pantalla)) } else { paneles.ocultarVistaPrevia() }
        }
        arrastre = a
    }

    private func soltar() {
        paneles.ocultarVistaPrevia()
        guard let a = arrastre, a.moviendo, let zona = a.zona, let pantalla = a.pantalla else { arrastre = nil; return }
        arrastre = nil
        let destino = marco(zona, en: pantalla)
        // Se mira dónde quedó un instante después de soltar: la app termina de moverla sola.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let suelta = VentanasVisibles.marco(de: a.id) ?? a.actual
            AX.cola.async {
                guard let ventana = Mosaico.ventanaAX(pid: a.pid, marco: suelta) else { return }
                Mosaico.colocar(ventana, pid: a.pid, en: destino) { quedo in
                    DispatchQueue.main.async {
                        self?.sumar(Miembro(id: a.id, pid: a.pid, ventana: ventana, zona: zona, quedo: quedo), en: pantalla)
                    }
                }
            }
        }
    }

    /// El rectángulo de una zona en una pantalla, con las barras donde las dejó su grupo (si tiene).
    private func marco(_ zona: ZonaMosaico, en pantalla: PantallaCG) -> CGRect {
        let divisiones = grupos.first { $0.pantalla == pantalla }?.divisiones ?? Divisiones()
        return ReglasMosaico.marco(zona, en: pantalla.visible, divisiones: divisiones)
    }

    // MARK: - Grupos

    /// Suma una ventana recién acomodada a su grupo (las que tapa salen) y ofrece lo que quedó libre.
    private func sumar(_ miembro: Miembro, en pantalla: PantallaCG) {
        let i: Int
        if let existente = grupos.firstIndex(where: { $0.pantalla == pantalla }) {
            i = existente
        } else {
            grupos.append(Grupo(pantalla: pantalla))
            i = grupos.count - 1
        }
        grupos[i].miembros.removeAll { $0.id == miembro.id || ReglasMosaico.sePisan($0.zona, miembro.zona) }
        grupos[i].miembros.append(miembro)
        vigilar()
        ofrecerLibre(grupos[i])
    }

    /// Una ventana que se empezó a mover sale de su grupo; los grupos vacíos se olvidan (y sus barras vuelven al medio).
    private func sacar(_ id: CGWindowID) {
        for i in grupos.indices { grupos[i].miembros.removeAll { $0.id == id } }
        grupos.removeAll { $0.miembros.isEmpty }
        vigilar()
    }

    /// Cada segundo, mientras haya grupos: las ventanas que ya no están a la vista o que se movieron a mano salen.
    private func vigilar() {
        if grupos.isEmpty {
            revision?.invalidate()
            revision = nil
            paneles.ocultarBarra()
            return
        }
        guard revision == nil else { return }
        revision = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.revisar() }
    }

    private func revisar() {
        guard arrastre == nil, !paneles.arrastrandoBarra, !aplicando else { return }
        var marcos: [CGWindowID: CGRect] = [:]
        for v in VentanasVisibles.todas() { marcos[v.id] = v.marco }
        for i in grupos.indices {
            grupos[i].miembros.removeAll { m in
                guard let marco = marcos[m.id] else { return true }
                return !Geometria.parecidos(marco, m.quedo, tolerancia: 10)
            }
        }
        grupos.removeAll { $0.miembros.isEmpty }
        vigilar()
    }

    // MARK: - ¿Qué va acá?

    private func ofrecerLibre(_ grupo: Grupo) {
        guard let libre = ReglasMosaico.libre(ocupadas: grupo.ocupadas) else { paneles.cerrarAsistente(); return }
        let acomodadas = Set(grupos.flatMap { $0.miembros.map(\.id) })
        let candidatas = VentanasVisibles.todas().filter { !acomodadas.contains($0.id) }
        guard !candidatas.isEmpty else { paneles.cerrarAsistente(); return }
        let pantalla = grupo.pantalla
        paneles.mostrarAsistente(en: marco(libre, en: pantalla), candidatas: Array(candidatas.prefix(8))) { [weak self] elegida in
            self?.poner(elegida, en: libre, pantalla: pantalla)
        }
    }

    private func poner(_ v: VentanaVisible, en zona: ZonaMosaico, pantalla: PantallaCG) {
        let destino = marco(zona, en: pantalla)
        AX.cola.async { [weak self] in
            guard let ventana = Mosaico.ventanaAX(pid: v.pid, marco: v.marco) else { return }
            Mosaico.traerAdelante(ventana, pid: v.pid)
            Mosaico.colocar(ventana, pid: v.pid, en: destino) { quedo in
                DispatchQueue.main.async {
                    self?.sumar(Miembro(id: v.id, pid: v.pid, ventana: ventana, zona: zona, quedo: quedo), en: pantalla)
                }
            }
        }
    }

    // MARK: - Barras

    /// Con el mouse sobre la unión entre dos ventanas acomodadas (y esas ventanas a la vista a los dos lados),
    /// aparece la manija justo ahí.
    private func mirarBarras(en p: CGPoint) {
        guard !paneles.arrastrandoBarra, arrastre == nil else { return }
        for grupo in grupos {
            let ids = Set(grupo.miembros.map(\.id))
            for barra in ReglasMosaico.barras(ocupadas: grupo.ocupadas, en: grupo.pantalla.visible, divisiones: grupo.divisiones) {
                let cerca = barra.linea.insetBy(dx: barra.vertical ? -5 : 0, dy: barra.vertical ? 0 : -5)
                guard cerca.contains(p) else { continue }
                // Que no haya otra ventana encima de la unión: las de los dos lados tienen que ser del grupo.
                let lados = barra.vertical ? [CGPoint(x: p.x - 12, y: p.y), CGPoint(x: p.x + 12, y: p.y)]
                                           : [CGPoint(x: p.x, y: p.y - 12), CGPoint(x: p.x, y: p.y + 12)]
                guard lados.allSatisfy({ VentanasVisibles.bajo($0).map { ids.contains($0.id) } == true }) else { continue }
                let pantalla = grupo.pantalla
                paneles.mostrarBarra(barra, en: p) { [weak self] punto, final in
                    self?.moverBarra(barra, en: pantalla, hasta: punto, final: final)
                }
                return
            }
        }
    }

    /// La manija se arrastra: se corre la división y se reacomodan todas las ventanas del grupo.
    private func moverBarra(_ barra: BarraMosaico, en pantalla: PantallaCG, hasta p: CGPoint, final: Bool) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        let fraccion = ReglasMosaico.fraccion(barra, hasta: p, en: pantalla.visible)
        if barra.vertical { grupos[i].divisiones.x = fraccion } else { grupos[i].divisiones.y = fraccion }
        aplicar(pantalla)
    }

    private func aplicar(_ pantalla: PantallaCG) {
        if aplicando { pendiente = pantalla; return }
        guard let grupo = grupos.first(where: { $0.pantalla == pantalla }) else { return }
        aplicando = true
        let tanda = grupo.miembros.map { m in
            (m, ReglasMosaico.marco(m.zona, en: pantalla.visible, divisiones: grupo.divisiones))
        }
        AX.cola.async { [weak self] in
            let quedaron = tanda.map { m, marco -> CGRect? in
                Mosaico.ponerMarco(m.ventana, pid: m.pid, marco)
                return AX.marco(m.ventana)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.aplicando = false
                if let i = self.grupos.firstIndex(where: { $0.pantalla == pantalla }) {
                    for ((m, _), quedo) in zip(tanda, quedaron) {
                        if let quedo, let j = self.grupos[i].miembros.firstIndex(where: { $0.id == m.id }) {
                            self.grupos[i].miembros[j].quedo = quedo
                        }
                    }
                }
                if let otra = self.pendiente {
                    self.pendiente = nil
                    self.aplicar(otra)
                }
            }
        }
    }

    // MARK: - Accesibilidad (en `AX.cola`)

    /// La ventana de Accesibilidad de `pid` que está en `marco` (la lista del servidor de ventanas no da el elemento).
    static func ventanaAX(pid: pid_t, marco: CGRect) -> AXUIElement? {
        AX.elementos(AX.app(pid), kAXWindowsAttribute).first { ventana in
            AX.marco(ventana).map { Geometria.parecidos($0, marco, tolerancia: 8) } == true
                && AX.booleano(ventana, "AXFullScreen") != true && AX.sePuedeCambiar(ventana, kAXSizeAttribute)
        }
    }

    /// Mueve y agranda una ventana. Las apps con la "interfaz mejorada" de Accesibilidad prendida ignoran el tamaño:
    /// se apaga un momento y se vuelve a prender (como en `Maximizar`).
    static func ponerMarco(_ ventana: AXUIElement, pid: pid_t, _ marco: CGRect) {
        let app = AX.app(pid)
        let mejorada = AX.booleano(app, "AXEnhancedUserInterface") == true
        if mejorada { AX.poner(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        AX.ponerMarco(ventana, marco)
        if mejorada { AX.poner(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    /// Como `ponerMarco`, pero mira a los 0,15 s si quedó y, si la app la corrigió, insiste hasta dos veces.
    /// `listo` recibe cómo quedó de verdad.
    static func colocar(_ ventana: AXUIElement, pid: pid_t, en marco: CGRect, intento: Int = 0, listo: @escaping (CGRect) -> Void) {
        ponerMarco(ventana, pid: pid, marco)
        AX.cola.asyncAfter(deadline: .now() + 0.15) {
            let ahora = AX.marco(ventana) ?? marco
            if !Geometria.parecidos(ahora, marco) && intento < 2 {
                colocar(ventana, pid: pid, en: marco, intento: intento + 1, listo: listo)
            } else {
                listo(ahora)
            }
        }
    }

    static func traerAdelante(_ ventana: AXUIElement, pid: pid_t) {
        AX.poner(ventana, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(ventana, kAXRaiseAction as CFString)
        DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
    }
}

// MARK: - Ventanas a la vista

/// Una ventana común de otra app, según el servidor de ventanas.
struct VentanaVisible: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let marco: CGRect
    let app: String
    /// Vacío si macOS no lo da (sin el permiso de Grabación de pantalla).
    let titulo: String
}

/// La lista de ventanas del servidor de ventanas (sin Accesibilidad: es barata). Cualquier hilo.
enum VentanasVisibles {
    /// Las ventanas comunes a la vista en este escritorio, de adelante hacia atrás, sin las de Alero ni del Dock.
    /// Solo las que tocan alguna pantalla: hay apps que guardan una ventana escondida lejos (Dixity, en -20000).
    static func todas() -> [VentanaVisible] {
        let pantallas = Pantallas.shared.actuales
        return lista().compactMap { comun($0) }.filter { v in pantallas.contains { $0.marco.intersects(v.marco) } }
    }

    /// La ventana común que está más adelante en `p`, o nil si lo de más adelante es otra cosa (un menú, la barra
    /// de menús). Las ventanas de Alero no cuentan: la del notch es invisible, no recibe clics y ocupa una franja
    /// ancha arriba de cada pantalla (justo donde están las barras de título de las ventanas grandes).
    static func bajo(_ p: CGPoint) -> VentanaVisible? {
        for info in lista() {
            guard let marco = marcoDeVentana(info), marco.contains(p) else { continue }
            let alfa = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alfa == 0 { continue }
            if (info[kCGWindowOwnerPID as String] as? NSNumber).map({ Int64($0.int32Value) == MarcaPropia.proceso }) == true { continue }
            // La ventana transparente del Dock en macOS 26 (ver `BotonVerde.ventanaCandidata`) no tapa nada.
            if info[kCGWindowOwnerName as String] as? String == "Dock" { continue }
            return comun(info)
        }
        return nil
    }

    static func marco(de id: CGWindowID) -> CGRect? {
        guard let lista = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = lista.first else { return nil }
        return marcoDeVentana(info)
    }

    private static func lista() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// Solo ventanas comunes (capa 0) de buen tamaño y de otra app.
    private static func comun(_ info: [String: Any]) -> VentanaVisible? {
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, Int64(pid) != MarcaPropia.proceso,
              let marco = marcoDeVentana(info), marco.width >= 120, marco.height >= 80,
              ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { return nil }
        let app = info[kCGWindowOwnerName as String] as? String ?? ""
        if app == "Dock" { return nil }
        return VentanaVisible(id: id, pid: pid, marco: marco, app: app, titulo: info[kCGWindowName as String] as? String ?? "")
    }
}

// MARK: - El acomodo propio de macOS

/// El acomodo de ventanas de macOS 15 y más nuevos, prendido de fábrica: arrastrarlas a los costados
/// (`EnableTilingByEdgeDrag`) o a la barra de menús (`EnableTopTilingByEdgeDrag`). Con los dos a la vez, cada uno
/// muestra su vista previa y acomoda a su manera: por eso `Mosaico` lo apaga al prenderse y lo devuelve como estaba al
/// apagarse. El de mantener ⌥ no se pisa con Alero y no se toca.
enum MosaicoDeMacOS {
    private static let dominio = "com.apple.WindowManager" as CFString
    private static let claves = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]
    /// Cómo estaban las dos opciones antes de que Alero las apagara (en los ajustes de Alero).
    private static let antes = "ventanas.macOSAntes"

    /// Si alguna de las dos sigue prendida (la página lo avisa).
    static var prendido: Bool {
        guard #available(macOS 15, *) else { return false }
        CFPreferencesAppSynchronize(dominio)
        return claves.contains(where: valor)
    }

    /// Al prender "Acomodar ventanas" (y al abrir Alero con eso prendido): anota cómo estaban, la primera vez, y las apaga.
    static func apagar() {
        guard #available(macOS 15, *) else { return }
        CFPreferencesAppSynchronize(dominio)
        if UserDefaults.standard.dictionary(forKey: antes) == nil {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: claves.map { ($0, valor($0)) }), forKey: antes)
        }
        claves.forEach { escribir($0, false) }
    }

    /// Al apagar "Acomodar ventanas": las deja como estaban antes de que Alero las tocara.
    static func devolver() {
        guard let guardado = UserDefaults.standard.dictionary(forKey: antes) as? [String: Bool] else { return }
        for (clave, valor) in guardado where claves.contains(clave) { escribir(clave, valor) }
        UserDefaults.standard.removeObject(forKey: antes)
    }

    static func abrirAjustes() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Sin la clave guardada, macOS la toma como prendida.
    private static func valor(_ clave: String) -> Bool {
        CFPreferencesCopyAppValue(clave as CFString, dominio) as? Bool ?? true
    }

    private static func escribir(_ clave: String, _ valor: Bool) {
        CFPreferencesSetAppValue(clave as CFString, valor as CFBoolean, dominio)
        CFPreferencesAppSynchronize(dominio)
    }
}
