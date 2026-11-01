import CoreGraphics
import Foundation

// Tipos de las opciones de Mouse y teclado: qué hace el clic en el Dock, qué hace cada botón del mouse y los atajos
// de teclado grabados. Se guardan en `Ajustes` (los botones como JSON chiquito).

enum ModoDock: String, CaseIterable, Identifiable {
    case minimizar
    /// Lo mismo que ⌘H: la app desaparece entera y vuelve con otro clic (eso ya lo hace el Dock solo).
    case ocultar

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .minimizar: return T("Minimizar", "Minimize")
        case .ocultar: return T("Ocultar (⌘H)", "Hide (⌘H)")
        }
    }
}

/// Los botones que se pueden configurar, con el número que les da macOS (0 izquierdo, 1 derecho, 2 la rueda…).
enum BotonMouse: Int64, CaseIterable, Identifiable {
    case rueda = 2, cuatro = 3, cinco = 4

    var id: Int64 { rawValue }

    var nombre: String {
        switch self {
        case .rueda: return T("Botón de la rueda", "Wheel button")
        case .cuatro: return T("Botón 4", "Button 4")
        case .cinco: return T("Botón 5", "Button 5")
        }
    }

    var detalle: String {
        switch self {
        case .rueda: return T("Apretar la rueda (botón 3).", "Pressing the wheel (button 3).")
        case .cuatro: return T("El lateral de atrás, en la mayoría de los mouses.", "The rear side button on most mice.")
        case .cinco: return T("El lateral de adelante, en la mayoría de los mouses.", "The front side button on most mice.")
        }
    }
}

enum AccionBoton: String, CaseIterable, Identifiable, Codable {
    case nada, atras, adelante, missionControl, ventanasApp, escritorio, launchpad, atajo

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .nada: return T("Nada (lo de macOS)", "Nothing (macOS default)")
        case .atras: return T("Atrás", "Back")
        case .adelante: return T("Adelante", "Forward")
        case .missionControl: return "Mission Control"
        case .ventanasApp: return T("Ventanas de la app", "App windows")
        case .escritorio: return T("Mostrar el escritorio", "Show desktop")
        case .launchpad: return "Launchpad"
        case .atajo: return T("Atajo de teclado…", "Keyboard shortcut…")
        }
    }
}

/// Una combinación de teclas grabada: la tecla física, las modificadoras y cómo se muestra ("⌃⌥T").
struct AtajoTeclado: Codable, Equatable {
    var codigo: UInt16
    /// Solo ⌃ ⌥ ⇧ ⌘, como banderas de CGEvent.
    var modificadores: UInt64
    var texto: String

    var flags: CGEventFlags { CGEventFlags(rawValue: modificadores).intersection(Teclado.modificadores) }

    /// Los símbolos de las modificadoras en el orden de macOS (⌃⌥⇧⌘) seguidos del nombre de la tecla.
    static func texto(flags: CGEventFlags, tecla: String) -> String {
        var simbolos = ""
        if flags.contains(.maskControl) { simbolos += "⌃" }
        if flags.contains(.maskAlternate) { simbolos += "⌥" }
        if flags.contains(.maskShift) { simbolos += "⇧" }
        if flags.contains(.maskCommand) { simbolos += "⌘" }
        return simbolos + tecla
    }

    /// Nombre de una tecla para mostrar. Las que no escriben (flechas, F1…) salen de la tabla; el resto, de la letra
    /// que da la distribución de teclado de la persona (así en un teclado francés se ve "A" donde está la A).
    static func nombreTecla(codigo: UInt16, caracteres: String?) -> String {
        if let especial = especiales[codigo] { return especial }
        let letra = (caracteres ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return letra.isEmpty ? "#\(codigo)" : letra
    }

    /// F1…F20: se pueden grabar sin modificadoras (no escriben nada).
    static func esTeclaDeFuncion(_ codigo: UInt16) -> Bool { especiales[codigo]?.hasPrefix("F") == true }

    private static let especiales: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: T("Espacio", "Space"), 51: "⌫", 53: "⎋", 117: "⌦", 76: "⌤",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}

/// Qué hace un botón del mouse. El atajo se guarda aparte de la acción: si la persona elige otra cosa y después
/// vuelve a "Atajo de teclado…", no tiene que grabarlo de nuevo.
struct ConfigBoton: Codable, Equatable {
    var accion: AccionBoton = .nada
    var atajo: AtajoTeclado?

    /// Lo que hay que hacer de verdad: un "atajo" sin grabar todavía no hace nada (el clic sigue a la app).
    var efectiva: AccionBoton {
        accion == .atajo && atajo == nil ? .nada : accion
    }

    func datos() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func leer(_ datos: Data?, siNo porDefecto: ConfigBoton) -> ConfigBoton {
        guard let datos, let config = try? JSONDecoder().decode(ConfigBoton.self, from: datos) else { return porDefecto }
        return config
    }
}
