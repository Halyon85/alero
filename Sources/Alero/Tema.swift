import AppKit
import SwiftUI

// Paleta de Alero: la misma familia que Relevo y Dixity (grises cálidos, botón principal casi negro o casi blanco)
// con un acento celeste propio. El notch es siempre negro, para fundirse con el notch físico.

enum Tema {
    static func dinamico(_ claro: UInt32, _ oscuro: UInt32, alfaClaro: CGFloat = 1, alfaOscuro: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { apariencia in
            let esOscuro = apariencia.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: esOscuro ? oscuro : claro, alfa: esOscuro ? alfaOscuro : alfaClaro)
        })
    }

    // Ventanas (claro / oscuro), como en Relevo.
    static let fondo = dinamico(0xFBFAF9, 0x1D1D1C)
    static let tarjeta = dinamico(0xFFFFFF, 0x242321)
    static let relleno = dinamico(0x2B2A29, 0xFFE4D3, alfaClaro: 0.05, alfaOscuro: 0.08)
    static let rellenoSuave = dinamico(0x2B2A29, 0xFFDBB7, alfaClaro: 0.03, alfaOscuro: 0.06)
    static let titulo = dinamico(0x161616, 0xFAF7F7)
    static let texto = dinamico(0x1D1D1C, 0xF8F4F3)
    static let subtitulo = dinamico(0x494543, 0xD0C4C0)
    static let apagado = dinamico(0x877A76, 0x9F928E)
    static let bordeSuave = dinamico(0x2B2A29, 0xFFDCC6, alfaClaro: 0.06, alfaOscuro: 0.10)
    static let pildora = dinamico(0x1D1D1C, 0xFAF7F7)
    static let pildoraTexto = dinamico(0xFFFFFF, 0x000000)
    static let exito = Color(nsColor: NSColor(hex: 0x00B489))
    static let error = Color(nsColor: NSColor(hex: 0xE5484D))
    /// Acento de Alero en las ventanas: celeste más oscuro en claro para que se lea sobre blanco.
    static let acentoVentana = dinamico(0x0A84C2, 0x8FD8FF)

    static let radioTarjeta: CGFloat = 14
    static let anchoBarra: CGFloat = 220
    static let anchoPagina: CGFloat = 640
    static let expo = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)

    // Notch (siempre oscuro)
    static let notch = Color.black
    static let acento = Color(nsColor: NSColor(hex: 0x8FD8FF))
    static let acentoFondo = Color(nsColor: NSColor(hex: 0x0F2A36))
    static let textoNotch = Color(nsColor: NSColor(hex: 0xF5F5F7))
    static let textoNotchSuave = Color(nsColor: NSColor(hex: 0xA1A1A6))
    static let rellenoNotch = Color(nsColor: NSColor(hex: 0x1C1C1F))
    static let bordeNotch = Color(nsColor: NSColor(hex: 0x2E2E33))
}

extension NSColor {
    convenience init(hex: UInt32, alfa: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alfa)
    }
}

extension Font {
    static func titulo(_ tam: CGFloat, _ peso: Font.Weight = .medium) -> Font { .system(size: tam, weight: peso) }
}
