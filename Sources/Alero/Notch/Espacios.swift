import SwiftUI

// Qué se puede poner en el notch abierto y cómo se elige. Arriba, a cada lado de la cámara, va una fila de íconos
// iguales que se eligen y se ordenan en Alero › Notch abierto: pestañas (espacios: Inicio, Sonido, Utilidades…) y
// botones (café, captura, ajustes…). El espacio Inicio junta dos tarjetas a elección. La idea de los espacios sale de
// otras apps de notch.

enum EspacioNotch: String, CaseIterable, Identifiable {
    case inicio, sonido, utilidades, limpiar, agentes, teleprompter, terminal, estante

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .inicio: return T("Inicio", "Home")
        case .sonido: return T("Sonido y brillo", "Sound & brightness")
        case .utilidades: return T("Utilidades", "Utilities")
        case .limpiar: return T("Limpiar la Mac", "Clean up")
        case .agentes: return T("Agentes de IA", "AI agents")
        case .teleprompter: return T("Teleprompter", "Teleprompter")
        case .terminal: return T("Terminal", "Terminal")
        case .estante: return T("Estante", "Shelf")
        }
    }

    var detalle: String {
        switch self {
        case .inicio: return T("Las dos tarjetas que elijas abajo.", "The two cards you pick below.")
        case .sonido: return T("Salida de sonido y volumen de cada app; brillo de las pantallas y luz del teclado.",
                               "Sound output and each app's volume; display brightness and keyboard light.")
        case .utilidades: return T("Estado de la Mac y desinstalar apps.", "Mac status and uninstalling apps.")
        case .limpiar: return T("Busca lo que sobra y lo manda a la Papelera.", "Finds leftovers and moves them to the Trash.")
        case .agentes: return T("Si Claude Code o Codex están trabajando, y su cupo.", "Whether Claude Code or Codex are working, and their quota.")
        case .teleprompter: return T("Tu guion debajo de la cámara.", "Your script under the camera.")
        case .terminal: return T("Comandos sin salir del notch.", "Commands without leaving the notch.")
        case .estante: return T("Los archivos que dejaste en el notch.", "The files you left in the notch.")
        }
    }

    var icono: String {
        switch self {
        case .inicio: return "house.fill"
        case .sonido: return "slider.horizontal.3"
        case .utilidades: return "wrench.and.screwdriver.fill"
        case .limpiar: return "sparkles"
        case .agentes: return "brain.head.profile"
        case .teleprompter: return "text.alignleft"
        case .terminal: return "apple.terminal.fill"
        case .estante: return "tray.full.fill"
        }
    }
}

/// Un ícono de la barra de arriba: una pestaña (espacio) o un botón que hace algo.
enum ElementoBarra: Hashable, Identifiable {
    case espacio(EspacioNotch)
    case accion(AtajoNotch)

    /// Los botones que repiten una pestaña (Estante, Teleprompter) no van en la barra: estaban dos veces en "Agregar".
    static let accionesRepetidas: Set<AtajoNotch> = [.estante, .prompter]

    static var todos: [ElementoBarra] {
        EspacioNotch.allCases.map(ElementoBarra.espacio) + AtajoNotch.allCases.filter { !accionesRepetidas.contains($0) }.map(ElementoBarra.accion)
    }

    /// Cómo se guarda: "e:inicio" o "a:cafe".
    var clave: String {
        switch self {
        case .espacio(let espacio): return "e:" + espacio.rawValue
        case .accion(let atajo): return "a:" + atajo.rawValue
        }
    }

    init?(clave: String) {
        let partes = clave.split(separator: ":", maxSplits: 1).map(String.init)
        guard partes.count == 2 else { return nil }
        if partes[0] == "e", let espacio = EspacioNotch(rawValue: partes[1]) { self = .espacio(espacio); return }
        if partes[0] == "a", let atajo = AtajoNotch(rawValue: partes[1]), !ElementoBarra.accionesRepetidas.contains(atajo) {
            self = .accion(atajo)
            return
        }
        return nil
    }

    var id: String { clave }

