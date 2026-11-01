import Combine
import SwiftUI

// Alero › Sonido y brillo: el volumen por app (si el macOS lo permite) con su permiso, el brillo de los
// monitores, las teclas de brillo en la pantalla del puntero y la lista de pantallas con el método de cada una.

struct PaginaSonido: View {
    @ObservedObject private var ajustes = Ajustes.shared
    @ObservedObject private var monitores = Monitores.shared
    @State private var permisoAudio = PermisoAudio.estado
    private let reloj = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TituloPagina(titulo: T("Sonido y brillo", "Sound & brightness"),
                     subtitulo: T("El volumen de cada app y el brillo de cada pantalla, en el notch.",
                                  "Each app's volume and each display's brightness, in the notch."))
        if ajustes.brilloTeclasPuntero && ajustes.notchTeclas { AvisoAccesibilidad() }

        if Mezclador.disponible {
            Tarjeta(titulo: T("Volumen por app", "App volume")) {
                FilaLlave(titulo: T("Volumen por app", "App volume"),
                          detalle: T("En la columna de sonido del notch, un deslizador para cada app que suena. Las apps al 100 % no se tocan.",
                                     "In the notch's sound column, a slider for each app that's playing. Apps at 100% are left alone."),
                          valor: $ajustes.mezcladorActivo)
                if ajustes.mezcladorActivo {
                    FilaLlave(titulo: T("Recordar el volumen de cada app", "Remember each app's volume"),
                              detalle: T("La próxima vez que suene, vuelve al volumen que le dejaste.",
                                         "Next time it plays, it goes back to the volume you left it at."),
                              valor: $ajustes.mezcladorRecordar)
                    Fila(titulo: T("Grabación de audio del sistema", "System Audio Recording"),
                         detalle: T("Para bajar una app, Alero recibe su sonido y lo vuelve a mandar más bajo. No se graba nada.",
                                    "To lower an app, Alero receives its sound and plays it back quieter. Nothing is recorded."),
                         divisor: false) {
                        EstadoPermiso(concedido: permisoAudio == .concedido) {
                            if permisoAudio == .sinPedir {
                                PermisoAudio.pedir { _ in permisoAudio = PermisoAudio.estado }
                            } else {
                                PermisoAudio.abrirAjustes()
                            }
                        }
                    }
                }
            }
        }

        Tarjeta(titulo: T("Pantallas", "Displays")) {
            FilaLlave(titulo: T("Brillo de los monitores", "Display brightness"),
                      detalle: T("Un deslizador por pantalla en el notch. Los monitores comunes cambian su propio brillo (DDC); los que no lo aceptan se oscurecen por software.",
                                 "A slider per display in the notch. Regular monitors change their own brightness (DDC); the ones that don't support it are dimmed in software."),
                      valor: $ajustes.brilloMonitores)
            FilaLlave(titulo: T("Teclas de brillo en la pantalla del puntero", "Brightness keys on the pointer's display"),
                      detalle: ajustes.notchTeclas
                        ? T("Las teclas cambian la pantalla donde está el mouse, con el aviso arriba de esa pantalla.",
                            "The keys change the display the pointer is on, with the overlay at the top of that display.")
                        : T("Prendé \"Volumen y brillo\" en Ajustes › Notch para que Alero atienda las teclas.",
                            "Turn on \"Volume & brightness\" in Settings › Notch so Alero handles the keys."),
                      divisor: ajustes.brilloMonitores && !monitores.lista.isEmpty,
                      valor: $ajustes.brilloTeclasPuntero)
            if ajustes.brilloMonitores {
                ForEach(Array(monitores.lista.enumerated()), id: \.element.id) { i, monitor in
                    Fila(titulo: monitor.nombre, detalle: monitor.metodo.nombre, divisor: i < monitores.lista.count - 1) {
                        Text(monitor.nivel.map { "\(Int(($0 * 100).rounded())) %" } ?? "–")
                            .font(.system(size: 13).monospacedDigit()).foregroundStyle(Tema.apagado)
                    }
                }
            }
        }
        .onReceive(reloj) { _ in permisoAudio = PermisoAudio.estado }
    }
}
