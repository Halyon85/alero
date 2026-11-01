import AppKit
import SwiftUI

// El lienzo del editor: muestra la captura (o su recorte) entera en el espacio que hay, nunca más grande que su
// tamaño real, y convierte el mouse en anotaciones. Las cuentas van en píxeles de la imagen; la vista solo hace zoom.
// El texto se escribe en un campo encima y, al terminar, pasa a ser una anotación más.

struct Lienzo: NSViewRepresentable {
    @ObservedObject var modelo: ModeloEditor

    func makeNSView(context: Context) -> LienzoEditor { LienzoEditor(modelo: modelo) }

    func updateNSView(_ vista: LienzoEditor, context: Context) {
        vista.herramientaCambio()
        vista.needsDisplay = true
    }
}

final class LienzoEditor: NSView, NSTextFieldDelegate {
    private let modelo: ModeloEditor
    /// Lo que se está dibujando con el mouse apretado (todavía no está en el historial).
    private var borrador: Anotacion?
    private var recorteBorrador: CGRect?
    private var inicio: CGPoint?
    private var campo: NSTextField?
    private var origenCampo: CGPoint = .zero

    init(modelo: ModeloEditor) {
        self.modelo = modelo
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Zoom

    /// Margen alrededor de la imagen, para que respire.
    private let margen: CGFloat = 24

    private var zoom: CGFloat {
        let area = modelo.visible
        let disponible = bounds.insetBy(dx: margen, dy: margen)
        guard area.width > 0, area.height > 0, disponible.width > 0, disponible.height > 0 else { return 1 }
        // Como mucho a tamaño real (un punto de la captura = un punto de la pantalla).
        return min(disponible.width / area.width, disponible.height / area.height, 1 / modelo.escala)
    }

    /// Dónde cae la imagen visible dentro de la vista.
    private var marcoImagen: CGRect {
        let area = modelo.visible
        let tamano = CGSize(width: area.width * zoom, height: area.height * zoom)
        return CGRect(x: ((bounds.width - tamano.width) / 2).rounded(), y: ((bounds.height - tamano.height) / 2).rounded(),
                      width: tamano.width, height: tamano.height)
    }

    private func aImagen(_ p: CGPoint) -> CGPoint {
        let marco = marcoImagen
        let area = modelo.visible
        let x = (p.x - marco.minX) / zoom + area.minX
        let y = (p.y - marco.minY) / zoom + area.minY
        return CGPoint(x: min(max(x, area.minX), area.maxX), y: min(max(y, area.minY), area.maxY))
    }

    private func aVista(_ p: CGPoint) -> CGPoint {
        let marco = marcoImagen
        let area = modelo.visible
        return CGPoint(x: (p.x - area.minX) * zoom + marco.minX, y: (p.y - area.minY) * zoom + marco.minY)
    }

    // MARK: - Dibujo

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let marco = marcoImagen
        let area = modelo.visible
        // Sombra suave debajo de la imagen.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(marco)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: marco)
        ctx.translateBy(x: marco.minX, y: marco.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.interpolationQuality = .high
        var anotaciones = modelo.edicion.anotaciones
        if let borrador { anotaciones.append(borrador) }
        DibujoAnotaciones.dibujar(imagen: modelo.imagen, anotaciones: anotaciones, escala: modelo.escala, en: ctx)
        ctx.restoreGState()

        if let recorteBorrador { dibujarRecorte(recorteBorrador, ctx: ctx, marco: marco) }
    }

    /// Mientras se arrastra el recorte: oscurece lo que queda afuera y marca las esquinas.
    private func dibujarRecorte(_ r: CGRect, ctx: CGContext, marco: CGRect) {
        let a = aVista(r.origin)
        let b = aVista(CGPoint(x: r.maxX, y: r.maxY))
        let vista = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        ctx.saveGState()
        ctx.addRect(marco)
        ctx.addRect(vista)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(vista.insetBy(dx: 0.5, dy: 0.5))
        ctx.setLineWidth(3)
        let l: CGFloat = min(16, vista.width / 2, vista.height / 2)
        for (x, y, dx, dy) in [(vista.minX, vista.minY, l, l), (vista.maxX, vista.minY, -l, l),
                               (vista.minX, vista.maxY, l, -l), (vista.maxX, vista.maxY, -l, -l)] {
            ctx.move(to: CGPoint(x: x + dx, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y + dy))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = modelo.herramienta == .texto ? .iBeam : .crosshair
        addCursorRect(marcoImagen, cursor: cursor)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let punto = aImagen(convert(event.locationInWindow, from: nil))
        if modelo.herramienta == .texto {
            terminarTexto()
            empezarTexto(en: punto)
            return
        }
        terminarTexto()
        inicio = punto
        if modelo.herramienta == .resaltador { borrador = .trazo([punto], color: modelo.color) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let inicio else { return }
        let punto = aImagen(convert(event.locationInWindow, from: nil))
        let color = modelo.color
        switch modelo.herramienta {
        case .flecha: borrador = .flecha(desde: inicio, hasta: punto, color: color)
        case .rectangulo: borrador = .rectangulo(rectangulo(inicio, punto), color: color)
        case .resaltador:
            if case .trazo(var puntos, _) = borrador {
                puntos.append(punto)
                borrador = .trazo(puntos, color: color)
            }
        case .recortar: recorteBorrador = rectangulo(inicio, punto)
        case .texto: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            inicio = nil
            borrador = nil
            recorteBorrador = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        if let recorteBorrador { modelo.recortar(recorteBorrador); return }
        guard let borrador else { return }
        // Un clic sin arrastrar no deja una flecha o un rectángulo invisibles.
        switch borrador {
        case .flecha(let a, let b, _) where hypot(b.x - a.x, b.y - a.y) < 4 * modelo.escala: return
        case .rectangulo(let r, _) where r.width < 4 || r.height < 4: return
        default: modelo.sumar(borrador)
        }
    }

    private func rectangulo(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Texto

    private func empezarTexto(en punto: CGPoint) {
        let campo = NSTextField(string: "")
        let fuente = DibujoAnotaciones.fuenteTexto(escala: modelo.escala)
        campo.font = NSFont(descriptor: fuente.fontDescriptor, size: fuente.pointSize * zoom)
        campo.textColor = modelo.color.nsColor
        campo.isBordered = false
        campo.drawsBackground = false
        campo.focusRingType = .none
        campo.placeholderString = T("Escribí…", "Type…")
        campo.delegate = self
        campo.cell?.wraps = false
        campo.cell?.isScrollable = true
        let vista = aVista(punto)
        // El campo deja unos 2 pt de margen a la izquierda: se compensa para que el texto quede donde se hizo clic.
        campo.frame = NSRect(x: vista.x - 2, y: vista.y, width: max(160, marcoImagen.maxX - vista.x), height: ceil(fuente.pointSize * zoom * 1.3))
        origenCampo = punto
        addSubview(campo)
        window?.makeFirstResponder(campo)
        self.campo = campo
    }

    /// Pasa lo escrito a una anotación (si escribió algo) y saca el campo.
    func terminarTexto() {
        guard let campo else { return }
        self.campo = nil
        let texto = campo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = modelo.color
        campo.delegate = nil
        campo.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !texto.isEmpty { modelo.sumar(.texto(texto, origen: origenCampo, color: color)) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { terminarTexto(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            campo?.stringValue = ""
            terminarTexto()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ aviso: Notification) { terminarTexto() }

    /// Cambiar de herramienta (o de color) cierra el texto a medias y cambia el cursor.
    func herramientaCambio() {
        if campo != nil, modelo.herramienta != .texto { terminarTexto() }
        campo?.textColor = modelo.color.nsColor
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ nuevo: NSSize) {
        // Si cambia el tamaño de la ventana el zoom cambia: el texto a medias se termina para que no quede corrido.
        terminarTexto()
        super.setFrameSize(nuevo)
    }
}
