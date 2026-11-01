import AppKit
import Combine

// Clic en el ícono del Dock de la app que ya está al frente: si tiene varias ventanas y la opción está prendida, trae
// la siguiente; si no, la minimiza (u oculta, según el ajuste) y otro clic la vuelve a mostrar en el mismo orden. Clics con modificadoras, arrastres de íconos, el menú (mantener apretado) y el
// Dock que se oculta solo siguen como en macOS. Necesita Accesibilidad.
//
// Cómo: el Down sobre la franja del Dock se traga y queda pendiente mientras `AX.cola` averigua de qué app es el
// ícono (la escucha no espera). Si no es para Alero, el Down vuelve al Dock apenas se sabe; también si se arrastra
// más de 6 pt o se mantiene medio segundo. Si es, se actúa al soltar y el Dock nunca ve el clic: si lo viera,
// volvería a activar la app al minimizarla o abriría una ventana nueva al restaurarla.

/// Qué hacer con la app de un ícono. Lo decide `VentanasApp` en la cola de Accesibilidad.
struct ObjetivoDock {
    enum Accion {
        /// Ventanas a minimizar, de adelante hacia atrás.
        case minimizar([AXUIElement])
        case ocultar
        case restaurar
        /// Traer al frente esta ventana (la de más atrás): con varias ventanas, cada clic pasa a la siguiente.
        case siguiente(AXUIElement)
    }

    let app: NSRunningApplication
    let accion: Accion
}

final class ClicDock: ManejadorClics {
    static let shared = ClicDock()

    private var suscripciones = Set<AnyCancellable>()

    // Todo lo de abajo, solo en el hilo de eventos.
    private var prendido = false
    private var modo: ModoDock = .minimizar
    private var alternar = true
    private var estado: Estado = .libre
    /// Cada clic tragado lleva un número: una respuesta de la cola que llega tarde (de un clic viejo) se descarta.
    private var numero = 0
    private var ultimaAccion: CFTimeInterval = 0

    private struct Pendiente {
        let numero: Int
        let abajo: CGEvent
        let punto: CGPoint
        var resuelto = false
        var objetivo: ObjetivoDock?
        /// El Up, si llegó antes que la respuesta de la cola.
        var arriba: CGEvent?
    }

    private enum Estado {
        case libre
        case esperando(Pendiente)
        /// El Down ya volvió al Dock: el resto del clic pasa sin tocar.
        case pasando
        /// Doble clic justo después de una acción: se tira entero (si no, deshace lo que se acaba de hacer).
        case descartando
    }

    func arrancar() {
        Pantallas.shared.arrancar()
        EscuchaClics.shared.sumar(self)
        let ajustes = Ajustes.shared
        ajustes.$dockMinimizar.combineLatest(ajustes.$dockModo, ajustes.$dockAlternarVentanas)
            .sink { [weak self] prender, modo, alternar in
                HiloEventos.shared.ejecutar {
                    self?.prendido = prender
                    self?.modo = modo
                    self?.alternar = alternar
                }
                EscuchaClics.shared.revisar()
            }
            .store(in: &suscripciones)
    }

    // MARK: - En el hilo de eventos

    var mascara: CGEventMask {
        let resto = CGEventType.leftMouseDragged.bit | CGEventType.leftMouseUp.bit
        if prendido { return CGEventType.leftMouseDown.bit | resto }
        if case .libre = estado { return 0 }
        return resto
    }

    func manejar(_ tipo: CGEventType, _ evento: CGEvent, proxy: CGEventTapProxy) -> DecisionClic {
        switch tipo {
        case .leftMouseDown: return bajar(evento)
        case .leftMouseDragged: return arrastrar(evento, proxy)
        case .leftMouseUp: return soltar(evento)
        default: return .seguir
        }
    }

    func alReanudar() {
        // Si el botón ya no está apretado, el Up se perdió mientras la escucha estaba cortada.
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        if case .libre = estado { return }
        estado = .libre
        drenado()
    }

