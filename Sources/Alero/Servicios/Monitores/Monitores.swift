import AppKit
import Combine

// El brillo de cada pantalla conectada, por el camino que acepte:
//  - integrada: la de la MacBook y los monitores de Apple, con DisplayServices (`Brillo`);
//  - DDC: los monitores comunes, por el cable (`CanalDDC`), como los botones del propio monitor;
//  - gamma: los que no aceptan DDC (adaptadores, teles), oscureciendo la imagen por software (`GammaPantallas`).
// Cada monitor se reconoce por fabricante:modelo:serie, no por su número de pantalla (se recicla al reconectar).
//
// Liviano: con la función apagada no hace nada. Prendida, lee las pantallas al arrancar, cuando cambian y al
// despertar (sin consultar a cada rato); el DDC solo se usa al mover un deslizador o una tecla, y al abrir la columna
// de sonido del notch para mostrar el brillo de verdad.
//
// Main thread, salvo `pasoTecla` (lo llaman las teclas desde el hilo de eventos).

enum MetodoBrillo: Equatable {
    case integrada, ddc, gamma, ninguno
    /// Todavía no se sabe: el monitor está dormido o se le está preguntando.
    case buscando

    var nombre: String {
        switch self {
        case .integrada: return T("Brillo de macOS", "macOS brightness")
        case .ddc: return T("DDC (el brillo del monitor)", "DDC (the monitor's own brightness)")
        case .gamma: return T("Atenuación por software", "Software dimming")
        case .ninguno: return T("Sin control", "Not adjustable")
        case .buscando: return T("Buscando…", "Checking…")
        }
    }

    var controlable: Bool { self == .integrada || self == .ddc || self == .gamma }
}

struct Monitor: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let huella: String
    let nombre: String
    /// La pantalla de la MacBook.
    let integrada: Bool
    var metodo: MetodoBrillo
    /// 0…1. Nil si todavía no se sabe.
    var nivel: Float?
}

final class Monitores: ObservableObject {
    static let shared = Monitores()

    @Published private(set) var lista: [Monitor] = []

    /// Hay algún monitor además de la MacBook (si no, la columna del notch no muestra la sección Pantallas).
    var hayExternos: Bool { lista.contains { !$0.integrada } }

    private var suscripciones = Set<AnyCancellable>()
    private var observadores: [NSObjectProtocol] = []
    private var activo = false
    private var simulado = false
    private var lectura = 0
    private var canales: [CGDirectDisplayID: CanalMonitor] = [:]
    private var maximos: [CGDirectDisplayID: UInt16] = [:]
    private let gamma = GammaPantallas()

    // Lo que leen las teclas desde el hilo de eventos y la cola de órdenes DDC pendientes, con candado.
    private let candado = NSLock()
    private var copia: [CGDirectDisplayID: (metodo: MetodoBrillo, nivel: Float?)] = [:]
    private var pendientes: [CGDirectDisplayID: Float] = [:]
    private var enviando: Set<CGDirectDisplayID> = []

    func arrancar() {
        Ajustes.shared.$brilloMonitores.removeDuplicates().sink { [weak self] prender in
            prender ? self?.prender() : self?.apagar()
        }.store(in: &suscripciones)
    }

