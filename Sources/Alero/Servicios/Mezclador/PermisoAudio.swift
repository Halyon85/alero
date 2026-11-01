import AppKit

// Permiso "Grabación de audio del sistema" (lo pide el mezclador: para bajar una app, Alero recibe su sonido).
// macOS no tiene una función pública para saber si está concedido. Se usa TCC, la misma pieza de macOS que muestra
// el cartel, cargada con dlopen; si en un macOS futuro no está, queda "desconocido" y el mezclador lo deduce cuando
// el tap no se puede crear.
//
// Importa saberlo ANTES de crear el tap: sin permiso, el tap entrega silencio y la app quedaría muda.

enum PermisoAudio {
    enum Estado: Equatable { case concedido, negado, sinPedir, desconocido }

    private static let servicio = "kTCCServiceAudioCapture" as CFString
    private typealias Preguntar = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Pedir = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private static let biblioteca = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY)
    private static let preguntar: Preguntar? = simbolo("TCCAccessPreflight")
    private static let pedirFuncion: Pedir? = simbolo("TCCAccessRequest")

    private static func simbolo<F>(_ nombre: String) -> F? {
        guard let biblioteca, let puntero = dlsym(biblioteca, nombre) else { return nil }
        return unsafeBitCast(puntero, to: F.self)
    }

    /// Mirar no muestra carteles. Cualquier hilo.
    static var estado: Estado {
        guard let preguntar else { return .desconocido }
        switch preguntar(servicio, nil) {
        case 0: return .concedido
        case 1: return .negado
        default: return .sinPedir
        }
    }

    /// Muestra el cartel de macOS (solo la primera vez) y avisa la respuesta en el hilo principal.
    static func pedir(_ respuesta: @escaping (Bool) -> Void) {
        guard let pedirFuncion else { DispatchQueue.main.async { respuesta(false) }; return }
        pedirFuncion(servicio, nil) { concedido in DispatchQueue.main.async { respuesta(concedido) } }
    }

    static func abrirAjustes() {
        let direccion = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        if let url = URL(string: direccion) { NSWorkspace.shared.open(url) }
    }
}
