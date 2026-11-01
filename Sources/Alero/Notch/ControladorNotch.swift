import AppKit
import Combine
import SwiftUI

// Maneja las ventanas del notch y todo lo que las mueve: el mouse (abrir al pasar, cerrar al salir), el arrastre de
// archivos (abre el estante) y deslizar encima (atajos). Main thread.
//
// Puede haber un notch por pantalla (opción "Todas") o uno solo que se ubica según la opción elegida, incluso
// siguiendo al mouse. Los avisos (volumen, reunión, auriculares) van al notch de la pantalla donde está el puntero.
//
// Cada ventana es fija y transparente; lo que crece es la forma negra. Para no robarle clics a la barra de menú,
// la ventana solo acepta el mouse cuando el puntero está dentro de la forma actual (Boring Notch y otros dejan
// una franja invisible que tapa a otras apps). El mouse se escucha con monitores de eventos: sin permisos y sin
// consultar a cada rato.

final class ControladorNotch {
    static let shared = ControladorNotch()

    private var instancias: [InstanciaNotch] = []
    /// Notches armados solo para un aviso de brillo en una pantalla sin notch propio (ver `mostrarHud`).
    private var pasajeras: [InstanciaNotch] = []
    private var monitores: [Any] = []
    private var suscripciones = Set<AnyCancellable>()
    private var activo = false

    // Arrastre de archivos (idea de Boring Notch): si al mover el mouse con el botón apretado cambió el contenido
    // del portapapeles de arrastre y trae archivos, la persona está arrastrando algo.
    private var cuentaArrastre = 0
    private var arrastrandoArchivo = false

    /// El notch que recibe los avisos: el de la pantalla del puntero, o el primero.
    var estado: EstadoNotch {
        (instanciaBajoElPuntero() ?? instancias.first)?.estado ?? EstadoNotch()
    }

