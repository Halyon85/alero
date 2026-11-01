import AppKit
import SwiftUI

// Las ventanitas de "Acomodar ventanas" (ver `Mosaico`), todas en el hilo principal y ninguna activa Alero:
// - la vista previa: un rectángulo de vidrio con borde celeste, del tamaño exacto en que va a quedar la ventana;
// - "¿Qué va acá?": en el lugar libre, las apps abiertas y un buscador que también encuentra las instaladas
//   (Esc o la X cancelan; un clic afuera solo la cierra);
// - las barras: sobre la unión entre ventanas, una línea fina con una pastilla (o la perilla del cruce, con cuatro)
//   que se arrastra; doble clic las centra. La franja que se agarra es más ancha que la línea y tapa los bordes con
//   que macOS agranda las ventanas, así el clic lo toma la barra. Un clic en la pastilla abre un menú chico:
//   "Cambiar", "Al medio", "Sumar app", "Quitar app" (elegís cuál) y "Salir";
// - las cortinas: mientras se arrastra una barra, un vidrio con el ícono de la app tapa cada ventana y va a su lugar
//   nuevo al instante (las ventanas de verdad se mueven al soltar). Van entre las ventanas comunes y las barras, y
//   son una capa de color, sin desenfoque: se redibujan en cada movimiento y tienen que ser livianas.
// Los rectángulos llegan en coordenadas de eventos (origen arriba) y se pasan a las de AppKit (origen abajo).

final class PanelesMosaico {
    /// Una barra para mostrar: `mover` recibe el puntero mientras se arrastra y una vez más al soltar (`final`).
    struct Pedido {
        let clave: String
        let barra: BarraMosaico
        /// Dónde van las pastillas a lo largo de la barra (0,5 = al medio). Con el cruce, a los costados.
        let pastillas: [CGFloat]
        let mover: (CGPoint, Bool) -> Void
        let centrar: () -> Void
        /// Nil en el cruce (no hay lados que cambiar).
        let cambiar: (() -> Void)?
        /// Nil con cuatro ventanas (no entra otra).
        let sumar: (() -> Void)?
        /// Las ventanas del grupo, para "Quitar app".
        let apps: [AppDelGrupo]
        let quitar: (CGWindowID) -> Void
        let salir: () -> Void
    }

    struct AppDelGrupo: Identifiable {
        let id: CGWindowID
        let pid: pid_t
    }

    /// Una ventana tapada mientras se arrastra: dónde tiene que estar ya.
    struct Cortina {
        let id: CGWindowID
        let pid: pid_t
        let marco: CGRect
    }

