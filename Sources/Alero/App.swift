import AppKit

// Arranque de Alero: app de barra de menú (sin ícono en el Dock). Cada pieza arranca sola y, si le falta un permiso,
// queda apagada sin frenar a las demás.
// Modos para revisar sin usar la app: `Alero --capturas <carpeta>` dibuja cada pantalla a PNG (no usa permisos),
// `--icono <archivo.png>` guarda el ícono y `--ensayo-memoria` abre y cierra solo cada ventana (ver `EnsayoMemoria`).
// `--conectar-claude` y `--desconectar-claude` hacen lo mismo que el botón de General (ver `CupoClaude`) y salen.

@main
enum Principal {
    static let delegado = Delegado()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--capturas"), i + 1 < CommandLine.arguments.count {
            let carpeta = CommandLine.arguments[i + 1]
            MainActor.assumeIsolated { Capturas.hacer(en: carpeta) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--icono"), i + 1 < CommandLine.arguments.count {
            IconoApp.guardar(en: CommandLine.arguments[i + 1])
            return
        }
        for (opcion, hacer) in [("--conectar-claude", CupoClaude.conectar), ("--desconectar-claude", CupoClaude.desconectar)]
        where CommandLine.arguments.contains(opcion) {
            print(hacer() ?? T("Listo.", "Done."))
            return
        }
        app.delegate = delegado
        app.run()
    }
}

final class Delegado: NSObject, NSApplicationDelegate {
    /// Las escuchas de SIGTERM y SIGINT (se guardan para que sigan vivas).
    private var senales: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ aviso: Notification) {
        cerrarBienAlPedirlo()
        MenuEdicion.instalar()
        BarraMenu.shared.instalar()
        ControladorNotch.shared.arrancar()
        Scroll.shared.arrancar()
        TeclasMedia.shared.arrancar()
        Mezclador.shared.arrancar()
        Monitores.shared.arrancar()
        ClicDock.shared.arrancar()
        BotonVerde.shared.arrancar()
        BotonesMouse.shared.arrancar()
        CortarPegar.shared.arrancar()
        Capturador.shared.arrancar()
        if !UserDefaults.standard.bool(forKey: "app.yaAbrio") {
            UserDefaults.standard.set(true, forKey: "app.yaAbrio")
            VentanaAlero.shared.mostrar()
        }
        if EnsayoMemoria.pedido {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { EnsayoMemoria.empezar() }
        }
    }

    // Abrir Alero otra vez (desde Aplicaciones o Spotlight) muestra los ajustes: no hay otra ventana.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        VentanaAlero.shared.mostrar()
        return false
    }

    /// `pkill`, `kill` y Ctrl-C mandan una señal que, sin esto, cierra la app de golpe sin pasar por
    /// `applicationWillTerminate`: el adaptador de música quedaba huérfano para siempre (~6,5 MB cada vez;
    /// `compilar.sh instalar` lo hace en cada instalación). Con la señal se cierra por el camino normal.
    private func cerrarBienAlPedirlo() {
        for senal in [SIGTERM, SIGINT] {
            signal(senal, SIG_IGN)
            let fuente = DispatchSource.makeSignalSource(signal: senal, queue: .main)
            fuente.setEventHandler { NSApp.terminate(nil) }
            fuente.resume()
            senales.append(fuente)
        }
    }

    func applicationWillTerminate(_ aviso: Notification) {
        Musica.shared.detener()
        // El vigilante de la tapa cerrada lo nota igual al cerrarse Alero; así vuelve antes a la normalidad.
        CafeTapa.apagar()
        Cafe.shared.apagar()
        Mezclador.shared.terminar()
        Monitores.shared.terminar()
    }
}

/// El menú Edición, invisible (Alero no tiene barra de menú propia): sin él, ⌘C, ⌘V, ⌘X, ⌘A y ⌘Z no andan en los
/// campos de texto de una app de barra de menú (no se podía pegar el guion del teleprompter, 01/11/2026).
enum MenuEdicion {
    static func instalar() {
        let principal = NSMenu()
        let edicion = NSMenu(title: T("Edición", "Edit"))
        let items: [(String, Selector, String)] = [
            (T("Deshacer", "Undo"), Selector(("undo:")), "z"),
            (T("Rehacer", "Redo"), Selector(("redo:")), "Z"),
            (T("Cortar", "Cut"), #selector(NSText.cut(_:)), "x"),
            (T("Copiar", "Copy"), #selector(NSText.copy(_:)), "c"),
            (T("Pegar", "Paste"), #selector(NSText.paste(_:)), "v"),
            (T("Seleccionar todo", "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ]
        for (titulo, accion, tecla) in items { edicion.addItem(NSMenuItem(title: titulo, action: accion, keyEquivalent: tecla)) }
        let item = NSMenuItem()
        item.submenu = edicion
        principal.addItem(item)
        NSApp.mainMenu = principal
    }
}
