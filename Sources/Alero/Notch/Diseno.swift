import AppKit
import SwiftUI

// Medidas y animaciones del notch, todas en un solo lugar (en Boring Notch están repartidas y desparejas).
// Los resortes salen de Boring Notch y se ajustan acá: abrir con un rebote apenas perceptible, cerrar sin rebote.

struct MedidasNotch: Equatable {
    /// Ancho y alto del notch físico (o de una cápsula equivalente en pantallas sin notch).
    let ancho: CGFloat
    let alto: CGFloat
    let fisico: Bool
    /// Centro horizontal del notch, en coordenadas de pantalla.
    let centroX: CGFloat
    let arriba: CGFloat

    static let deRelleno = MedidasNotch(ancho: 185, alto: 32, fisico: true, centroX: 0, arriba: 0)
}

extension NSScreen {
    var tieneNotch: Bool { safeAreaInsets.top > 0 }

    var medidasNotch: MedidasNotch {
        if tieneNotch, let izquierda = auxiliaryTopLeftArea, let derecha = auxiliaryTopRightArea {
            let centro = (izquierda.maxX + derecha.minX) / 2
            return MedidasNotch(ancho: derecha.minX - izquierda.maxX, alto: safeAreaInsets.top, fisico: true,
                                centroX: centro, arriba: frame.maxY)
        }
        // Sin notch: la cápsula mide como la barra de menú de esa pantalla (24 si la barra está escondida).
        let barra = frame.maxY - visibleFrame.maxY
        let alto = barra >= 20 ? min(barra, 32) : 24
        return MedidasNotch(ancho: 168, alto: alto, fisico: false, centroX: frame.midX, arriba: frame.maxY)
    }
}

enum ModoNotch: Equatable {
    case cerrado, abierto, aviso, hud, atajos, estante
    /// Aviso de captura lista, con la miniatura: más alto que un aviso, más chico que el notch abierto.
    case captura
    /// El teleprompter: no se cierra al sacar el mouse (se cierra con su botón).
    case prompter

    var esGrande: Bool { self == .abierto || self == .estante }
    /// Los que se van solos (y no se van mientras el mouse está encima).
    var esPasajero: Bool { self == .aviso || self == .atajos || self == .hud || self == .captura }
    /// Los que bajan por encima de las ventanas y necesitan sombra para despegarse.
    var conSombra: Bool { esGrande || self == .captura || self == .prompter }
}

enum Diseno {
    static let abrir = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let cerrar = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let cambio = Animation.smooth(duration: 0.3)

    /// Ancho de cada "ala" (a los costados de la cámara) según lo que se muestra cerrado.
    static let alaMusica: CGFloat = 38
    static let alaPunto: CGFloat = 28
    static let alaAviso: CGFloat = 136
    static let alaAtajos: CGFloat = 50

    /// Límites del tamaño abierto que se elige en Ajustes (ancho y alto, sin contar la franja de la cámara).
    static let anchosPosibles: ClosedRange<Double> = 560...840
    static let altosPosibles: ClosedRange<Double> = 150...260
    static let anchoEstante: CGFloat = 500
    static let altoEstante: CGFloat = 126
    static let anchoCaptura: CGFloat = 470
    static let altoCaptura: CGFloat = 96
    /// El teleprompter: grande para leer cómodo (más grande desde el 01/11/2026).
    static let anchoPrompter: CGFloat = 660
    static let altoPrompter: CGFloat = 200

    private static var anchoAbierto: CGFloat { CGFloat(min(max(Ajustes.shared.notchAncho, anchosPosibles.lowerBound), anchosPosibles.upperBound)) }
    private static var altoAbierto: CGFloat { CGFloat(min(max(Ajustes.shared.notchAlto, altosPosibles.lowerBound), altosPosibles.upperBound)) }

    /// Lo que mide la ventana fija del notch (no se agranda nunca: se anima la forma adentro). Alcanza para el
    /// tamaño más grande que se puede elegir, así cambiar el tamaño no mueve la ventana.
    static func tamanoVentana(_ medidas: MedidasNotch) -> CGSize {
        CGSize(width: CGFloat(anchosPosibles.upperBound) + 2 * 19 + 60, height: medidas.alto + CGFloat(altosPosibles.upperBound) + 40)
    }

