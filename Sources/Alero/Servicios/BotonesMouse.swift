import AppKit
import Combine

// Botones del mouse con acciones: el de la rueda y los laterales 4 y 5, cada uno con la suya (atrás, adelante,
// Mission Control, un atajo de teclado…). El izquierdo y el derecho nunca se tocan. Necesita Accesibilidad.
//
// Trampa: si se traga el Down de un botón, hay que tragarse también su Up y sus arrastres, aunque la función se
// apague con el botón apretado; si no, la app de abajo recibe medio clic. Por eso la escucha sigue pidiendo esos
// eventos hasta que se suelta ("drenaje").

final class BotonesMouse: ManejadorClics {
    static let shared = BotonesMouse()

    private var suscripciones = Set<AnyCancellable>()

    // Solo en el hilo de eventos.
    private var prendido = false
    private var acciones: [Int64: ConfigBoton] = [:]
    /// Botones cuyo Down se tragó y todavía no se soltaron.
    private var tragados = Set<Int64>()

    func arrancar() {
        EscuchaClics.shared.sumar(self)
        let ajustes = Ajustes.shared
        Publishers.CombineLatest4(ajustes.$botonesMouse, ajustes.$botonRueda, ajustes.$boton4, ajustes.$boton5)
            .sink { [weak self] prender, rueda, cuatro, cinco in
                let mapa = [BotonMouse.rueda.rawValue: rueda, BotonMouse.cuatro.rawValue: cuatro, BotonMouse.cinco.rawValue: cinco]
                HiloEventos.shared.ejecutar {
                    self?.prendido = prender
                    self?.acciones = mapa
                }
                EscuchaClics.shared.revisar()
            }
            .store(in: &suscripciones)
    }

    // MARK: - En el hilo de eventos

    var mascara: CGEventMask {
        let resto = CGEventType.otherMouseDragged.bit | CGEventType.otherMouseUp.bit
        // Si ningún botón tiene acción, no hace falta escuchar nada (ni con la llave prendida).
        let algunaAccion = acciones.values.contains { $0.efectiva != .nada }
        if prendido && algunaAccion { return CGEventType.otherMouseDown.bit | resto }
        return tragados.isEmpty ? 0 : resto
    }

    func manejar(_ tipo: CGEventType, _ evento: CGEvent, proxy: CGEventTapProxy) -> DecisionClic {
        let boton = evento.getIntegerValueField(.mouseEventButtonNumber)
        switch tipo {
        case .otherMouseDown:
            guard prendido, let config = acciones[boton], config.efectiva != .nada else { return .seguir }
            tragados.insert(boton)
            DispatchQueue.main.async { AccionesMouse.hacer(config.efectiva, atajo: config.atajo) }
            return .tragar
        case .otherMouseDragged:
            return tragados.contains(boton) ? .tragar : .seguir
        case .otherMouseUp:
            guard tragados.remove(boton) != nil else { return .seguir }
            if !prendido { EscuchaClics.shared.revisar() }
            return .tragar
        default:
            return .seguir
        }
    }

    func alReanudar() {
        // Los que ya se soltaron mientras la escucha estaba cortada perdieron su Up: se olvidan.
        tragados = tragados.filter { boton in
            CGMouseButton(rawValue: UInt32(boton)).map { CGEventSource.buttonState(.combinedSessionState, button: $0) } ?? false
        }
        if !prendido { EscuchaClics.shared.revisar() }
    }
}

/// Lo que hace cada acción. Main thread (lo de Accesibilidad sigue en `AX.cola`).
enum AccionesMouse {
    static func hacer(_ accion: AccionBoton, atajo: AtajoTeclado?) {
        switch accion {
        case .nada: break
        case .atras: navegar(adelante: false)
        case .adelante: navegar(adelante: true)
        case .missionControl: missionControl(nil)
        // El programa de Mission Control de macOS acepta "2" (ventanas de la app del frente) y "1" (escritorio).
        case .ventanasApp: missionControl("2")
        case .escritorio: missionControl("1")
        case .launchpad: abrirLaunchpad()
        case .atajo:
            if let atajo { Teclado.enviar(codigo: CGKeyCode(atajo.codigo), flags: atajo.flags) }
        }
    }

