import Combine
import SwiftUI

// Ajustes › Mouse y teclado: la rueda (suave e invertida), el Dock y el botón verde, los botones del mouse y cortar y
// pegar en Finder. Cada función tiene su llave; apagada no escucha nada. El trackpad no se toca.

struct PaginaMouse: View {
    @ObservedObject private var ajustes = Ajustes.shared

    var body: some View {
        TituloPagina(titulo: T("Mouse y teclado", "Mouse & keyboard"),
                     subtitulo: T("La rueda, los botones, el Dock, el botón verde y Finder. El trackpad queda como está.",
                                  "The wheel, the buttons, the Dock, the green button and Finder. The trackpad stays as it is."))
        AvisoAccesibilidad()
        rueda
        dockYVentanas
        botones
        finder
    }

    private var rueda: some View {
        Tarjeta(titulo: T("Rueda", "Wheel")) {
            FilaLlave(titulo: T("Desplazamiento suave", "Smooth scrolling"),
                      detalle: T("La rueda planea en vez de saltar de a líneas.", "The wheel glides instead of jumping line by line."),
                      valor: $ajustes.scrollSuave)
            if ajustes.scrollSuave {
                Fila(titulo: T("Respuesta", "Response"),
                     detalle: T("A la izquierda planea más largo; a la derecha sigue a la rueda al instante.",
                                "Left glides longer; right follows the wheel instantly.")) {
                    Slider(value: $ajustes.scrollRespuesta, in: 0...100).frame(width: 200).tint(Tema.acentoVentana)
                }
                Fila(titulo: T("Distancia por clic", "Distance per notch"),
                     detalle: T("Cuánto avanza cada clic de la rueda.", "How far each wheel notch moves.")) {
                    Slider(value: $ajustes.scrollPaso, in: 20...100, step: 5).frame(width: 200).tint(Tema.acentoVentana)
                }
            }
            FilaLlave(titulo: T("Invertir el sentido", "Reverse direction"),
                      detalle: T("Solo el mouse: el trackpad sigue con el sentido natural de macOS.",
                                 "Mouse only: the trackpad keeps macOS's natural direction."),
                      divisor: false, valor: $ajustes.scrollInvertir)
        }
    }

    private var dockYVentanas: some View {
        Tarjeta(titulo: T("Dock y ventanas", "Dock & windows")) {
            FilaLlave(titulo: T("Clic en el Dock para minimizar", "Click in the Dock to minimize"),
                      detalle: T("Si la app ya está al frente, un clic en su ícono la minimiza y otro la vuelve a mostrar. Con el Dock que se oculta solo no actúa.",
                                 "If the app is already in front, clicking its icon minimizes it and another click brings it back. Not with an auto-hiding Dock."),
                      valor: $ajustes.dockMinimizar)
            if ajustes.dockMinimizar {
                Fila(titulo: T("Al hacer clic", "On click"),
                     detalle: T("Ocultar hace desaparecer la app entera, como ⌘H.", "Hide makes the whole app disappear, like ⌘H.")) {
                    Segmentos(valor: $ajustes.dockModo, opciones: ModoDock.allCases) { $0.nombre }
                }
                FilaLlave(titulo: T("Con varias ventanas, pasar a la siguiente", "With several windows, go to the next one"),
                          detalle: T("Si la app tiene más de una ventana abierta (por ejemplo, varias de Chrome), cada clic trae la siguiente al frente. Con una sola, minimiza.",
                                     "If the app has more than one window open (say, several Chrome windows), each click brings the next one to the front. With just one, it minimizes."),
                          valor: $ajustes.dockAlternarVentanas)
            }
            FilaLlave(titulo: T("Botón verde para maximizar", "Green button to maximize"),
                      detalle: T("Agranda la ventana a toda la pantalla sin pasar a pantalla completa; otro clic la vuelve a su tamaño. Con ⌥ hace lo de siempre.",
                                 "Grows the window to fill the screen without going full screen; another click restores it. With ⌥ it does the usual."),
                      divisor: false, valor: $ajustes.botonVerde)
        }
    }

