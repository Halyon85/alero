import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Las herramientas de Mantenimiento en el notch abierto: desinstalar apps (en Utilidades) y limpiar la Mac. Usan los mismos modelos que la ventana de Alero; todo lo que se borra va a la Papelera (se puede
// recuperar). Para revisar archivo por archivo, el botón "Detalle" abre la página de Alero.
// Los modelos del notch viven mientras Alero está abierta: así cerrar el notch no pierde una búsqueda (pesan poco: una
// lista de rutas).

enum ModelosNotch {
    static let desinstalador = ModeloDesinstalador()
    static let limpiador = ModeloLimpiador()
}

// MARK: - Limpiar la Mac

/// Buscar lo que sobra, ver cuánto ocupa cada tipo y mandar lo elegido a la Papelera.
struct EspacioLimpiar: View {
    @ObservedObject private var modelo = ModelosNotch.limpiador

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                TituloSeccionNotch(texto: T("LIMPIAR LA MAC", "CLEAN UP"))
                Text(resumen).font(.system(size: 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(detalle).font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if modelo.ocupado {
                        ProgressView().controlSize(.small)
                    } else if modelo.estado == .listo, !modelo.elegidos.isEmpty {
                        Button(T("Mandar a la Papelera", "Move to Trash")) { modelo.mandarElegidos() }.buttonStyle(BotonPastilla())
                    } else {
                        Button(modelo.estado == .inicio ? T("Buscar", "Scan") : T("Buscar de nuevo", "Scan again")) { modelo.buscar() }
                            .buttonStyle(BotonPastilla())
                    }
                    Button(T("Detalle", "Details")) { VentanaAlero.shared.mostrar(.limpiador) }.buttonStyle(BotonPastilla())
                }
            }
            .frame(width: 200, alignment: .topLeading)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            DesplazableNotch {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CategoriaLimpieza.allCases) { categoria in fila(categoria) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var resumen: String {
        switch modelo.estado {
        case .inicio: return T("Buscá lo que sobra", "Find what's left over")
        case .buscando: return T("Buscando…", "Scanning…")
        case .moviendo: return T("Moviendo…", "Moving…")
        case .listo:
            if let resultado = modelo.resultado, modelo.elegidos.isEmpty {
                return T("\(Papelera.texto(resultado.bytes)) liberados", "\(Papelera.texto(resultado.bytes)) freed")
            }
            return Papelera.texto(modelo.bytes(modelo.candidatos.filter { modelo.elegidos.contains($0.id) }))
        }
    }

    private var detalle: String {
        switch modelo.estado {
        case .inicio: return T("Cachés, registros viejos, Xcode, Homebrew, instaladores y capturas olvidadas.",
                               "Caches, old logs, Xcode, Homebrew, installers and forgotten screenshots.")
        case .buscando(let categoria): return categoria?.titulo ?? ""
        case .moviendo: return T("A la Papelera: se puede recuperar.", "To the Trash: you can get it back.")
        case .listo: return T("Elegido para la Papelera (se puede recuperar).", "Picked for the Trash (you can get it back).")
        }
    }

    private func fila(_ categoria: CategoriaLimpieza) -> some View {
        let lista = modelo.de(categoria)
        let elegida = !lista.isEmpty && lista.allSatisfy { modelo.elegidos.contains($0.id) }
        return Button { modelo.alternar(categoria) } label: {
            HStack(spacing: 8) {
                Image(systemName: elegida ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13)).foregroundStyle(elegida ? Tema.acento : Tema.textoNotchSuave)
                Text(categoria.titulo).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Text(lista.isEmpty ? "–" : Papelera.texto(modelo.bytes(lista)))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Tema.textoNotchSuave)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lista.isEmpty || modelo.ocupado)
    }
}
