import AppKit
import ApplicationServices

// Ayudas para hablar con otras apps por Accesibilidad (AX): leer y escribir atributos, marcos y acciones. Todo
// lo de AX corre en `AX.cola`, nunca dentro de una escucha: una app trabada no puede frenar el mouse de la Mac.

enum AX {
    /// Una sola cola para todo lo de Accesibilidad de Alero (Dock, botón verde, menús, Finder).
    static let cola = DispatchQueue(label: "alero.accesibilidad", qos: .userInteractive)

    /// A propósito: el tiempo de espera del elemento de sistema vale para TODOS los elementos de Alero. Así ninguna
    /// app colgada traba la cola más de 0,35 s por pregunta (el valor de macOS es 6 s). Alero no usa AX para nada
    /// más largo.
    static let sistema: AXUIElement = {
        let elemento = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(elemento, 0.35)
        return elemento
    }()

    /// El elemento de una app. Ojo con Chrome y las apps Electron: preguntarle el rol (o casi cualquier cosa de
    /// "qué sos") a este elemento las pasa a modo accesibilidad completo para siempre y gastan mucho procesador.
    /// Solo se le piden la barra de menú, la ventana enfocada o la lista de ventanas.
    static func app(_ pid: pid_t) -> AXUIElement {
        _ = sistema
        return AXUIElementCreateApplication(pid)
    }

    static func valor<T>(_ elemento: AXUIElement, _ atributo: String) -> T? {
        var crudo: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elemento, atributo as CFString, &crudo) == .success else { return nil }
        return crudo as? T
    }

    /// Un atributo que es otro elemento (la ventana de un botón, el elemento enfocado). Se controla el tipo: un
    /// `as?` a un tipo de Core Foundation siempre "funciona" aunque sea otra cosa.
    static func elemento(_ elemento: AXUIElement, _ atributo: String) -> AXUIElement? {
        var crudo: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elemento, atributo as CFString, &crudo) == .success, let crudo,
              CFGetTypeID(crudo) == AXUIElementGetTypeID() else { return nil }
        return (crudo as! AXUIElement)
    }

    static func elementos(_ elemento: AXUIElement, _ atributo: String) -> [AXUIElement] {
        valor(elemento, atributo) ?? []
    }

    static func texto(_ elemento: AXUIElement, _ atributo: String) -> String? { valor(elemento, atributo) }

    /// Varios atributos en una sola pregunta (para recorrer menús largos sin una vuelta por atributo). Lo que el
    /// elemento no tiene vuelve como nil.
    static func varios(_ elemento: AXUIElement, _ atributos: [String]) -> [Any?] {
        var crudo: CFArray?
        let pedidos = atributos.map { $0 as CFString } as CFArray
        guard AXUIElementCopyMultipleAttributeValues(elemento, pedidos, [], &crudo) == .success,
              let valores = crudo as? [AnyObject], valores.count == atributos.count else {
            return Array(repeating: nil, count: atributos.count)
        }
        return valores.map { valor in
            // Un atributo que falta llega como un AXValue de tipo "error".
            if CFGetTypeID(valor) == AXValueGetTypeID(), AXValueGetType(valor as! AXValue) == .axError { return nil }
            return valor
        }
    }

    static func booleano(_ elemento: AXUIElement, _ atributo: String) -> Bool? {
        (valor(elemento, atributo) as NSNumber?)?.boolValue
    }

    static func marco(_ elemento: AXUIElement) -> CGRect? {
        guard let posicion: AXValue = valor(elemento, kAXPositionAttribute),
              let tamano: AXValue = valor(elemento, kAXSizeAttribute) else { return nil }
        var punto = CGPoint.zero
        var medida = CGSize.zero
        guard AXValueGetValue(posicion, .cgPoint, &punto), AXValueGetValue(tamano, .cgSize, &medida) else { return nil }
        return CGRect(origin: punto, size: medida)
    }

    @discardableResult
    static func poner(_ elemento: AXUIElement, _ atributo: String, _ valor: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(elemento, atributo as CFString, valor) == .success
    }

    /// Posición, tamaño y otra vez posición: al agrandar, la app puede correr la ventana si choca con un borde.
    static func ponerMarco(_ elemento: AXUIElement, _ r: CGRect) {
        var punto = r.origin
        var medida = r.size
        guard let posicion = AXValueCreate(.cgPoint, &punto), let tamano = AXValueCreate(.cgSize, &medida) else { return }
        poner(elemento, kAXPositionAttribute, posicion)
        poner(elemento, kAXSizeAttribute, tamano)
        poner(elemento, kAXPositionAttribute, posicion)
    }

    static func pid(_ elemento: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(elemento, &pid) == .success ? pid : nil
    }

    /// El elemento bajo un punto (coordenadas de eventos).
    static func elemento(en punto: CGPoint) -> AXUIElement? {
        var encontrado: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sistema, Float(punto.x), Float(punto.y), &encontrado) == .success else { return nil }
        return encontrado
    }

    static func sePuedeCambiar(_ elemento: AXUIElement, _ atributo: String) -> Bool {
        var sePuede: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(elemento, atributo as CFString, &sePuede) == .success && sePuede.boolValue
    }

    @discardableResult
    static func apretar(_ elemento: AXUIElement) -> AXError {
        AXUIElementPerformAction(elemento, kAXPressAction as CFString)
    }
}
