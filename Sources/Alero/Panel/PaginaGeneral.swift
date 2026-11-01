import Combine
import ServiceManagement
import SwiftUI

// Alero › General: abrir al iniciar sesión, mostrar o esconder el ícono de la barra de menú, estado de los permisos
// (Accesibilidad, Grabación de pantalla, Finder y Calendario), versión y, en las versiones publicadas, buscar
// actualizaciones (`Actualizaciones`).

struct PaginaGeneral: View {
    @ObservedObject private var calendario = Calendario.shared
    @ObservedObject private var ajustes = Ajustes.shared
    @State private var alIniciar = SMAppService.mainApp.status == .enabled
    @State private var errorInicio: String?
    @State private var accesibilidad = Permisos.accesibilidad
    @State private var grabacion = Permisos.grabacionPantalla
    private let reloj = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TituloPagina(titulo: T("General", "General"),
                     subtitulo: T("Alero vive en la barra de menú y en el notch.", "Alero lives in the menu bar and the notch."))
        Tarjeta(titulo: T("Arranque", "Startup")) {
            Fila(titulo: T("Abrir al iniciar sesión", "Open at login"),
                 detalle: errorInicio ?? T("Alero arranca sola cuando prendés la Mac.", "Alero starts when you log in."), divisor: false) {
                Toggle("", isOn: Binding(get: { alIniciar }, set: cambiarInicio)).toggleStyle(.switch).labelsHidden().tint(Tema.acentoVentana)
            }
        }
        Tarjeta(titulo: T("Barra de menú", "Menu bar")) {
            FilaLlave(titulo: T("Mostrar el ícono en la barra de menú", "Show the icon in the menu bar"),
                      detalle: T("Escondido, Alero sigue andando: la abrís otra vez desde Aplicaciones o con el atajo \"Ícono de la barra\" del notch.",
                                 "When hidden, Alero keeps running: open it again from Applications or with the notch's \"Menu bar icon\" shortcut."),
                      divisor: false, valor: $ajustes.iconoBarra)
        }
        TarjetaClaude()
        Tarjeta(titulo: T("Permisos", "Permissions")) {
            Fila(titulo: T("Accesibilidad", "Accessibility"),
                 detalle: T("Para el mouse, el teclado y las teclas de volumen y brillo.", "For the mouse, the keyboard and the volume and brightness keys.")) {
                EstadoPermiso(concedido: accesibilidad) {
                    Permisos.pedirAccesibilidad()
                    Permisos.abrirAjustesDeAccesibilidad()
                }
            }
            Fila(titulo: T("Grabación de pantalla", "Screen Recording"), detalle: T("Para las capturas de pantalla.", "For screenshots.")) {
                EstadoPermiso(concedido: grabacion) { PermisoGrabacion.pedir() }
            }
            if ajustes.finderCortar { FilaPermisoFinder() }
            Fila(titulo: T("Calendario", "Calendar"),
                 detalle: T("Para mostrar tus reuniones en el notch.", "To show your meetings in the notch."), divisor: false) {
                EstadoPermiso(concedido: calendario.permiso == .concedido) {
                    calendario.permiso == .sinPedir ? calendario.pedirPermiso() : Calendario.abrirAjustesDePrivacidad()
                }
            }
        }
        Tarjeta(titulo: T("Acerca de", "About")) {
            Fila(titulo: "Alero \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",
                 detalle: T("Código abierto, licencia Apache 2.0.", "Open source, Apache 2.0 license."), divisor: Actualizaciones.disponibles) {
                EmptyView()
            }
            if Actualizaciones.disponibles {
                Fila(titulo: T("Actualizaciones", "Updates"),
                     detalle: T("Alero busca una versión nueva una vez por día y te pregunta antes de instalarla.",
                                "Alero looks for a new version once a day and asks you before installing it."), divisor: false) {
                    BotonSecundario(texto: T("Buscar ahora", "Check Now"), icono: "arrow.triangle.2.circlepath") { Actualizaciones.buscar() }
                }
            }
        }
        .onReceive(reloj) { _ in
            accesibilidad = Permisos.accesibilidad
            grabacion = Permisos.grabacionPantalla
            calendario.revisarPermiso()
        }
    }

    private func cambiarInicio(_ prender: Bool) {
        do {
            if prender { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            errorInicio = nil
        } catch {
            errorInicio = T("No se pudo cambiar: \(error.localizedDescription)", "Couldn't change it: \(error.localizedDescription)")
        }
        alIniciar = SMAppService.mainApp.status == .enabled
    }
}

/// Conectar el cupo de Claude Code al notch (espacio Agentes). Ver `CupoClaude`.
private struct TarjetaClaude: View {
    @State private var conectado = CupoClaude.conectado
    @State private var error: String?

    var body: some View {
        Tarjeta(titulo: "Claude Code") {
            Fila(titulo: T("Cupo en el notch", "Quota in the notch"),
                 detalle: error ?? (conectado
                    ? T("Conectado: el espacio Agentes muestra el cupo de 5 h y de la semana. La barra de estado que tenías sigue andando.",
                        "Connected: the Agents space shows the 5-hour and weekly quota. Your previous status line keeps working.")
                    : T("Pone una barra de estado chiquita de Alero en Claude Code (guarda una copia de tu configuración). Sin claves ni internet.",
                        "Adds a tiny Alero status line to Claude Code (keeps a copy of your settings). No keys, no internet.")),
                 divisor: false) {
                BotonSecundario(texto: conectado ? T("Desconectar", "Disconnect") : T("Conectar", "Connect")) {
                    error = conectado ? CupoClaude.desconectar() : CupoClaude.conectar()
                    conectado = CupoClaude.conectado
                }
            }
        }
    }
}
