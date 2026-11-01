import AppKit

// Minimizar, ocultar, volver a mostrar o pasar a la siguiente ventana de una app (lo pide el clic en el Dock). Todo corre en
// `AX.cola`. Solo se restauran las ventanas que minimizó Alero: las minimizadas a mano las sigue manejando el Dock.
//
// El orden importa: antes de minimizar se anota qué ventana estaba adelante (la lista de Accesibilidad no lo dice
// bien, y una vez minimizadas no hay orden). Al restaurar, se traen de atrás hacia adelante, así la de adelante
// queda arriba sola sin reacomodar después (eso hace parpadear).

final class VentanasApp {
    static let shared = VentanasApp()

    // Solo en `AX.cola`.
    /// Ventanas que minimizó Alero, por app, de adelante hacia atrás.
    private var minimizadas: [pid_t: [AXUIElement]] = [:]
    private var ultima: (pid: pid_t, accion: ObjetivoDock.Accion, ventanas: [AXUIElement], cuando: CFTimeInterval)?

    /// Qué hacer con un clic en el ícono de `app`. Nil = lo hace el Dock (abrir, traer al frente, etc.).
    func decidir(_ app: NSRunningApplication, modo: ModoDock, alternar: Bool) -> ObjetivoDock? {
        let pid = app.processIdentifier
        // Mientras dura la animación de minimizar o restaurar, lo que dice macOS de cada ventana es confuso: un clic
        // en ese rato alterna desde lo último que hizo Alero en vez de volver a mirar.
        if let ultima, ultima.pid == pid, CACurrentMediaTime() - ultima.cuando < 1.5 {
            switch ultima.accion {
            case .minimizar: return ObjetivoDock(app: app, accion: .restaurar)
            case .restaurar: return ObjetivoDock(app: app, accion: .minimizar(ultima.ventanas))
            case .ocultar, .siguiente: return nil
            }
        }
        // `isActive` miente en algunos lanzadores: se mira también cuál es la app del frente.
        let alFrente = !app.isHidden && (app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
        if alFrente {
            let ordenZ = VentanasApp.ventanasEnPantalla(pid)
            // Sin ventanas a la vista, el clic es para que el Dock haga lo suyo (por ejemplo, abrir una nueva).
            guard !ordenZ.isEmpty else { return nil }
            if modo == .ocultar { return ObjetivoDock(app: app, accion: .ocultar) }
            let ventanas = VentanasApp.normales(pid, ordenZ: ordenZ)
            // Una ventana en pantalla completa no se minimiza: macOS la saca de su escritorio y queda rara.
            guard !ventanas.isEmpty, !ventanas.contains(where: { AX.booleano($0, "AXFullScreen") == true }) else { return nil }
            // Con varias ventanas, la de más atrás pasa adelante: clic a clic se recorren todas (como ⌘`).
            if alternar, ventanas.count > 1, let atras = ventanas.last { return ObjetivoDock(app: app, accion: .siguiente(atras)) }
            return ObjetivoDock(app: app, accion: .minimizar(ventanas))
        }
        if let guardadas = minimizadas[pid], guardadas.contains(where: { AX.booleano($0, kAXMinimizedAttribute) == true }) {
            return ObjetivoDock(app: app, accion: .restaurar)
        }
        return nil
    }

    func hacer(_ objetivo: ObjetivoDock) {
        let app = objetivo.app
        let pid = app.processIdentifier
        switch objetivo.accion {
        case .ocultar:
            DispatchQueue.main.async { _ = app.hide() }
            ultima = (pid, .ocultar, [], CACurrentMediaTime())
        case .minimizar(let ventanas):
            ventanas.forEach { AX.poner($0, kAXMinimizedAttribute, kCFBooleanTrue) }
            minimizadas[pid] = ventanas
            ultima = (pid, objetivo.accion, ventanas, CACurrentMediaTime())
            // Hay apps que dicen que sí y no minimizan: se mira de nuevo un rato después y se insiste una vez.
            AX.cola.asyncAfter(deadline: .now() + 0.35) {
                for ventana in ventanas where AX.booleano(ventana, kAXMinimizedAttribute) == false {
                    AX.poner(ventana, kAXMinimizedAttribute, kCFBooleanTrue)
                }
            }
        case .siguiente(let ventana):
            AX.poner(ventana, kAXMainAttribute, kCFBooleanTrue)
            AXUIElementPerformAction(ventana, kAXRaiseAction as CFString)
        case .restaurar:
            let ventanas = (minimizadas.removeValue(forKey: pid) ?? []).filter { AX.booleano($0, kAXMinimizedAttribute) == true }
            ventanas.reversed().forEach { AX.poner($0, kAXMinimizedAttribute, kCFBooleanFalse) }
            if let adelante = ventanas.first {
                AX.poner(adelante, kAXMainAttribute, kCFBooleanTrue)
                AXUIElementPerformAction(adelante, kAXRaiseAction as CFString)
            }
            ultima = (pid, objetivo.accion, ventanas, CACurrentMediaTime())
            // Activar recién ahora, con las ventanas de atrás ya arriba: antes, macOS trae la principal por su cuenta.
            DispatchQueue.main.async { VentanasApp.activar(app) }
        }
    }

    /// Desde macOS 14 una app que no está al frente (Alero nunca lo está) no puede activar a otra de prepo: se pide
    /// la activación "cooperativa" y, si macOS no la hizo, se le avisa a la app por Accesibilidad. Main thread.
    private static func activar(_ app: NSRunningApplication) {
        if !app.activate(from: NSRunningApplication.current, options: []) {
            app.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !app.isActive else { return }
            AX.cola.async { AX.poner(AX.app(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue) }
        }
    }

    /// Marcos de las ventanas comunes de la app que se ven en este escritorio, de adelante hacia atrás (el orden
    /// del servidor de ventanas, que es el real).
    static func ventanasEnPantalla(_ pid: pid_t) -> [CGRect] {
        guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return lista.compactMap { ventana in
            guard (ventana[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (ventana[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((ventana[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { return nil }
            return marcoDeVentana(ventana)
        }
    }

    /// Las ventanas de Accesibilidad de la app que se pueden minimizar, en el orden de `ordenZ`. Se dejan afuera
    /// paneles, el escritorio de Finder (que figura como "área de desplazamiento") y lo que ya está minimizado.
    private static func normales(_ pid: pid_t, ordenZ: [CGRect]) -> [AXUIElement] {
        let todas = AX.elementos(AX.app(pid), kAXWindowsAttribute).filter {
            AX.texto($0, kAXRoleAttribute) == kAXWindowRole
                && AX.texto($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
                && AX.booleano($0, kAXMinimizedAttribute) != true
        }
        let orden = ordenar(todas.map { AX.marco($0) ?? .null }, segun: ordenZ)
        return orden.map { todas[$0] }
    }

    /// Ordena ventanas de Accesibilidad según el orden del servidor de ventanas, emparejándolas por marco (sin
    /// usar la función privada que da el número de ventana). Las que no aparecen en `ordenZ` (otro escritorio)
    /// quedan afuera: se minimiza lo que se ve.
    static func ordenar(_ marcos: [CGRect], segun ordenZ: [CGRect]) -> [Int] {
        var libres = Array(marcos.indices)
        var resultado: [Int] = []
        for marcoZ in ordenZ {
            if let i = libres.firstIndex(where: { !marcos[$0].isNull && Geometria.parecidos(marcos[$0], marcoZ, tolerancia: 2) }) {
                resultado.append(libres.remove(at: i))
            }
        }
        return resultado
    }
}
