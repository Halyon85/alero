import SwiftUI

// Alero › Teleprompter: el guion, la velocidad, el tamaño de letra y si se esconde al compartir pantalla. "Empezar"
// lo abre en el notch de la MacBook (debajo de la cámara). También se abre desde el menú de la barra y con el botón
// del notch.

struct PaginaTeleprompter: View {
    @ObservedObject private var ajustes = Ajustes.shared
    @ObservedObject private var tele = Teleprompter.shared
    @Environment(\.dibujandoMuestra) private var dibujandoMuestra

    var body: some View {
        HStack(alignment: .top) {
            TituloPagina(titulo: T("Teleprompter", "Teleprompter"),
                         subtitulo: T("Tu guion justo debajo de la cámara, para mirar a la gente y no a tus notas.",
                                      "Your script right under the camera, so you look at people and not at your notes."))
            Spacer()
            BotonPrimario(texto: T("Empezar", "Start")) {
                ControladorNotch.shared.abrirPrompter()
                Teleprompter.shared.empezar()
            }
        }
        Tarjeta(titulo: T("Cómo se usa", "How it works")) {
            Fila(titulo: T("1. Escribí o pegá tu guion", "1. Write or paste your script"),
                 detalle: T("En el cuadro de abajo. Se guarda solo; con ⌘V pegás un texto que tengas copiado.",
                            "In the box below. It saves by itself; ⌘V pastes text you copied.")) { EmptyView() }
            Fila(titulo: T("2. Tocá Empezar", "2. Press Start"),
                 detalle: T("Aparece en el notch de la pantalla donde estás, justo debajo de la cámara. Cuenta 3, 2, 1 y avanza solo.",
                            "It shows up in the notch of the screen you're on, right under the camera. It counts 3, 2, 1 and scrolls by itself.")) { EmptyView() }
            Fila(titulo: T("3. Leé mirando a la cámara", "3. Read while looking at the camera"),
                 detalle: T("Pasá el mouse por encima para pausar, ir más rápido o más lento, cambiar la letra o cerrarlo. La rueda del mouse lo mueve a mano.",
                            "Hover over it to pause, speed up or slow down, change the text size or close it. The mouse wheel moves it by hand."),
                 divisor: false) { EmptyView() }
        }
        Tarjeta(titulo: T("Guion", "Script")) {
            Group {
                // El dibujante de `--capturas` no muestra un editor de texto: va el texto tal cual.
                if dibujandoMuestra {
                    Text(tele.texto).font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                } else {
                    TextEditor(text: $tele.texto)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                }
            }
            .padding(12)
        }
        Tarjeta(titulo: T("Lectura", "Reading")) {
            Fila(titulo: T("Velocidad", "Speed"), detalle: T("\(Int(ajustes.prompterVelocidad)) puntos por segundo", "\(Int(ajustes.prompterVelocidad)) points per second")) {
                Slider(value: Binding(get: { ajustes.prompterVelocidad }, set: { tele.cambiarVelocidad($0) }), in: 10...150, step: 5)
                    .frame(width: 220).tint(Tema.acentoVentana)
            }
            Fila(titulo: T("Tamaño de letra", "Text size"), detalle: "\(Int(ajustes.prompterLetra)) pt") {
                Slider(value: $ajustes.prompterLetra, in: 14...34, step: 1).frame(width: 220).tint(Tema.acentoVentana)
            }
            FilaLlave(titulo: T("Esconder al compartir pantalla", "Hide when sharing the screen"),
                      detalle: T("Mientras está abierto, el notch no sale en Zoom, Meet, Teams ni en grabaciones: solo lo ves vos.",
                                 "While it's open, the notch doesn't show up in Zoom, Meet, Teams or recordings: only you see it."),
                      divisor: false, valor: $ajustes.prompterOcultar)
        }
    }
}
