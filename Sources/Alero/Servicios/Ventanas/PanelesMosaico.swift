import AppKit
import SwiftUI

// Las ventanitas de "Acomodar ventanas" (ver `Mosaico`), todas en el hilo principal y ninguna activa Alero:
// - la vista previa: un rectángulo de vidrio con borde celeste, del tamaño exacto en que va a quedar la ventana;
// - "¿Qué va acá?": en el lugar libre, las apps abiertas y un buscador que también encuentra las instaladas
//   (Esc o la X cancelan; un clic afuera solo la cierra);
// - las barras: en el hueco entre dos ventanas acomodadas, una franja oscura con una pastilla que se arrastra para
//   agrandar una y achicar la otra (doble clic: al medio).
// Los rectángulos llegan en coordenadas de eventos (origen arriba) y se pasan a las de AppKit (origen abajo).

final class PanelesMosaico {
    /// Una barra para mostrar: `mover` recibe el puntero mientras se arrastra y una vez más al soltar (`final`).
    struct Pedido {
        let clave: String
        let barra: BarraMosaico
        let mover: (CGPoint, Bool) -> Void
        let centrar: () -> Void
    }

    private var vistaPrevia: NSPanel?
    private var asistente: PanelAsistente?
    private var barras: [String: PanelBarra] = [:]

    /// Mientras se arrastra alguna barra (`Mosaico` no revisa los grupos en ese rato).
    var arrastrandoBarra: Bool { barras.values.contains { $0.vista.arrastrando } }

    static func aAppKit(_ r: CGRect) -> CGRect {
        // Pasar de un sistema al otro es la misma cuenta en los dos sentidos.
        Geometria.aEventos(r, altoPrincipal: NSScreen.screens.first?.frame.height ?? 0)
    }

    func cerrarTodo() {
        ocultarVistaPrevia()
        cerrarAsistente()
        mostrarBarras([])
    }

    // MARK: - Vista previa

    func mostrarVistaPrevia(_ r: CGRect) {
        let destino = PanelesMosaico.aAppKit(r)
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
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        let vidrio = NSVisualEffectView()
        vidrio.material = .hudWindow
        vidrio.blendingMode = .behindWindow
        vidrio.state = .active
        vidrio.wantsLayer = true
        vidrio.layer?.cornerRadius = 12
        vidrio.layer?.masksToBounds = true
        vidrio.layer?.borderWidth = 2
        vidrio.layer?.borderColor = NSColor(hex: 0x8FD8FF).withAlphaComponent(0.9).cgColor
        vidrio.layer?.backgroundColor = NSColor(hex: 0x8FD8FF).withAlphaComponent(0.10).cgColor
        panel.contentView = vidrio
        return panel
    }

    // MARK: - ¿Qué va acá?

    /// `abiertas`: los nombres de las apps abiertas (el buscador no las repite entre las instaladas).
    func mostrarAsistente(en r: CGRect, candidatas: [AppsAbiertas.Candidata], abiertas: Set<String>,
                          elegir: @escaping (AppsAbiertas.Candidata) -> Void, abrir: @escaping (URL) -> Void,
                          cancelar: @escaping () -> Void) {
        cerrarAsistente()
        let panel = PanelAsistente(marco: PanelesMosaico.aAppKit(r).insetBy(dx: 10, dy: 10))
        let vista = VistaAsistente(candidatas: candidatas, abiertas: abiertas) { [weak self] elegida in
            self?.cerrarAsistente()
            elegir(elegida)
        } abrir: { [weak self] url in
            self?.cerrarAsistente()
            abrir(url)
        } cancelar: { [weak self] in
            self?.cerrarAsistente()
            cancelar()
        }
        panel.cancelar = { [weak self] in
            self?.cerrarAsistente()
            cancelar()
        }
        panel.contentView = NSHostingView(rootView: vista)
        panel.alphaValue = 0
        // Toma el teclado (sin activar Alero) para el buscador y para que Esc la cierre.
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { contexto in
            contexto.duration = 0.18
            panel.animator().alphaValue = 1
        }
        asistente = panel
    }

