import AppKit
import Combine
import SwiftUI

// Ajustes › Capturas: los atajos de cada modo, dónde se guardan, si se copian y suenan, el formato y cómo se elige
// (pantalla congelada y lupa). Arriba, el aviso si falta el permiso de Grabación de pantalla.

struct PaginaCapturas: View {
    @ObservedObject private var ajustes = Ajustes.shared
    @ObservedObject private var capturador = Capturador.shared

    var body: some View {
        TituloPagina(titulo: T("Capturas", "Screenshots"),
                     subtitulo: T("De un área, una ventana o la pantalla entera, con un atajo, el menú o el notch.",
                                  "Of an area, a window or the whole screen, with a shortcut, the menu or the notch."))
        AvisoGrabacion()
        atajos
        alCapturar
        alElegir
    }

    private var atajos: some View {
        Tarjeta(titulo: T("Atajos de teclado", "Keyboard shortcuts")) {
            ForEach(ModoCaptura.allCases) { modo in
                Fila(titulo: modo.accion, detalle: detalle(modo), divisor: modo != .pantalla) {
                    GrabadorAtajo(atajo: Binding(get: { ajustes.atajoCaptura(modo) }, set: { ajustes.cambiarAtajoCaptura(modo, a: $0) }))
                }
            }
        }
    }

    private func detalle(_ modo: ModoCaptura) -> String {
        if capturador.conflictos.contains(modo) {
            return T("Otra app ya usa esta combinación: grabá otra.", "Another app already uses this shortcut: record a different one.")
        }
        switch modo {
        case .area: return T("Arrastrá para elegir. Espacio pasa a ventana. ⌫ borra el atajo.", "Drag to select. Space switches to window. ⌫ clears it.")
        case .ventana: return T("Clic en una ventana: sale con su sombra (con ⌥, sin).", "Click a window: it comes with its shadow (⌥ for none).")
        case .pantalla: return T("Clic en la pantalla que quieras.", "Click the screen you want.")
        }
    }

    private var alCapturar: some View {
        Tarjeta(titulo: T("Al capturar", "After capturing")) {
            Fila(titulo: T("Carpeta", "Folder"), detalle: nombreCarpeta) {
                BotonSecundario(texto: T("Abrir", "Open"), icono: "folder") { Capturador.shared.abrirCarpeta() }
                BotonSecundario(texto: T("Elegir…", "Choose…")) { elegirCarpeta() }
                if !ajustes.capturaCarpeta.isEmpty {
                    BotonSecundario(texto: T("Escritorio", "Desktop")) { ajustes.capturaCarpeta = "" }
                }
            }
            FilaLlave(titulo: T("Copiar al portapapeles", "Copy to clipboard"),
                      detalle: T("Además de guardarla, para pegarla al toque con ⌘V.", "Besides saving it, so you can paste it right away with ⌘V."),
                      valor: $ajustes.capturaCopiar)
            FilaLlave(titulo: T("Sonido", "Sound"), detalle: T("El de las capturas de macOS.", "The macOS screenshot sound."),
                      valor: $ajustes.capturaSonido)
            Fila(titulo: T("Formato", "Format"),
                 detalle: T("PNG queda nítido; JPG pesa menos (para fotos).", "PNG stays sharp; JPG is smaller (for photos)."), divisor: false) {
                Segmentos(valor: $ajustes.capturaFormato, opciones: FormatoCaptura.allCases) { $0.nombre }
            }
        }
    }

    private var alElegir: some View {
        Tarjeta(titulo: T("Al elegir", "While selecting")) {
            FilaLlave(titulo: T("Congelar la pantalla", "Freeze the screen"),
                      detalle: T("Elegís sobre una foto quieta: lo que se mueve (un video, un menú) no se escapa.",
                                 "You select over a still image: moving things (a video, a menu) don't get away."),
                      valor: $ajustes.capturaCongelar)
            FilaLlave(titulo: T("Lupa", "Magnifier"),
                      detalle: T("Muestra los píxeles de cerca al elegir un área (con la pantalla congelada).",
                                 "Shows the pixels up close while selecting an area (with the screen frozen)."),
                      divisor: false, valor: $ajustes.capturaLupa)
        }
    }

    private var nombreCarpeta: String {
        if ajustes.capturaCarpeta.isEmpty { return T("El Escritorio", "The Desktop") }
        return (ajustes.capturaCarpeta as NSString).abbreviatingWithTildeInPath
    }

    private func elegirCarpeta() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = T("Elegir", "Choose")
        panel.message = T("Dónde se guardan las capturas", "Where screenshots are saved")
        panel.directoryURL = Capturador.shared.carpeta
        if panel.runModal() == .OK, let url = panel.url { ajustes.capturaCarpeta = url.path }
    }
}

/// Aviso arriba de la página cuando falta Grabación de pantalla. macOS no avisa cuando se concede: se mira cada 2 s
/// mientras se ve la página (mirar no muestra carteles).
struct AvisoGrabacion: View {
    @State private var concedido = Permisos.grabacionPantalla
    private let reloj = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        if !concedido {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 16)).foregroundStyle(Tema.acentoVentana)
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Falta el permiso de Grabación de pantalla", "Screen Recording permission needed")).font(.titulo(14))
                    Text(T("Sin él no se puede capturar. Si ya lo diste y sigue sin andar, sacá Alero de la lista y volvé a sumarla.",
                           "Without it nothing can be captured. If you already allowed it and it still fails, remove Alero from the list and add it again."))
                        .font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                BotonPrimario(texto: T("Dar permiso", "Allow")) { PermisoGrabacion.pedir() }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
            .onReceive(reloj) { _ in concedido = Permisos.grabacionPantalla }
        }
    }
}

/// Pedir Grabación de pantalla desde Ajustes: el cartel de macOS y, además, Ajustes del Sistema en el lugar justo
/// (el cartel sale una sola vez en la vida de la app).
enum PermisoGrabacion {
    static func pedir() {
        UserDefaults.standard.set(true, forKey: "captura.pidioPermiso")
        Permisos.pedirGrabacionPantalla()
        Permisos.abrirAjustesDeGrabacion()
    }
}