    var nombre: String {
        switch self {
        case .espacio(let espacio): return espacio.nombre
        case .accion(let atajo): return atajo.nombre
        }
    }

    var detalle: String {
        switch self {
        case .espacio(let espacio): return T("Pestaña", "Tab") + " · " + espacio.detalle
        case .accion(let atajo): return T("Botón", "Button") + " · " + atajo.detalle
        }
    }

    var icono: String {
        switch self {
        case .espacio(let espacio): return espacio.icono
        case .accion(let atajo): return atajo.icono
        }
    }
}

/// Lo que puede ir a cada lado del espacio Inicio.
enum TarjetaNotch: String, CaseIterable, Identifiable {
    case musica, agenda, sonido, estado, agentes, nada

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .musica: return T("Música", "Music")
        case .agenda: return T("Agenda", "Calendar")
        case .sonido: return T("Sonido", "Sound")
        case .estado: return T("Estado de la Mac", "Mac status")
        case .agentes: return T("Agentes de IA", "AI agents")
        case .nada: return T("Nada", "Nothing")
        }
    }
}

/// El fondo del notch abierto.
enum EstiloNotch: String, CaseIterable, Identifiable {
    case negro, vidrio
    var id: String { rawValue }
    var nombre: String { self == .negro ? T("Negro", "Black") : T("Vidrio", "Glass") }
}

/// Las reglas de la barra de arriba, sin vistas (se prueban con `swift test`).
enum ReglasBarra {
    /// Lo que viene la primera vez. Entra holgado en el notch más angosto (560 pt): 5 íconos por lado.
    static let izquierdaDeFabrica: [ElementoBarra] = [.espacio(.inicio), .espacio(.sonido), .espacio(.utilidades), .espacio(.terminal)]
    static let derechaDeFabrica: [ElementoBarra] = [.espacio(.agentes), .espacio(.teleprompter), .espacio(.estante),
                                                    .accion(.cafe), .accion(.ajustes)]

    /// Cuántos íconos entran de cada lado según el ancho del notch abierto y el de la cámara.
    static func capacidad(anchoAbierto: CGFloat, anchoCamara: CGFloat) -> Int {
        let lado = (anchoAbierto - anchoCamara) / 2 - 18
        return max(Int((lado - 4) / 28), 1)
    }

    /// Las pestañas que hay, en el orden en que se ven (izquierda y después derecha), sin repetidas. Si no quedó
    /// ninguna, Inicio (el notch abierto nunca puede quedar vacío).
    static func espacios(izquierda: [ElementoBarra], derecha: [ElementoBarra]) -> [EspacioNotch] {
        var vistos = Set<EspacioNotch>()
        let lista = (izquierda + derecha).compactMap { elemento -> EspacioNotch? in
            if case .espacio(let espacio) = elemento, vistos.insert(espacio).inserted { return espacio }
            return nil
        }
        return lista.isEmpty ? [.inicio] : lista
    }

    /// El espacio que se abre: el pedido si está en la barra; si no, el primero.
    static func elegido(_ pedido: EspacioNotch?, entre espacios: [EspacioNotch]) -> EspacioNotch {
        if let pedido, espacios.contains(pedido) { return pedido }
        return espacios.first ?? .inicio
    }

    /// Sube (-1) o baja (+1) un elemento en su lista. Fuera de rango no cambia nada.
    static func mover(_ elemento: ElementoBarra, _ paso: Int, en lista: [ElementoBarra]) -> [ElementoBarra] {
        guard let i = lista.firstIndex(of: elemento), lista.indices.contains(i + paso) else { return lista }
        var nueva = lista
        nueva.swapAt(i, i + paso)
        return nueva
    }

    /// Si se puede sacar un elemento: la última pestaña que queda no (el notch abierto quedaría vacío).
    static func sePuedeSacar(_ elemento: ElementoBarra, izquierda: [ElementoBarra], derecha: [ElementoBarra]) -> Bool {
        guard case .espacio = elemento else { return true }
        let pestanas = (izquierda + derecha).filter { if case .espacio = $0 { return true } else { return false } }
        return pestanas.count > 1
    }
}