    /// Tamaño del cuerpo negro (sin los hombros) para cada modo.
    static func tamano(_ modo: ModoNotch, _ medidas: MedidasNotch, musica: Bool, punto: Bool) -> CGSize {
        let notch = medidas.ancho
        switch modo {
        case .cerrado:
            if musica { return CGSize(width: notch + 2 * alaMusica, height: medidas.alto) }
            if punto { return CGSize(width: notch + 2 * alaPunto, height: medidas.alto) }
            // Sin notch físico: una cápsula para verlo y abrirlo (opción de Ajustes), o nada.
            let visible = medidas.fisico || Ajustes.shared.notchCapsula
            return CGSize(width: visible ? notch : 0, height: medidas.alto)
        case .aviso, .hud: return CGSize(width: notch + 2 * alaAviso, height: medidas.alto)
        case .atajos:
            // Cada ala alcanza para la mitad de los atajos elegidos (34 pt cada uno).
            let porLado = CGFloat((Ajustes.shared.notchAtajosElegidos.count + 1) / 2)
            return CGSize(width: notch + 2 * max(alaAtajos, 16 + porLado * 34), height: medidas.alto)
        case .abierto: return CGSize(width: max(anchoAbierto, notch + 300), height: medidas.alto + altoAbierto)
        case .estante: return CGSize(width: max(anchoEstante, notch + 200), height: medidas.alto + altoEstante)
        case .captura: return CGSize(width: max(anchoCaptura, notch + 220), height: medidas.alto + altoCaptura)
        case .prompter: return CGSize(width: max(anchoPrompter, notch + 260), height: medidas.alto + altoPrompter)
        }
    }

    /// Radios: el "hombro" cóncavo arriba (donde toca la barra) y la esquina de abajo.
    static func radios(_ modo: ModoNotch) -> (hombro: CGFloat, esquina: CGFloat) {
        switch modo {
        case .cerrado: return (6, 12)
        case .aviso, .hud, .atajos: return (8, 14)
        case .captura, .prompter: return (14, 22)
        case .abierto, .estante: return (19, 26)
        }
    }
}

/// Forma del notch: cuerpo con esquinas redondeadas abajo y dos hombros cóncavos arriba que lo funden con el
/// borde de la pantalla. Los dos radios se animan.
struct FormaNotch: Shape {
    var hombro: CGFloat
    var esquina: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(hombro, esquina) }
        set { hombro = newValue.first; esquina = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let h = min(hombro, rect.height / 2)
        let r = min(esquina, (rect.width - 2 * h) / 2, rect.height - h)
        var camino = Path()
        camino.move(to: CGPoint(x: rect.minX, y: rect.minY))
        camino.addQuadCurve(to: CGPoint(x: rect.minX + h, y: rect.minY + h), control: CGPoint(x: rect.minX + h, y: rect.minY))
        camino.addLine(to: CGPoint(x: rect.minX + h, y: rect.maxY - r))
        camino.addQuadCurve(to: CGPoint(x: rect.minX + h + r, y: rect.maxY), control: CGPoint(x: rect.minX + h, y: rect.maxY))
        camino.addLine(to: CGPoint(x: rect.maxX - h - r, y: rect.maxY))
        camino.addQuadCurve(to: CGPoint(x: rect.maxX - h, y: rect.maxY - r), control: CGPoint(x: rect.maxX - h, y: rect.maxY))
        camino.addLine(to: CGPoint(x: rect.maxX - h, y: rect.minY + h))
        camino.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - h, y: rect.minY))
        camino.closeSubpath()
        return camino
    }
}

/// Cómo entra el contenido: de un poco más chico, desenfocado y transparente a nítido (anclado arriba).
struct Entrada: ViewModifier {
    let activo: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(activo ? 0.86 : 1, anchor: .top)
            .blur(radius: activo ? 10 : 0)
            .opacity(activo ? 0 : 1)
    }
}

extension AnyTransition {
    static var entradaNotch: AnyTransition {
        .modifier(active: Entrada(activo: true), identity: Entrada(activo: false))
    }
}
