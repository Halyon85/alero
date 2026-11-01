import AppKit
import Combine

// El ícono de Alero en la barra de menú y su menú: los accesos rápidos (café, capturas, teleprompter, limpiar el teclado), las
// secciones de Mantenimiento y la ventana de Alero. Todo lo que se abre va a la misma ventana. El menú se arma cada
// vez que se abre, así siempre muestra el estado real (y los atajos de captura que estén grabados). El ícono se puede
// esconder desde Alero › General o con el atajo del notch.

final class BarraMenu: NSObject, NSMenuDelegate {
    static let shared = BarraMenu()

    private var item: NSStatusItem?
    private var suscripciones = Set<AnyCancellable>()

    func instalar() {
        Cafe.shared.$prendido.receive(on: RunLoop.main).sink { [weak self] _ in self?.actualizarIcono() }.store(in: &suscripciones)
        // Escondido, el ícono se saca de la barra del todo (no solo invisible) y se vuelve a crear al mostrarlo.
        Ajustes.shared.$iconoBarra.removeDuplicates().sink { [weak self] mostrar in
            guard let self else { return }
            if mostrar { self.crearIcono() } else { self.sacarIcono() }
        }
        .store(in: &suscripciones)
    }

    private func crearIcono() {
        guard item == nil else { return }
        let nuevo = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        nuevo.button?.toolTip = "Alero"
        let menu = NSMenu()
        menu.delegate = self
        nuevo.menu = menu
        item = nuevo
        actualizarIcono()
    }

    private func sacarIcono() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func actualizarIcono() {
        item?.button?.image = IconoApp.barra(cafe: Cafe.shared.prendido)
    }

    /// El menú se rearma cada vez que se abre (lo llama AppKit justo antes de mostrarlo).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(itemCafe())
        menu.addItem(itemCapturas())
        menu.addItem(item(T("Teleprompter", "Teleprompter"), icono: "text.alignleft", accion: #selector(abrirPrompter)))
        menu.addItem(item(T("Limpiar el teclado…", "Clean the Keyboard…"), icono: "keyboard", accion: #selector(trabarTeclado)))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: T("Mantenimiento", "Maintenance")))
        for seccion in [SeccionAlero.limpiador, .desinstalador, .homebrew] {
            let entrada = item(BarraMenu.entrada(seccion), icono: seccion.icono, accion: #selector(abrirSeccion(_:)))
            entrada.representedObject = seccion.rawValue
            menu.addItem(entrada)
        }
        menu.addItem(.separator())
        let abrir = item(T("Abrir Alero…", "Open Alero…"), icono: "gearshape", accion: #selector(abrirAlero))
        abrir.keyEquivalent = ","
        menu.addItem(abrir)
        menu.addItem(NSMenuItem(title: T("Salir de Alero", "Quit Alero"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ titulo: String, icono: String, accion: Selector) -> NSMenuItem {
        let nuevo = NSMenuItem(title: titulo, action: accion, keyEquivalent: "")
        nuevo.target = self
        nuevo.image = NSImage(systemSymbolName: icono, accessibilityDescription: nil)
        return nuevo
    }

    private static func entrada(_ seccion: SeccionAlero) -> String {
        switch seccion {
        case .limpiador: return T("Limpiar la Mac…", "Clean Up Your Mac…")
        case .desinstalador: return T("Desinstalar una app…", "Uninstall an App…")
        default: return T("Homebrew…", "Homebrew…")
        }
    }

    /// Café con su estado, las duraciones y, si está prendido, "Apagar".
    private func itemCafe() -> NSMenuItem {
        let cafe = Cafe.shared
        let titulo = cafe.prendido
            ? T("Café: \(cafe.descripcion.lowercased())", "Coffee: \(cafe.descripcion.lowercased())")
            : T("Café", "Coffee")
        let itemCafe = NSMenuItem(title: titulo, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let duraciones: [(String, TimeInterval?)] = [
            (T("30 minutos", "30 minutes"), 30 * 60), (T("1 hora", "1 hour"), 3600),
            (T("2 horas", "2 hours"), 2 * 3600), (T("Sin fin", "Until turned off"), nil),
        ]
        for (nombre, segundos) in duraciones {
            let opcion = NSMenuItem(title: nombre, action: #selector(elegirCafe(_:)), keyEquivalent: "")
            opcion.target = self
            opcion.representedObject = segundos.map { NSNumber(value: $0) }
            sub.addItem(opcion)
        }
        if cafe.prendido {
            sub.addItem(.separator())
            let apagar = NSMenuItem(title: T("Apagar", "Turn off"), action: #selector(apagarCafe), keyEquivalent: "")
            apagar.target = self
            sub.addItem(apagar)
        }
        itemCafe.submenu = sub
        itemCafe.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        itemCafe.state = cafe.prendido ? .on : .off
        return itemCafe
    }

    /// "Capturar" con un ítem por modo (con su atajo grabado, si es de una sola tecla) y "Abrir carpeta de capturas".
    private func itemCapturas() -> NSMenuItem {
        let capturas = NSMenuItem(title: T("Capturar", "Capture"), action: nil, keyEquivalent: "")
        capturas.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        let sub = NSMenu()
        for modo in ModoCaptura.allCases {
            let entrada = item(modo.accion, icono: modo.icono, accion: #selector(capturar(_:)))
            entrada.representedObject = modo.rawValue
            if let atajo = Ajustes.shared.atajoCaptura(modo), atajo.teclaSola.count == 1 {
                entrada.keyEquivalent = atajo.teclaSola.lowercased()
                entrada.keyEquivalentModifierMask = BarraMenu.modificadoras(atajo.flags)
            }
            sub.addItem(entrada)
        }
        sub.addItem(.separator())
        sub.addItem(item(T("Abrir carpeta de capturas", "Open Screenshots Folder"), icono: "folder", accion: #selector(abrirCarpeta)))
        capturas.submenu = sub
        return capturas
    }

    @objc private func elegirCafe(_ opcion: NSMenuItem) {
        Cafe.shared.prender(por: (opcion.representedObject as? NSNumber)?.doubleValue)
    }

    @objc private func apagarCafe() { Cafe.shared.apagar() }

    @objc private func abrirAlero() { VentanaAlero.shared.mostrar() }

    @objc private func abrirPrompter() { ControladorNotch.shared.abrirPrompter() }

    @objc private func capturar(_ item: NSMenuItem) {
        guard let modo = (item.representedObject as? String).flatMap(ModoCaptura.init(rawValue:)) else { return }
        // A propósito: se espera a que el menú termine de irse, si no sale en la foto congelada.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Capturador.shared.empezar(modo) }
    }

    @objc private func abrirCarpeta() { Capturador.shared.abrirCarpeta() }

    @objc private func trabarTeclado() {
        // A propósito: se espera a que el menú se cierre, si no la capa queda abajo del menú abierto.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { TrabaTeclado.shared.empezar() }
    }

    @objc private func abrirSeccion(_ item: NSMenuItem) {
        guard let seccion = (item.representedObject as? String).flatMap(SeccionAlero.init(rawValue:)) else { return }
        VentanaAlero.shared.mostrar(seccion)
    }

    /// Las modificadoras de un atajo grabado como las pide un ítem de menú.
    private static func modificadoras(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var mascara: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { mascara.insert(.command) }
        if flags.contains(.maskShift) { mascara.insert(.shift) }
        if flags.contains(.maskAlternate) { mascara.insert(.option) }
        if flags.contains(.maskControl) { mascara.insert(.control) }
        return mascara
    }
}
