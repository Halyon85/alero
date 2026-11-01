import AppKit

// "Fijar en pantalla": la captura en una ventanita que flota encima de todo, para tenerla a la vista mientras
// trabajás. Se mueve arrastrándola, se agranda desde los bordes (sin deformarse) y se cierra con su botón o con ⎋.
// No activa Alero ni le saca el foco a la app que estás usando. Al cerrarse suelta la imagen.

final class VentanaFijada: NSPanel {
    /// Las abiertas (retenidas acá hasta que se cierran).
    private static var abiertas: [VentanaFijada] = []

    static func fijar(_ imagen: CGImage, escala: CGFloat) {
        let pantalla = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = pantalla?.visibleFrame else { return }
        // A su tamaño real, salvo que pase de la mitad de la pantalla.
        var tamano = NSSize(width: CGFloat(imagen.width) / escala, height: CGFloat(imagen.height) / escala)
        let tope = min(visible.width * 0.5 / tamano.width, visible.height * 0.5 / tamano.height, 1)
        tamano = NSSize(width: (tamano.width * tope).rounded(), height: (tamano.height * tope).rounded())
        // Cada una nueva un poco corrida, para que no queden todas encimadas.
        let corrimiento = CGFloat(abiertas.count % 6) * 24
        let origen = NSPoint(x: visible.maxX - tamano.width - 32 - corrimiento, y: visible.maxY - tamano.height - 32 - corrimiento)
        let ventana = VentanaFijada(imagen: imagen, marco: NSRect(origin: origen, size: tamano))
        abiertas.append(ventana)
        ventana.orderFrontRegardless()
    }

    private init(imagen: CGImage, marco: NSRect) {
        super.init(contentRect: marco, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Sin la animación de AppKit: en macOS 27 dejaba viva la ventana en WindowServer con la imagen entera
        // (+23 MB por cada captura fijada, medido el 01/11/2026). Ver `VentanaAlero`.
        animationBehavior = .none
        contentAspectRatio = marco.size
        minSize = NSSize(width: 80, height: 80 * marco.height / max(marco.width, 1))
        contentView = VistaFijada(imagen: imagen) { [weak self] in self?.close() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        (contentView as? VistaFijada)?.soltar()
        super.close()
        VentanaFijada.abiertas.removeAll { $0 === self }
    }
}

/// La imagen con esquinas redondeadas y un botón de cerrar que aparece con el mouse encima.
private final class VistaFijada: NSView {
    private let capaImagen = CALayer()
    private let boton: NSButton
    private let cerrar: () -> Void

    init(imagen: CGImage, cerrar: @escaping () -> Void) {
        self.cerrar = cerrar
        boton = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        capaImagen.contents = imagen
        capaImagen.contentsGravity = .resizeAspect
        capaImagen.minificationFilter = .trilinear
        layer?.addSublayer(capaImagen)

        boton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: T("Cerrar", "Close"))
        boton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))
        boton.isBordered = false
        boton.imagePosition = .imageOnly
        boton.target = self
        boton.action = #selector(apretoCerrar)
        boton.toolTip = T("Cerrar (⎋)", "Close (⎋)")
        boton.alphaValue = 0
        addSubview(boton)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capaImagen.frame = bounds
        CATransaction.commit()
        boton.setFrameOrigin(NSPoint(x: 8, y: bounds.height - boton.frame.height - 8))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { mostrarBoton(true) }
    override func mouseExited(with event: NSEvent) { mostrarBoton(false) }

    private func mostrarBoton(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { contexto in
            contexto.duration = 0.15
            boton.animator().alphaValue = visible ? 1 : 0
        }
    }

    @objc private func apretoCerrar() { cerrar() }

    func soltar() { capaImagen.contents = nil }
}
