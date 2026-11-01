import AppKit
import SwiftUI

// Una vuelta de selección: una superficie por pantalla (encima de todo, hasta del notch), la barra de modos, el
// teclado (Espacio alterna área y ventana, ↩ captura la pantalla, ⎋ cancela) y qué está resaltado. Cuando la
// persona elige algo, o cancela, cierra todo, suelta las fotos y le avisa al `Capturador`. Main thread.

/// Lo que eligió la persona. Rectángulos en coordenadas de AppKit.
enum EleccionCaptura {
    case area(CGRect, pantalla: CGDirectDisplayID)
    case ventana(VentanaCandidata, sombra: Bool)
    case pantalla(CGDirectDisplayID)
}

final class SesionCaptura {
    let estadoBarra: EstadoBarra
    var modo: ModoCaptura { estadoBarra.modo }
    private let ventanas: [VentanaCandidata]
    private let conLupa: Bool
    private(set) var ventanaResaltada: VentanaCandidata?
    private(set) var pantallaResaltada: CGDirectDisplayID?

    private var paneles: [PanelSeleccion] = []
    private var lupa: VistaLupa?
    private var alTerminar: ((EleccionCaptura?) -> Void)?
    private var observador: NSObjectProtocol?

    /// `fotos` vacío = en vivo (sin congelar). La lupa solo existe con la pantalla congelada.
    init(modo: ModoCaptura, fotos: [MotorCaptura.Foto], ventanas: [VentanaCandidata], lupa: Bool,
         alTerminar: @escaping (EleccionCaptura?) -> Void) {
        estadoBarra = EstadoBarra(modo: modo)
        self.ventanas = ventanas
        conLupa = lupa && !fotos.isEmpty
        self.alTerminar = alTerminar
        for pantalla in NSScreen.screens {
            let foto = fotos.first { $0.pantalla == pantalla.numero }?.imagen
            paneles.append(PanelSeleccion(pantalla: pantalla, foto: foto, sesion: self))
        }
    }