    func arrancar() {
        let ajustes = Ajustes.shared
        ajustes.$notchActivo.removeDuplicates().sink { [weak self] prendido in
            prendido ? self?.prender() : self?.apagar()
        }.store(in: &suscripciones)
        ajustes.$notchPantalla.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rearmar() }
        }.store(in: &suscripciones)
        // Música y calendario solo se ven en el notch: con el notch apagado no se abren (el lector de música es un
        // proceso aparte de ~6,5 MB y el calendario se conecta con la base de Calendario de macOS).
        ajustes.$notchActivo.combineLatest(ajustes.$notchMusica).map { $0 && $1 }.removeDuplicates().sink { activa in
            activa ? Musica.shared.arrancar() : Musica.shared.detener()
        }.store(in: &suscripciones)
        ajustes.$notchActivo.combineLatest(ajustes.$notchCalendario).map { $0 && $1 }.removeDuplicates().filter { $0 }.sink { _ in
            Calendario.shared.arrancar()
        }.store(in: &suscripciones)

        Calendario.shared.alAcercarse = { [weak self] evento in
            let minutos = Int(ceil(evento.inicio.timeIntervalSinceNow / 60))
            self?.estado.mostrar(.reunion(titulo: evento.titulo, minutos: max(minutos, 0)), durante: 6)
        }
        Sonido.shared.alConectarse = { [weak self] salida in
            guard Ajustes.shared.avisoSalida else { return }
            self?.estado.mostrar(.salida(tipo: salida.tipo, nombre: salida.nombre))
        }
        Corriente.shared.alCambiar = { [weak self] enchufada, porcentaje in
            self?.estado.mostrar(.corriente(enchufada: enchufada, porcentaje: porcentaje), durante: 3)
        }
        Descargas.shared.alTerminar = { [weak self] nombres in
            let nombre = nombres.count == 1 ? nombres[0] : VistaAviso.archivos(nombres.count)
            self?.estado.mostrar(.descarga(nombre: nombre), durante: 4)
        }
        // Cargador y descargas: solo escuchan con el notch y su aviso prendidos.
        ajustes.$notchActivo.combineLatest(ajustes.$avisoCorriente).map { $0 && $1 }.removeDuplicates().sink { prender in
            prender ? Corriente.shared.arrancar() : Corriente.shared.detener()
        }.store(in: &suscripciones)
        ajustes.$notchActivo.combineLatest(ajustes.$avisoDescargas).map { $0 && $1 }.removeDuplicates().sink { prender in
            prender ? Descargas.shared.arrancar() : Descargas.shared.detener()
        }.store(in: &suscripciones)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rearmar()
        }
    }

    private func prender() {
        guard !activo else { return }
        activo = true
        rearmar()
        escucharMouse()
    }

    private func apagar() {
        activo = false
        monitores.forEach(NSEvent.removeMonitor)
        monitores = []
        (instancias + pasajeras).forEach { $0.cerrarVentana() }
        instancias = []
        pasajeras = []
    }

    // MARK: - Pantallas

    /// Las pantallas donde tiene que haber notch según la opción elegida.
    private func pantallasElegidas() -> [NSScreen] {
        let todas = NSScreen.screens
        switch Ajustes.shared.notchPantalla {
        case .conNotch: return [todas.first(where: \.tieneNotch) ?? NSScreen.main].compactMap { $0 }
        case .principal: return [todas.first].compactMap { $0 }
        case .todas: return todas
        case .mouse: return [pantallaDelPuntero() ?? NSScreen.main].compactMap { $0 }
        }
    }

    private func pantallaDelPuntero() -> NSScreen? {
        let puntero = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(puntero) }
    }

    /// Deja una ventana por pantalla elegida: reusa las que ya están, crea las que faltan y cierra las que sobran.
    private func rearmar() {
        guard activo else { return }
        let elegidas = pantallasElegidas()
        let ids = Set(elegidas.map(\.numero))
        instancias.filter { !ids.contains($0.pantalla) }.forEach { $0.cerrarVentana() }
        instancias.removeAll { !ids.contains($0.pantalla) }
        for pantalla in elegidas {
            if let existente = instancias.first(where: { $0.pantalla == pantalla.numero }) {
                existente.ubicar(en: pantalla)
            } else {
                instancias.append(InstanciaNotch(pantalla: pantalla))
            }
        }
    }

    /// El aviso de volumen o brillo. Con `pantalla`, en el notch de esa pantalla (el brillo de un monitor va arriba de
    /// ese monitor): si ahí no hay notch (por ejemplo con "La de la MacBook"), se arma uno solo para el aviso, que se
    /// va cuando el aviso termina. Sin pantalla, donde está el puntero.
    func mostrarHud(_ tipo: TipoHud, valor: Float, silencio: Bool, en pantalla: CGDirectDisplayID?) {
        guard activo, let pantalla else { estado.mostrarHud(tipo, valor: valor, silencio: silencio); return }
        if let propia = instancias.first(where: { $0.pantalla == pantalla }) ?? pasajeras.first(where: { $0.pantalla == pantalla }) {
            propia.estado.mostrarHud(tipo, valor: valor, silencio: silencio)
            return
        }
        guard let destino = NSScreen.screens.first(where: { $0.numero == pantalla }) else {
            estado.mostrarHud(tipo, valor: valor, silencio: silencio)
            return
        }
        let nueva = InstanciaNotch(pantalla: destino)
        pasajeras.append(nueva)
        nueva.estado.mostrarHud(tipo, valor: valor, silencio: silencio)
        nueva.alCerrarse = { [weak self, weak nueva] in
            // Se espera a que termine la animación de cierre antes de sacar la ventana.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self, let nueva, nueva.estado.modo == .cerrado else { return }
                nueva.cerrarVentana()
                self.pasajeras.removeAll { $0 === nueva }
            }
        }
    }

    /// Un aviso chico en el notch de la pantalla del puntero (o el primero).
    func avisar(_ aviso: AvisoNotch, durante segundos: TimeInterval = 3.5) {
        estado.mostrar(aviso, durante: segundos)
    }

    /// Abre el teleprompter en el notch desde donde se pidió (`en`) o en el de la pantalla del puntero: la que estás
    /// mirando. Antes iba siempre a la MacBook y, mirando el monitor, parecía que no andaba (01/11/2026).
    /// En los demás notches se cierra.
    func abrirPrompter(en estado: EstadoNotch? = nil) {
        let desde = estado.flatMap { pedido in instancias.first { $0.estado === pedido } }
        guard let elegida = desde ?? instanciaBajoElPuntero() ?? instancias.first else { return }
        for instancia in instancias where instancia !== elegida && instancia.estado.modo == .prompter { instancia.estado.cerrar() }
        elegida.estado.mostrarPrompter()
    }

    /// Cierra el teleprompter donde esté abierto.
    func cerrarPrompter() {
        Teleprompter.shared.cerrar()
        for instancia in instancias where instancia.estado.modo == .prompter { instancia.estado.cerrar() }
    }

    /// Desde Alero › Notch abierto: abre el notch unos segundos para ver los cambios en vivo (en la pantalla del puntero
    /// o en la primera). No se cierra al mover el mouse en la ventana de Alero.
    func probar() {
        (instanciaBajoElPuntero() ?? instancias.first)?.probar()
    }

    private func instanciaBajoElPuntero() -> InstanciaNotch? {
        guard let pantalla = pantallaDelPuntero() else { return nil }
        return instancias.first { $0.pantalla == pantalla.numero }
    }

    // MARK: - Mouse

    private func escucharMouse() {
        // La rueda también se escucha afuera: con el notch cerrado, la ventana deja pasar el mouse hasta que el puntero
        // entra, y el primer giro (o todo el gesto, si el puntero llegó deslizando) va a la app de abajo.
        let tipos: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        let manejar: (NSEvent) -> Void = { [weak self] evento in
            if evento.type == .scrollWheel { self?.instanciaBajoElPuntero()?.deslizar(evento) } else { self?.recibir(evento) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: tipos, handler: manejar) {
            monitores.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: tipos, handler: { evento in
            manejar(evento)
            return evento
        }) {
            monitores.append(local)
        }
    }

    private func recibir(_ evento: NSEvent) {
        let puntero = NSEvent.mouseLocation
        switch evento.type {
        case .leftMouseDown:
            cuentaArrastre = NSPasteboard(name: .drag).changeCount
            // Un clic afuera mientras se escribe en la terminal cierra el notch (sacar el mouse no lo cierra).
            for instancia in instancias where instancia.escribiendo && !instancia.zona().contains(puntero) { instancia.estado.cerrar() }
        case .leftMouseDragged:
            detectarArrastre(puntero)
        case .leftMouseUp:
            terminarArrastre()
        default:
            break
        }
        seguirAlMouse()
        for instancia in instancias {
            instancia.mouse(en: puntero, arrastrando: arrastrandoArchivo)
        }
    }

    /// Con "Sigue al mouse", el notch se muda a la pantalla del puntero (solo si está cerrado: no se escapa mientras
    /// lo usás).
    private func seguirAlMouse() {
        guard Ajustes.shared.notchPantalla == .mouse, let pantalla = pantallaDelPuntero(), let unica = instancias.first,
              unica.pantalla != pantalla.numero, unica.estado.modo == .cerrado else { return }
        unica.ubicar(en: pantalla)
    }

    // MARK: - Arrastre de archivos

    private func detectarArrastre(_ puntero: NSPoint) {
        guard Ajustes.shared.notchEstante else { return }
        if !arrastrandoArchivo {
            let tablero = NSPasteboard(name: .drag)
            guard tablero.changeCount != cuentaArrastre,
                  tablero.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
            arrastrandoArchivo = true
        }
        // Se abre recién cuando el archivo se acerca al notch: arrastrar algo en Finder no tiene que abrirlo siempre.
        for instancia in instancias where instancia.zona().insetBy(dx: -140, dy: -120).contains(puntero) {
            instancia.abrirEstante()
        }
    }

    private func terminarArrastre() {
        guard arrastrandoArchivo else { return }
        arrastrandoArchivo = false
        // Si lo soltó afuera, se cierra con medio segundo de gracia. Si lo soltó adentro, `soltar` ya avisó.
        for instancia in instancias where instancia.estado.modo == .estante {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if instancia.estado.modo == .estante { instancia.estado.cerrar() }
            }
        }
    }
}