    private func prender() {
        guard !activo, !simulado else { return }
        activo = true
        let centro = NotificationCenter.default
        observadores.append(centro.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leer()
        })
        // Al despertar, los monitores tardan en volver a contestar por DDC y macOS puede reponer la curva de colores.
        observadores.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil,
                                                                              queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.leer() }
        })
        leer()
    }

    private func apagar() {
        guard activo else { return }
        activo = false
        observadores.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observadores = []
        gamma.restaurarTodas()
        canales = [:]
        lista = []
        candado.lock()
        copia = [:]
        pendientes = [:]
        candado.unlock()
    }

    /// La columna de sonido del notch avisa cuando aparece: se vuelve a leer el brillo (pudo cambiar con los botones
    /// del monitor o con el Centro de control).
    func mirar() {
        guard activo else { return }
        for monitor in lista where monitor.metodo == .integrada {
            if let nivel = Brillo.actual(en: monitor.id) { actualizar(monitor.id, metodo: .integrada, nivel: nivel) }
        }
        for monitor in lista where monitor.metodo == .ddc || monitor.metodo == .buscando { preguntarDDC(monitor.id) }
    }

    // MARK: - Leer las pantallas

    private func leer() {
        guard activo else { return }
        lectura += 1
        let numero = lectura
        CanalDDC.cola.async { [weak self] in
            let canales = CanalDDC.canales()
            DispatchQueue.main.async { self?.armar(con: canales, lectura: numero) }
        }
    }

    private func armar(con canalesNuevos: [CanalMonitor], lectura numero: Int) {
        guard activo, numero == lectura else { return }
        let ids = Self.pantallasConectadas()
        let identidades = ids.map { id in
            IdentidadMonitor(fabricante: CGDisplayVendorNumber(id), modelo: CGDisplayModelNumber(id), serie: CGDisplaySerialNumber(id))
        }
        // Solo los externos que no son de Apple buscan canal DDC.
        let externos = ids.indices.filter { CGDisplayIsBuiltin(ids[$0]) == 0 }
        let pares = IdentidadMonitor.emparejar(pantallas: externos.map { identidades[$0] }, canales: canalesNuevos.map(\.identidad))
        canales = [:]
        for (posicion, canal) in pares { canales[ids[externos[posicion]]] = canalesNuevos[canal] }

        let anteriores = Dictionary(lista.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nuevos: [Monitor] = []
        for (i, id) in ids.enumerated() {
            let huella = identidades[i].huella
            let integrada = CGDisplayIsBuiltin(id) != 0
            var monitor = Monitor(id: id, huella: huella, nombre: Self.nombre(de: id, integrada: integrada), integrada: integrada,
                                  metodo: .buscando, nivel: nil)
            if let nivel = Brillo.actual(en: id) {
                monitor.metodo = .integrada
                monitor.nivel = nivel
            } else if canales[id] != nil, Ajustes.shared.datoMonitor("sinDDC", de: huella) as? Bool != true {
                // Mientras se pregunta, se muestra lo último que se supo.
                if let anterior = anteriores[id], anterior.huella == huella, anterior.metodo == .ddc { monitor = anterior }
            } else {
                monitor.metodo = .gamma
                monitor.nivel = ReglasBrillo.nivelAlReconectar((Ajustes.shared.datoMonitor("nivelGamma", de: huella) as? NSNumber)?.floatValue)
            }
            nuevos.append(monitor)
        }
        lista = nuevos
        candado.lock()
        copia = Dictionary(nuevos.map { ($0.id, (metodo: $0.metodo, nivel: $0.nivel)) }, uniquingKeysWith: { a, _ in a })
        candado.unlock()
        for monitor in nuevos {
            switch monitor.metodo {
            case .gamma:
                // Solo se toca la curva si había quedado atenuado: con 100 % no hay nada que hacer.
                if let nivel = monitor.nivel, nivel < 0.999 { aplicarGamma(monitor.id, huella: monitor.huella, nivel: nivel) }
            case .buscando, .ddc:
                preguntarDDC(monitor.id)
            default:
                break
            }
        }
    }

    /// Las pantallas conectadas, sin las copias de una pantalla espejada (se maneja la original).
    private static func pantallasConectadas() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var cantidad: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &cantidad) == .success else { return [] }
        return ids.prefix(Int(cantidad)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    private static func nombre(de id: CGDirectDisplayID, integrada: Bool) -> String {
        if let pantalla = NSScreen.screens.first(where: { $0.numero == id }) { return pantalla.localizedName }
        return integrada ? T("Pantalla de la MacBook", "MacBook display") : T("Monitor", "Display")
    }

    /// Lee el brillo por DDC. Si contesta, queda en DDC. Si no: dormido = se vuelve a probar al despertar; despierto
    /// = queda en DDC "sin lectura" y la primera orden decide (si el canal la rechaza, pasa a gamma).
    private func preguntarDDC(_ id: CGDirectDisplayID) {
        guard let canal = canales[id] else { return }
        CanalDDC.cola.async { [weak self] in
            let brillo = CanalDDC.leerBrillo(canal)
            let dormido = CGDisplayIsAsleep(id) != 0
            DispatchQueue.main.async {
                guard let self, self.activo, self.canales[id]?.identidad == canal.identidad else { return }
                if let brillo {
                    self.maximos[id] = brillo.maximo
                    self.actualizar(id, metodo: .ddc, nivel: ProtocoloDDC.nivel(de: brillo.actual, maximo: brillo.maximo))
                } else if !dormido, self.lista.first(where: { $0.id == id })?.metodo == .buscando {
                    self.actualizar(id, metodo: .ddc, nivel: nil)
                }
            }
        }
    }

    private func actualizar(_ id: CGDirectDisplayID, metodo: MetodoBrillo, nivel: Float?) {
        guard let i = lista.firstIndex(where: { $0.id == id }) else { return }
        lista[i].metodo = metodo
        lista[i].nivel = nivel
        candado.lock()
        copia[id] = (metodo, nivel)
        candado.unlock()
    }

    // MARK: - Cambiar el brillo

    /// Desde el deslizador del notch (0…1).
    func poner(_ id: CGDirectDisplayID, nivel: Float) {
        guard activo, let i = lista.firstIndex(where: { $0.id == id }), lista[i].metodo.controlable else { return }
        let nivel = min(max(nivel, 0), 1)
        let monitor = lista[i]
        actualizar(id, metodo: monitor.metodo, nivel: nivel)
        switch monitor.metodo {
        case .integrada: Brillo.poner(nivel, en: id)
        case .ddc: encolarDDC(id, nivel: nivel)
        case .gamma: aplicarGamma(id, huella: monitor.huella, nivel: nivel)
        default: break
        }
    }

    /// Las teclas de brillo, desde el hilo de eventos: sube o baja un paso la pantalla dada y devuelve el valor nuevo
    /// (para el aviso del notch). Nil si esa pantalla no se puede manejar desde Alero (la tecla sigue a macOS).
    func pasoTecla(_ id: CGDirectDisplayID, delta: Float, paso: Float) -> Float? {
        candado.lock()
        guard let actual = copia[id], actual.metodo.controlable else { candado.unlock(); return nil }
        let base = actual.metodo == .integrada ? (Brillo.actual(en: id) ?? actual.nivel ?? 1) : (actual.nivel ?? 1)
        let nuevo = TeclasMedia.redondear(base + delta, paso: paso)
        copia[id] = (actual.metodo, nuevo)
        candado.unlock()
        if actual.metodo == .integrada {
            // DisplayServices se puede llamar desde este hilo (como la pantalla de la MacBook).
            guard Brillo.poner(nuevo, en: id) else { return nil }
            DispatchQueue.main.async { self.actualizar(id, metodo: .integrada, nivel: nuevo) }
        } else {
            DispatchQueue.main.async { self.poner(id, nivel: nuevo) }
        }
        return nuevo
    }

    /// El arrastre de un deslizador manda decenas de valores: se guarda solo el último por monitor y la cola de DDC lo
    /// manda cuando le toca (50 ms entre órdenes). Al terminar se repite el último una vez: algunos monitores pierden
    /// una orden suelta.
    private func encolarDDC(_ id: CGDirectDisplayID, nivel: Float) {
        guard let canal = canales[id] else { return }
        let maximo = maximos[id] ?? 100
        candado.lock()
        pendientes[id] = nivel
        let yaEnviando = !enviando.insert(id).inserted
        candado.unlock()
        guard !yaEnviando else { return }
        CanalDDC.cola.async { [weak self] in
            guard let self else { return }
            var ultimo: UInt16?
            while true {
                self.candado.lock()
                let siguiente = self.pendientes.removeValue(forKey: id)
                self.candado.unlock()
                if let siguiente {
                    let valor = ProtocoloDDC.valor(de: siguiente, maximo: maximo)
                    guard CanalDDC.escribirBrillo(canal, valor: valor) else {
                        self.candado.lock()
                        self.enviando.remove(id)
                        self.pendientes.removeValue(forKey: id)
                        self.candado.unlock()
                        DispatchQueue.main.async { self.pasarAGamma(id, nivel: siguiente) }
                        return
                    }
                    ultimo = valor
                    continue
                }
                // Nada pendiente: se repite el último una vez y se termina (salvo que haya llegado otro en el medio).
                if let repetir = ultimo {
                    _ = CanalDDC.escribirBrillo(canal, valor: repetir)
                    ultimo = nil
                }
                self.candado.lock()
                let terminado = self.pendientes[id] == nil
                if terminado { self.enviando.remove(id) }
                self.candado.unlock()
                if terminado { return }
            }
        }
    }

    /// El canal rechazó la orden: el monitor (o el adaptador) no acepta DDC. Se recuerda y pasa a gamma.
    private func pasarAGamma(_ id: CGDirectDisplayID, nivel: Float) {
        guard let monitor = lista.first(where: { $0.id == id }) else { return }
        NSLog("Alero: \(monitor.nombre) no acepta DDC; se atenúa por software")
        Ajustes.shared.guardarDatoMonitor(true, "sinDDC", de: monitor.huella)
        actualizar(id, metodo: .gamma, nivel: nivel)
        aplicarGamma(id, huella: monitor.huella, nivel: nivel)
    }

    private func aplicarGamma(_ id: CGDirectDisplayID, huella: String, nivel: Float) {
        if gamma.aplicar(nivel, en: id, huella: huella) {
            Ajustes.shared.guardarDatoMonitor(nivel < 0.999 ? Double(nivel) : nil, "nivelGamma", de: huella)
        } else {
            actualizar(id, metodo: .ninguno, nivel: nil)
        }
    }

    /// Al cerrar Alero, la curva de colores vuelve a la original (macOS también lo hace al terminar el proceso).
    func terminar() {
        gamma.restaurarTodas()
    }

    // MARK: - Capturas

    /// Solo para `--capturas`: pantallas de ejemplo sin tocar ninguna.
    func simular(_ ejemplo: [Monitor]) {
        simulado = true
        lista = ejemplo
    }
}

