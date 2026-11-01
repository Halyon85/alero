import AppKit
import SwiftUI

// Las tres ventanitas de "Acomodar ventanas" (ver `Mosaico`), todas en el hilo principal y ninguna activa Alero:
// - la vista previa: un rectángulo de vidrio con borde celeste donde va a quedar la ventana mientras la llevás;
// - "¿Qué va acá?": en el lugar libre, las otras ventanas abiertas para elegir una (Esc o un clic afuera la cierran);
// - la manija: una pastilla sobre la unión entre dos ventanas acomodadas, que se arrastra para cambiar los tamaños.
// Los rectángulos llegan en coordenadas de eventos (origen arriba) y se pasan a las de AppKit (origen abajo).

final class PanelesMosaico {
    private var vistaPrevia: NSPanel?
    private var asistente: PanelAsistente?
    private var manija: PanelManija?

    /// Mientras se arrastra la manija (`Mosaico` no revisa los grupos en ese rato).
    var arrastrandoBarra: Bool { manija?.vista.arrastrando == true }

    static func aAppKit(_ r: CGRect) -> CGRect {
        // Pasar de un sistema al otro es la misma cuenta en los dos sentidos.
        Geometria.aEventos(r, altoPrincipal: NSScreen.screens.first?.frame.height ?? 0)
    }

    func cerrarTodo() {
        ocultarVistaPrevia()
        cerrarAsistente()
        ocultarBarra()
    }

    // MARK: - Vista previa

