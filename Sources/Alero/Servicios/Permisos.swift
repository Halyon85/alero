import AppKit
import ApplicationServices

// Permisos de macOS. Accesibilidad: lo necesitan las piezas que escuchan el mouse y el teclado de toda la Mac (scroll,
// botones, Dock, botón verde, carteles de volumen y brillo). Automatización de Finder: solo cortar y pegar archivos.
// Grabación de pantalla: solo las capturas. Sin ellos esas piezas quedan apagadas y el resto de Alero anda igual.

enum Permisos {
    static var accesibilidad: Bool { AXIsProcessTrusted() }

    /// Abre el cartel de macOS que lleva a Ajustes del Sistema › Privacidad › Accesibilidad.
    static func pedirAccesibilidad() {
        let opciones = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opciones)
    }

    static func abrirAjustesDeAccesibilidad() {
        let direccion = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: direccion) { NSWorkspace.shared.open(url) }
    }

    private static var esperando: [() -> Void] = []
    private static var reloj: Timer?

    /// Corre `hacer` apenas haya Accesibilidad (al toque si ya está). Mientras falte revisa cada 2 s; macOS no avisa
    /// cuando la persona lo concede. El reloj se apaga solo al concederse. Main thread.
    static func cuandoHayaAccesibilidad(_ hacer: @escaping () -> Void) {
        if accesibilidad { hacer(); return }
        esperando.append(hacer)
        guard reloj == nil else { return }
        reloj = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            guard accesibilidad else { return }
            reloj?.invalidate()
            reloj = nil
            let pendientes = esperando
            esperando = []
            pendientes.forEach { $0() }
        }
    }

    // MARK: - Grabación de pantalla (capturas)

    /// Mirar no tiene efectos (no muestra carteles): sirve para revisar cada tanto.
    static var grabacionPantalla: Bool { CGPreflightScreenCaptureAccess() }

    /// La primera vez muestra el cartel de macOS; después ya no hace nada (hay que ir a Ajustes del Sistema).
    static func pedirGrabacionPantalla() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func abrirAjustesDeGrabacion() {
        let direccion = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: direccion) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Automatización (controlar Finder)

    enum EstadoAutomatizacion { case concedido, sinPedir, negado }

    /// Si Alero puede mandarle órdenes a Finder. Con `preguntar`, macOS muestra su cartel la primera vez y esta
    /// llamada espera la respuesta: en ese caso, nunca en el hilo principal.
    static func automatizacionFinder(preguntar: Bool) -> EstadoAutomatizacion {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let direccion = finder.aeDesc else { return .sinPedir }
        switch AEDeterminePermissionToAutomateTarget(direccion, typeWildCard, typeWildCard, preguntar) {
        case noErr: return .concedido
        case OSStatus(errAEEventNotPermitted): return .negado
        // -1744: todavía no se preguntó. -600: Finder no está abierto (no se puede saber).
        default: return .sinPedir
        }
    }

    static func abrirAjustesDeAutomatizacion() {
        let direccion = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        if let url = URL(string: direccion) { NSWorkspace.shared.open(url) }
    }
}
