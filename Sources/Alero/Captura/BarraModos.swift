import SwiftUI

// La barra flotante de la superficie de selección: Área, Ventana y Pantalla, una pista de qué hacer y la cruz para
// salir. Va abajo al centro de la pantalla donde estaba el puntero. Oscura como el notch, para que se lea sobre
// cualquier fondo.

final class EstadoBarra: ObservableObject {
    @Published var modo: ModoCaptura
    /// Mientras se arrastra un área la barra se aparta (se vuelve transparente) para no tapar lo que se elige.
    @Published var arrastrando = false

    init(modo: ModoCaptura) { self.modo = modo }
}

struct BarraModos: View {
    @ObservedObject var estado: EstadoBarra
    let elegir: (ModoCaptura) -> Void
    let cerrar: () -> Void
    @Namespace private var espacio

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(ModoCaptura.allCases) { modo in boton(modo) }
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 22).padding(.horizontal, 4)
                Button(action: cerrar) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Tema.textoNotchSuave)
                        .background(Tema.rellenoNotch, in: Circle())
                }
                .buttonStyle(BotonPresionable())
                .help(T("Cancelar (⎋)", "Cancel (⎋)"))
                .accessibilityLabel(T("Cancelar", "Cancel"))
            }
            Text(pista)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tema.textoNotchSuave)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .opacity(estado.arrastrando ? 0 : 1)
        .animation(.easeOut(duration: 0.16), value: estado.arrastrando)
        .animation(.easeOut(duration: 0.16), value: estado.modo)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func boton(_ modo: ModoCaptura) -> some View {
        let elegido = estado.modo == modo
        return Button { elegir(modo) } label: {
            HStack(spacing: 6) {
                Image(systemName: modo.icono).font(.system(size: 12, weight: .semibold))
                Text(modo.nombre).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(elegido ? Tema.acento : Tema.textoNotch)
            .background {
                if elegido {
                    Capsule().fill(Tema.acentoFondo).matchedGeometryEffect(id: "modo", in: espacio)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(BotonPresionable())
        .accessibilityAddTraits(elegido ? .isSelected : [])
    }

    private var pista: String {
        switch estado.modo {
        case .area: return T("Arrastrá para elegir · Espacio: ventana · ↩ pantalla entera · ⎋ salir",
                             "Drag to select · Space: window · ↩ whole screen · ⎋ quit")
        case .ventana: return T("Clic en una ventana · ⌥ sin sombra · Espacio: área · ⎋ salir",
                                "Click a window · ⌥ no shadow · Space: area · ⎋ quit")
        case .pantalla: return T("Clic en la pantalla que querés · ⎋ salir", "Click the screen you want · ⎋ quit")
        }
    }
}
