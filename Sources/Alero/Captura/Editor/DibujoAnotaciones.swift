import AppKit

// Cómo se dibuja cada anotación. Lo usan el lienzo del editor (a cualquier zoom) y la exportación (a tamaño real),
// así lo que se ve es lo que se guarda. El contexto viene en píxeles de la imagen con origen arriba (y para abajo).
// Los grosores van en puntos por `escala`: una flecha mide lo mismo a la vista en una captura Retina o en una de 1×.

enum DibujoAnotaciones {
    static func dibujar(imagen: CGImage, anotaciones: [Anotacion], escala: CGFloat, en ctx: CGContext) {
        // CGContext dibuja las imágenes con el origen abajo: se da vuelta solo para la foto.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(imagen.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(imagen, in: CGRect(x: 0, y: 0, width: imagen.width, height: imagen.height))
        ctx.restoreGState()
        for anotacion in anotaciones { dibujar(anotacion, escala: escala, en: ctx) }
    }

    static func dibujar(_ anotacion: Anotacion, escala: CGFloat, en ctx: CGContext) {
        switch anotacion {
        case .flecha(let desde, let hasta, let color): flecha(desde, hasta, color: color.nsColor, escala: escala, en: ctx)
        case .rectangulo(let rect, let color): rectangulo(rect, color: color.nsColor, escala: escala, en: ctx)
        case .trazo(let puntos, let color): resaltador(puntos, color: color.nsColor, escala: escala, en: ctx)
        case .texto(let texto, let origen, let color): self.texto(texto, en: origen, color: color.nsColor, escala: escala, ctx: ctx)
        }
    }

    /// Tamaño de letra del texto, en píxeles de la imagen.
    static func tamanoTexto(escala: CGFloat) -> CGFloat { 22 * escala }

    static func fuenteTexto(escala: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: tamanoTexto(escala: escala), weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
    }

    // MARK: - Cada una

    /// Sombra chica para que las marcas se lean sobre cualquier fondo.
    private static func sombra(_ ctx: CGContext, escala: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: 1 * escala), blur: 3 * escala, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    }

    private static func flecha(_ a: CGPoint, _ b: CGPoint, color: NSColor, escala: CGFloat, en ctx: CGContext) {
        let largo = hypot(b.x - a.x, b.y - a.y)
        guard largo > 1 else { return }
        let grosor = 4 * escala
        let punta = min(max(16 * escala, grosor * 4), largo * 0.6)
        let angulo = atan2(b.y - a.y, b.x - a.x)
        let apertura: CGFloat = .pi / 7
        let base = CGPoint(x: b.x - cos(angulo) * punta * 0.8, y: b.y - sin(angulo) * punta * 0.8)
        ctx.saveGState()
        sombra(ctx, escala: escala)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(grosor)
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: base)
        ctx.strokePath()
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: b.x - cos(angulo - apertura) * punta, y: b.y - sin(angulo - apertura) * punta))
        ctx.addLine(to: CGPoint(x: b.x - cos(angulo + apertura) * punta, y: b.y - sin(angulo + apertura) * punta))
        ctx.closePath()
        ctx.setLineJoin(.round)
        ctx.setLineWidth(grosor * 0.5)
        ctx.drawPath(using: .fillStroke)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func rectangulo(_ r: CGRect, color: NSColor, escala: CGFloat, en ctx: CGContext) {
        let grosor = 4 * escala
        ctx.saveGState()
        sombra(ctx, escala: escala)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(grosor)
        ctx.setLineJoin(.round)
        let radio = min(6 * escala, r.width / 2, r.height / 2)
        ctx.addPath(CGPath(roundedRect: r.standardized, cornerWidth: radio, cornerHeight: radio, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Como un marcador de verdad: trazo ancho, transparente y en "multiplicar", así el texto de abajo se sigue leyendo.
    /// Se dibuja como un solo camino para que los cruces no se oscurezcan.
    private static func resaltador(_ puntos: [CGPoint], color: NSColor, escala: CGFloat, en ctx: CGContext) {
        guard let primero = puntos.first else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(20 * escala)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: primero)
        if puntos.count == 1 { ctx.addLine(to: primero) }
        for punto in puntos.dropFirst() { ctx.addLine(to: punto) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func texto(_ texto: String, en origen: CGPoint, color: NSColor, escala: CGFloat, ctx: CGContext) {
        let atributos: [NSAttributedString.Key: Any] = [.font: fuenteTexto(escala: escala), .foregroundColor: color]
        ctx.saveGState()
        sombra(ctx, escala: escala)
        // El contexto ya va con el origen arriba: AppKit escribe derecho si se le avisa que está dado vuelta.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: texto, attributes: atributos).draw(at: origen)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}
