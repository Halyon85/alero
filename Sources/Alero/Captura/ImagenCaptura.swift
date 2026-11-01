import AppKit
import ImageIO

// Lo que se hace con la imagen ya capturada: recortarla soltando la foto grande, ponerle sombra a una ventana,
// pasarla a PNG o JPG, guardarla, copiarla al portapapeles y sacar la miniatura para el notch. Lo pesado (codificar y
// escribir) corre fuera del hilo principal; nada queda guardado en memoria después.

enum ImagenCaptura {
    /// Copia de `recorte` (píxeles, origen arriba) en una imagen propia. A propósito no se usa `cropping(to:)` solo:
    /// ese recorte comparte la memoria de la foto entera y la mantendría viva (decenas de MB por pantalla).
    static func copia(_ imagen: CGImage, recorte: CGRect) -> CGImage? {
        guard let parte = imagen.cropping(to: recorte) else { return nil }
        return redibujar(parte, lienzo: CGSize(width: parte.width, height: parte.height), en: .zero, sombra: nil)
    }

    /// La ventana sobre un lienzo transparente más grande, con una sombra suave como la de macOS.
    static func conSombra(_ ventana: CGImage, escala: CGFloat) -> CGImage? {
        let margen = GeometriaCaptura.margenesSombra(escala: escala)
        let lienzo = CGSize(width: CGFloat(ventana.width) + 2 * margen.lado,
                            height: CGFloat(ventana.height) + margen.arriba + margen.abajo)
        // El contexto cuenta desde abajo: la ventana queda `abajo` píxeles arriba del borde inferior.
        let sombra = (desplazamiento: CGSize(width: 0, height: -14 * escala), difuminado: 34 * escala)
        return redibujar(ventana, lienzo: lienzo, en: CGPoint(x: margen.lado, y: margen.abajo), sombra: sombra)
    }

    private static func redibujar(_ imagen: CGImage, lienzo: CGSize, en origen: CGPoint,
                                  sombra: (desplazamiento: CGSize, difuminado: CGFloat)?) -> CGImage? {
        guard let ctx = contexto(lienzo, como: imagen, alfa: .premultipliedLast) else { return nil }
        if let sombra {
            ctx.setShadow(offset: sombra.desplazamiento, blur: sombra.difuminado, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        }
        ctx.draw(imagen, in: CGRect(origin: origen, size: CGSize(width: imagen.width, height: imagen.height)))
        return ctx.makeImage()
    }

    /// Lienzo de 8 bits en el espacio de color de la captura (P3 en las Mac nuevas, así no se lavan los colores). Si
    /// ese espacio no sirve para dibujar (por ejemplo, uno de HDR), en sRGB.
    static func contexto(_ tamano: CGSize, como imagen: CGImage?, alfa: CGImageAlphaInfo) -> CGContext? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        for espacio in [imagen?.colorSpace, srgb].compactMap({ $0 }) {
            if let ctx = CGContext(data: nil, width: Int(tamano.width), height: Int(tamano.height), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: espacio, bitmapInfo: alfa.rawValue) { return ctx }
        }
        return nil
    }

    /// El archivo en PNG o JPG, marcado con su densidad (144 ppp en Retina) para que Vista Previa la muestre a su
    /// tamaño real. JPG no tiene transparencia: se pone sobre blanco (si no, las esquinas de una ventana salen negras).
    static func codificar(_ imagen: CGImage, formato: FormatoCaptura, escala: CGFloat) -> Data? {
        let datos = NSMutableData()
        guard let destino = CGImageDestinationCreateWithData(datos, formato.uti as CFString, 1, nil) else { return nil }
        var propiedades: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * escala, kCGImagePropertyDPIHeight: 72 * escala]
        var final = imagen
        if formato == .jpg {
            propiedades[kCGImageDestinationLossyCompressionQuality] = 0.9
            final = sobreBlanco(imagen) ?? imagen
        }
        CGImageDestinationAddImage(destino, final, propiedades as CFDictionary)
        guard CGImageDestinationFinalize(destino) else { return nil }
        return datos as Data
    }

    private static func sobreBlanco(_ imagen: CGImage) -> CGImage? {
        guard let ctx = contexto(CGSize(width: imagen.width, height: imagen.height), como: imagen, alfa: .noneSkipLast) else { return nil }
        let todo = CGRect(x: 0, y: 0, width: imagen.width, height: imagen.height)
        ctx.setFillColor(.white)
        ctx.fill(todo)
        ctx.draw(imagen, in: todo)
        return ctx.makeImage()
    }

    /// Miniatura chiquita (hasta 360 px) para el aviso del notch, sacada de los datos ya codificados.
    static func miniatura(de datos: Data, escala: CGFloat) -> NSImage? {
        guard let fuente = CGImageSourceCreateWithData(datos as CFData, nil) else { return nil }
        let opciones: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 360,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
        guard let chica = CGImageSourceCreateThumbnailAtIndex(fuente, 0, opciones as CFDictionary) else { return nil }
        return NSImage(cgImage: chica, size: NSSize(width: CGFloat(chica.width) / 2, height: CGFloat(chica.height) / 2))
    }

    /// Lee una captura guardada (para el editor y para fijarla) con su escala, sacada de la densidad del archivo.
    static func leer(_ url: URL) -> (imagen: CGImage, escala: CGFloat)? {
        guard let fuente = CGImageSourceCreateWithURL(url as CFURL, nil),
              let imagen = CGImageSourceCreateImageAtIndex(fuente, 0, nil) else { return nil }
        let propiedades = CGImageSourceCopyPropertiesAtIndex(fuente, 0, nil) as? [CFString: Any]
        let ppp = (propiedades?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return (imagen, max(1, CGFloat(ppp / 72).rounded()))
    }

    /// Al portapapeles como PNG (lo que entienden casi todas las apps). Main thread.
    static func copiar(png: Data) {
        let tablero = NSPasteboard.general
        tablero.clearContents()
        tablero.setData(png, forType: .png)
    }

    /// El sonido de captura de macOS. Si un macOS futuro lo mueve, no suena nada (no es grave).
    static func sonar() {
        let ruta = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        guard FileManager.default.fileExists(atPath: ruta) else { return }
        NSSound(contentsOfFile: ruta, byReference: true)?.play()
    }
}