    func mostrarVistaPrevia(_ r: CGRect) {
        let destino = PanelesMosaico.aAppKit(r).insetBy(dx: 8, dy: 8)
        if let panel = vistaPrevia, panel.isVisible {
            NSAnimationContext.runAnimationGroup { contexto in
                contexto.duration = 0.16
                contexto.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(destino, display: true)
            }
            return
        }
        let panel = vistaPrevia ?? PanelesMosaico.crearVistaPrevia()
        vistaPrevia = panel
        panel.setFrame(destino, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { contexto in
            contexto.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func ocultarVistaPrevia() {
        vistaPrevia?.orderOut(nil)
    }

    private static func crearVistaPrevia() -> NSPanel {
        let panel = panelBase(nivel: .floating)
        panel.ignoresMouseEvents = true
        let vidrio = NSVisualEffectView()
        vidrio.material = .hudWindow
        vidrio.blendingMode = .behindWindow
        vidrio.state = .active
        vidrio.wantsLayer = true
        vidrio.layer?.cornerRadius = 16
        vidrio.layer?.masksToBounds = true
        vidrio.layer?.borderWidth = 2
        vidrio.layer?.borderColor = NSColor(hex: 0x8FD8FF).withAlphaComponent(0.9).cgColor
        vidrio.layer?.backgroundColor = NSColor(hex: 0x8FD8FF).withAlphaComponent(0.10).cgColor
        panel.contentView = vidrio
        return panel
    }

    // MARK: - ¿Qué va acá?

    func mostrarAsistente(en r: CGRect, candidatas: [VentanaVisible], elegir: @escaping (VentanaVisible) -> Void) {
        cerrarAsistente()
        let panel = PanelAsistente(marco: PanelesMosaico.aAppKit(r).insetBy(dx: 10, dy: 10))
        let vista = VistaAsistente(candidatas: candidatas) { [weak self] elegida in
            self?.cerrarAsistente()
            elegir(elegida)
        } cerrar: { [weak self] in
            self?.cerrarAsistente()
        }
        panel.cerrar = { [weak self] in self?.cerrarAsistente() }
        panel.contentView = NSHostingView(rootView: vista)
        panel.alphaValue = 0
        // Toma el teclado (sin activar Alero) para que Esc la cierre.
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { contexto in
            contexto.duration = 0.18
            panel.animator().alphaValue = 1
        }
        asistente = panel
    }

    func cerrarAsistente() {
        asistente?.orderOut(nil)
        asistente = nil
    }

    // MARK: - Manija

    /// Muestra la manija sobre `barra`, a la altura (o el ancho) del puntero. `mover` recibe el puntero mientras se
    /// arrastra y una vez más al soltar (`final`).
    func mostrarBarra(_ barra: BarraMosaico, en p: CGPoint, mover: @escaping (CGPoint, Bool) -> Void) {
        let panel = manija ?? PanelManija()
        manija = panel
        guard !panel.vista.arrastrando else { return }
        panel.vista.vertical = barra.vertical
        panel.vista.mover = { [weak panel] punto, final in
            mover(punto, final)
            panel?.seguir(punto, barra: barra)
        }
        panel.ubicar(barra: barra, en: p)
        panel.orderFrontRegardless()
    }

    func ocultarBarra() {
        guard manija?.vista.arrastrando != true else { return }
        manija?.orderOut(nil)
    }

    fileprivate static func panelBase(nivel: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = nivel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }
}

// MARK: - Paneles

/// El panel de "¿Qué va acá?": puede tomar el teclado (solo para Esc) sin activar Alero.
private final class PanelAsistente: NSPanel {
    var cerrar: (() -> Void)?

    init(marco: CGRect) {
        super.init(contentRect: marco, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { cerrar?() }
}

/// El panel de la manija: chiquito, sobre la unión, siguiendo al puntero mientras se arrastra.
private final class PanelManija: NSPanel {
    let vista = VistaManija()
    private static let largo: CGFloat = 88
    private static let ancho: CGFloat = 22

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = vista
        vista.alSalir = { [weak self] in
            guard let self, !self.vista.arrastrando else { return }
            self.orderOut(nil)
        }
    }

    /// Centrada en la línea de la barra, a la altura (o el ancho) del puntero.
    func ubicar(barra: BarraMosaico, en p: CGPoint) {
        let l = barra.linea
        let r: CGRect
        if barra.vertical {
            let y = min(max(p.y - PanelManija.largo / 2, l.minY), l.maxY - PanelManija.largo)
            r = CGRect(x: l.minX - PanelManija.ancho / 2, y: y, width: PanelManija.ancho, height: PanelManija.largo)
        } else {
            let x = min(max(p.x - PanelManija.largo / 2, l.minX), l.maxX - PanelManija.largo)
            r = CGRect(x: x, y: l.minY - PanelManija.ancho / 2, width: PanelManija.largo, height: PanelManija.ancho)
        }
        setFrame(PanelesMosaico.aAppKit(r), display: true)
    }

    /// Mientras se arrastra, la manija va con el puntero (solo a lo ancho en una vertical, a lo alto en una horizontal).
    func seguir(_ p: CGPoint, barra: BarraMosaico) {
        var marco = PanelesMosaico.aAppKit(frame)
        if barra.vertical { marco.origin.x = p.x - PanelManija.ancho / 2 } else { marco.origin.y = p.y - PanelManija.ancho / 2 }
        setFrame(PanelesMosaico.aAppKit(marco), display: true)
    }
}

/// La pastilla de la manija. Cambia el cursor a ↔ (o ↕) y avisa los arrastres a `mover`.
private final class VistaManija: NSView {
    var vertical = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var mover: ((CGPoint, Bool) -> Void)?
    var alSalir: (() -> Void)?
    private(set) var arrastrando = false
    private var encima = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        let grueso: CGFloat = arrastrando || encima ? 6 : 5
        let largo: CGFloat = vertical ? bounds.height - 20 : bounds.width - 20
        let pastilla = vertical
            ? CGRect(x: bounds.midX - grueso / 2, y: bounds.midY - largo / 2, width: grueso, height: largo)
            : CGRect(x: bounds.midX - largo / 2, y: bounds.midY - grueso / 2, width: largo, height: grueso)
        NSGraphicsContext.saveGraphicsState()
        let sombra = NSShadow()
        sombra.shadowColor = NSColor.black.withAlphaComponent(0.45)
        sombra.shadowBlurRadius = 6
        sombra.set()
        (arrastrando ? NSColor(hex: 0x8FD8FF) : NSColor.white.withAlphaComponent(0.92)).setFill()
        NSBezierPath(roundedRect: pastilla, xRadius: grueso / 2, yRadius: grueso / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseEntered(with event: NSEvent) {
        encima = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        encima = false
        needsDisplay = true
        alSalir?()
    }

    override func mouseDown(with event: NSEvent) {
        arrastrando = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        mover?(Mosaico.puntero(), false)
    }

    override func mouseUp(with event: NSEvent) {
        arrastrando = false
        needsDisplay = true
        mover?(Mosaico.puntero(), true)
        if !(window.map { NSPointInRect(NSEvent.mouseLocation, $0.frame) } ?? false) { alSalir?() }
    }
}

// MARK: - Vista de "¿Qué va acá?"

private struct VistaAsistente: View {
    let candidatas: [VentanaVisible]
    let elegir: (VentanaVisible) -> Void
    let cerrar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(T("¿Qué va acá?", "What goes here?")).font(.system(size: 17, weight: .semibold))
                    Text(T("Elegí una ventana para este lugar.", "Pick a window for this spot."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: cerrar) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(T("Cerrar (Esc)", "Close (Esc)"))
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)], spacing: 10) {
                    ForEach(candidatas) { v in TarjetaVentana(ventana: v) { elegir(v) } }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(nsColor: NSColor(hex: 0x8FD8FF)).opacity(0.6), lineWidth: 1.5))
    }
}

private struct TarjetaVentana: View {
    let ventana: VentanaVisible
    let elegir: () -> Void
    @State private var encima = false

    var body: some View {
        Button(action: elegir) {
            VStack(spacing: 8) {
                Image(nsImage: icono).resizable().frame(width: 44, height: 44)
                VStack(spacing: 2) {
                    Text(ventana.app).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if !ventana.titulo.isEmpty {
                        Text(ventana.titulo).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(encima ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(encima ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { encima = $0 }
        .animation(.easeOut(duration: 0.12), value: encima)
    }

    private var icono: NSImage {
        NSRunningApplication(processIdentifier: ventana.pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
    }
}
