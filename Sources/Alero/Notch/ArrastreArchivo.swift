import AppKit
import SwiftUI

// Origen de arrastre de AppKit para sacar un archivo del notch (el estante y la miniatura de una captura). Lo usa
// SwiftUI encima de la ficha. Un clic sin arrastrar puede hacer otra cosa (`alClic`: abrir el editor de la captura).

/// Deja llevar el archivo afuera solo como COPIA. Si se ofreciera "mover", Finder lo movería y el estante perdería la
/// referencia.
struct ArrastreArchivo: NSViewRepresentable {
    let url: URL
    let icono: NSImage
    /// Lado de la imagen que se ve mientras se arrastra.
    var lado: CGFloat = 44
    var alClic: (() -> Void)? = nil

    func makeNSView(context: Context) -> VistaArrastrable { VistaArrastrable(url: url, icono: icono) }

    func updateNSView(_ vista: VistaArrastrable, context: Context) {
        vista.url = url
        vista.icono = icono
        vista.lado = lado
        vista.alClic = alClic
    }

    final class VistaArrastrable: NSView, NSDraggingSource {
        var url: URL
        var icono: NSImage
        var lado: CGFloat = 44
        var alClic: (() -> Void)?
        /// Si este clic ya empezó a arrastrar (entonces al soltar no es un clic).
        private var arrastro = false

        init(url: URL, icono: NSImage) {
            self.url = url
            self.icono = icono
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { arrastro = false }

        override func mouseUp(with event: NSEvent) {
            if !arrastro { alClic?() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !arrastro else { return }
            arrastro = true
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let proporcion = icono.size.height > 0 ? icono.size.width / icono.size.height : 1
            let tamano = proporcion >= 1 ? NSSize(width: lado, height: lado / proporcion) : NSSize(width: lado * proporcion, height: lado)
            item.setDraggingFrame(NSRect(x: bounds.midX - tamano.width / 2, y: bounds.midY - tamano.height / 2,
                                         width: tamano.width, height: tamano.height), contents: icono)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ sesion: NSDraggingSession, sourceOperationMaskFor contexto: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
