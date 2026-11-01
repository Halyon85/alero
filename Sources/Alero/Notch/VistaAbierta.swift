import AppKit
import SwiftUI

// El notch abierto: arriba, a cada lado de la cámara, una fila de íconos iguales (pestañas y botones) que se eligen y
// se ordenan en Alero › Notch abierto; abajo, el espacio elegido (ver `Espacios.swift`). Los espacios que miden algo
// (estado, agentes, sonido) solo trabajan mientras se ven.

struct VistaAbiertaNotch: View {
    @ObservedObject var estado: EstadoNotch
    @ObservedObject private var ajustes = Ajustes.shared
    /// Una sola marca para las dos filas: la cápsula de la pestaña elegida se desliza de un lado al otro.
    @Namespace private var marca

    var body: some View {
        VStack(spacing: 0) {
            Alas(medidas: estado.medidas, margen: 14) {
                FilaBarra(estado: estado, elementos: ajustes.notchBarraIzquierda, marca: marca)
            } derecha: {
                FilaBarra(estado: estado, elementos: ajustes.notchBarraDerecha, marca: marca)
            }
            Group {
                switch estado.espacio {
                case .inicio: EspacioInicio(estado: estado)
                case .sonido: EspacioSonido()
                case .utilidades: EspacioUtilidades()
                case .limpiar: EspacioLimpiar()
                case .agentes: TarjetaAgentes(compacta: false)
                case .teleprompter: EspacioTeleprompter(estado: estado)
                case .terminal: EspacioTerminal(estado: estado)
                case .estante: ListaEstante()
                }
            }
            .id(estado.espacio)
            .transition(.entradaNotch)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Tema.textoNotch)
    }
}

/// Una fila de la barra de arriba: todos los íconos con el mismo formato. Las pestañas muestran la elegida sobre una
/// cápsula que se desliza; los botones hacen lo suyo y se pintan de celeste cuando están prendidos (café, silencio…).
struct FilaBarra: View {
    @ObservedObject var estado: EstadoNotch
    let elementos: [ElementoBarra]
    let marca: Namespace.ID
    // Para redibujar el estado de los botones (café prendido, silencio, salida de sonido).
    @ObservedObject private var cafe = Cafe.shared
    @ObservedObject private var sonido = Sonido.shared
    @ObservedObject private var ajustes = Ajustes.shared
    @State private var sobre: ElementoBarra?

    var body: some View {
        if !elementos.isEmpty {
            HStack(spacing: 2) {
                ForEach(elementos) { icono($0) }
            }
            .padding(2)
            .background(Color.white.opacity(0.05), in: Capsule())
        }
    }

