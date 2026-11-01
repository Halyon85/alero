import SwiftUI

// La terminal en el notch: la salida arriba (se va al final sola) y el renglón para escribir abajo. Mientras se ve,
// el notch puede tomar el teclado (ver `PanelNotch.aceptaTeclado`): un clic acá y escribís. Esc cierra el notch;
// ↑ y ↓ recorren los comandos anteriores.

struct EspacioTerminal: View {
    @ObservedObject private var terminal = Terminal.shared
    @ObservedObject var estado: EstadoNotch
    @State private var comando = ""
    @State private var posicion: Int?
    @FocusState private var enfocado: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { lector in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if terminal.lineas.isEmpty {
                            Text(T("Escribí un comando abajo. Corre en tu shell, en la carpeta que ves a la izquierda.",
                                   "Type a command below. It runs in your shell, in the folder shown on the left."))
                                .foregroundStyle(Tema.textoNotchSuave)
                        }
                        ForEach(terminal.lineas) { linea in
                            Text(linea.texto)
                                .foregroundStyle(color(linea.tipo))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(linea.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
                .onChange(of: terminal.lineas.last?.id) { _, ultimo in
                    if let ultimo { lector.scrollTo(ultimo, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { enfocado = true }

            HStack(spacing: 6) {
                Text(ReglasTerminal.corta(terminal.carpeta, casa: NSHomeDirectory()) + " ›")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tema.acento)
                    .lineLimit(1)
                    .fixedSize()
                TextField("", text: $comando)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($enfocado)
                    .onSubmit(enviar)
                    .onKeyPress(.upArrow) { recorrer(-1); return .handled }
                    .onKeyPress(.downArrow) { recorrer(1); return .handled }
                    .onExitCommand { estado.cerrar() }
                if terminal.corriendo {
                    Button { terminal.cortar() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                            .background(Tema.rellenoNotch, in: Circle())
                    }
                    .buttonStyle(BotonPresionable())
                    .help(T("Cortar (como Ctrl-C)", "Stop (like Ctrl-C)"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.white.opacity(enfocado ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .onAppear { DispatchQueue.main.async { enfocado = true } }
    }

    private func enviar() {
        terminal.ejecutar(comando)
        comando = ""
        posicion = nil
    }

    /// ↑ y ↓: los comandos anteriores, del más nuevo al más viejo.
    private func recorrer(_ paso: Int) {
        let historial = terminal.historial
        guard !historial.isEmpty else { return }
        let actual = posicion ?? historial.count
        let nueva = min(max(actual + paso, 0), historial.count)
        posicion = nueva
        comando = nueva < historial.count ? historial[nueva] : ""
    }

    private func color(_ tipo: LineaTerminal.Tipo) -> Color {
        switch tipo {
        case .comando: return Tema.textoNotch
        case .salida: return Tema.textoNotch.opacity(0.85)
        case .error: return Color(nsColor: NSColor(hex: 0xFF8A80))
        case .aviso: return Tema.textoNotchSuave
        }
    }
}
