import AppKit
import Combine
import SwiftUI

// La ventana de Alero: una sola, con todo adentro (ajustes del notch, del mouse, capturas, café, mantenimiento y
// general), agrupado por categoría en la barra lateral. Misma estructura que Relevo y Dixity: barra lateral flotante
// con el logo, una página por sección y las opciones en tarjetas. Se abre desde el menú de la barra, con ⌘, o al
// abrir Alero otra vez. Sigue el modo claro u oscuro de la Mac. Al cerrarla se suelta todo (listas, búsquedas en
// curso, relojes de las páginas); una operación de Homebrew que ya arrancó termina igual.

/// Las categorías de la barra lateral, en orden. Cada sección dice en cuál va.
enum GrupoSeccion: Hashable {
    case notch, herramientas, mantenimiento, alero

    /// El rótulo que se ve arriba del grupo (nil: sin rótulo).
    var titulo: String? {
        switch self {
        case .notch: return T("Notch", "Notch")
        case .herramientas: return T("Herramientas", "Tools")
        case .mantenimiento: return T("Mantenimiento", "Maintenance")
        case .alero: return nil
        }
    }
}

enum SeccionAlero: String, SeccionLateral {
    case notch, notchAbierto, sonido
    case mouse, capturas, teleprompter, cafe
    case limpiador, desinstalador, homebrew, teclado
    case general
    var id: String { rawValue }

    var grupo: GrupoSeccion {
        switch self {
        case .notch, .notchAbierto, .sonido: return .notch
        case .mouse, .capturas, .teleprompter, .cafe: return .herramientas
        case .limpiador, .desinstalador, .homebrew, .teclado: return .mantenimiento
        case .general: return .alero
        }
    }

    var titulo: String {
        switch self {
        case .notch: return T("Notch", "Notch")
        case .notchAbierto: return T("Notch abierto", "Open notch")
        case .sonido: return T("Sonido y brillo", "Sound & brightness")
        case .mouse: return T("Mouse y teclado", "Mouse & keyboard")
        case .capturas: return T("Capturas", "Screenshots")
        case .teleprompter: return T("Teleprompter", "Teleprompter")
        case .cafe: return T("Café", "Coffee")
        case .limpiador: return T("Limpiar la Mac", "Clean up")
        case .desinstalador: return T("Desinstalar apps", "Uninstall apps")
        case .homebrew: return "Homebrew"
        case .teclado: return T("Limpiar el teclado", "Clean the keyboard")
        case .general: return T("General", "General")
        }
    }

    var icono: String {
        switch self {
        case .notch: return "macbook"
        case .notchAbierto: return "rectangle.inset.filled.and.person.filled"
        case .sonido: return "speaker.wave.2"
        case .mouse: return "computermouse"
        case .capturas: return "camera.viewfinder"
        case .teleprompter: return "text.alignleft"
        case .cafe: return "cup.and.saucer"
        case .limpiador: return "sparkles"
        case .desinstalador: return "trash"
        case .homebrew: return "mug"
        case .teclado: return "keyboard"
        case .general: return "gearshape"
        }
    }
}

/// Qué página se ve. Aparte de la vista para poder cambiarla desde el menú con la ventana ya abierta.
final class NavegacionAlero: ObservableObject {
    @Published var seccion: SeccionAlero
    init(_ seccion: SeccionAlero) { self.seccion = seccion }
}

final class VentanaAlero: NSObject, NSWindowDelegate {
    static let shared = VentanaAlero()
    private var ventana: NSWindow?
    private var navegacion: NavegacionAlero?

