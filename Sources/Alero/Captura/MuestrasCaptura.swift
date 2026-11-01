import AppKit
import SwiftUI

// Muestras de las capturas para `Alero --capturas`: la superficie de selección (área, ventana y pantalla, con la
// barra y la lupa), el editor en claro y oscuro y la miniatura del aviso del notch. Usa un escritorio inventado
// (nunca una foto de la pantalla de verdad) y no pide permisos.

@MainActor
enum MuestrasCaptura {
    /// Escritorio de ejemplo: fondo en degradé y dos ventanas, a 2× (como una pantalla Retina).
    static func escritorio(_ tamano: CGSize, escala: CGFloat = 2) -> CGImage {
        let px = CGSize(width: tamano.width * escala, height: tamano.height * escala)
        let ctx = ImagenCaptura.contexto(px, como: nil, alfa: .premultipliedLast)!
        ctx.scaleBy(x: escala, y: escala)
        let colores = [NSColor(hex: 0x1B3A5C).cgColor, NSColor(hex: 0xD9653B).cgColor] as CFArray
        let degrade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colores, locations: [0, 1])!
        ctx.drawLinearGradient(degrade, start: .zero, end: CGPoint(x: tamano.width, y: tamano.height), options: [])
        for (marco, color) in [(CGRect(x: 90, y: 160, width: 520, height: 360), 0xF5F5F7),
                               (CGRect(x: 520, y: 90, width: 560, height: 330), 0xFFFFFF)] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(NSColor(hex: UInt32(color)).cgColor)
            ctx.addPath(CGPath(roundedRect: marco, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.setFillColor(NSColor(hex: 0xE4E4E7).cgColor)
            ctx.fill(CGRect(x: marco.minX, y: marco.maxY - 34, width: marco.width, height: 22))
            for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                ctx.setFillColor(NSColor(hex: UInt32(c)).cgColor)
                ctx.fillEllipse(in: CGRect(x: marco.minX + 14 + CGFloat(i) * 20, y: marco.maxY - 22, width: 12, height: 12))
            }
            ctx.setFillColor(NSColor(hex: 0xC7C7CC).cgColor)
            for fila in 0..<6 {
                ctx.fill(CGRect(x: marco.minX + 28, y: marco.maxY - 80 - CGFloat(fila) * 34, width: marco.width * (fila % 2 == 0 ? 0.7 : 0.5), height: 12))
            }
        }
        return ctx.makeImage()!
    }

    static func hacer(en destino: URL) {
        let tamano = CGSize(width: 1200, height: 760)
        let foto = escritorio(tamano)
        let ventanas = [VentanaCandidata(id: 2, marco: CGRect(x: 520, y: 90, width: 560, height: 330), app: "Notas"),
                        VentanaCandidata(id: 1, marco: CGRect(x: 90, y: 160, width: 520, height: 360), app: "Safari")]
        let casos: [(String, ModoCaptura, (VistaSeleccion) -> Void)] = [
            ("area", .area, { $0.simular(seleccion: CGRect(x: 300, y: 250, width: 420, height: 260)) }),
            ("ventana", .ventana, { _ in }),
            ("pantalla", .pantalla, { _ in }),
        ]
        for (nombre, modo, preparar) in casos {
            let vista = VistaSeleccion(numero: 1, marco: CGRect(origin: .zero, size: tamano), escala: 2, foto: foto)
            preparar(vista)
            vista.sinAnimar { vista.pintar(modo: modo, ventana: modo == .ventana ? ventanas[0] : nil, pantalla: modo == .pantalla ? 1 : nil) }
            let ctx = ImagenCaptura.contexto(CGSize(width: tamano.width * 2, height: tamano.height * 2), como: nil, alfa: .premultipliedLast)!
            ctx.scaleBy(x: 2, y: 2)
            vista.layer?.render(in: ctx)
            if modo == .area {
                let lupa = VistaLupa(foto: foto)
                lupa.mostrar(pixel: CGPoint(x: 720 * 2, y: (tamano.height - 250) * 2))
                let origen = GeometriaCaptura.junto(a: CGPoint(x: 720, y: 250), tamano: lupa.frame.size, separacion: 22,
                                                    limites: CGRect(origin: .zero, size: tamano))
                dibujar(lupa, en: ctx, origen: origen)
            }
            let barra = BarraModos(estado: EstadoBarra(modo: modo), elegir: { _ in }, cerrar: {})
            if let imagen = imagenSwiftUI(barra) {
                let x = ((tamano.width - imagen.size.width) / 2).rounded()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                imagen.draw(in: NSRect(x: x, y: 44, width: imagen.size.width, height: imagen.size.height))
                NSGraphicsContext.restoreGraphicsState()
            }
            guardar(ctx.makeImage(), como: destino.appendingPathComponent("captura-seleccion-\(nombre).png"))
        }
        editor(en: destino)
    }

    /// El editor con unas marcas de ejemplo, en claro y en oscuro.
    private static func editor(en destino: URL) {
        let modelo = ModeloEditor(imagen: escritorio(CGSize(width: 700, height: 440)), escala: 2, url: nil)
        modelo.sumar(.flecha(desde: CGPoint(x: 260, y: 640), hasta: CGPoint(x: 560, y: 420), color: .rojo))
        modelo.sumar(.rectangulo(CGRect(x: 600, y: 300, width: 520, height: 260), color: .rojo))
        modelo.sumar(.trazo([CGPoint(x: 1100, y: 700), CGPoint(x: 1300, y: 700)], color: .amarillo))
        modelo.sumar(.texto("Esto va acá", origen: CGPoint(x: 160, y: 700), color: .blanco))
        for (sufijo, apariencia) in [("claro", NSAppearance.Name.aqua), ("oscuro", .darkAqua)] {
            let ventana = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
            ventana.appearance = NSAppearance(named: apariencia)
            let vista = NSHostingView(rootView: VistaEditor(modelo: modelo, cerrar: {}))
            ventana.contentView = vista
            vista.layoutSubtreeIfNeeded()
            guard let rep = vista.bitmapImageRepForCachingDisplay(in: vista.bounds) else { continue }
            vista.cacheDisplay(in: vista.bounds, to: rep)
            guardar(rep.cgImage, como: destino.appendingPathComponent("captura-editor-\(sufijo).png"))
        }
    }

    private static func dibujar(_ vista: NSView, en ctx: CGContext, origen: CGPoint) {
        guard let rep = vista.bitmapImageRepForCachingDisplay(in: vista.bounds) else { return }
        vista.cacheDisplay(in: vista.bounds, to: rep)
        guard let imagen = rep.cgImage else { return }
        ctx.draw(imagen, in: CGRect(origin: origen, size: vista.bounds.size))
    }

    private static func imagenSwiftUI<V: View>(_ vista: V) -> NSImage? {
        let render = ImageRenderer(content: vista)
        render.scale = 2
        return render.nsImage
    }

    /// Miniatura de ejemplo para el aviso del notch.
    static func capturaDeEjemplo() -> CapturaLista {
        let foto = escritorio(CGSize(width: 320, height: 200), escala: 1)
        return CapturaLista(url: URL(fileURLWithPath: "/tmp/Captura de ejemplo.png"),
                            miniatura: NSImage(cgImage: foto, size: NSSize(width: 160, height: 100)),
                            copiada: true, carpeta: T("Escritorio", "Desktop"), respaldo: false)
    }

    private static func guardar(_ imagen: CGImage?, como url: URL) {
        guard let imagen, let datos = ImagenCaptura.codificar(imagen, formato: .png, escala: 2) else {
            print("No se pudo dibujar \(url.lastPathComponent)")
            return
        }
        do { try datos.write(to: url) } catch { print("No se pudo guardar \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}
