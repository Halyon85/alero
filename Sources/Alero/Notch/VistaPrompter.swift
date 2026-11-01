import SwiftUI

// El teleprompter en el notch: el guion sube justo debajo de la cámara, con los bordes fundidos para que la vista no
// se vaya a la línea siguiente. Con velocidad fija se redibuja mientras corre (hasta 30 veces por segundo); en modo
// voz, solo cuando avanza la palabra (la ya leída queda gris y la que toca, resaltada). Con el mouse encima (o en
// pausa) aparecen los controles abajo, entre ellos editar el guion y pasar de velocidad fija a voz.

struct VistaPrompter: View {
    @ObservedObject var estado: EstadoNotch
    @ObservedObject private var tele = Teleprompter.shared
    @ObservedObject private var ajustes = Ajustes.shared
    @State private var sobre = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: estado.medidas.alto)
            ZStack(alignment: .bottom) {
                guion
                if sobre || !tele.corriendo {
                    controles.transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let cuenta = tele.cuenta {
                    Text("\(cuenta)")
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.55))
                }
            }
            .overlay(alignment: .top) {
                if let aviso = tele.aviso {
                    Text(aviso).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(nsColor: NSColor(hex: 0xFF8A80)))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.85), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: sobre || !tele.corriendo)
            .animation(.smooth(duration: 0.3), value: tele.cuenta)
        }
        .foregroundStyle(Tema.textoNotch)
        .onHover { sobre = $0 }
    }

    private var guion: some View {
        let voz = ajustes.prompterVoz
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !tele.corriendo || voz)) { contexto in
            let subido = tele.desplazamiento(contexto.date)
            Text(voz ? textoMarcado : AttributedString(tele.texto))
                .font(.system(size: ajustes.prompterLetra, weight: .semibold))
                .lineSpacing(ajustes.prompterLetra * 0.35)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.top, 10)
                .background(GeometryReader { medida in
                    Color.clear.onAppear { tele.altoTexto = Double(medida.size.height) }
                        .onChange(of: medida.size.height) { _, nuevo in tele.altoTexto = Double(nuevo) }
                })
                .offset(y: -subido)
                .animation(voz ? .smooth(duration: 0.45) : nil, value: tele.palabraActual)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .onChange(of: !voz && subido >= tele.limite && tele.corriendo) { _, llego in
                    // Al final del guion se pausa solo (fuera de la actualización de la vista).
                    if llego { DispatchQueue.main.async { tele.pausar() } }
                }
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    /// Modo voz: lo ya leído en gris, la palabra que toca resaltada y el resto normal.
    private var textoMarcado: AttributedString {
        let texto = tele.texto
        var marcado = AttributedString(texto)
        let rangos = tele.palabras.rangos
        let actual = tele.palabraActual
        if actual > 0, actual - 1 < rangos.count,
           let fin = AttributedString.Index(rangos[actual - 1].upperBound, within: marcado) {
            marcado[marcado.startIndex..<fin].foregroundColor = Tema.textoNotchSuave.opacity(0.6)
        }
        if actual < rangos.count, let rango = Range(rangos[actual], in: marcado) {
            marcado[rango].foregroundColor = Tema.acento
        }
        return marcado
    }

    private var controles: some View {
        HStack(spacing: 6) {
            BotonPrompter(icono: "backward.end.fill", etiqueta: T("Al principio", "Back to start")) { tele.reiniciar() }
            if !ajustes.prompterVoz {
                BotonPrompter(icono: "tortoise.fill", etiqueta: T("Más lento", "Slower")) { tele.cambiarVelocidad(ajustes.prompterVelocidad - 10) }
            }
            Button { tele.alternar() } label: {
                Image(systemName: tele.corriendo || tele.cuenta != nil ? "pause.fill" : (ajustes.prompterVoz ? "mic.fill" : "play.fill"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(Tema.textoNotch, in: Circle())
            }
            .buttonStyle(BotonPresionable())
            .accessibilityLabel(tele.corriendo ? T("Pausar", "Pause") : T("Empezar", "Start"))
            if !ajustes.prompterVoz {
                BotonPrompter(icono: "hare.fill", etiqueta: T("Más rápido", "Faster")) { tele.cambiarVelocidad(ajustes.prompterVelocidad + 10) }
                Text("\(Int(ajustes.prompterVelocidad))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Tema.textoNotchSuave)
                    .frame(width: 24)
            }
            BotonPrompter(icono: ajustes.prompterVoz ? "waveform" : "speedometer",
                          etiqueta: ajustes.prompterVoz ? T("Sigue tu voz: pasar a velocidad fija", "Follows your voice: switch to fixed speed")
                                                        : T("Velocidad fija: pasar a seguir tu voz", "Fixed speed: switch to follow your voice"),
                          activo: ajustes.prompterVoz) { tele.cambiarModo() }
            BotonPrompter(icono: "textformat.size.smaller", etiqueta: T("Letra más chica", "Smaller text")) {
                ajustes.prompterLetra = max(ajustes.prompterLetra - 2, 14)
            }
            BotonPrompter(icono: "textformat.size.larger", etiqueta: T("Letra más grande", "Larger text")) {
                ajustes.prompterLetra = min(ajustes.prompterLetra + 2, 34)
            }
            BotonPrompter(icono: "pencil", etiqueta: T("Editar el guion", "Edit the script")) {
                tele.pausar()
                withAnimation(Diseno.cambio) { estado.abrir(.teleprompter) }
            }
            BotonPrompter(icono: "xmark", etiqueta: T("Cerrar el teleprompter", "Close the teleprompter")) {
                ControladorNotch.shared.cerrarPrompter()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.85), in: Capsule())
        .padding(.bottom, 10)
    }
}

private struct BotonPrompter: View {
    let icono: String
    let etiqueta: String
    var activo = false
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: icono).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(activo ? Tema.acento : Tema.textoNotch)
                .background(activo ? Tema.acentoFondo : Tema.rellenoNotch, in: Circle())
        }
        .buttonStyle(BotonPresionable())
        .help(etiqueta)
        .accessibilityLabel(etiqueta)
    }
}