/// Un notch en una pantalla: su ventana, su estado y su manejo del mouse.
final class InstanciaNotch {
    let estado = EstadoNotch()
    private(set) var pantalla: CGDirectDisplayID
    /// Se llama cada vez que el notch vuelve a cerrado (lo usan los notches de un solo aviso para irse).
    var alCerrarse: (() -> Void)?
    private let panel = PanelNotch()
    private var observacion: AnyCancellable?
    private var teclado: AnyCancellable?
    private var abrirPendiente: DispatchWorkItem?
    private var cerrarPendiente: DispatchWorkItem?
    private var acumulado: CGFloat = 0
    private var ultimoGesto = Date.distantPast
    /// Cuándo se abrió el notch por pasar el mouse (ver `deslizar`).
    private var abiertoPorMouse = Date.distantPast
    /// Hasta cuándo no se cierra al sacar el mouse (ver `probar`).
    private var fijoHasta = Date.distantPast

    init(pantalla: NSScreen) {
        self.pantalla = pantalla.numero
        let vista = AnfitrionNotch(rootView: VistaNotch(estado: estado))
        vista.instancia = self
        panel.contentView = vista
        ubicar(en: pantalla)
        panel.orderFrontRegardless()
        teclado = estado.$modo.combineLatest(estado.$espacio).sink { [weak self] modo, espacio in
            self?.permitirTeclado(modo == .abierto && InstanciaNotch.seEscribe(en: espacio))
        }
        observacion = estado.$modo.removeDuplicates().dropFirst().sink { [weak self] modo in
            guard let self else { return }
            // Con el teleprompter abierto, el notch no sale al compartir pantalla ni en grabaciones (solo lo ves vos).
            let ocultar = modo == .prompter && Ajustes.shared.prompterOcultar
            self.panel.sharingType = ocultar ? .none : .readOnly
            if modo == .cerrado { self.alCerrarse?() }
        }
    }