    private func bajar(_ evento: CGEvent) -> DecisionClic {
        guard prendido, case .libre = estado else { return .seguir }
        // Con ⌘, ⌥, ⌃ o ⇧ el Dock hace cosas propias (mostrar en Finder, ocultar las demás, menú): no se tocan.
        guard evento.flags.intersection(Teclado.modificadores).isEmpty else { return .seguir }
        let punto = evento.location
        guard let franja = Geometria.franjasDock(Pantallas.shared.actuales).first(where: { $0.zona.contains(punto) }),
              ClicDock.esDelDock(punto) else { return .seguir }
        let dobleClic = evento.getIntegerValueField(.mouseEventClickState) >= 2
        if dobleClic && CACurrentMediaTime() - ultimaAccion < 0.5 {
            estado = .descartando
            return .tragar
        }
        guard let abajo = evento.copy() else { return .seguir }
        numero += 1
        let esteClic = numero
        let modoElegido = modo
        let alternarElegido = alternar
        estado = .esperando(Pendiente(numero: esteClic, abajo: abajo, punto: punto))
        AX.cola.async { [weak self] in
            let objetivo = ClicDock.resolver(punto, horizontal: franja.horizontal, modo: modoElegido, alternar: alternarElegido)
            HiloEventos.shared.ejecutar { self?.resuelto(esteClic, objetivo) }
        }
        // Mantener apretado abre el menú del ícono: a los 0,5 s sin soltar, el clic vuelve al Dock.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            HiloEventos.shared.ejecutar { self?.mantenido(esteClic) }
        }
        return .tragar
    }

    private func arrastrar(_ evento: CGEvent, _ proxy: CGEventTapProxy) -> DecisionClic {
        switch estado {
        case .esperando(let pendiente):
            let movido = hypot(evento.location.x - pendiente.punto.x, evento.location.y - pendiente.punto.y)
            guard movido > 6 else { return .tragar }
            // Es un arrastre de ícono: el Down vuelve justo delante de este movimiento y el Dock arrastra como siempre.
            copiaMarcada(pendiente.abajo, tipo: .leftMouseDown)?.tapPostEvent(proxy)
            estado = .pasando
            return .seguir
        case .descartando:
            return .tragar
        case .libre, .pasando:
            return .seguir
        }
    }

    private func soltar(_ evento: CGEvent) -> DecisionClic {
        switch estado {
        case .esperando(var pendiente):
            pendiente.arriba = evento.copy()
            if pendiente.resuelto {
                terminar(pendiente)
            } else {
                estado = .esperando(pendiente)
            }
            return .tragar
        case .pasando:
            estado = .libre
            drenado()
            return .seguir
        case .descartando:
            estado = .libre
            drenado()
            return .tragar
        case .libre:
            return .seguir
        }
    }

    /// Llega la respuesta de la cola: nil = el clic no es para Alero y vuelve al Dock.
    private func resuelto(_ clic: Int, _ objetivo: ObjetivoDock?) {
        guard case .esperando(var pendiente) = estado, pendiente.numero == clic else { return }
        pendiente.resuelto = true
        pendiente.objetivo = objetivo
        if pendiente.arriba != nil || objetivo == nil {
            terminar(pendiente)
        } else {
            estado = .esperando(pendiente)
        }
    }

    private func mantenido(_ clic: Int) {
        guard case .esperando(let pendiente) = estado, pendiente.numero == clic, pendiente.arriba == nil else { return }
        devolver(pendiente.abajo, .leftMouseDown)
        estado = .pasando
    }

    /// Cierra un clic resuelto: o actúa (ya soltado; el Dock no ve nada) o le devuelve al Dock lo que se tragó.
    private func terminar(_ pendiente: Pendiente) {
        guard let objetivo = pendiente.objetivo else {
            devolver(pendiente.abajo, .leftMouseDown)
            if let arriba = pendiente.arriba {
                devolver(arriba, .leftMouseUp)
                estado = .libre
                drenado()
            } else {
                estado = .pasando
            }
            return
        }
        ultimaAccion = CACurrentMediaTime()
        AX.cola.async { VentanasApp.shared.hacer(objetivo) }
        estado = .libre
        drenado()
    }

    private func devolver(_ evento: CGEvent, _ tipo: CGEventType) {
        copiaMarcada(evento, tipo: tipo)?.post(tap: .cgSessionEventTap)
    }

    /// Terminó un clic: si la función se apagó en el medio, la escucha ya puede dejar de pedir los Up.
    private func drenado() {
        if !prendido { EscuchaClics.shared.revisar() }
    }

    /// Que la primera ventana bajo el punto sea la del Dock, y no un menú o un panel puesto encima. Usa la lista
    /// del servidor de ventanas (~0,2 ms, sin Accesibilidad); solo se paga en clics sobre la franja del Dock.
    /// Ojo: desde macOS 26 la ventana del Dock cubre toda la pantalla, así que esto solo vale junto con la franja.
    static func esDelDock(_ punto: CGPoint) -> Bool {
        guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for ventana in lista {
            guard let marco = marcoDeVentana(ventana), marco.contains(punto) else { continue }
            let pid = (ventana[kCGWindowOwnerPID as String] as? NSNumber)?.int64Value
            let alfa = (ventana[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            // Las ventanas del notch de Alero y las transparentes no cuentan: no se quedan con el clic.
            if pid == MarcaPropia.proceso || alfa == 0 { continue }
            let capa = (ventana[kCGWindowLayer as String] as? NSNumber)?.intValue
            return ventana[kCGWindowOwnerName as String] as? String == "Dock" && capa == Int(CGWindowLevelForKey(.dockWindow))
        }
        return false
    }

    // MARK: - En la cola de Accesibilidad

    /// De qué app es el ícono bajo el punto y qué hacer con ella. Nil = lo maneja el Dock.
    private static func resolver(_ punto: CGPoint, horizontal: Bool, modo: ModoDock, alternar: Bool) -> ObjetivoDock? {
        // Con el permiso quitado, una pregunta de Accesibilidad puede quedar colgada: se mira antes.
        guard AXIsProcessTrusted(), let app = appDelIcono(en: punto, horizontal: horizontal) else { return nil }
        return VentanasApp.shared.decidir(app, modo: modo, alternar: alternar)
    }

    private static func appDelIcono(en punto: CGPoint, horizontal: Bool) -> NSRunningApplication? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let hijos = AX.elementos(AX.app(dock.processIdentifier), kAXChildrenAttribute)
        guard let lista = hijos.first(where: { AX.texto($0, kAXRoleAttribute) == kAXListRole }) else { return nil }
        let iconos = AX.elementos(lista, kAXChildrenAttribute)
        let marcos = iconos.map { AX.marco($0) ?? .null }
        guard let i = indiceIcono(marcos, punto: punto, horizontal: horizontal) else { return nil }
        // Carpetas, la papelera y las ventanas minimizadas no son apps: esas siguen con el Dock.
        guard AX.texto(iconos[i], kAXSubroleAttribute) == "AXApplicationDockItem",
              let url: URL = AX.valor(iconos[i], kAXURLAttribute) else { return nil }
        let ruta = url.standardizedFileURL.resolvingSymlinksInPath().path
        // Si una app tiene varias copias abiertas, se toma la primera (caso raro).
        return NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != pid_t(MarcaPropia.proceso)
                && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == ruta
        }
    }

    /// Qué ícono está bajo el punto mirando solo el largo del Dock: en macOS 26+ el marco que informa Accesibilidad
    /// para cada ícono puede venir corrido en el otro eje (el corto), y el punto ya se sabe dentro de la franja.
    static func indiceIcono(_ marcos: [CGRect], punto: CGPoint, horizontal: Bool) -> Int? {
        marcos.firstIndex { marco in
            guard !marco.isNull else { return false }
            return horizontal ? (marco.minX...marco.maxX).contains(punto.x) : (marco.minY...marco.maxY).contains(punto.y)
        }
    }
}

/// El marco de una ventana de la lista del servidor de ventanas (coordenadas de eventos).
func marcoDeVentana(_ ventana: [String: Any]) -> CGRect? {
    guard let dic = ventana[kCGWindowBounds as String] as? NSDictionary as CFDictionary? else { return nil }
    return CGRect(dictionaryRepresentation: dic)
}
