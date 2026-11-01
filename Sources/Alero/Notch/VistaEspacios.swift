import AppKit
import SwiftUI

// Los espacios del notch abierto que no son Inicio ni Estante: Sonido, Pantallas, Utilidades y Agentes de IA (el
// desinstalador, Limpiar, Teleprompter y Terminal tienen su archivo). Estado y Agentes también pueden ir en Inicio. Cada una avisa a su servicio al
// aparecer y al irse: con el notch cerrado no se mide nada.

// MARK: - Sonido y brillo

/// Una sola pestaña para el sonido y el brillo (01/11/2026: así queda un ícono libre). Todo en filas de una
/// línea (ícono, deslizador y valor; el nombre aparece al pasar el mouse), así entra sin desplazar y se acomoda al
/// ancho del notch. Izquierda: la salida (un menú) y el volumen de cada app. Derecha: cada pantalla y la luz del teclado.
struct EspacioSonido: View {
    @ObservedObject private var ajustes = Ajustes.shared
    @ObservedObject private var sonido = Sonido.shared
    @ObservedObject private var mezclador = Mezclador.shared
    @ObservedObject private var monitores = Monitores.shared
    @State private var luzTeclado: Float = BrilloTeclado.actual() ?? 0
    @State private var hayTeclado = BrilloTeclado.disponible

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DesplazableNotch {
                VStack(alignment: .leading, spacing: 7) {
                    menuSalida
                    if Mezclador.disponible && ajustes.mezcladorActivo { apps }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            DesplazableNotch {
                VStack(alignment: .leading, spacing: 7) {
                    TituloSeccionNotch(texto: T("BRILLO", "BRIGHTNESS"))
                    if ajustes.brilloMonitores {
                        ForEach(monitores.lista) { monitor in
                            FilaCompacta(simbolo: monitor.integrada ? "laptopcomputer" : "display", nombre: monitor.nombre,
                                         valor: monitor.nivel ?? 0, apagado: !monitor.metodo.controlable,
                                         texto: monitor.metodo.controlable ? monitor.nivel.map(FilaCompacta.porciento) ?? "–" : "–") {
                                Monitores.shared.poner(monitor.id, nivel: $0)
                            }
                        }
                    }
                    if hayTeclado {
                        FilaCompacta(simbolo: luzTeclado == 0 ? "light.min" : "light.max",
                                     nombre: T("Luz del teclado (también ⌘ + brillo)", "Keyboard light (also ⌘ + brightness)"),
                                     valor: luzTeclado, apagado: false, texto: FilaCompacta.porciento(luzTeclado)) { nuevo in
                            luzTeclado = nuevo
                            BrilloTeclado.poner(nuevo)
                        }
                    }
                    if !ajustes.brilloMonitores && !hayTeclado {
                        TextoVacio(T("El brillo está apagado (Alero › Sonido y brillo).", "Brightness is off (Alero › Sound & brightness)."))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            Mezclador.shared.mirar(true)
            Monitores.shared.mirar()
            luzTeclado = BrilloTeclado.actual() ?? luzTeclado
        }
        .onDisappear { Mezclador.shared.mirar(false) }
    }

    /// La salida de sonido en un renglón: el nombre de la actual y un menú con las demás.
    private var menuSalida: some View {
        VStack(alignment: .leading, spacing: 5) {
            TituloSeccionNotch(texto: T("SALIDA", "OUTPUT"))
            Menu {
                ForEach(sonido.salidas) { salida in
                    Button { sonido.elegir(salida) } label: {
                        Label(salida.nombre, systemImage: salida.id == sonido.salidaActual?.id ? "checkmark" : VistaAviso.icono(de: salida.tipo))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: VistaAviso.icono(de: sonido.salidaActual?.tipo ?? .otro)).font(.system(size: 10, weight: .semibold))
                        .frame(width: 18)
                    Text(sonido.salidaActual?.nombre ?? T("Sin salida", "No output")).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Tema.textoNotchSuave)
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    @ViewBuilder private var apps: some View {
        TituloSeccionNotch(texto: T("VOLUMEN POR APP", "APP VOLUME"))
        if mezclador.permiso == .negado {
            Button(T("Dar permiso de audio", "Allow audio access")) { PermisoAudio.abrirAjustes() }.buttonStyle(BotonPastilla())
        } else if mezclador.apps.isEmpty {
            TextoVacio(T("Ninguna app está sonando.", "No app is playing."))
        } else {
            ForEach(mezclador.apps) { app in
                FilaCompacta(imagen: FilaApp.icono(de: app), nombre: app.nombre, valor: app.volumen, apagado: app.silencio || app.fallo,
                             texto: app.silencio ? T("mudo", "muted") : FilaCompacta.porciento(app.volumen)) {
                    Mezclador.shared.cambiar(app.id, volumen: $0)
                } alTocarIcono: {
                    Mezclador.shared.alternarSilencio(app.id)
                }
            }
        }
    }
}

/// Una fila de una línea: ícono (o imagen de app), deslizador y valor. El nombre va en la ayuda al pasar el mouse.
/// Tocar el ícono hace lo que se le pase (en las apps, silenciar).
struct FilaCompacta: View {
    var simbolo: String? = nil
    var imagen: NSImage? = nil
    let nombre: String
    let valor: Float
    let apagado: Bool
    let texto: String
    let cambiar: (Float) -> Void
    var alTocarIcono: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button { alTocarIcono?() } label: {
                Group {
                    if let imagen {
                        Image(nsImage: imagen).resizable().interpolation(.high).opacity(apagado ? 0.5 : 1)
                    } else {
                        Image(systemName: simbolo ?? "circle").font(.system(size: 10, weight: .semibold))
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(alTocarIcono == nil)
            DeslizadorNotch(valor: valor, apagado: apagado, etiqueta: nombre, cambiar: cambiar)
            Text(texto).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Tema.textoNotchSuave)
                .lineLimit(1).frame(width: 34, alignment: .trailing)
        }
        .frame(height: 20)
        .help(nombre)
    }

    static func porciento(_ valor: Float) -> String { "\(Int((valor * 100).rounded())) %" }
}

// MARK: - Estado de la Mac

/// Procesador y memoria en dos anillos, centrados, y abajo la presión de memoria (lo que importa en Apple Silicon).
/// Va en Utilidades y como tarjeta de Inicio.
struct TarjetaEstado: View {
    @ObservedObject private var estadoMac = EstadoMac.shared
    @Environment(\.enCapturas) private var enCapturas

    var body: some View {
        VStack(spacing: 12) {
            TituloSeccionNotch(texto: T("ESTADO DE LA MAC", "MAC STATUS")).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 22) {
                Anillo(valor: estadoMac.cpu, color: Tema.acento, titulo: T("Procesador", "CPU"),
                       texto: "\(Int((estadoMac.cpu * 100).rounded())) %")
                Anillo(valor: estadoMac.total > 0 ? Double(estadoMac.usada) / Double(estadoMac.total) : 0, color: colorPresion,
                       titulo: T("Memoria", "Memory"), texto: EstadoMac.gigas(estadoMac.usada))
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Circle().fill(colorPresion).frame(width: 6, height: 6)
                Text(descripcionPresion).font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { if !enCapturas { estadoMac.empezar() } }
        .onDisappear { if !enCapturas { estadoMac.terminar() } }
    }

    private var colorPresion: Color {
        switch estadoMac.presion {
        case .normal: return Color(nsColor: NSColor(hex: 0x4CD964))
        case .aviso: return Color(nsColor: NSColor(hex: 0xFFCC00))
        case .critica: return Color(nsColor: NSColor(hex: 0xFF453A))
        }
    }

    private var descripcionPresion: String {
        let swap = estadoMac.swap > 0 ? " · swap \(EstadoMac.gigas(estadoMac.swap))" : ""
        switch estadoMac.presion {
        case .normal: return T("Memoria tranquila", "Memory is fine") + swap
        case .aviso: return T("Memoria justa", "Memory is tight") + swap
        case .critica: return T("Memoria al límite", "Memory is maxed out") + swap
        }
    }
}

/// Un anillo de progreso con el valor en el medio y el título abajo.
struct Anillo: View {
    let valor: Double
    let color: Color
    let titulo: String
    let texto: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: min(max(valor, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: valor)
                Text(texto).font(.system(size: 11, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 7)
            }
            .frame(width: 60, height: 60)
            Text(titulo).font(.system(size: 10, weight: .medium)).foregroundStyle(Tema.textoNotchSuave)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Utilidades

/// El estado de la Mac a la izquierda y el desinstalador a la derecha.
struct EspacioUtilidades: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            TarjetaEstado().frame(width: 200)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            DesinstaladorNotch().frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Agentes

/// Claude Code y Codex: si están trabajando, en qué proyecto y el cupo de Codex. Compacta va uno debajo del otro.
struct TarjetaAgentes: View {
    let compacta: Bool
    @ObservedObject private var agentes = Agentes.shared
    @Environment(\.enCapturas) private var enCapturas

    var body: some View {
        // Se redibuja cada 5 s para que "hace 2 min" y "trabajando" se pongan al día (solo mientras se ve).
        TimelineView(.periodic(from: .now, by: 5)) { contexto in
            let filas = Group {
                FilaAgente(nombre: "Claude Code", icono: "asterisk", estado: agentes.claude, ahora: contexto.date)
                FilaAgente(nombre: "Codex", icono: "chevron.left.forwardslash.chevron.right", estado: agentes.codex, ahora: contexto.date)
            }
            if compacta {
                VStack(alignment: .leading, spacing: 10) {
                    TituloSeccionNotch(texto: T("AGENTES DE IA", "AI AGENTS"))
                    filas
                }
            } else {
                // Como pestaña: dos tarjetas iguales, centradas en el alto del notch.
                VStack(alignment: .leading, spacing: 10) {
                    TituloSeccionNotch(texto: T("AGENTES DE IA", "AI AGENTS"))
                    HStack(spacing: 12) {
                        filas.padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .frame(maxHeight: 110)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { if !enCapturas { agentes.empezar() } }
        .onDisappear { if !enCapturas { agentes.terminar() } }
    }
}

struct FilaAgente: View {
    let nombre: String
    let icono: String
    let estado: EstadoAgente
    let ahora: Date

    var body: some View {
        let trabajando = estado.trabajando(ahora)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icono)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .foregroundStyle(trabajando ? Tema.acento : Tema.textoNotch)
                .background(trabajando ? Tema.acentoFondo : Tema.rellenoNotch, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if trabajando { PuntoLatiendo().offset(x: 3, y: -3) }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(nombre).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let modelo = estado.chat.modelo {
                        Text(ReglasAgentes.nombreModelo(modelo)).font(.system(size: 10, weight: .medium)).foregroundStyle(Tema.textoNotchSuave)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .lineLimit(1)
                    }
                }
                if let titulo = estado.chat.titulo {
                    Text(titulo).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                Text(lineaEstado(trabajando)).font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave).lineLimit(1)
                if let contexto = estado.chat.contexto, let ventana = estado.chat.ventana, ventana > 0 {
                    barra(Double(contexto) / Double(ventana),
                          T("contexto \(FilaAgente.miles(contexto)) de \(FilaAgente.miles(ventana))",
                            "context \(FilaAgente.miles(contexto)) of \(FilaAgente.miles(ventana))"))
                }
                ForEach(estado.cupos, id: \.nombre) { cupo in barra(cupo.usado, textoCupo(cupo)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barra(_ valor: Double, _ texto: String) -> some View {
        HStack(spacing: 6) {
            DeslizadorNotch(valor: Float(valor), apagado: true, etiqueta: texto) { _ in }
                .allowsHitTesting(false)
                .frame(width: 60)
            Text(texto).font(.system(size: 10).monospacedDigit()).foregroundStyle(Tema.textoNotchSuave).lineLimit(1)
        }
    }

    /// 457.000 → "457 k"; 1.000.000 → "1 M".
    static func miles(_ n: Int) -> String {
        n >= 1_000_000 ? (n % 1_000_000 == 0 ? "\(n / 1_000_000) M" : String(format: "%.1f M", Double(n) / 1_000_000))
            : "\(Int((Double(n) / 1000).rounded())) k"
    }

    private func lineaEstado(_ trabajando: Bool) -> String {
        let proyecto = (estado.proyecto.map { " · \($0)" } ?? "") + (estado.chat.rama.map { " · \($0)" } ?? "")
        if trabajando { return T("Trabajando", "Working") + proyecto }
        guard let ultimo = estado.ultimo else { return T("Sin actividad reciente", "No recent activity") }
        let hace = ultimo.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return T("Quieto · \(hace)", "Idle · \(hace)") + proyecto
    }

    /// "47 % semana · vuelve el mié" o "12 % 5 h · vuelve 18:30" (dentro del día, la hora).
    private func textoCupo(_ cupo: EstadoAgente.Cupo) -> String {
        let usado = "\(Int((cupo.usado * 100).rounded())) % \(cupo.nombre)"
        guard let reinicia = cupo.reinicia else { return usado }
        let cuando = reinicia.timeIntervalSince(ahora) < 86_400
            ? reinicia.formatted(date: .omitted, time: .shortened)
            : T("el ", "") + reinicia.formatted(.dateTime.weekday(.abbreviated))
        return T("\(usado) · vuelve \(cuando)", "\(usado) · resets \(cuando)")
    }
}

/// El punto verde que late mientras un agente trabaja.
struct PuntoLatiendo: View {
    @State private var latido = false

    var body: some View {
        Circle().fill(Color(nsColor: NSColor(hex: 0x4CD964))).frame(width: 7, height: 7)
            .scaleEffect(latido ? 1.25 : 0.85)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: latido)
            .onAppear { latido = true }
    }
}

// MARK: - Piezas

/// Texto gris para cuando no hay nada que mostrar.
struct TextoVacio: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }
    var body: some View {
        Text(texto).font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave).fixedSize(horizontal: false, vertical: true)
    }
}

/// Se desplaza si el contenido no entra en el alto del notch (en `--capturas` se corta, porque el dibujante no muestra
/// lo que está dentro de un ScrollView).
struct DesplazableNotch<C: View>: View {
    @ViewBuilder let contenido: C
    @Environment(\.enCapturas) private var enCapturas

    var body: some View {
        if enCapturas {
            contenido.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                contenido.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            }
        }
    }
}

extension EstadoMac {
    /// "3,2 GB" o "850 MB".
    static func gigas(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