    /// Prende o apaga que el notch tome el teclado. Al apagarlo, si lo tenía, lo suelta (se saca y se vuelve a poner sin
    /// pedir el teclado): si no, lo que escribís seguiría yendo al notch cerrado.
    private func permitirTeclado(_ permitir: Bool) {
        guard panel.aceptaTeclado != permitir else { return }
        panel.aceptaTeclado = permitir
        if !permitir && panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// Escribiendo en la terminal, en el guion o en el buscador del desinstalador, sacar el mouse no cierra el notch
    /// (se cierra con un clic afuera).
    var escribiendo: Bool {
        panel.isKeyWindow && estado.modo == .abierto && InstanciaNotch.seEscribe(en: estado.espacio)
    }

    /// Las pestañas con algo para escribir: la terminal, el guion del teleprompter y el buscador de apps de Utilidades.
    /// Solo ahí el notch puede tomar el teclado, y solo cuando hacés clic en el campo.
    static func seEscribe(en espacio: EspacioNotch) -> Bool { [.terminal, .teleprompter, .utilidades].contains(espacio) }

    func ubicar(en nueva: NSScreen) {
        pantalla = nueva.numero
        let medidas = nueva.medidasNotch
        estado.medidas = medidas
        let tamano = Diseno.tamanoVentana(medidas)
        let marco = NSRect(x: medidas.centroX - tamano.width / 2, y: medidas.arriba - tamano.height,
                           width: tamano.width, height: tamano.height)
        panel.setFrame(marco, display: true)
    }

    func cerrarVentana() {
        abrirPendiente?.cancel()
        cerrarPendiente?.cancel()
        panel.orderOut(nil)
    }

    /// Rectángulo (en coordenadas de pantalla) de la forma que se está mostrando, con un pequeño margen.
    func zona() -> NSRect {
        let medidas = estado.medidas
        let musica = Ajustes.shared.notchMusica && Musica.shared.pista?.sonando == true
        var tamano = Diseno.tamano(estado.modo, medidas, musica: musica, punto: Cafe.shared.prendido)
        // Aunque no se dibuje nada (sin notch y sin cápsula), arriba al centro igual se puede abrir.
        if tamano.width == 0 { tamano.width = medidas.ancho }
        let hombro = Diseno.radios(estado.modo).hombro
        let ancho = tamano.width + 2 * hombro
        return NSRect(x: medidas.centroX - ancho / 2, y: medidas.arriba - tamano.height, width: ancho, height: tamano.height)
            .insetBy(dx: -2, dy: -2)
    }

    func mouse(en puntero: NSPoint, arrastrando: Bool) {
        let dentro = zona().contains(puntero)
        panel.ignoresMouseEvents = !dentro
        if !arrastrando { hover(dentro: dentro) }
    }

    func abrirEstante() {
        // En Utilidades, lo que se arrastra es una app para desinstalar: el notch no se pasa al estante.
        let desinstalando = estado.modo == .abierto && estado.espacio == .utilidades
        guard estado.modo != .estante, !desinstalando else { return }
        cerrarPendiente?.cancel()
        cerrarPendiente = nil
        estado.abrirEstante()
    }

    private func hover(dentro: Bool) {
        let modo = estado.modo
        let pasajero = modo.esPasajero
        if dentro {
            cerrarPendiente?.cancel()
            cerrarPendiente = nil
            if pasajero { estado.detenerVuelta() }
            let demora = Ajustes.shared.notchDemora
            guard modo == .cerrado, demora > 0, abrirPendiente == nil else { return }
            let tarea = DispatchWorkItem { [weak self] in
                self?.abrirPendiente = nil
                self?.abiertoPorMouse = Date()
                self?.estado.abrir()
            }
            abrirPendiente = tarea
            DispatchQueue.main.asyncAfter(deadline: .now() + demora, execute: tarea)
        } else {
            abrirPendiente?.cancel()
            abrirPendiente = nil
            if pasajero { estado.reanudarVuelta() }
            // Al salir se cierra con un cuarto de segundo de margen (Boring cierra a los 100 ms y se siente brusco).
            guard modo.esGrande, cerrarPendiente == nil, Date() >= fijoHasta, !escribiendo else { return }
            let tarea = DispatchWorkItem { [weak self] in
                self?.cerrarPendiente = nil
                self?.estado.cerrar()
            }
            cerrarPendiente = tarea
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: tarea)
        }
    }