    /// Cierra sin deshacer nada (un clic afuera, o ya se eligió).
    func cerrarAsistente() {
        asistente?.orderOut(nil)
        asistente = nil
    }

    // MARK: - Barras

    /// Deja a la vista exactamente estas barras: las nuevas aparecen, las que ya estaban se reubican y las demás se
    /// esconden. Una barra que se está arrastrando no se toca.
    func mostrarBarras(_ pedidos: [Pedido]) {
        let claves = Set(pedidos.map(\.clave))
        for (clave, panel) in barras where !claves.contains(clave) && !panel.vista.arrastrando {
            panel.orderOut(nil)
            barras[clave] = nil
        }
        for pedido in pedidos {
            let panel = barras[pedido.clave] ?? PanelBarra()
            barras[pedido.clave] = panel
            guard !panel.vista.arrastrando else { continue }
            panel.vista.vertical = pedido.barra.vertical
            panel.vista.mover = { [weak panel] p, final in
                pedido.mover(p, final)
                panel?.seguir(p, vertical: pedido.barra.vertical)
            }
            panel.vista.centrar = pedido.centrar
            panel.setFrame(PanelesMosaico.aAppKit(pedido.barra.franja), display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
}

// MARK: - Paneles

/// El panel de "¿Qué va acá?": puede tomar el teclado (buscador y Esc) sin activar Alero.
private final class PanelAsistente: NSPanel {
    var cancelar: (() -> Void)?

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
    override func cancelOperation(_ sender: Any?) { cancelar?() }
}

/// El panel de una barra: ocupa el hueco entre las ventanas.
private final class PanelBarra: NSPanel {
    let vista = VistaBarra()

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
    }

    /// Mientras se arrastra, la barra va con el puntero (a lo ancho en una vertical, a lo alto en una horizontal).
    func seguir(_ p: CGPoint, vertical: Bool) {
        var marco = PanelesMosaico.aAppKit(frame)
        if vertical { marco.origin.x = p.x - marco.width / 2 } else { marco.origin.y = p.y - marco.height / 2 }
        setFrame(PanelesMosaico.aAppKit(marco), display: true)
    }
}

/// La franja oscura con la pastilla. Cambia el cursor a ↔ (o ↕) y avisa los arrastres y el doble clic.
private final class VistaBarra: NSView {
    var vertical = true { didSet { if vertical != oldValue { needsDisplay = true } } }
    var mover: ((CGPoint, Bool) -> Void)?
    var centrar: (() -> Void)?
    private(set) var arrastrando = false
    private var encima = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor { vertical ? .resizeLeftRight : .resizeUpDown }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func draw(_ dirtyRect: NSRect) {
        let fondo = bounds.insetBy(dx: vertical ? 1 : 0, dy: vertical ? 0 : 1)
        NSColor.black.withAlphaComponent(encima || arrastrando ? 0.75 : 0.55).setFill()
        NSBezierPath(roundedRect: fondo, xRadius: 4, yRadius: 4).fill()
        let grueso: CGFloat = 4
        let largo: CGFloat = min(56, (vertical ? bounds.height : bounds.width) - 16)
        let pastilla = vertical
            ? CGRect(x: bounds.midX - grueso / 2, y: bounds.midY - largo / 2, width: grueso, height: largo)
            : CGRect(x: bounds.midX - largo / 2, y: bounds.midY - grueso / 2, width: largo, height: grueso)
        (arrastrando || encima ? NSColor(hex: 0x8FD8FF) : NSColor.white.withAlphaComponent(0.85)).setFill()
        NSBezierPath(roundedRect: pastilla, xRadius: grueso / 2, yRadius: grueso / 2).fill()
    }

    override func mouseEntered(with event: NSEvent) {
        encima = true
        cursor.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        encima = false
        if !arrastrando { NSCursor.arrow.set() }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            centrar?()
            return
        }
        arrastrando = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard arrastrando else { return }
        mover?(Mosaico.puntero(), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard arrastrando else { return }
        arrastrando = false
        needsDisplay = true
        mover?(Mosaico.puntero(), true)
    }
}

// MARK: - Vista de "¿Qué va acá?"

private struct VistaAsistente: View {
    let candidatas: [AppsAbiertas.Candidata]
    let abiertas: Set<String>
    let elegir: (AppsAbiertas.Candidata) -> Void
    let abrir: (URL) -> Void
    let cancelar: () -> Void
    @State private var busqueda = ""
    @State private var instaladas: [AppsAbiertas.Instalada] = []
    @FocusState private var enfocado: Bool

    private let columnas = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(T("¿Qué va acá?", "What goes here?")).font(.system(size: 17, weight: .semibold))
                    Text(T("Elegí una app abierta o buscá otra.", "Pick an open app or search for another."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: cancelar) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(T("Cancelar (Esc)", "Cancel (Esc)"))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField(T("Buscar una app", "Search for an app"), text: $busqueda)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($enfocado)
                    .onSubmit(elegirPrimera)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if !abiertasFiltradas.isEmpty {
                        LazyVGrid(columns: columnas, spacing: 10) {
                            ForEach(abiertasFiltradas) { c in
                                TarjetaApp(icono: icono(c.pid), nombre: c.app, detalle: detalle(c)) { elegir(c) }
                            }
                        }
                    }
                    if !instaladasFiltradas.isEmpty {
                        Text(T("Otras apps", "Other apps")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: columnas, spacing: 10) {
                            ForEach(instaladasFiltradas) { app in
                                TarjetaApp(icono: NSWorkspace.shared.icon(forFile: app.url.path), nombre: app.nombre,
                                        detalle: T("Abrirla acá", "Open it here")) { abrir(app.url) }
                            }
                        }
                    }
                    if abiertasFiltradas.isEmpty && instaladasFiltradas.isEmpty {
                        Text(T("Ninguna app con «\(busqueda)».", "No app matches “\(busqueda)”."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color(nsColor: NSColor(hex: 0x8FD8FF)).opacity(0.6), lineWidth: 1.5))
        .onAppear {
            DispatchQueue.main.async { enfocado = true }
            DispatchQueue.global(qos: .userInitiated).async {
                let lista = AppsAbiertas.instaladas()
                DispatchQueue.main.async { instaladas = lista }
            }
        }
    }

    private var abiertasFiltradas: [AppsAbiertas.Candidata] {
        let texto = busqueda.trimmingCharacters(in: .whitespaces)
        guard !texto.isEmpty else { return candidatas }
        return candidatas.filter { coincide($0.app, texto) || coincide($0.titulo, texto) }
    }

    /// Las instaladas aparecen solo buscando, y sin las que ya están abiertas.
    private var instaladasFiltradas: [AppsAbiertas.Instalada] {
        let texto = busqueda.trimmingCharacters(in: .whitespaces)
        guard !texto.isEmpty else { return [] }
        return Array(instaladas.filter { coincide($0.nombre, texto) && !abiertas.contains($0.nombre) }.prefix(12))
    }

    private func coincide(_ nombre: String, _ texto: String) -> Bool {
        nombre.range(of: texto, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Enter: la primera de la lista (abierta o, si no hay, instalada).
    private func elegirPrimera() {
        if let primera = abiertasFiltradas.first { elegir(primera) } else if let app = instaladasFiltradas.first { abrir(app.url) }
    }

    private func detalle(_ c: AppsAbiertas.Candidata) -> String {
        switch c.estado {
        case .aLaVista: return c.titulo
        case .minimizada: return T("Minimizada", "Minimized") + (c.titulo.isEmpty ? "" : " · \(c.titulo)")
        case .oculta: return T("Oculta", "Hidden") + (c.titulo.isEmpty ? "" : " · \(c.titulo)")
        case .sinVentana: return T("Abrir una ventana", "Open a window")
        }
    }

    private func icono(_ pid: pid_t) -> NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
    }
}

private struct TarjetaApp: View {
    let icono: NSImage
    let nombre: String
    let detalle: String
    let accion: () -> Void
    @State private var encima = false

    var body: some View {
        Button(action: accion) {
            VStack(spacing: 8) {
                Image(nsImage: icono).resizable().frame(width: 44, height: 44)
                VStack(spacing: 2) {
                    Text(nombre).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if !detalle.isEmpty {
                        Text(detalle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
}
