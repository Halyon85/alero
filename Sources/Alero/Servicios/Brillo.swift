import CoreGraphics
import Foundation

// Brillo de la pantalla de la Mac (la integrada) y de los monitores de Apple (Studio Display, Pro Display), que
// responden igual. Apple no tiene una función pública para esto: se usa DisplayServices, la misma que usa macOS
// para sus teclas. Se carga con dlopen: si en un macOS futuro no está, `disponible` da false y las teclas de brillo
// siguen yendo a macOS como siempre. Los demás monitores van por `Monitores` (DDC o atenuación por software).

enum Brillo {
    private typealias Leer = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Poner = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let biblioteca = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let leerFuncion: Leer? = simbolo("DisplayServicesGetBrightness")
    private static let ponerFuncion: Poner? = simbolo("DisplayServicesSetBrightness")

    private static func simbolo<F>(_ nombre: String) -> F? {
        guard let biblioteca, let puntero = dlsym(biblioteca, nombre) else { return nil }
        return unsafeBitCast(puntero, to: F.self)
    }

    /// La pantalla integrada si hay (MacBook), si no la principal.
    private static var pantalla: CGDirectDisplayID {
        var cantidad: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &cantidad)
        return ids.prefix(Int(cantidad)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var disponible: Bool { actual() != nil }

    /// 0…1, o nil si no se puede leer (en otra pantalla: no es de Apple). Sin pantalla, la integrada.
    static func actual(en id: CGDirectDisplayID? = nil) -> Float? {
        guard let leerFuncion else { return nil }
        var valor: Float = 0
        return leerFuncion(id ?? pantalla, &valor) == 0 ? valor : nil
    }

    /// Devuelve false si no se pudo (la tecla tiene que seguir hacia macOS).
    @discardableResult
    static func poner(_ valor: Float, en id: CGDirectDisplayID? = nil) -> Bool {
        guard let ponerFuncion else { return false }
        return ponerFuncion(id ?? pantalla, min(max(valor, 0), 1)) == 0
    }
}