    /// Atrás y adelante aprietan el ítem del menú de la app que tiene ⌘[ o ⌘] (Finder, Safari, Chrome, Mail…), en
    /// vez de mandar las teclas a ciegas: en algunas apps esas teclas editan el documento. Si la app no tiene ese
    /// ítem, recién ahí se mandan las teclas, a la tecla donde está el corchete en el teclado de la persona.
    private static func navegar(adelante: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let corchete = adelante ? "]" : "["
        let tecla = Teclado.teclaQueEscribe(corchete)
        // Códigos de [ y ] en el teclado estadounidense, si la distribución no tiene corchetes.
        let codigo = tecla?.codigo ?? (adelante ? 30 : 33)
        let caracteres = [corchete, tecla?.base].compactMap { $0 }
        AX.cola.async {
            guard MenuApp.apretar(pid: pid, caracteres: caracteres) == .noEncontrado else { return }
            DispatchQueue.main.async { Teclado.enviar(codigo: codigo, flags: .maskCommand) }
        }
    }

    private static let appMissionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    /// Se abre la app como `open -a "Mission Control"`, por LaunchServices. Antes se corría su programa directo y en
    /// macOS 27 no hacía nada (botón del medio, 01/11/2026).
    private static func missionControl(_ argumento: String?) {
        let configuracion = NSWorkspace.OpenConfiguration()
        configuracion.arguments = argumento.map { [$0] } ?? []
        configuracion.activates = false
        NSWorkspace.shared.openApplication(at: appMissionControl, configuration: configuracion) { _, error in
            if let error { NSLog("Alero: no se pudo abrir Mission Control: \(error.localizedDescription)") }
        }
    }

    /// Desde macOS 26 Launchpad se llama "Apps"; se abre el que exista.
    private static func abrirLaunchpad() {
        let rutas = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
        guard let ruta = rutas.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            NSLog("Alero: no se encontró Launchpad")
            return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: ruta), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("Alero: no se pudo abrir Launchpad: \(error.localizedDescription)") }
        }
    }
}

/// Buscar y apretar un ítem del menú de otra app por su atajo. Solo en `AX.cola`.
enum MenuApp {
    enum Resultado { case apretado, deshabilitado, noEncontrado }

    /// Busca en la barra de menú de la app el ítem con ⌘ + alguno de `caracteres` (solo ⌘) y lo
    /// aprieta. Recorre barra → menú → ítem; los submenús no, porque ahí ⌘[ suele ser otra cosa (reducir sangría).
    /// Tope de 600 ítems por si una app tiene menús enormes.
    static func apretar(pid: pid_t, caracteres: [String]) -> Resultado {
        guard AXIsProcessTrusted(), let barra = AX.elemento(AX.app(pid), kAXMenuBarAttribute) else { return .noEncontrado }
        let atributos = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute]
        var vistos = 0
        // El primero es el menú de Apple: no tiene nada de esto.
        for titulo in AX.elementos(barra, kAXChildrenAttribute).dropFirst() {
            for menu in AX.elementos(titulo, kAXChildrenAttribute) {
                for item in AX.elementos(menu, kAXChildrenAttribute) {
                    vistos += 1
                    if vistos > 600 { return .noEncontrado }
                    let valores = AX.varios(item, atributos)
                    let modificadores = (valores[1] as? NSNumber)?.intValue
                    let deEste = valores[0] as? String
                    guard caracteres.contains(where: { coincide(caracter: deEste, modificadores: modificadores, buscado: $0) }) else { continue }
                    guard (valores[2] as? NSNumber)?.boolValue == true else { return .deshabilitado }
                    // Si la app tarda en hacer lo del ítem, la pregunta vence (error "no se pudo completar") pero el
                    // ítem igual se apretó: no se mandan las teclas encima, sería navegar dos veces.
                    AX.apretar(item)
                    return .apretado
                }
            }
        }
        return .noEncontrado
    }

    /// `modificadores` es el número de Accesibilidad: 0 = solo ⌘ (1 suma ⇧, 2 ⌥, 4 ⌃, 8 = sin ⌘).
    static func coincide(caracter: String?, modificadores: Int?, buscado: String) -> Bool {
        guard let caracter, caracter.lowercased() == buscado.lowercased() else { return false }
        return (modificadores ?? 0) == 0
    }
}