    private var botones: some View {
        Tarjeta(titulo: T("Botones del mouse", "Mouse buttons")) {
            FilaLlave(titulo: T("Usar los botones del mouse", "Use the mouse buttons"),
                      detalle: T("El botón de la rueda y los laterales hacen lo que elijas. El izquierdo y el derecho no se tocan.",
                                 "The wheel button and the side buttons do what you choose. Left and right clicks are untouched."),
                      divisor: ajustes.botonesMouse, valor: $ajustes.botonesMouse)
            if ajustes.botonesMouse {
                ForEach(BotonMouse.allCases) { boton in
                    FilaBoton(boton: boton, divisor: boton != BotonMouse.allCases.last)
                }
            }
        }
    }

    private var finder: some View {
        Tarjeta(titulo: "Finder") {
            FilaLlave(titulo: T("Cortar y pegar archivos", "Cut and paste files"),
                      detalle: T("⌘X marca los archivos elegidos y ⌘V los mueve a la carpeta abierta. Mientras escribís un nombre, son los de siempre.",
                                 "⌘X marks the selected files and ⌘V moves them to the open folder. While you type a name, they work as usual."),
                      divisor: ajustes.finderCortar, valor: $ajustes.finderCortar)
            if ajustes.finderCortar { FilaPermisoFinder(divisor: false) }
        }
    }
}

/// Un botón del mouse con su acción y, si es "Atajo de teclado…", el grabador al lado.
private struct FilaBoton: View {
    let boton: BotonMouse
    let divisor: Bool
    @ObservedObject private var ajustes = Ajustes.shared

    var body: some View {
        let config = ajustes.config(boton)
        Fila(titulo: boton.nombre, detalle: boton.detalle, divisor: divisor) {
            if config.accion == .atajo {
                GrabadorAtajo(atajo: Binding(get: { ajustes.config(boton).atajo }, set: { nuevo in cambiar { $0.atajo = nuevo } }))
            }
            Picker("", selection: Binding(get: { config.accion }, set: { nueva in cambiar { $0.accion = nueva } })) {
                ForEach(AccionBoton.allCases) { accion in Text(accion.nombre).tag(accion) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private func cambiar(_ cambio: (inout ConfigBoton) -> Void) {
        var config = ajustes.config(boton)
        cambio(&config)
        ajustes.cambiar(boton, a: config)
    }
}

/// Estado del permiso para controlar Finder (Automatización). Se mira fuera del hilo principal cada 2 s mientras
/// se ve la fila: macOS no avisa cuando la persona lo cambia en Ajustes del Sistema.
struct FilaPermisoFinder: View {
    var divisor = true
    @State private var estado: Permisos.EstadoAutomatizacion = .sinPedir
    private let reloj = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Fila(titulo: T("Controlar Finder", "Control Finder"),
             detalle: estado == .negado ? T("Lo negaste: prendé Alero › Finder en Ajustes del Sistema › Automatización.",
                                            "Denied: turn on Alero › Finder in System Settings › Automation.")
                                        : T("Para cortar y pegar: Alero le pregunta a Finder qué elegiste y dónde estás.",
                                            "For cut and paste: Alero asks Finder what you selected and where you are."),
             divisor: divisor) {
            EstadoPermiso(concedido: estado == .concedido, accion: pedir)
        }
        .onAppear(perform: revisar)
        .onReceive(reloj) { _ in revisar() }
    }

    private func revisar() {
        DispatchQueue.global(qos: .utility).async {
            let actual = Permisos.automatizacionFinder(preguntar: false)
            DispatchQueue.main.async { estado = actual }
        }
    }

    private func pedir() {
        guard estado != .negado else { Permisos.abrirAjustesDeAutomatizacion(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let actual = Permisos.automatizacionFinder(preguntar: true)
            DispatchQueue.main.async { estado = actual }
        }
    }
}