/// La atenuación por software: la curva de colores de la pantalla (gamma) multiplicada por un factor. La curva
/// original de cada monitor se lee una sola vez, antes de atenuarlo, y se guarda por su huella: nunca se lee una curva
/// atenuada. Main thread.
final class GammaPantallas {
    private struct Curva { let rojo: [CGGammaValue]; let verde: [CGGammaValue]; let azul: [CGGammaValue] }
    private var originales: [String: Curva] = [:]
    private var atenuadas: [CGDirectDisplayID: String] = [:]

    func aplicar(_ nivel: Float, en id: CGDirectDisplayID, huella: String) -> Bool {
        if originales[huella] == nil {
            guard let curva = leer(id) else { return false }
            originales[huella] = curva
        }
        guard let curva = originales[huella] else { return false }
        let factor = ReglasBrillo.factorGamma(nivel)
        let r = ReglasBrillo.escalar(curva.rojo, factor: factor)
        let g = ReglasBrillo.escalar(curva.verde, factor: factor)
        let b = ReglasBrillo.escalar(curva.azul, factor: factor)
        guard CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b) == .success else { return false }
        if factor < 0.999 { atenuadas[id] = huella } else { atenuadas.removeValue(forKey: id) }
        return true
    }

    func restaurarTodas() {
        for (id, huella) in atenuadas {
            guard let curva = originales[huella] else { continue }
            CGSetDisplayTransferByTable(id, UInt32(curva.rojo.count), curva.rojo, curva.verde, curva.azul)
        }
        atenuadas = [:]
    }

    private func leer(_ id: CGDirectDisplayID) -> Curva? {
        let capacidad = CGDisplayGammaTableCapacity(id)
        guard capacidad > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacidad))
        var g = r
        var b = r
        var cantidad: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacidad, &r, &g, &b, &cantidad) == .success, cantidad > 0 else { return nil }
        return Curva(rojo: Array(r.prefix(Int(cantidad))), verde: Array(g.prefix(Int(cantidad))), azul: Array(b.prefix(Int(cantidad))))
    }
}
