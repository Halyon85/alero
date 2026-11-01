import Foundation

// La cuenta de Esc para salir del modo limpieza: 5 Esc seguidos, sin otra tecla en el medio y sin pasar más de 6 s
// entre uno y otro. Mantener Esc apretado no suma (la repetición del teclado no es una pulsación). Sin AppKit: se prueba
// en `TrabaTecladoTests`.
//
// A propósito 6 s y no 2: con un paño en la mano 2 s no alcanzan y nunca se podría salir; pasar el paño casi nunca
// aprieta Esc cinco veces sin tocar otra tecla.

struct SalidaTraba {
    static let necesarios = 5
    static let pausaMaxima: TimeInterval = 6

    private(set) var cuenta = 0
    private var ultima: TimeInterval?

    /// Una tecla bajó. Devuelve cuántos Esc seguidos van (0 si fue otra tecla).
    mutating func tecla(esEsc: Bool, repite: Bool, ahora: TimeInterval) -> Int {
        guard esEsc else { reiniciar(); return 0 }
        if repite { return cuenta }
        if let ultima, ahora - ultima > SalidaTraba.pausaMaxima { cuenta = 0 }
        cuenta += 1
        ultima = ahora
        return cuenta
    }

    /// Cualquier otra cosa del teclado (modificadoras, brillo, volumen) corta la cuenta.
    mutating func reiniciar() {
        cuenta = 0
        ultima = nil
    }

    var completa: Bool { cuenta >= SalidaTraba.necesarios }
}

/// Cuánto dura la traba antes de soltarse sola (se elige en Ajustes › General).
enum TopeTraba: Int, CaseIterable, Identifiable {
    case sinTope = 0, uno = 60, dos = 120, cinco = 300

    var id: Int { rawValue }

    var nombre: String {
        switch self {
        case .sinTope: return T("Sin tope", "No limit")
        case .uno: return T("1 min", "1 min")
        case .dos: return T("2 min", "2 min")
        case .cinco: return T("5 min", "5 min")
        }
    }
}
