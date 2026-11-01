import AppKit
import Combine

// Botón verde = maximizar: agranda la ventana a toda la pantalla (sin tapar la barra de menú ni el Dock) en vez de
// pasarla a pantalla completa. Otro clic la vuelve a su tamaño. Con ⌥ (o cualquier modificadora) hace lo de macOS.
// Necesita Accesibilidad.
//
// Cómo: primero un filtro barato con la lista de ventanas (¿el clic cae donde va el semáforo de una ventana?). Solo
// ahí se traga el Down y `AX.cola` confirma que es el botón verde. Si no lo era, el Down vuelve a la app al toque.
// Preguntarle a Accesibilidad en cada clic de la Mac trabaría a algunas apps: por eso el filtro va antes.

/// Una ventana cuyo botón verde se apretó.
struct ObjetivoVentana {
    let pid: pid_t
    let ventana: AXUIElement
    let boton: AXUIElement
    /// El botón de "zoom" clásico (sin pantalla completa): si Alero no puede, se lo aprieta y la app hace lo suyo.
    let esZoom: Bool
}

final class BotonVerde: ManejadorClics {
    static let shared = BotonVerde()

    private var suscripciones = Set<AnyCancellable>()

    // Solo en el hilo de eventos.
    private var prendido = false
    private var estado: Estado = .libre
    private var numero = 0

    private struct Pendiente {
        let numero: Int
        let abajo: CGEvent
        let punto: CGPoint
        var resuelto = false
        var objetivo: ObjetivoVentana?
        var arriba: CGEvent?
    }

    private enum Estado {
        case libre
        case esperando(Pendiente)
        case pasando
    }

