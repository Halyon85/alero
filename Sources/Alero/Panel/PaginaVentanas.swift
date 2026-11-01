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
                 T("Aparecen todas tus apps abiertas y un buscador para abrir otra: tocás una y va ahí. Con la X o Esc, la ventana vuelve a como estaba.",
                   "All your open apps show up, plus a search to open another: click one and it goes there. With the X or Esc, the window goes back to how it was."),
                 icono: "square.grid.2x2")
            paso(T("Una app más", "One more app"),
                 T("Con la pantalla en dos mitades, llevá la tercera a una esquina: la de ese lado pasa al otro cuarto.",
                   "With the screen split in halves, drag the third one to a corner: the one on that side moves to the other quarter."),
                 icono: "rectangle.split.1x2")
            paso(T("La barra del medio", "The middle bar"),
                 T("Entre las ventanas queda una barra: arrastrala para agrandar una y achicar la otra; doble clic la centra. Si estirás una ventana desde su borde, las demás la siguen.",
                   "A bar sits between the windows: drag it to grow one and shrink the other; double-click centers it. If you stretch a window from its edge, the others follow."),
                 icono: "arrow.left.and.right")
            paso(T("Sacar una ventana", "Take a window out"),
                 T("Arrastrala afuera por su barra de arriba y vuelve a su tamaño de antes.", "Drag it out by its title bar and it goes back to its earlier size."),
                 icono: "arrow.uturn.backward")
            paso(T("Con dos monitores", "With two displays"),
                 T("Del lado donde la pantalla sigue en el otro monitor, quedate un momento cerca del borde.",
                   "On the side where the screen continues onto the other display, hold near the edge for a moment."),
                 icono: "display.2", divisor: false)
        }
        .onReceive(reloj) { _ in deMacOS = MosaicoDeMacOS.prendido }
    }

    private func paso(_ titulo: String, _ detalle: String, icono: String, divisor: Bool = true) -> some View {
        Fila(titulo: titulo, detalle: detalle, divisor: divisor) {
            Image(systemName: icono).font(.system(size: 18, weight: .regular)).foregroundStyle(Tema.acentoVentana).frame(width: 28)
        }
    }
}
