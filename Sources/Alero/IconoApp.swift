import AppKit

// Los dos logos de Alero, dibujados en código (nítidos en cualquier tamaño y sin archivos):
// - el de la app: un mosaico claro con el "alero" negro arriba (el notch con sus hombros) y la luz celeste;
// - el de la barra de menú: una pantalla con su notch, en plantilla (macOS la pinta blanca o negra).
// `Alero --icono <archivo.png>` guarda el de la app en 1024 px para armar AppIcon.icns.

enum IconoApp {
    static func imagen(lado: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: lado, height: lado), flipped: true) { _ in
            let s = lado / 1024
            // Mosaico con la forma de los íconos de macOS (margen de 100 px de la grilla de Apple).
            let mosaico = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                                       xRadius: 186 * s, yRadius: 186 * s)
            NSGraphicsContext.saveGraphicsState()
            let sombra = NSShadow()
            sombra.shadowColor = NSColor.black.withAlphaComponent(0.28)
            sombra.shadowBlurRadius = 24 * s
            sombra.shadowOffset = NSSize(width: 0, height: -10 * s)
            sombra.set()
            NSColor(hex: 0xF7F4F1).setFill()
            mosaico.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            mosaico.addClip()
            NSGradient(starting: NSColor(hex: 0xFFFFFF), ending: NSColor(hex: 0xE8E2DC))?.draw(in: mosaico, angle: 90)
            // El alero: cuerpo negro con hombros cóncavos arriba, pegado al borde superior del mosaico.
            alero(en: NSRect(x: 230 * s, y: 100 * s, width: 564 * s, height: 250 * s), hombro: 52 * s, esquina: 110 * s).fill(con: .black)
            // La luz: la "isla" viva.
            NSColor(hex: 0x8FD8FF).setFill()
            NSBezierPath(ovalIn: NSRect(x: 640 * s, y: 196 * s, width: 64 * s, height: 64 * s)).fill()
            NSColor(hex: 0x3A3A3C).setFill()
            NSBezierPath(roundedRect: NSRect(x: 330 * s, y: 212 * s, width: 150 * s, height: 32 * s), xRadius: 16 * s, yRadius: 16 * s).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Ícono de la barra: una pantalla redondeada con el notch arriba. Con el café prendido, el notch lleva un punto.
    static func barra(cafe: Bool) -> NSImage {
        let imagen = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let pantalla = NSBezierPath(roundedRect: NSRect(x: 1.7, y: 2.2, width: 16.6, height: 12), xRadius: 3.2, yRadius: 3.2)
            pantalla.lineWidth = 1.5
            pantalla.stroke()
            let notch = alero(en: NSRect(x: 6, y: 1.5, width: 8, height: 4.6), hombro: 1.1, esquina: 2)
            notch.fill()
            if cafe {
                NSBezierPath(ovalIn: NSRect(x: 8.2, y: 8.4, width: 3.6, height: 3.6)).fill()
            }
            return true
        }
        imagen.isTemplate = true
        imagen.accessibilityDescription = "Alero"
        return imagen
    }

    /// La misma forma del notch de la app (hombros cóncavos arriba, esquinas redondeadas abajo), en AppKit.
    private static func alero(en r: NSRect, hombro h: CGFloat, esquina e: CGFloat) -> NSBezierPath {
        let camino = NSBezierPath()
        camino.move(to: NSPoint(x: r.minX - h, y: r.minY))
        camino.curve(to: NSPoint(x: r.minX, y: r.minY + h),
                     controlPoint1: NSPoint(x: r.minX - h * 0.45, y: r.minY), controlPoint2: NSPoint(x: r.minX, y: r.minY + h * 0.45))
        camino.line(to: NSPoint(x: r.minX, y: r.maxY - e))
        camino.curve(to: NSPoint(x: r.minX + e, y: r.maxY),
                     controlPoint1: NSPoint(x: r.minX, y: r.maxY - e * 0.45), controlPoint2: NSPoint(x: r.minX + e * 0.45, y: r.maxY))
        camino.line(to: NSPoint(x: r.maxX - e, y: r.maxY))
        camino.curve(to: NSPoint(x: r.maxX, y: r.maxY - e),
                     controlPoint1: NSPoint(x: r.maxX - e * 0.45, y: r.maxY), controlPoint2: NSPoint(x: r.maxX, y: r.maxY - e * 0.45))
        camino.line(to: NSPoint(x: r.maxX, y: r.minY + h))
        camino.curve(to: NSPoint(x: r.maxX + h, y: r.minY),
                     controlPoint1: NSPoint(x: r.maxX, y: r.minY + h * 0.45), controlPoint2: NSPoint(x: r.maxX + h * 0.45, y: r.minY))
        camino.close()
        return camino
    }

    static func guardar(en ruta: String) {
        let imagen = imagen(lado: 1024)
        guard let tiff = imagen.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("No se pudo dibujar el ícono")
            return
        }
        do { try png.write(to: URL(fileURLWithPath: ruta)); print("Ícono en \(ruta)") } catch {
            print("No se pudo guardar el ícono: \(error.localizedDescription)")
        }
    }
}

private extension NSBezierPath {
    func fill(con color: NSColor) {
        color.setFill()
        fill()
    }
}