    func mostrar() {
        let posicion = NSEvent.mouseLocation
        let delPuntero = paneles.first { $0.vista.marcoPantalla.contains(posicion) } ?? paneles.first
        if let delPuntero {
            let barra = NSHostingView(rootView: BarraModos(estado: estadoBarra, elegir: { [weak self] in self?.cambiar(a: $0) },
                                                           cerrar: { [weak self] in self?.cancelar() }))
            barra.setFrameSize(barra.fittingSize)
            let ancho = delPuntero.vista.bounds.width
            barra.setFrameOrigin(NSPoint(x: ((ancho - barra.frame.width) / 2).rounded(), y: 44))
            delPuntero.contentView?.addSubview(barra)
        }
        for panel in paneles { panel.vista.sinAnimar { panel.vista.actualizar() } }
        // Se activa Alero mientras se elige: si no, macOS no deja poner el cursor en cruz ni recibir las teclas.
        NSApp.activate(ignoringOtherApps: true)
        for panel in paneles {
            panel === delPuntero ? panel.makeKeyAndOrderFront(nil) : panel.orderFrontRegardless()
        }
        delPuntero?.makeFirstResponder(delPuntero?.vista)
        puntero(en: posicion, desde: delPuntero?.vista)
        // Si se conecta o desconecta una pantalla en el medio, las cuentas ya no valen: se cancela.
        observador = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                            object: nil, queue: .main) { [weak self] _ in self?.cancelar() }
    }

    // MARK: - Lo que mandan las superficies

    func cambiar(a nuevo: ModoCaptura) {
        guard nuevo != modo else { return }
        estadoBarra.modo = nuevo
        estadoBarra.arrastrando = false
        paneles.forEach { $0.vista.reiniciar() }
        puntero(en: NSEvent.mouseLocation, desde: nil)
        (nuevo == .area ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    /// Espacio: de área a ventana y de ventana a área (desde pantalla, a área).
    func alternar() { cambiar(a: modo == .area ? .ventana : .area) }

    func puntero(en global: CGPoint, desde vista: VistaSeleccion?) {
        let ventana = modo == .ventana ? GeometriaCaptura.ventana(bajo: global, en: ventanas) : nil
        let pantalla = modo == .pantalla ? paneles.first { $0.vista.marcoPantalla.contains(global) }?.vista.numero : nil
        let cambio = ventana != ventanaResaltada || pantalla != pantallaResaltada
        ventanaResaltada = ventana
        pantallaResaltada = pantalla
        if cambio || modo == .area {
            for panel in paneles where cambio || panel.vista === vista {
                panel.vista.sinAnimar { panel.vista.actualizar() }
            }
        }
        moverLupa(global, en: vista)
    }

    func punteroSalio(de vista: VistaSeleccion) {
        if lupa?.superview === vista.superview { lupa?.isHidden = true }
    }

    func empezoArrastre() { estadoBarra.arrastrando = true }
    func terminoArrastre() { estadoBarra.arrastrando = false }

    /// Devuelve true si la tecla era de la sesión.
    func tecla(_ evento: NSEvent) -> Bool {
        switch evento.keyCode {
        case 53: cancelar()
        case 49: alternar()
        case 36, 76:
            let posicion = NSEvent.mouseLocation
            let panel = paneles.first { $0.vista.marcoPantalla.contains(posicion) } ?? paneles.first
            if let panel { elegir(.pantalla(panel.vista.numero)) }
        default: return false
        }
        return true
    }

    func elegir(_ eleccion: EleccionCaptura) { terminar(eleccion) }

    func cancelar() { terminar(nil) }

    // MARK: - Fin

    private func terminar(_ eleccion: EleccionCaptura?) {
        guard let avisar = alTerminar else { return }
        alTerminar = nil
        if let observador { NotificationCenter.default.removeObserver(observador) }
        observador = nil
        // Trampa: AppKit hace un fundido al esconder la ventana y un clic rápido caía en la superficie
        // que se iba. Se deja de aceptar el mouse antes de esconderla.
        for panel in paneles {
            panel.ignoresMouseEvents = true
        }
        CATransaction.flush()
        for panel in paneles {
            panel.orderOut(nil)
            panel.vista.soltarFoto()
            panel.contentView = nil
        }
        lupa?.soltarFoto()
        lupa = nil
        paneles = []
        avisar(eleccion)
    }

    private func moverLupa(_ global: CGPoint, en vista: VistaSeleccion?) {
        guard conLupa, let vista, let foto = vista.foto, let contenedor = vista.superview else { return }
        guard modo == .area else { lupa?.isHidden = true; return }
        if lupa == nil || lupa?.superview !== contenedor {
            lupa?.removeFromSuperview()
            let nueva = VistaLupa(foto: foto)
            contenedor.addSubview(nueva)
            lupa = nueva
        }
        guard let lupa else { return }
        let local = CGPoint(x: global.x - vista.marcoPantalla.minX, y: global.y - vista.marcoPantalla.minY)
        let lado = VistaLupa.lado
        let origen = GeometriaCaptura.junto(a: local, tamano: CGSize(width: lado, height: lado), separacion: 22, limites: vista.bounds)
        lupa.isHidden = false
        lupa.setFrameOrigin(origen)
        lupa.mostrar(pixel: CGPoint(x: local.x * vista.escala, y: (vista.bounds.height - local.y) * vista.escala))
    }
}

/// Una superficie de selección: sin bordes, encima de todo (el nivel que usa macOS para la pantalla bloqueada), en
/// todos los escritorios y sobre las apps en pantalla completa.
final class PanelSeleccion: NSPanel {
    let vista: VistaSeleccion

    init(pantalla: NSScreen, foto: CGImage?, sesion: SesionCaptura) {
        vista = VistaSeleccion(pantalla: pantalla, foto: foto)
        super.init(contentRect: pantalla.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        vista.sesion = sesion
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = foto != nil
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        let contenedor = NSView(frame: NSRect(origin: .zero, size: pantalla.frame.size))
        contenedor.addSubview(vista)
        contentView = contenedor
        setFrame(pantalla.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
