import Foundation

// Brillo del teclado de la MacBook (la luz de las teclas). Apple no tiene una función pública: se usa
// `KeyboardBrightnessClient` de CoreBrightness, la misma que usa macOS, cargada con dlopen y llamada por su selector.
// No pide permisos. Si en un macOS futuro la clase o sus funciones cambian, `disponible` da false y las teclas siguen
// hacia macOS como siempre. Lo llaman las teclas (desde el hilo de eventos) y el deslizador del notch (hilo principal):
// el cliente se crea una sola vez, protegido con un candado.
//
// Comprobado en macOS 27.2 (MacBook M5, 01/11/2026): `copyKeyboardBacklightIDs` devuelve un solo teclado y leer el
// brillo anda sin permisos. La idea de usar esta clase sale de Atoll (código abierto).

enum BrilloTeclado {
    private typealias Leer = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Poner = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let candado = NSLock()
    private static var cargado = false
    private static var cliente: NSObject?
    private static var teclado: UInt64 = 1

    /// Crea el cliente la primera vez. Devuelve nil si CoreBrightness no está o cambió.
    private static func obtenerCliente() -> NSObject? {
        candado.lock()
        defer { candado.unlock() }
        if cargado { return cliente }
        cargado = true
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let clase = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let nuevo = clase.init()
        let lectura = NSSelectorFromString("brightnessForKeyboard:")
        let escritura = NSSelectorFromString("setBrightness:forKeyboard:")
        guard nuevo.responds(to: lectura), nuevo.responds(to: escritura) else { return nil }
        // El ID real del teclado integrado; si no se puede leer, el 1 también funciona (probado).
        let ids = NSSelectorFromString("copyKeyboardBacklightIDs")
        if nuevo.responds(to: ids), let lista = nuevo.perform(ids)?.takeRetainedValue() as? [NSNumber], let primero = lista.first {
            teclado = primero.uint64Value
        }
        cliente = nuevo
        return nuevo
    }

    static var disponible: Bool { actual() != nil }

    /// 0…1, o nil si no se puede leer (Mac sin teclado con luz, o macOS cambió la función).
    static func actual() -> Float? {
        guard let cliente = obtenerCliente() else { return nil }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        let funcion = unsafeBitCast(cliente.method(for: selector), to: Leer.self)
        let valor = funcion(cliente, selector, teclado)
        return (0...1).contains(valor) ? valor : nil
    }

    /// Devuelve false si no hay cliente (la tecla tiene que seguir hacia macOS).
    @discardableResult
    static func poner(_ valor: Float) -> Bool {
        guard let cliente = obtenerCliente() else { return false }
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        let funcion = unsafeBitCast(cliente.method(for: selector), to: Poner.self)
        // A propósito se ignora lo que devuelve: no está documentado si es un BOOL fiable, y si diera false la tecla
        // seguiría a macOS y el brillo cambiaría dos veces.
        _ = funcion(cliente, selector, min(max(valor, 0), 1), teclado)
        return true
    }
}
