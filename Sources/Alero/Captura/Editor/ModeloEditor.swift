import AppKit
import Combine

// Lo que se edita de una captura: las anotaciones (flecha, rectángulo, resaltador, texto) y el recorte, con su
// historial para deshacer. Todo en píxeles de la imagen con origen arriba: así la pantalla y el archivo dibujan
// igual, a cualquier zoom. La imagen original no se toca hasta que se guarda.

enum HerramientaEditor: String, CaseIterable, Identifiable {
    case recortar, flecha, rectangulo, resaltador, texto

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .recortar: return T("Recortar", "Crop")
        case .flecha: return T("Flecha", "Arrow")
        case .rectangulo: return T("Rectángulo", "Rectangle")
        case .resaltador: return T("Resaltador", "Highlighter")
        case .texto: return T("Texto", "Text")
        }
    }

    var icono: String {
        switch self {
        case .recortar: return "crop"
        case .flecha: return "arrow.up.right"
        case .rectangulo: return "rectangle"
        case .resaltador: return "highlighter"
        case .texto: return "textformat"
        }
    }
}

enum ColorAnotacion: String, CaseIterable, Identifiable {
    case rojo, amarillo, celeste, verde, blanco, negro

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .rojo: return NSColor(hex: 0xFF3B30)
        case .amarillo: return NSColor(hex: 0xFFCC00)
        case .celeste: return NSColor(hex: 0x0A84FF)
        case .verde: return NSColor(hex: 0x30D158)
        case .blanco: return .white
        case .negro: return NSColor(hex: 0x1D1D1C)
        }
    }

    var nombre: String {
        switch self {
        case .rojo: return T("Rojo", "Red")
        case .amarillo: return T("Amarillo", "Yellow")
        case .celeste: return T("Azul", "Blue")
        case .verde: return T("Verde", "Green")
        case .blanco: return T("Blanco", "White")
        case .negro: return T("Negro", "Black")
        }
    }
}

enum Anotacion: Equatable {
    case flecha(desde: CGPoint, hasta: CGPoint, color: ColorAnotacion)
    case rectangulo(CGRect, color: ColorAnotacion)
    case trazo([CGPoint], color: ColorAnotacion)
    /// `origen`: la esquina de arriba a la izquierda del texto.
    case texto(String, origen: CGPoint, color: ColorAnotacion)
}

struct Edicion: Equatable {
    var anotaciones: [Anotacion] = []
    /// En píxeles de la imagen; nil = la imagen entera.
    var recorte: CGRect?
}

final class ModeloEditor: ObservableObject {
    let imagen: CGImage
    /// Píxeles por punto (2 en Retina): da el grosor de los trazos y el tamaño del texto.
    let escala: CGFloat
    /// El archivo de la captura: "Guardar" lo reemplaza por la versión editada.
    let url: URL?

    @Published private(set) var edicion = Edicion()
    @Published var herramienta: HerramientaEditor = .flecha
    @Published var color: ColorAnotacion = .rojo
    @Published private(set) var sinGuardar = false
    @Published private(set) var historial: [Edicion] = []

    init(imagen: CGImage, escala: CGFloat, url: URL?) {
        self.imagen = imagen
        self.escala = escala
        self.url = url
    }

    var completa: CGRect { CGRect(x: 0, y: 0, width: imagen.width, height: imagen.height) }
    /// Lo que se ve y lo que se guarda.
    var visible: CGRect { edicion.recorte ?? completa }
    var puedeDeshacer: Bool { !historial.isEmpty }

    func sumar(_ anotacion: Anotacion) {
        cambiar { $0.anotaciones.append(anotacion) }
    }

    /// Recorta a `rect` (píxeles). Se ignora si queda muy chico (un clic sin querer con la herramienta de recortar).
    func recortar(_ rect: CGRect) {
        let limpio = rect.standardized.integral.intersection(visible)
        guard !limpio.isNull, limpio.width >= 8, limpio.height >= 8 else { return }
        cambiar { $0.recorte = limpio }
    }

    func deshacer() {
        guard let anterior = historial.popLast() else { return }
        edicion = anterior
        sinGuardar = true
    }

    private func cambiar(_ hacer: (inout Edicion) -> Void) {
        historial.append(edicion)
        hacer(&edicion)
        sinGuardar = true
    }

    /// La imagen final, a resolución completa: recortada y con las anotaciones.
    func exportar() -> CGImage? {
        let area = visible
        guard let ctx = ImagenCaptura.contexto(area.size, como: imagen, alfa: .premultipliedLast) else { return nil }
        // Origen arriba, como las anotaciones, y corrido al recorte.
        ctx.translateBy(x: 0, y: area.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        DibujoAnotaciones.dibujar(imagen: imagen, anotaciones: edicion.anotaciones, escala: escala, en: ctx)
        return ctx.makeImage()
    }

    /// Reemplaza el archivo por la versión editada, en su mismo formato. Main thread (es una imagen sola).
    func guardar() -> Bool {
        guard let url, let final = exportar(),
              let datos = ImagenCaptura.codificar(final, formato: FormatoCaptura.de(url), escala: escala) else { return false }
        do {
            try datos.write(to: url, options: .atomic)
            sinGuardar = false
            return true
        } catch {
            NSLog("Alero: no se pudo guardar la captura editada: \(error.localizedDescription)")
            return false
        }
    }

    func copiar() -> Bool {
        guard let final = exportar(), let png = ImagenCaptura.codificar(final, formato: .png, escala: escala) else { return false }
        ImagenCaptura.copiar(png: png)
        return true
    }
}