    /// Sin sección, con la ventana ya abierta, deja la página que se esté viendo (la persona puede estar en otra).
    func mostrar(_ seccion: SeccionAlero? = nil) {
        if let navegacion {
            if let seccion { navegacion.seccion = seccion }
        } else {
            let navegacion = NavegacionAlero(seccion ?? .notch)
            let nueva = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 740),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
            nueva.titlebarAppearsTransparent = true
            nueva.titleVisibility = .hidden
            nueva.isReleasedWhenClosed = false
            // Sin la animación de AppKit al abrir: en macOS 27 cada ventana que la usa queda viva del lado de
            // WindowServer después de cerrarse, con su imagen (medido el 01/11/2026: de 2 a 23 MB por apertura, según
            // la ventana, que no vuelven nunca). Vale igual para el editor, las fijadas y el notch.
            nueva.animationBehavior = .none
            // El alto mínimo deja entrar la barra lateral entera (12 secciones en 4 grupos).
            nueva.minSize = NSSize(width: 780, height: 690)
            nueva.title = "Alero"
            nueva.delegate = self
            nueva.contentView = NSHostingView(rootView: PanelAlero(navegacion: navegacion))
            nueva.center()
            ventana = nueva
            self.navegacion = navegacion
        }
        NSApp.activate(ignoringOtherApps: true)
        ventana?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ aviso: Notification) {
        // Soltar la vista apaga los relojes de las páginas (revisan permisos cada 2 s), suelta los modelos de
        // Mantenimiento (y cancela lo que estén buscando) y libera las pantallas: antes, cerrada, seguía viva y
        // despertando a la app (medido el 01/11/2026: ~20 MB que no volvían).
        ventana?.contentView = nil
        ventana?.delegate = nil
        ventana = nil
        navegacion = nil
    }
}

struct PanelAlero: View {
    @ObservedObject var navegacion: NavegacionAlero
    /// En `--capturas` va en false: el dibujante de imágenes no muestra lo que está dentro de un ScrollView.
    var desplazable = true
    // Los de Mantenimiento viven lo que la ventana: cambiar de página no pierde una búsqueda ni la lista.
    @StateObject private var limpiador: ModeloLimpiador
    @StateObject private var desinstalador: ModeloDesinstalador
    @StateObject private var homebrew: ModeloHomebrew

    init(navegacion: NavegacionAlero, desplazable: Bool = true, limpiador: ModeloLimpiador = ModeloLimpiador(),
         desinstalador: ModeloDesinstalador = ModeloDesinstalador(), homebrew: ModeloHomebrew = ModeloHomebrew()) {
        self.navegacion = navegacion
        self.desplazable = desplazable
        _limpiador = StateObject(wrappedValue: limpiador)
        _desinstalador = StateObject(wrappedValue: desinstalador)
        _homebrew = StateObject(wrappedValue: homebrew)
    }

    var body: some View {
        HStack(spacing: 0) {
            BarraLateral(actual: navegacion.seccion) { navegacion.seccion = $0 }.padding(8)
            Group {
                if desplazable { ScrollView { contenido } } else { contenido.frame(maxHeight: .infinity, alignment: .top) }
            }
            .padding(.top, 8)
            .id(navegacion.seccion)
            .transition(.opacity)
        }
        .background(Tema.fondo)
        .foregroundStyle(Tema.texto)
        .focusEffectDisabled()
        .environment(\.dibujandoMuestra, !desplazable)
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch navegacion.seccion {
            case .notch: PaginaNotch()
            case .notchAbierto: PaginaNotchAbierto()
            case .sonido: PaginaSonido()
            case .mouse: PaginaMouse()
            case .capturas: PaginaCapturas()
            case .teleprompter: PaginaTeleprompter()
            case .cafe: PaginaCafe()
            case .limpiador: PaginaLimpiador(modelo: limpiador)
            case .desinstalador: PaginaDesinstalador(modelo: desinstalador)
            case .homebrew: PaginaHomebrew(modelo: homebrew)
            case .teclado: PaginaTeclado()
            case .general: PaginaGeneral()
            }
        }
        .frame(maxWidth: Tema.anchoPagina, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Aviso arriba de una página cuando falta Accesibilidad para lo que se muestra ahí.
struct AvisoAccesibilidad: View {
    @State private var concedido = Permisos.accesibilidad
    private let reloj = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        if !concedido {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.system(size: 16)).foregroundStyle(Tema.acentoVentana)
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Falta el permiso de Accesibilidad", "Accessibility permission needed")).font(.titulo(14))
                    Text(T("Sin él no andan el mouse, el teclado ni los carteles de volumen y brillo. Lo demás sí.",
                           "Without it the mouse, keyboard and the volume and brightness overlays won't work. Everything else will."))
                        .font(.system(size: 12)).foregroundStyle(Tema.apagado)
                }
                Spacer()
                BotonPrimario(texto: T("Dar permiso", "Allow")) {
                    Permisos.pedirAccesibilidad()
                    Permisos.abrirAjustesDeAccesibilidad()
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
            .onReceive(reloj) { _ in concedido = Permisos.accesibilidad }
        }
    }
}
