import SwiftUI

// La barra lateral de la ventana de Alero: logo arriba, las secciones agrupadas por categoría (con su rótulo) y el
// pie de Halyon Team abajo. Es la misma de Relevo y Dixity, con filas un poco más bajas para que entren las 13.

/// Una sección de una ventana con barra lateral. Las secciones seguidas con el mismo `grupo` van juntas.
protocol SeccionLateral: Hashable, Identifiable, CaseIterable where AllCases: RandomAccessCollection {
    var titulo: String { get }
    var icono: String { get }
    var grupo: GrupoSeccion { get }
}

struct BarraLateral<S: SeccionLateral>: View {
    let actual: S
    let elegir: (S) -> Void
    @State private var sobre: S?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Logo(tam: 26)
                Text("Alero").font(.titulo(15, .semibold)).foregroundStyle(Tema.titulo)
            }
            .padding(12)
            .frame(height: 44)
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(grupos, id: \.grupo) { bloque in
                    VStack(alignment: .leading, spacing: 2) {
                        if let titulo = bloque.grupo.titulo {
                            Text(titulo.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Tema.apagado)
                                .padding(.leading, 8)
                                .padding(.bottom, 4)
                        }
                        ForEach(bloque.secciones) { fila($0) }
                    }
                }
            }
            Spacer()
            PieHalyon()
        }
        .padding(.top, 8)
        .padding([.horizontal, .bottom], 12)
        .frame(width: Tema.anchoBarra)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tema.tarjeta.opacity(0.8)))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }

    /// Las secciones en bloques por grupo, en el orden en que están declaradas.
    private var grupos: [(grupo: GrupoSeccion, secciones: [S])] {
        var bloques: [(grupo: GrupoSeccion, secciones: [S])] = []
        for seccion in S.allCases {
            if bloques.last?.grupo == seccion.grupo {
                bloques[bloques.count - 1].secciones.append(seccion)
            } else {
                bloques.append((seccion.grupo, [seccion]))
            }
        }
        return bloques
    }

    private func fila(_ p: S) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { elegir(p) } } label: {
            HStack(spacing: 8) {
                Image(systemName: p.icono)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Tema.rellenoSuave))
                    .foregroundStyle(Tema.titulo)
                Text(p.titulo).font(.titulo(13.5))
                    .foregroundStyle(actual == p ? Tema.titulo : Tema.subtitulo)
                Spacer()
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(actual == p ? Tema.relleno : (sobre == p ? Tema.rellenoSuave : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { dentro in sobre = dentro ? p : (sobre == p ? nil : sobre) }
        .accessibilityAddTraits(actual == p ? .isSelected : [])
    }
}
