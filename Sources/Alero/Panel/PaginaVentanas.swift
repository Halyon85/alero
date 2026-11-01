import AppKit
import SwiftUI

// Herramientas › Ventanas: la llave de "Acomodar ventanas" (`Mosaico`) y cómo se usa. Al prenderla, Alero apaga el
// acomodo propio de macOS 15 (`MosaicoDeMacOS`); si igual quedó prendido (se volvió a prender a mano), un aviso dice
// cómo apagarlo, con los nombres de Ajustes del Sistema › Escritorio y Dock › Ventanas tal cual.

struct PaginaVentanas: View {
    @ObservedObject private var ajustes = Ajustes.shared
    @State private var deMacOS = MosaicoDeMacOS.prendido
    private let reloj = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TituloPagina(titulo: T("Ventanas", "Windows"),
                     subtitulo: T("Acomodá hasta cuatro apps en la pantalla y cambiales el tamaño juntas, como en el iPad.",
                                  "Arrange up to four apps on screen and resize them together, like on the iPad."))
        AvisoAccesibilidad()
        Tarjeta(titulo: T("Acomodar ventanas", "Arrange windows")) {
            FilaLlave(titulo: T("Acomodar ventanas", "Arrange windows"),
                      detalle: T("Llevá una ventana contra un borde o una esquina de la pantalla y Alero la acomoda. Mientras está prendido, Alero apaga el acomodo propio de macOS y, al apagarlo, lo deja como estaba.",
                                 "Drag a window against an edge or a corner of the screen and Alero arranges it. While it's on, Alero turns off macOS's own tiling and puts it back as it was when you turn this off."),
                      divisor: false, valor: $ajustes.mosaico)
        }
        if ajustes.mosaico && deMacOS {
            AvisoTarjeta(tono: .info, titulo: T("macOS también acomoda ventanas", "macOS arranges windows too"),
                         detalle: T("Para que no se pisen, en Ajustes del Sistema › Escritorio y Dock › Ventanas apagá «Arrastrar ventanas al borde izquierdo o derecho de la pantalla para disponerlas en mosaico» y «Arrastrar ventanas a la barra de menús para llenar la pantalla».",
                                    "So they don't clash, in System Settings › Desktop & Dock › Windows turn off “Drag windows to left or right edge of screen to tile” and “Drag windows to menu bar to fill screen”.")) {
                BotonSecundario(texto: T("Abrir Escritorio y Dock", "Open Desktop & Dock")) { MosaicoDeMacOS.abrirAjustes() }
            }
        }
        Tarjeta(titulo: T("Cómo se usa", "How it works")) {
            paso(T("A un costado", "To a side"), T("La ventana ocupa la mitad de la pantalla.", "The window takes half the screen."),
                 icono: "rectangle.lefthalf.filled")
            paso(T("A una esquina", "To a corner"), T("Ocupa un cuarto: entran hasta cuatro apps.", "It takes a quarter: up to four apps fit."),
                 icono: "rectangle.split.2x2")
            paso(T("Arriba, contra la barra de menús", "Up against the menu bar"),
                 T("Ocupa toda la pantalla, sin pasar a pantalla completa.", "It fills the screen, without going full screen."),
                 icono: "rectangle.inset.filled")
            paso(T("El lugar que queda", "The spot that's left"),
                 T("Alero te muestra las otras apps abiertas: tocás una y va ahí.", "Alero shows your other open apps: click one and it goes there."),
                 icono: "square.grid.2x2")
            paso(T("La barra del medio", "The middle bar"),
                 T("Pasá el mouse por la unión entre dos ventanas y arrastrá la barra: cambian de tamaño juntas.",
                   "Hover over the seam between two windows and drag the bar: they resize together."),
                 icono: "arrow.left.and.right", divisor: false)
        }
        .onReceive(reloj) { _ in deMacOS = MosaicoDeMacOS.prendido }
    }

    private func paso(_ titulo: String, _ detalle: String, icono: String, divisor: Bool = true) -> some View {
        Fila(titulo: titulo, detalle: detalle, divisor: divisor) {
            Image(systemName: icono).font(.system(size: 18, weight: .regular)).foregroundStyle(Tema.acentoVentana).frame(width: 28)
        }
    }
}
