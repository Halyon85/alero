import CoreGraphics
import Foundation

// Tipos de las capturas de pantalla: qué se captura (área, ventana o pantalla), en qué formato se guarda, cómo se
// llama el archivo y el atajo de fábrica. Lógica pura (sin pantalla ni permisos): se prueba con `swift test`.

enum ModoCaptura: String, CaseIterable, Identifiable {
    case area, ventana, pantalla

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .area: return T("Área", "Area")
        case .ventana: return T("Ventana", "Window")
        case .pantalla: return T("Pantalla", "Screen")
        }
    }

    /// Lo que dice el menú de la barra.
    var accion: String {
        switch self {
        case .area: return T("Capturar área", "Capture area")
        case .ventana: return T("Capturar ventana", "Capture window")
        case .pantalla: return T("Capturar pantalla", "Capture screen")
        }
    }

    var icono: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .ventana: return "macwindow"
        case .pantalla: return "display"
        }
    }

    /// Número del atajo para Carbon (cada modo tiene el suyo).
    var numeroAtajo: UInt32 {
        switch self {
        case .area: return 1
        case .ventana: return 2
        case .pantalla: return 3
        }
    }
}

enum FormatoCaptura: String, CaseIterable, Identifiable {
    case png, jpg

    var id: String { rawValue }
    var nombre: String { rawValue.uppercased() }
    var extensionArchivo: String { rawValue }
    /// Tipo de archivo para ImageIO.
    var uti: String { self == .png ? "public.png" : "public.jpeg" }

    /// Por la extensión de un archivo ya guardado (el editor guarda en el mismo formato).
    static func de(_ url: URL) -> FormatoCaptura {
        ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpg : .png
    }
}

enum NombreCaptura {
    /// "Captura 2026-10-31 a las 23.15.42.png" (o "Screenshot 2026-10-31 at 23.15.42.png"), como macOS: con puntos
    /// en la hora porque Finder no deja ":" en los nombres. La fecha sale del calendario, no de cuentas a mano.
    static func nombre(fecha: Date, formato: FormatoCaptura, castellano: Bool, zona: TimeZone = .current) -> String {
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = zona
        let c = calendario.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fecha)
        let dia = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let hora = String(format: "%02d.%02d.%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let base = castellano ? "Captura \(dia) a las \(hora)" : "Screenshot \(dia) at \(hora)"
        return "\(base).\(formato.extensionArchivo)"
    }
}

extension AtajoTeclado {
    /// ⇧⌘2: macOS no lo usa (las suyas son ⇧⌘3, 4, 5 y 6). La tecla 19 es el 2 de la fila de números en todos
    /// los teclados.
    static let capturaPorDefecto = AtajoTeclado(codigo: 19, modificadores: CGEventFlags([.maskShift, .maskCommand]).rawValue,
                                                 texto: "⇧⌘2")

    /// Un atajo que puede no estar: sin atajo se guarda vacío (así se distingue de "nunca se tocó", que usa el de
    /// fábrica registrado en `Ajustes`).
    static func datos(_ atajo: AtajoTeclado?) -> Data {
        guard let atajo else { return Data() }
        return (try? JSONEncoder().encode(atajo)) ?? Data()
    }

    static func leer(_ datos: Data?) -> AtajoTeclado? {
        guard let datos, !datos.isEmpty else { return nil }
        return try? JSONDecoder().decode(AtajoTeclado.self, from: datos)
    }

    /// La tecla sola, sin los símbolos de las modificadoras ("⇧⌘2" → "2"), para el atajo que muestra el menú.
    var teclaSola: String {
        String(texto.drop { "⌃⌥⇧⌘".contains($0) })
    }
}
