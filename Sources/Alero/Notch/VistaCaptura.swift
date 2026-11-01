import AppKit
import SwiftUI

// El aviso de captura lista: la miniatura (se arrastra afuera como copia del archivo; un clic abre el editor), dónde
// quedó y tres atajos: editar, fijar en pantalla y sumar al estante. Se va solo a los pocos segundos, salvo que el
// mouse esté encima.

struct VistaCaptura: View {
    @ObservedObject var estado: EstadoNotch
    /// En `--capturas` va en false: el dibujante de imágenes no sabe dibujar el origen de arrastre de AppKit.
    var arrastrable = true
    @ObservedObject private var estante = Estante.shared
    @State private var encima = false

    var body: some View {
        if let captura = estado.captura {
            HStack(spacing: 14) {
                miniatura(captura)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Captura lista", "Screenshot ready")).font(.system(size: 13, weight: .semibold))
                        Text(detalle(captura)).font(.system(size: 11)).foregroundStyle(captura.respaldo ? Tema.acento : Tema.textoNotchSuave)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 6) {
                        PastillaNotch(icono: "pencil", texto: T("Editar", "Edit"), activa: false,
                                      etiqueta: T("Abrir en el editor", "Open in the editor")) { editar(captura) }
                        PastillaNotch(icono: "pin.fill", texto: T("Fijar", "Pin"), activa: false,
                                      etiqueta: T("Fijar en pantalla", "Pin to screen")) { fijar(captura) }
                        let enEstante = estante.items.contains { estante.url(de: $0)?.standardizedFileURL == captura.url.standardizedFileURL }
                        PastillaNotch(icono: enEstante ? "checkmark" : "tray.and.arrow.down.fill", texto: T("Estante", "Shelf"),
                                      activa: enEstante, etiqueta: T("Sumar al estante", "Add to the shelf")) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { _ = estante.agregar([captura.url]) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, estado.medidas.alto + 8)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .foregroundStyle(Tema.textoNotch)
        }
    }

    private func miniatura(_ captura: CapturaLista) -> some View {
        Image(nsImage: captura.miniatura)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 118, maxHeight: 70)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(encima ? 0.5 : 0.16), lineWidth: 1))
            .scaleEffect(encima ? 1.04 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: encima)
            .overlay {
                if arrastrable { ArrastreArchivo(url: captura.url, icono: captura.miniatura, lado: 120) { editar(captura) } }
            }
            .onHover { encima = $0 }
            .frame(width: 118, height: 70)
            .help(T("Clic para editar · arrastrala para llevarla a otra app", "Click to edit · drag it into another app"))
            .accessibilityLabel(T("Miniatura de la captura", "Screenshot thumbnail"))
    }

    private func detalle(_ captura: CapturaLista) -> String {
        if captura.respaldo {
            return T("Guardada en el Escritorio: la carpeta elegida falló", "Saved to the Desktop: the chosen folder failed")
        }
        return captura.copiada ? T("Copiada y guardada en \(captura.carpeta)", "Copied and saved to \(captura.carpeta)")
                               : T("Guardada en \(captura.carpeta)", "Saved to \(captura.carpeta)")
    }

    private func editar(_ captura: CapturaLista) {
        estado.cerrar()
        VentanaEditor.abrir(captura.url)
    }

    private func fijar(_ captura: CapturaLista) {
        estado.cerrar()
        guard let leida = ImagenCaptura.leer(captura.url) else { NSSound.beep(); return }
        VentanaFijada.fijar(leida.imagen, escala: leida.escala)
    }
}