    private func icono(_ elemento: ElementoBarra) -> some View {
        let elegido: Bool
        let activo: Bool
        let simbolo: String
        let etiqueta: String
        switch elemento {
        case .espacio(let espacio):
            elegido = estado.espacio == espacio
            activo = false
            simbolo = espacio.icono
            etiqueta = espacio.nombre
        case .accion(let atajo):
            elegido = false
            activo = AccionesNotch.activo(atajo, estado: estado)
            simbolo = AccionesNotch.icono(atajo)
            etiqueta = AccionesNotch.etiqueta(atajo)
        }
        return Button {
            switch elemento {
            case .espacio(let espacio): withAnimation(Diseno.cambio) { estado.espacio = espacio }
            case .accion(let atajo): AccionesNotch.ejecutar(atajo, estado: estado)
            }
        } label: {
            Image(systemName: simbolo)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
                .foregroundStyle(activo ? Tema.acento : (elegido ? Tema.textoNotch : Tema.textoNotchSuave))
                .background {
                    if elegido {
                        Capsule().fill(Color.white.opacity(0.16)).matchedGeometryEffect(id: "marca", in: marca)
                    } else if activo {
                        Capsule().fill(Tema.acentoFondo)
                    } else if sobre == elemento {
                        Capsule().fill(Color.white.opacity(0.07))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(BotonPresionable())
        .onHover { dentro in sobre = dentro ? elemento : (sobre == elemento ? nil : sobre) }
        .help(etiqueta)
        .accessibilityLabel(etiqueta)
        .accessibilityAddTraits(elegido ? .isSelected : [])
    }
}

/// El espacio Inicio: la tarjeta de la izquierda (ancho libre) y la de la derecha (columna de 214 pt).
struct EspacioInicio: View {
    @ObservedObject var estado: EstadoNotch
    @ObservedObject private var ajustes = Ajustes.shared

    var body: some View {
        let izquierda = ajustes.notchInicioIzquierda
        let derecha = ajustes.notchInicioDerecha
        HStack(alignment: .top, spacing: 18) {
            if izquierda != .nada { tarjeta(izquierda).frame(maxWidth: .infinity, alignment: .topLeading) }
            if izquierda != .nada && derecha != .nada { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
            if derecha != .nada {
                tarjeta(derecha).frame(width: izquierda == .nada ? nil : 214, alignment: .topLeading)
                    .frame(maxWidth: izquierda == .nada ? .infinity : nil, alignment: .topLeading)
            }
            if izquierda == .nada && derecha == .nada {
                Text(T("Elegí qué mostrar en Alero › Notch abierto.", "Pick what to show in Alero › Open notch."))
                    .font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave)
            }
        }
    }

    @ViewBuilder private func tarjeta(_ tarjeta: TarjetaNotch) -> some View {
        switch tarjeta {
        case .musica:
            // El parlante lleva al espacio Sonido (si está prendido).
            let conSonido = ajustes.notchEspacios.contains(.sonido)
            Reproductor(sonidoVisible: false, conParlante: conSonido) {
                withAnimation(Diseno.cambio) { estado.espacio = .sonido }
            }
            // Un poco más arriba que el centro del espacio: con la barra de arriba, centrado se veía bajo.
            .padding(.bottom, 12)
        case .agenda: Agenda()
        case .sonido: ColumnaSonido()
        case .estado: TarjetaEstado()
        case .agentes: TarjetaAgentes(compacta: true)
        case .nada: EmptyView()
        }
    }
}

/// Pastilla chica del notch (ícono y texto), resaltada en celeste cuando está activa.
struct PastillaNotch: View {
    let icono: String
    let texto: String
    let activa: Bool
    let etiqueta: String
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            HStack(spacing: 5) {
                Image(systemName: icono).font(.system(size: 11, weight: .semibold))
                Text(texto).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(activa ? Tema.acento : Tema.textoNotch)
            .background(activa ? Tema.acentoFondo : Tema.rellenoNotch, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(BotonPresionable())
        .help(etiqueta)
        .accessibilityLabel(etiqueta)
    }
}

// MARK: - Reproductor

struct Reproductor: View {
    let sonidoVisible: Bool
    /// Sin el espacio Sonido no hay a dónde ir: el parlante no se muestra.
    var conParlante = true
    let alternarSonido: () -> Void
    @ObservedObject private var musica = Musica.shared
    @ObservedObject private var ajustes = Ajustes.shared
    @ObservedObject private var sonido = Sonido.shared

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if ajustes.notchMusica, let pista = musica.pista {
                ZStack {
                    // Halo: la misma carátula agrandada, girada y desenfocada, detrás (idea de Boring Notch).
                    Caratula(imagen: musica.caratula, lado: 96, radio: 14)
                        .scaleEffect(1.3).rotationEffect(.degrees(92)).blur(radius: 36)
                        .opacity(pista.sonando ? 0.5 : 0)
                    Caratula(imagen: musica.caratula, lado: 96, radio: 14)
                        .scaleEffect(pista.sonando ? 1 : 0.88)
                        .brightness(pista.sonando ? 0 : -0.15)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                }
                .frame(width: 96, height: 96)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: pista.sonando)
                .id(pista.titulo)
                .transition(.opacity.animation(.easeInOut(duration: 0.35)))

                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pista.titulo).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(pista.artista).font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave).lineLimit(1)
                    }
                    Progreso(pista: pista)
                    controles(sonando: pista.sonando)
                }
            } else {
                Caratula(imagen: nil, lado: 64, radio: 12)
                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(T("Nada sonando", "Nothing playing")).font(.system(size: 15, weight: .semibold))
                        Text(musica.disponible || !ajustes.notchMusica
                             ? T("Poné música en cualquier app y aparece acá.", "Play music in any app and it shows up here.")
                             : T("Falta el lector de música en esta copia de Alero.", "The music reader is missing from this copy of Alero."))
                            .font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave).lineLimit(2)
                    }
                    HStack { Spacer(); if conParlante { botonSonido } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func controles(sonando: Bool) -> some View {
        HStack(spacing: 14) {
            BotonControl(icono: "backward.fill", etiqueta: T("Anterior", "Previous")) { musica.anterior() }
            Button { musica.alternar() } label: {
                Image(systemName: sonando ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Tema.textoNotch, in: Circle())
            }
            .buttonStyle(BotonPresionable())
            .accessibilityLabel(sonando ? T("Pausar", "Pause") : T("Reproducir", "Play"))
            BotonControl(icono: "forward.fill", etiqueta: T("Siguiente", "Next")) { musica.siguiente() }
            Spacer(minLength: 0)
            if conParlante { botonSonido }
        }
    }

    /// Ícono de la salida actual: lleva al espacio Sonido (salidas y volumen de cada app).
    private var botonSonido: some View {
        Button(action: alternarSonido) {
            Image(systemName: VistaAviso.icono(de: sonido.salidaActual?.tipo ?? .otro))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(sonidoVisible ? Tema.acento : Tema.textoNotch)
                .background(sonidoVisible ? Tema.acentoFondo : Tema.rellenoNotch, in: Circle())
        }
        .buttonStyle(BotonPresionable())
        .help(T("Salida de sonido", "Sound output"))
        .accessibilityLabel(T("Salida de sonido: \(sonido.salidaActual?.nombre ?? "")", "Sound output: \(sonido.salidaActual?.nombre ?? "")"))
    }
}