// MARK: - La pestaña Teleprompter del notch abierto

/// El guion, editable ahí mismo (el notch toma el teclado en esta pestaña, como en la terminal), y a la derecha cómo
/// se lee (velocidad fija o siguiendo tu voz) y Empezar.
struct EspacioTeleprompter: View {
    @ObservedObject var estado: EstadoNotch
    @ObservedObject private var tele = Teleprompter.shared
    @ObservedObject private var ajustes = Ajustes.shared
    @Environment(\.enCapturas) private var enCapturas

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TituloSeccionNotch(texto: T("GUION · ESCRIBÍ O PEGÁ CON ⌘V", "SCRIPT · TYPE OR PASTE WITH ⌘V"))
                Group {
                    // El dibujante de `--capturas` no muestra un editor de texto: va el texto tal cual.
                    if enCapturas {
                        Text(tele.texto).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        TextEditor(text: $tele.texto).scrollContentBackground(.hidden).scrollIndicators(.never)
                    }
                }
                .font(.system(size: 12))
                .padding(6)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    modo(T("Velocidad", "Speed"), voz: false)
                    modo(T("Mi voz", "My voice"), voz: true)
                }
                if ajustes.prompterVoz {
                    Text(T("Avanza con lo que vas leyendo, en español.", "Follows what you read, in Spanish."))
                        .font(.system(size: 10)).foregroundStyle(Tema.textoNotchSuave).fixedSize(horizontal: false, vertical: true)
                } else {
                    ajuste(T("Velocidad", "Speed"), "\(Int(ajustes.prompterVelocidad))",
                           menos: { tele.cambiarVelocidad(ajustes.prompterVelocidad - 10) },
                           mas: { tele.cambiarVelocidad(ajustes.prompterVelocidad + 10) })
                }
                ajuste(T("Letra", "Text"), "\(Int(ajustes.prompterLetra))",
                       menos: { ajustes.prompterLetra = max(ajustes.prompterLetra - 2, 14) },
                       mas: { ajustes.prompterLetra = min(ajustes.prompterLetra + 2, 34) })
                Spacer(minLength: 0)
                Button {
                    ControladorNotch.shared.abrirPrompter(en: estado)
                    tele.empezar()
                } label: {
                    Label(T("Empezar", "Start"), systemImage: ajustes.prompterVoz ? "mic.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(Tema.textoNotch, in: Capsule())
                }
                .buttonStyle(BotonPresionable())
            }
            .frame(width: 176, alignment: .topLeading)
        }
    }

    private func modo(_ titulo: String, voz: Bool) -> some View {
        let elegido = ajustes.prompterVoz == voz
        return Button { if !elegido { tele.cambiarModo() } } label: {
            Text(titulo).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 24)
                .foregroundStyle(elegido ? Tema.textoNotch : Tema.textoNotchSuave)
                .background(elegido ? Color.white.opacity(0.16) : Color.white.opacity(0.05), in: Capsule())
        }
        .buttonStyle(BotonPresionable())
    }

    private func ajuste(_ titulo: String, _ valor: String, menos: @escaping () -> Void, mas: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(titulo).font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave)
            Spacer(minLength: 4)
            BotonAtajo(icono: "minus", etiqueta: titulo + " −", activo: false, accion: menos)
            Text(valor).font(.system(size: 11, weight: .semibold).monospacedDigit()).frame(width: 24)
            BotonAtajo(icono: "plus", etiqueta: titulo + " +", activo: false, accion: mas)
        }
    }
}
