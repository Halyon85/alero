import SwiftUI

// Alero › Limpiar el teclado: trabar el teclado y el trackpad para limpiarlos, y cuánto tarda en soltarse solo.
// La traba en sí está en `TrabaTeclado`; también se prende desde el menú de la barra.

struct PaginaTeclado: View {
    @ObservedObject private var ajustes = Ajustes.shared

    var body: some View {
        TituloPagina(titulo: T("Limpiar el teclado", "Clean the keyboard"),
                     subtitulo: T("Traba el teclado y el trackpad para que puedas limpiarlos sin escribir nada.",
                                  "Locks the keyboard and trackpad so you can clean them without typing anything."))
        Tarjeta {
            Fila(titulo: T("Trabar ahora", "Lock now"),
                 detalle: T("Para salir antes: Esc 5 veces o mantener apretado el botón de la pantalla.",
                            "To leave sooner: press Esc 5 times or hold the on-screen button.")) {
                BotonPrimario(texto: T("Trabar", "Lock")) { TrabaTeclado.shared.empezar() }
            }
            Fila(titulo: T("Se destraba sola después de", "Unlocks by itself after"), divisor: false) {
                Segmentos(valor: Binding(get: { TopeTraba(rawValue: ajustes.limpiezaTope) ?? .dos }, set: { ajustes.limpiezaTope = $0.rawValue }),
                          opciones: TopeTraba.allCases) { $0.nombre }
            }
        }
    }
}