    func arrancar() {
        Pantallas.shared.arrancar()
        EscuchaClics.shared.sumar(self)
        Ajustes.shared.$botonVerde.removeDuplicates()
            .sink { [weak self] prender in
                HiloEventos.shared.ejecutar { self?.prendido = prender }
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
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        if case .libre = estado { return }
        estado = .libre
        drenado()
    }

    private func bajar(_ evento: CGEvent) -> DecisionClic {
        guard prendido, case .libre = estado, evento.flags.intersection(Teclado.modificadores).isEmpty else { return .seguir }
        let punto = evento.location
        guard let pid = BotonVerde.ventanaCandidata(punto), let abajo = evento.copy() else { return .seguir }
        numero += 1
        let esteClic = numero
        estado = .esperando(Pendiente(numero: esteClic, abajo: abajo, punto: punto))
        AX.cola.async { [weak self] in
            let objetivo = BotonVerde.resolver(punto, pid: pid)
            HiloEventos.shared.ejecutar { self?.resuelto(esteClic, objetivo) }
        }
        return .tragar
    }

    private func arrastrar(_ evento: CGEvent, _ proxy: CGEventTapProxy) -> DecisionClic {
        guard case .esperando(let pendiente) = estado else { return .seguir }
        let movido = hypot(evento.location.x - pendiente.punto.x, evento.location.y - pendiente.punto.y)
        guard movido > 6 else { return .tragar }
        // Se está arrastrando la ventana (o un botón de la barra): el Down vuelve justo antes de este movimiento.
        copiaMarcada(pendiente.abajo, tipo: .leftMouseDown)?.tapPostEvent(proxy)
        estado = .pasando
        return .seguir
    }

    private func soltar(_ evento: CGEvent) -> DecisionClic {
        switch estado {
        case .esperando(var pendiente):
            pendiente.arriba = evento.copy()
            if pendiente.resuelto { terminar(pendiente) } else { estado = .esperando(pendiente) }
            return .tragar
        case .pasando:
            estado = .libre
            drenado()
            return .seguir
        case .libre:
            return .seguir
        }
    }

    private func resuelto(_ clic: Int, _ objetivo: ObjetivoVentana?) {
        guard case .esperando(var pendiente) = estado, pendiente.numero == clic else { return }
        pendiente.resuelto = true
        pendiente.objetivo = objetivo
        if pendiente.arriba != nil || objetivo == nil { terminar(pendiente) } else { estado = .esperando(pendiente) }
    }

    private func terminar(_ pendiente: Pendiente) {
        guard let objetivo = pendiente.objetivo else {
            copiaMarcada(pendiente.abajo, tipo: .leftMouseDown)?.post(tap: .cgSessionEventTap)
            if let arriba = pendiente.arriba {
                copiaMarcada(arriba, tipo: .leftMouseUp)?.post(tap: .cgSessionEventTap)
                estado = .libre
                drenado()
            } else {
                estado = .pasando
            }
            return
        }
        // Como en macOS: si se suelta fuera del botón (se corrió más de 8 pt), no pasa nada.
        if let arriba = pendiente.arriba, hypot(arriba.location.x - pendiente.punto.x, arriba.location.y - pendiente.punto.y) <= 8 {
            AX.cola.async { Maximizar.shared.alternar(objetivo) }
        }
        estado = .libre
        drenado()
    }

    private func drenado() {
        if !prendido { EscuchaClics.shared.revisar() }
    }

    /// La app de la ventana bajo el punto, si el punto cae en la zona del semáforo (botones de arriba a la
    /// izquierda) de una ventana común. Lista del servidor de ventanas, sin Accesibilidad.
    static func ventanaCandidata(_ punto: CGPoint) -> pid_t? {
        guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for ventana in lista {
            guard let marco = marcoDeVentana(ventana), marco.contains(punto),
                  let pid = (ventana[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            let alfa = (ventana[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if Int64(pid) == MarcaPropia.proceso || alfa == 0 { continue }
            // Desde macOS 26 el Dock tiene una ventana transparente del tamaño de la pantalla por encima de todas
            // (capa 20) que no se queda con los clics fuera de sus íconos: no cuenta. Si lo de abajo es Mission
            // Control (también del Dock), Accesibilidad no confirma el botón y el clic vuelve tal cual.
            if ventana[kCGWindowOwnerName as String] as? String == "Dock" { continue }
            // La primera ventana que se queda con el clic tiene que ser una ventana común (capa 0) de buen tamaño.
            let capa = (ventana[kCGWindowLayer as String] as? NSNumber)?.intValue
            guard capa == 0, marco.width >= 80, marco.height >= 80, enZonaDelVerde(punto, ventana: marco) else { return nil }
            return pid
        }
        return nil
    }

    /// Zona amplia donde puede estar el botón verde, medida desde la esquina de arriba a la izquierda: cubre la
    /// barra de título común y las barras de herramientas altas de macOS 26+. Accesibilidad confirma después.
    static func enZonaDelVerde(_ punto: CGPoint, ventana: CGRect) -> Bool {
        let dx = punto.x - ventana.minX
        let dy = punto.y - ventana.minY
        return (42...104).contains(dx) && (0...46).contains(dy)
    }

    // MARK: - En la cola de Accesibilidad

    private static func resolver(_ punto: CGPoint, pid: pid_t) -> ObjetivoVentana? {
        guard AXIsProcessTrusted(), let elemento = AX.elemento(en: punto), AX.pid(elemento) == pid else { return nil }
        // Trampa de Chrome y Electron (ver `AX.app`): si lo que hay bajo el punto es la app entera, no se le pregunta nada.
        if CFEqual(elemento, AX.app(pid)) { return nil }
        let subrol = AX.texto(elemento, kAXSubroleAttribute)
        guard subrol == kAXZoomButtonSubrole || subrol == kAXFullScreenButtonSubrole,
              let ventana = AX.elemento(elemento, kAXWindowAttribute),
              AX.booleano(ventana, "AXFullScreen") != true,
              AX.sePuedeCambiar(ventana, kAXSizeAttribute) else { return nil }
        return ObjetivoVentana(pid: pid, ventana: ventana, boton: elemento, esZoom: subrol == kAXZoomButtonSubrole)
    }
}

/// Agranda una ventana a la parte visible de su pantalla y la vuelve a su tamaño. Solo en `AX.cola`.
final class Maximizar {
    static let shared = Maximizar()

    private struct Guardado {
        let ventana: AXUIElement
        /// Cómo estaba antes de maximizar.
        let antes: CGRect
        /// Cómo quedó de verdad: Terminal y otras apps redondean a su grilla y no llenan la pantalla justa.
        var quedo: CGRect?
    }

    /// Una entrada por ventana maximizada; pasadas 30 se olvidan las más viejas.
    private var guardados: [Guardado] = []

    func alternar(_ objetivo: ObjetivoVentana) {
        guard let actual = AX.marco(objetivo.ventana),
              let pantalla = Geometria.pantalla(de: actual, en: Pantallas.shared.actuales) else { return }
        let indice = guardados.firstIndex { CFEqual($0.ventana, objetivo.ventana) }
        let grande = Geometria.parecidos(actual, pantalla.visible)
        if let indice {
            let guardado = guardados[indice]
            if grande || guardado.quedo.map({ Geometria.parecidos(actual, $0) }) == true {
                guardados.remove(at: indice)
                aplicar(guardado.antes, a: objetivo)
                return
            }
            // La persona la movió o la achicó a mano desde que Alero la agrandó: lo guardado ya no sirve.
            guardados.remove(at: indice)
        } else if grande {
            // Ya estaba grande y Alero no sabe cómo era antes: que la app haga su "zoom" de siempre.
            if objetivo.esZoom { AX.apretar(objetivo.boton) }
            return
        }
        guardados.append(Guardado(ventana: objetivo.ventana, antes: actual))
        if guardados.count > 30 { guardados.removeFirst() }
        aplicar(pantalla.visible, a: objetivo)
    }

    /// Algunas apps aplican el tamaño un rato después, o lo corrigen: se mira a los 0,15 s y se insiste hasta dos
    /// veces. Las apps con la "interfaz mejorada" de Accesibilidad prendida (la prenden lectores de pantalla y
    /// algunos gestores de ventanas) mueven la ventana pero ignoran el tamaño: se apaga un momento y se vuelve a
    /// prender. macOS a veces devuelve error al prenderla aunque funcione; por eso no se mira el resultado.
    private func aplicar(_ marco: CGRect, a objetivo: ObjetivoVentana, intento: Int = 0) {
        let app = AX.app(objetivo.pid)
        let mejorada = AX.booleano(app, "AXEnhancedUserInterface") == true
        if mejorada { AX.poner(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        AX.ponerMarco(objetivo.ventana, marco)
        if mejorada { AX.poner(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
        AX.cola.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let ahora = AX.marco(objetivo.ventana) else { return }
            if !Geometria.parecidos(ahora, marco) && intento < 2 {
                self.aplicar(marco, a: objetivo, intento: intento + 1)
                return
            }
            if let i = self.guardados.firstIndex(where: { CFEqual($0.ventana, objetivo.ventana) }) { self.guardados[i].quedo = ahora }
        }
    }
}
