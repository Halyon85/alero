import AppKit
import Combine
import SwiftUI

// Modo limpieza: traba el teclado, el trackpad (scroll y gestos) y las teclas de sistema (brillo, volumen, música)
// para poder pasar un paño sin que pase nada. Una capa negra cubre todas las pantallas con cómo salir. Los clics sí
// pasan, para poder tocar el botón de salir. Se abre desde el menú de la barra ("Limpiar el teclado…").
//
// Nunca deja la Mac trabada:
// - Sin Accesibilidad no arranca (pide el permiso). La escucha existe solo mientras dura la traba.
// - Salidas: Esc 5 veces seguidas, mantener apretado el botón de la pantalla (no depende de la escucha) o el tope de
//   tiempo (Ajustes › General, 2 min de fábrica).
// - Si macOS apaga la escucha y no se puede volver a prender, o se cambia de usuario o la Mac se duerme, se destraba.
// - Se sale al soltar la tecla o el botón, no al apretar: así la app de abajo no recibe medio clic o media tecla.
//
// La escucha va al principio de todo (`cghidEventTap`): las demás de Alero (scroll, botones, volumen) están después
// y no ven nada mientras dura la traba. Corre en `HiloEventos`, como todas.

final class EstadoTraba: ObservableObject {
    /// Cuántos Esc seguidos van.
    @Published var escs = 0
    /// Cuándo se suelta sola (nil = sin tope).
    @Published var fin: Date?
}

final class TrabaTeclado {
    static let shared = TrabaTeclado()

    // Main thread.
    private(set) var trabado = false
    private var paneles: [NSPanel] = []
    private var escucha: CFMachPort?
    private var observadores: [(NotificationCenter, NSObjectProtocol)] = []
    private var tope: DispatchWorkItem?
    private var estado = EstadoTraba()

    // Solo en el hilo de eventos.
    private var salida = SalidaTraba()
    private var esperandoSoltarEsc = false
    private var puerto: CFMachPort?

    /// Teclado, modificadoras, scroll, botones extra del mouse, teclas de sistema (14) y gestos del trackpad
    /// (18 girar, 19 y 20 empezar y terminar, 29 gesto, 30 pellizcar, 31 deslizar, 32 doble toque).
    private static let mascara: CGEventMask = {
        let tipos: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let crudos: [UInt32] = [14, 18, 19, 20, 29, 30, 31, 32]
        return tipos.reduce(CGEventMask(0)) { $0 | $1.bit } | crudos.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
    }()