struct Progreso: View {
    let pista: Pista

    var body: some View {
        // Se redibuja una vez por segundo y solo mientras el notch está abierto.
        TimelineView(.periodic(from: .now, by: 1)) { contexto in
            let actual = pista.transcurridoAhora(contexto.date)
            let parte = pista.duracion > 0 ? actual / pista.duracion : 0
            HStack(spacing: 8) {
                Text(Progreso.tiempo(actual))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(Tema.textoNotch).frame(width: geo.size.width * parte)
                    }
                }
                .frame(height: 4)
                Text(Progreso.tiempo(pista.duracion))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Tema.textoNotchSuave)
        }
    }

    static func tiempo(_ segundos: Double) -> String {
        let total = Int(max(segundos, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct BotonControl: View {
    let icono: String
    let etiqueta: String
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: icono).font(.system(size: 15, weight: .semibold)).frame(width: 28, height: 28)
        }
        .buttonStyle(BotonPresionable())
        .foregroundStyle(Tema.textoNotch)
        .accessibilityLabel(etiqueta)
    }
}

// MARK: - Agenda

struct Agenda: View {
    @ObservedObject private var calendario = Calendario.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("AGENDA", "AGENDA")).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Tema.textoNotchSuave)
            switch calendario.permiso {
            case .denegado:
                Text(T("Alero no tiene permiso para ver tu calendario.", "Alero can't see your calendar."))
                    .font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave)
                Button(T("Dar permiso", "Allow access")) { Calendario.abrirAjustesDePrivacidad() }
                    .buttonStyle(BotonPastilla())
            case .sinPedir:
                Button(T("Mostrar mi calendario", "Show my calendar")) { calendario.pedirPermiso() }.buttonStyle(BotonPastilla())
            case .concedido:
                if calendario.eventos.isEmpty {
                    Text(T("Nada más por hoy ni mañana.", "Nothing else today or tomorrow."))
                        .font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { contexto in
                        VStack(alignment: .leading, spacing: 8) {
                            if let primero = calendario.eventos.first { Proximo(evento: primero, ahora: contexto.date) }
                            ForEach(calendario.eventos.dropFirst().prefix(2)) { evento in
                                Button { calendario.abrirEnCalendario(evento) } label: {
                                    HStack {
                                        Circle().fill(evento.color).frame(width: 6, height: 6)
                                        Text(evento.titulo).lineLimit(1)
                                        Spacer(minLength: 6)
                                        Text(Agenda.cuando(evento, ahora: contexto.date)).foregroundStyle(Tema.textoNotchSuave)
                                    }
                                    .font(.system(size: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { calendario.revisarPermiso() }
    }

    /// "ahora", "en 12 min", "15:30" o "mañana 9:00".
    static func cuando(_ evento: Evento, ahora: Date) -> String {
        let calendario = Foundation.Calendar.current
        if evento.inicio <= ahora { return T("ahora", "now") }
        let hora = evento.todoElDia ? T("todo el día", "all day") : evento.inicio.formatted(date: .omitted, time: .shortened)
        if !calendario.isDate(evento.inicio, inSameDayAs: ahora) { return T("mañana \(hora)", "tomorrow \(hora)") }
        let minutos = Int(evento.inicio.timeIntervalSince(ahora) / 60)
        return !evento.todoElDia && minutos < 60 ? T("en \(max(minutos, 1)) min", "in \(max(minutos, 1)) min") : hora
    }
}

struct Proximo: View {
    let evento: Evento
    let ahora: Date
    @ObservedObject private var calendario = Calendario.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { calendario.abrirEnCalendario(evento) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(evento.titulo).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        if !evento.todoElDia {
                            Text("\(evento.inicio.formatted(date: .omitted, time: .shortened)) – \(evento.fin.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(Tema.textoNotchSuave)
                            Text("·").foregroundStyle(Tema.textoNotchSuave)
                        }
                        Text(Agenda.cuando(evento, ahora: ahora)).fontWeight(.semibold).foregroundStyle(Tema.acento)
                    }
                    .font(.system(size: 12))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let enlace = evento.enlace {
                Button(T("Unirse", "Join")) { NSWorkspace.shared.open(enlace) }.buttonStyle(BotonPastilla(relleno: true))
            }
        }
    }
}

struct BotonPastilla: ButtonStyle {
    var relleno = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 26)
            .foregroundStyle(relleno ? Color.black : Tema.textoNotch)
            .background(relleno ? Tema.acento : Tema.rellenoNotch, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Estante

/// Mientras arrastrás un archivo: la zona para soltarlo y, al lado, lo que ya está guardado.
struct VistaSoltar: View {
    @ObservedObject var estado: EstadoNotch
    @ObservedObject private var estante = Estante.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 5) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 20, weight: .semibold))
                Text(T("Soltalo en el estante", "Drop it on the shelf")).font(.system(size: 13, weight: .semibold))
                Text(T("Queda hasta que lo saques", "It stays until you take it out")).font(.system(size: 11)).opacity(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(estado.sobreZona ? Tema.acento : Tema.textoNotch)
            .background(estado.sobreZona ? Tema.acento.opacity(0.16) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(estado.sobreZona ? Tema.acento : Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 2.5, dash: [9, 6])))
            .animation(.smooth(duration: 0.16), value: estado.sobreZona)
            if !estante.items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(estante.items.suffix(3)) { item in
                        HStack(spacing: 7) {
                            Image(nsImage: estante.icono(de: item)).resizable().frame(width: 20, height: 20)
                            Text(item.nombre).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .frame(width: 150, alignment: .leading)
            }
        }
        .padding(.top, estado.medidas.alto + 6)
        .padding([.horizontal, .bottom], 14)
        .foregroundStyle(Tema.textoNotch)
    }
}

/// El estante dentro del notch abierto: cada archivo se arrastra a donde quieras (se copia, no se mueve).
struct ListaEstante: View {
    @ObservedObject private var estante = Estante.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TituloSeccionNotch(texto: T("ESTANTE", "SHELF"))
                Spacer()
                if !estante.items.isEmpty {
                    Button(T("Vaciar", "Clear")) { estante.vaciar() }.buttonStyle(BotonPastilla())
                }
            }
            if estante.items.isEmpty {
                Text(T("Arrastrá un archivo hacia el notch para dejarlo acá.", "Drag a file to the notch to keep it here."))
                    .font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(estante.items) { item in FichaEstante(item: item) }
                    }
                }
            }
        }
    }
}

struct FichaEstante: View {
    let item: ItemEstante
    @ObservedObject private var estante = Estante.shared
    @State private var encima = false

    var body: some View {
        let icono = estante.icono(de: item)
        VStack(spacing: 5) {
            Image(nsImage: icono).resizable().frame(width: 44, height: 44)
            Text(item.nombre).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
        }
        .frame(width: 78, height: 92)
        .background(encima ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if let url = estante.url(de: item) { ArrastreArchivo(url: url, icono: icono) } }
        .overlay(alignment: .topTrailing) {
            if encima {
                Button { estante.quitar(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Tema.textoNotchSuave)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T("Sacar del estante", "Remove from shelf"))
            }
        }
        .onHover { encima = $0 }
    }
}