    /// Abre el notch 5 s sin que el mouse lo cierre (el puntero está en la ventana de Alero), y después lo cierra.
    func probar() {
        fijoHasta = Date().addingTimeInterval(5)
        cerrarPendiente?.cancel()
        cerrarPendiente = nil
        estado.abrir()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, Date() >= self.fijoHasta, !self.zona().contains(NSEvent.mouseLocation) else { return }
            self.estado.cerrar()
        }
    }

    /// Un clic en el notch cerrado lo abre al toque (sin esperar la demora).
    func clic() {
        abrirPendiente?.cancel()
        abrirPendiente = nil
        if estado.modo == .cerrado || estado.modo == .aviso { estado.abrir() }
    }

    /// Deslizar (trackpad) o girar la rueda sobre el notch cerrado muestra los atajos; otra vez, los esconde. Con el
    /// notch recién abierto por pasar el mouse, un deslizamiento de costado también los muestra: antes, con la demora
    /// de 0,3 s, el notch se abría antes de terminar el gesto y los atajos no aparecían nunca (01/11/2026). Con el
    /// notch abierto, la rueda para arriba y abajo sigue siendo de la columna de sonido (se desplaza).
    func deslizar(_ evento: NSEvent) {
        guard zona().contains(NSEvent.mouseLocation) else { return }
        // Sobre el teleprompter, la rueda mueve el guion (y lo pausa).
        if estado.modo == .prompter {
            let paso = evento.hasPreciseScrollingDeltas ? evento.scrollingDeltaY : evento.scrollingDeltaY * 12
            Teleprompter.shared.desplazar(-Double(paso))
            return
        }
        guard Ajustes.shared.notchAtajos else { return }
        let modo = estado.modo
        let deCostado = abs(evento.scrollingDeltaX) > abs(evento.scrollingDeltaY) * 1.5
        let reciente = Date().timeIntervalSince(abiertoPorMouse) < 2.5
        guard modo == .cerrado || modo == .atajos || modo == .aviso || (modo == .abierto && deCostado && reciente) else { return }
        // Arrancó un gesto: el notch no se abre por la demora mientras tanto.
        abrirPendiente?.cancel()
        abrirPendiente = nil
        if evento.hasPreciseScrollingDeltas {
            if evento.phase == .began { acumulado = 0 }
            acumulado += abs(evento.scrollingDeltaX) + abs(evento.scrollingDeltaY)
            guard acumulado >= 30 else { return }
            acumulado = 0
        }
        guard Date().timeIntervalSince(ultimoGesto) > 0.45 else { return }
        ultimoGesto = Date()
        modo == .atajos ? estado.cerrar() : estado.mostrarAtajos()
    }
}

extension NSScreen {
    /// Número de la pantalla para macOS (estable mientras esté conectada).
    var numero: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Ventana del notch: sin bordes, por encima de la barra de menú, en todos los escritorios y sobre pantalla
/// completa. No activa la app (no le saca el foco a lo que estás usando) y solo toma el teclado en la terminal.
final class PanelNotch: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Lo que se anima es la forma (SwiftUI), nunca la ventana. Y la animación de AppKit deja viva en WindowServer
        // cada ventana que se cierra (ver `VentanaAlero`): los notches de un solo aviso se arman y se cierran seguido.
        animationBehavior = .none
    }

    /// Solo con la terminal, el guion del teleprompter o el buscador de apps a la vista: ahí se escribe. El resto del tiempo el notch nunca le saca el teclado a nadie.
    var aceptaTeclado = false
    override var canBecomeKey: Bool { aceptaTeclado }
    override var canBecomeMain: Bool { false }
}

/// Acepta el primer clic aunque Alero no esté activa, y un clic en el notch cerrado lo abre.
final class AnfitrionNotch: NSHostingView<VistaNotch> {
    weak var instancia: InstanciaNotch?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let instancia, instancia.estado.modo == .cerrado || instancia.estado.modo == .aviso {
            instancia.clic()
            return
        }
        super.mouseDown(with: event)
    }
}