    func empezar() {
        guard !trabado else { return }
        guard Permisos.accesibilidad else { pedirPermiso(); return }
        guard let escucha = HiloEventos.shared.agregarEscucha(lugar: .cghidEventTap, posicion: .headInsertEventTap, eventos: TrabaTeclado.mascara,
                                                              dueno: Unmanaged.passUnretained(self).toOpaque(), callback: { _, tipo, evento, dueno in
            guard let dueno else { return Unmanaged.passUnretained(evento) }
            return Unmanaged<TrabaTeclado>.fromOpaque(dueno).takeUnretainedValue().manejar(tipo, evento)
        }) else {
            NSLog("Alero: no se pudo trabar el teclado (¿falta Accesibilidad?)")
            pedirPermiso()
            return
        }
        self.escucha = escucha
        HiloEventos.shared.ejecutar { [self] in
            salida.reiniciar()
            esperandoSoltarEsc = false
            puerto = escucha
        }
        trabado = true
        estado = EstadoTraba()
        let segundos = Ajustes.shared.limpiezaTope
        if segundos > 0 {
            estado.fin = Date().addingTimeInterval(TimeInterval(segundos))
            let tarea = DispatchWorkItem { [weak self] in self?.terminar() }
            tope = tarea
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(segundos), execute: tarea)
        }
        mostrarPaneles()
        observar()
    }

    func terminar() {
        guard trabado else { return }
        trabado = false
        if let escucha { HiloEventos.shared.sacarEscucha(escucha) }
        escucha = nil
        HiloEventos.shared.ejecutar { [self] in puerto = nil }
        tope?.cancel()
        tope = nil
        observadores.forEach { centro, observador in centro.removeObserver(observador) }
        observadores = []
        paneles.forEach { $0.orderOut(nil); $0.contentView = nil }
        paneles = []
    }

    // MARK: - Pantallas

    /// Una capa por pantalla, arriba de todo (hasta de la barra de menú y del Dock), en todos los escritorios.
    private func mostrarPaneles() {
        paneles.forEach { $0.orderOut(nil); $0.contentView = nil }
        paneles = NSScreen.screens.map { pantalla in
            let panel = PanelTraba(contentRect: pantalla.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            // Sin la animación de AppKit, como las demás ventanas que se cierran (ver `VentanaAlero`). Acá no se
            // midió (trabar el teclado pide Accesibilidad), pero cada capa es una pantalla entera.
            panel.animationBehavior = .none
            panel.contentView = VistaPrimerClic(rootView: VistaTraba(estado: estado, salir: { [weak self] in self?.terminar() }))
            panel.setFrame(pantalla.frame, display: true)
            panel.orderFrontRegardless()
            return panel
        }
        paneles.first?.makeKey()
    }

    private func observar() {
        let espacio = NSWorkspace.shared.notificationCenter
        let destrabar: (Notification) -> Void = { [weak self] _ in self?.terminar() }
        for nombre in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observadores.append((espacio, espacio.addObserver(forName: nombre, object: nil, queue: .main, using: destrabar)))
        }
        let app = NotificationCenter.default
        observadores.append((app, app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.trabado == true { self?.mostrarPaneles() }
        }))
    }

    private func pedirPermiso() {
        NSApp.activate(ignoringOtherApps: true)
        let alerta = NSAlert()
        alerta.messageText = T("Falta el permiso de Accesibilidad", "Accessibility permission needed")
        alerta.informativeText = T("Para trabar el teclado mientras lo limpiás, Alero necesita Accesibilidad. Sin él no se traba nada.",
                                   "To lock the keyboard while you clean it, Alero needs Accessibility. Without it nothing gets locked.")
        alerta.addButton(withTitle: T("Abrir Ajustes", "Open Settings"))
        alerta.addButton(withTitle: T("Cancelar", "Cancel"))
        if alerta.runModal() == .alertFirstButtonReturn {
            Permisos.pedirAccesibilidad()
            Permisos.abrirAjustesDeAccesibilidad()
        }
    }

    // MARK: - En el hilo de eventos

    /// Se traga todo lo que está en la máscara. Rápido y sin llamadas a Accesibilidad (con la escucha viva, una
    /// llamada que se traba congela la entrada de toda la Mac).
    private func manejar(_ tipo: CGEventType, _ evento: CGEvent) -> Unmanaged<CGEvent>? {
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            // macOS la apagó: se vuelve a prender. Si no prende (o se fue el permiso), se destraba.
            if let puerto { CGEvent.tapEnable(tap: puerto, enable: true) }
            let sigue = puerto.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            if !sigue || !AXIsProcessTrusted() { DispatchQueue.main.async { [weak self] in self?.terminar() } }
            return Unmanaged.passUnretained(evento)
        }
        switch tipo {
        case .keyDown:
            let esEsc = evento.getIntegerValueField(.keyboardEventKeycode) == 53
            let repite = evento.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let cuenta = salida.tecla(esEsc: esEsc, repite: repite, ahora: ProcessInfo.processInfo.systemUptime)
            if salida.completa { esperandoSoltarEsc = true }
            publicar(cuenta)
        case .keyUp:
            if esperandoSoltarEsc, evento.getIntegerValueField(.keyboardEventKeycode) == 53 {
                esperandoSoltarEsc = false
                DispatchQueue.main.async { [weak self] in self?.terminar() }
            }
        case .flagsChanged:
            salida.reiniciar()
            publicar(0)
        default:
            // Teclas de sistema: solo cuentan al bajar (data1, bits 8 a 15 = 0xA), así la subida no corta nada.
            if tipo.rawValue == 14, let sistema = NSEvent(cgEvent: evento), sistema.subtype.rawValue == 8,
               (sistema.data1 & 0xFF00) >> 8 == 0xA {
                salida.reiniciar()
                publicar(0)
            }
        }
        return nil
    }

    private func publicar(_ cuenta: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.trabado, self.estado.escs != cuenta else { return }
            self.estado.escs = cuenta
        }
    }
}

/// La capa puede recibir clics sin activar Alero (así no le saca el frente a la app que estaba).
private final class PanelTraba: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// El primer clic ya toca el botón (si no, macOS lo usa para enfocar la capa).
private final class VistaPrimerClic<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
