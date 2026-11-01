import AppKit
import Sparkle

/// Actualizaciones con Sparkle, solo en las versiones publicadas por Halyon Team. Esas llevan en su Info.plist la
/// dirección de la lista de versiones (`SUFeedURL`) y la clave pública con la que se firma cada una (`SUPublicEDKey`):
/// las pone `herramientas/publicar-version.sh`. La que compila cada uno con `compilar.sh` no las tiene y no busca nada
/// (si buscara, le cambiaría su app por la publicada y macOS pediría los permisos de nuevo): se actualiza con
/// `git pull && ./compilar.sh instalar`. Busca una vez por día y siempre pregunta antes de instalar: nunca se instala
/// sola (`SUAllowsAutomaticUpdates` en falso saca esa opción de la ventana de Sparkle). Lo usan `Delegado` al arrancar
/// y el botón "Buscar ahora" de General (`PaginaGeneral`).
enum Actualizaciones {
    /// ¿Esta copia de Alero es una versión publicada (con lista de versiones y clave)?
    static var disponibles: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let lista = (info["SUFeedURL"] as? String) ?? "", clave = (info["SUPublicEDKey"] as? String) ?? ""
        return !lista.isEmpty && !clave.isEmpty && !EnsayoMemoria.pedido
    }

    private static var controlador: SPUStandardUpdaterController?
    private static let aviso = AvisoActualizacion()

    /// Prende la búsqueda diaria (cada cuánto lo dice el Info.plist de la versión publicada). La llama
    /// `Delegado.applicationDidFinishLaunching`, una sola vez.
    static func arrancar() {
        guard disponibles, controlador == nil else { return }
        controlador = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: aviso)
    }

    /// "Buscar ahora" de General: busca en el momento y muestra el resultado (también si ya está al día).
    static func buscar() {
        NSApp.activate(ignoringOtherApps: true)
        controlador?.checkForUpdates(nil)
    }
}

/// Alero vive en la barra de menú (sin ícono en el Dock): cuando Sparkle encuentra una versión nueva por su cuenta,
/// trae la app adelante para que la ventana no quede escondida detrás de las demás.
private final class AvisoActualizacion: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }
}