    private var vistaPrevia: NSPanel?
    private var asistente: PanelAsistente?
    private var barras: [String: PanelBarra] = [:]
    private var cortinas: [CGWindowID: PanelCortina] = [:]
    private var quitando: DispatchWorkItem?
    private let menu = MenuBarra()

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
        quitarCortinas()
    }

    func ocultarMenu() { menu.ocultar() }

    // MARK: - Cortinas

    /// Deja tapadas exactamente estas ventanas, cada cortina en su lugar nuevo (sin animación: tiene que seguir a la
    /// mano). Las barras quedan encima.
    func mostrarCortinas(_ pedidas: [Cortina]) {
        quitando?.cancel()
        quitando = nil
        let ids = Set(pedidas.map(\.id))
        for (id, panel) in cortinas where !ids.contains(id) {
            panel.orderOut(nil)
            cortinas[id] = nil
        }
        var nuevas = false
        for pedida in pedidas {
            let panel = cortinas[pedida.id] ?? PanelCortina(pid: pedida.pid)
            if cortinas[pedida.id] == nil { nuevas = true }
            cortinas[pedida.id] = panel
            panel.alphaValue = 1
            panel.setFrame(PanelesMosaico.aAppKit(pedida.marco), display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        if nuevas { barras.values.forEach { $0.orderFrontRegardless() } }
    }

    /// Las cortinas se van un instante después (para que las apps terminen de redibujarse) y con un fundido corto.
    func quitarCortinas() {
        guard !cortinas.isEmpty else { return }
        quitando?.cancel()
        let quitar = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paneles = Array(self.cortinas.values)
            self.cortinas = [:]
            NSAnimationContext.runAnimationGroup({ contexto in
                contexto.duration = 0.15
                paneles.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { paneles.forEach { $0.orderOut(nil) } })
        }
        quitando = quitar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: quitar)
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
        let panel = panelFlotante()
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

    fileprivate static func panelFlotante() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
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
    /// esconden. Una barra que se está arrastrando no se toca. El cruce va último, así queda encima de las líneas.
    func mostrarBarras(_ pedidos: [Pedido]) {
        let claves = Set(pedidos.map(\.clave))
        for (clave, panel) in barras where !claves.contains(clave) && !panel.vista.arrastrando {
            panel.orderOut(nil)
            barras[clave] = nil
            if menu.clave == clave { menu.ocultar() }
        }
        for pedido in pedidos.sorted(by: { ($0.barra.tipo == .cruce ? 1 : 0) < ($1.barra.tipo == .cruce ? 1 : 0) }) {
            let panel = barras[pedido.clave] ?? PanelBarra()
            barras[pedido.clave] = panel
            guard !panel.vista.arrastrando else { continue }
            let vista = panel.vista
            vista.tipo = pedido.barra.tipo
            vista.pastillas = pedido.pastillas
            vista.mover = { [weak self] p, final in
                self?.menu.ocultar()
                pedido.mover(p, final)
            }
            vista.centrar = { [weak self] in
                self?.menu.ocultar()
                pedido.centrar()
            }
            vista.alTocar = { [weak self, weak panel] centro in
                guard let self, let panel else { return }
                self.menu.alternar(pedido, cerca: panel.convertToScreen(CGRect(origin: centro, size: .zero)).origin)
            }
            panel.setFrame(PanelesMosaico.aAppKit(pedido.barra.franja), display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    /// Mueve una barra que ya está a la vista (mientras se arrastra, sin volver a mirar si se ve).
    func reubicar(_ clave: String, a franja: CGRect) {
        guard let panel = barras[clave], panel.isVisible else { return }
        panel.setFrame(PanelesMosaico.aAppKit(franja), display: true)
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

/// El panel de una barra: la franja que se agarra sobre la unión.
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
}

/// Una cortina: un panel oscuro con el ícono y el nombre de la app, centrados. No recibe clics.
private final class PanelCortina: NSPanel {
    init(pid: pid_t) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Arriba de las ventanas comunes y debajo de las barras (que son flotantes).
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        let vidrio = NSView()
        vidrio.wantsLayer = true
        vidrio.layer?.backgroundColor = NSColor(hex: 0x1C1D22).withAlphaComponent(0.97).cgColor
        vidrio.layer?.cornerRadius = 10
        vidrio.layer?.borderWidth = 1
        vidrio.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        let app = NSRunningApplication(processIdentifier: pid)
        let icono = NSImageView(image: app?.icon ?? NSWorkspace.shared.icon(for: .application))
        icono.imageScaling = .scaleProportionallyUpOrDown
        let nombre = NSTextField(labelWithString: app?.localizedName ?? "")
        nombre.font = .systemFont(ofSize: 14, weight: .semibold)
        nombre.textColor = .white.withAlphaComponent(0.9)
        let pila = NSStackView(views: [icono, nombre])
        pila.orientation = .vertical
        pila.spacing = 10
        pila.translatesAutoresizingMaskIntoConstraints = false
        vidrio.addSubview(pila)
        NSLayoutConstraint.activate([
            icono.widthAnchor.constraint(equalToConstant: 72), icono.heightAnchor.constraint(equalToConstant: 72),
            pila.centerXAnchor.constraint(equalTo: vidrio.centerXAnchor), pila.centerYAnchor.constraint(equalTo: vidrio.centerYAnchor),
        ])
        contentView = vidrio
    }
}

/// La línea con sus pastillas (o la perilla del cruce). Cambia el cursor y avisa arrastres, el doble clic y un clic
/// sin arrastrar (para el menú). Pasando el mouse, la pastilla se pinta de celeste.
private final class VistaBarra: NSView {
    var tipo: TipoBarra = .vertical { didSet { if tipo != oldValue { needsDisplay = true } } }
    var pastillas: [CGFloat] = [0.5] { didSet { if pastillas != oldValue { needsDisplay = true } } }
    var mover: ((CGPoint, Bool) -> Void)?
    var centrar: (() -> Void)?
    /// Un clic sin arrastrar: recibe el centro de la pastilla más cercana (en coordenadas de la vista).
    var alTocar: ((CGPoint) -> Void)?
    private(set) var arrastrando = false
    private var apretado: CGPoint?
    private var encima: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var vertical: Bool { tipo == .vertical }

    private var cursor: NSCursor {
        switch tipo {
        case .vertical: return .resizeLeftRight
        case .horizontal: return .resizeUpDown
        case .cruce: return arrastrando ? .closedHand : .openHand
        }
    }

    /// Las pastillas, en coordenadas de la vista.
    private var rectsPastillas: [CGRect] {
        if tipo == .cruce { return [bounds.insetBy(dx: 4, dy: 4)] }
        let largo: CGFloat = 56
        let grueso: CGFloat = 5
        return pastillas.map { f in
            vertical
                ? CGRect(x: bounds.midX - grueso / 2, y: bounds.height * f - largo / 2, width: grueso, height: largo)
                : CGRect(x: bounds.width * f - largo / 2, y: bounds.midY - grueso / 2, width: largo, height: grueso)
        }
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func draw(_ dirtyRect: NSRect) {
        // Casi transparente pero no del todo: con alfa 0 los clics pasarían a la ventana de abajo.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        let celeste = NSColor(hex: 0x8FD8FF)
        if tipo == .cruce {
            let r = bounds.insetBy(dx: 4, dy: 4)
            NSGraphicsContext.saveGraphicsState()
            let sombra = NSShadow()
            sombra.shadowColor = NSColor.black.withAlphaComponent(0.5)
            sombra.shadowBlurRadius = 6
            sombra.set()
            NSColor(white: 0.12, alpha: 0.92).setFill()
            NSBezierPath(ovalIn: r).fill()
            NSGraphicsContext.restoreGraphicsState()
            (encima != nil || arrastrando ? celeste : NSColor.white.withAlphaComponent(0.9)).setStroke()
            let borde = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            borde.lineWidth = 2
            borde.stroke()
            (encima != nil || arrastrando ? celeste : NSColor.white.withAlphaComponent(0.9)).setFill()
            NSBezierPath(ovalIn: CGRect(x: r.midX - 3, y: r.midY - 3, width: 6, height: 6)).fill()
            return
        }
        // La línea fina sobre la unión.
        let linea = vertical ? CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
                             : CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        NSColor.black.withAlphaComponent(arrastrando ? 0.6 : 0.35).setFill()
        linea.fill()
        for (i, pastilla) in rectsPastillas.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let sombra = NSShadow()
            sombra.shadowColor = NSColor.black.withAlphaComponent(0.55)
            sombra.shadowBlurRadius = 5
            sombra.set()
            (arrastrando || encima == i ? celeste : NSColor.white.withAlphaComponent(0.95)).setFill()
            NSBezierPath(roundedRect: pastilla, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
        mirar(event)
    }

    override func mouseMoved(with event: NSEvent) { mirar(event) }

    override func mouseExited(with event: NSEvent) {
        if !arrastrando { NSCursor.arrow.set() }
        if encima != nil {
            encima = nil
            needsDisplay = true
        }
    }

    /// ¿El mouse está sobre una pastilla? (con un margen generoso para no tener que apuntar justo).
    private func mirar(_ event: NSEvent) {
        guard !arrastrando else { return }
        let p = convert(event.locationInWindow, from: nil)
        let indice = rectsPastillas.firstIndex { $0.insetBy(dx: -12, dy: -12).contains(p) }
        guard indice != encima else { return }
        encima = indice
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            apretado = nil
            centrar?()
            return
        }
        apretado = Mosaico.puntero()
    }

    /// Recién después de correrse 3 pt es un arrastre (antes puede ser un clic para el menú).
    override func mouseDragged(with event: NSEvent) {
        let p = Mosaico.puntero()
        if !arrastrando {
            guard let apretado, hypot(p.x - apretado.x, p.y - apretado.y) > 3 else { return }
            arrastrando = true
            cursor.set()
            needsDisplay = true
        }
        mover?(p, false)
    }

    override func mouseUp(with event: NSEvent) {
        defer { apretado = nil }
        if arrastrando {
            arrastrando = false
            cursor.set()
            needsDisplay = true
            mover?(Mosaico.puntero(), true)
            return
        }
        guard apretado != nil, event.clickCount == 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cercana = rectsPastillas.min { hypot($0.midX - p.x, $0.midY - p.y) < hypot($1.midX - p.x, $1.midY - p.y) }
        if let cercana { alTocar?(CGPoint(x: cercana.midX, y: cercana.midY)) }
    }
}

// MARK: - Menú de la pastilla

/// El menú chico que abre un clic en una pastilla: "Cambiar", "Al medio", "Sumar app", "Quitar app" y "Salir".
/// "Quitar app" cambia el menú por las apps del grupo, para elegir cuál sale. Se cierra con un botón, con otro clic
/// en la pastilla, al arrastrar la barra o con un clic en cualquier otro lado (`Mosaico`).
private final class MenuBarra {
    private let panel = PanelesMosaico.panelFlotante()
    private(set) var clave: String?
    private var anfitrion: NSView?
    private var ancla = CGPoint.zero
    private var horizontal = false

    /// Lo abre junto a la pastilla tocada; si ya estaba abierto para esa barra, lo cierra.
    func alternar(_ pedido: PanelesMosaico.Pedido, cerca centro: CGPoint) {
        if panel.isVisible && clave == pedido.clave {
            ocultar()
            return
        }
        clave = pedido.clave
        ancla = centro
        if case .horizontal = pedido.barra.tipo { horizontal = true } else { horizontal = false }
        let cerrarY: (@escaping () -> Void) -> () -> Void = { accion in { [weak self] in
            self?.ocultar()
            accion()
        } }
        let vista = VistaMenuBarra(tipo: pedido.barra.tipo, cambiar: pedido.cambiar.map(cerrarY), centrar: cerrarY(pedido.centrar),
                                   sumar: pedido.sumar.map(cerrarY), apps: pedido.apps,
                                   quitar: { [weak self] id in
                                       self?.ocultar()
                                       pedido.quitar(id)
                                   },
                                   salir: cerrarY(pedido.salir),
                                   alCambiar: { [weak self] in DispatchQueue.main.async { self?.ubicar() } })
        let anfitrion = AnfitrionPrimerClic(rootView: vista)
        self.anfitrion = anfitrion
        panel.contentView = anfitrion
        ubicar()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { contexto in
            contexto.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Arriba de la pastilla en las verticales y el cruce; a la derecha en las horizontales; sin salirse de la
    /// pantalla. Se vuelve a llamar cuando el menú cambia de tamaño ("Quitar app").
    private func ubicar() {
        guard let anfitrion else { return }
        let tamano = anfitrion.fittingSize
        var origen = horizontal ? CGPoint(x: ancla.x + 44, y: ancla.y - tamano.height / 2)
                                : CGPoint(x: ancla.x - tamano.width / 2, y: ancla.y + 44)
        if let pantalla = NSScreen.screens.first(where: { $0.frame.contains(ancla) })?.visibleFrame {
            origen.x = min(max(origen.x, pantalla.minX + 8), pantalla.maxX - tamano.width - 8)
            origen.y = min(max(origen.y, pantalla.minY + 8), pantalla.maxY - tamano.height - 8)
        }
        panel.setFrame(CGRect(origin: origen, size: tamano), display: true)
    }

    func ocultar() {
        clave = nil
        panel.orderOut(nil)
    }
}

/// Un NSHostingView que acepta el primer clic: Alero no está activa y los botones tienen que andar al toque.
private final class AnfitrionPrimerClic<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct VistaMenuBarra: View {
    let tipo: TipoBarra
    let cambiar: (() -> Void)?
    let centrar: () -> Void
    let sumar: (() -> Void)?
    let apps: [PanelesMosaico.AppDelGrupo]
    let quitar: (CGWindowID) -> Void
    let salir: () -> Void
    /// El menú cambió de tamaño (pasó a elegir qué app quitar, o volvió).
    let alCambiar: () -> Void
    @State private var quitando = false

    var body: some View {
        HStack(spacing: 4) {
            if quitando {
                boton(T("Volver", "Back"), icono: "chevron.left") { cambiarModo(false) }
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 30)
                ForEach(apps) { app in
                    let corriendo = NSRunningApplication(processIdentifier: app.pid)
                    BotonMenuBarra(texto: corriendo?.localizedName ?? "", icono: nil, imagen: corriendo?.icon) { quitar(app.id) }
                }
            } else {
                if let cambiar {
                    boton(T("Cambiar", "Swap"), icono: tipo == .vertical ? "arrow.left.arrow.right" : "arrow.up.arrow.down", accion: cambiar)
                }
                boton(T("Al medio", "Center"), icono: tipo == .cruce ? "plus" : (tipo == .vertical ? "arrow.left.and.right" : "arrow.up.and.down"),
                      accion: centrar)
                if let sumar {
                    boton(T("Sumar app", "Add app"), icono: "plus.rectangle.on.rectangle", accion: sumar)
                }
                boton(T("Quitar app", "Remove app"), icono: "minus.rectangle") { cambiarModo(true) }
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 30)
                boton(T("Salir", "Exit"), icono: "xmark", accion: salir)
            }
        }
        .padding(6)
        .background(Color(white: 0.1).opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
        .fixedSize()
    }

    private func cambiarModo(_ quitar: Bool) {
        quitando = quitar
        alCambiar()
    }

    private func boton(_ texto: String, icono: String, accion: @escaping () -> Void) -> some View {
        BotonMenuBarra(texto: texto, icono: icono, imagen: nil, accion: accion)
    }
}

/// Un botón del menú: un símbolo (o el ícono de una app, en "Quitar app") con su nombre abajo.
private struct BotonMenuBarra: View {
    let texto: String
    let icono: String?
    let imagen: NSImage?
    let accion: () -> Void
    @State private var encima = false

    var body: some View {
        Button(action: accion) {
            VStack(spacing: 3) {
                if let imagen {
                    Image(nsImage: imagen).resizable().frame(width: 20, height: 20)
                } else if let icono {
                    Image(systemName: icono).font(.system(size: 13, weight: .semibold))
                }
                Text(texto).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .frame(width: 58, height: 42)
            .background(Color.white.opacity(encima ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { encima = $0 }
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
