import AppKit
import SwiftUI

// La columna de sonido del notch abierto (se abre con el ícono de parlante junto a los controles): arriba la salida
// de sonido, debajo el volumen de cada app que está sonando y, si hay un monitor además de la MacBook, el brillo de
// cada pantalla. Si no entra en el alto del notch, se desplaza.
//
// Mientras se ve, le avisa al mezclador (que escucha a Core Audio solo si hace falta) y a los monitores (que vuelven
// a leer el brillo de verdad).

struct ColumnaSonido: View {
    @ObservedObject private var mezclador = Mezclador.shared
    @ObservedObject private var monitores = Monitores.shared
    @ObservedObject private var ajustes = Ajustes.shared
    @Environment(\.enCapturas) private var enCapturas

    private var conApps: Bool { Mezclador.disponible && ajustes.mezcladorActivo }
    private var conPantallas: Bool { ajustes.brilloMonitores && monitores.hayExternos }

    var body: some View {
        Group {
            // El dibujante de `--capturas` no muestra lo que está dentro de un ScrollView.
            if enCapturas {
                // Se corta en el alto disponible, como se vería sin desplazar.
                contenido.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) { contenido.padding(.bottom, 10) }
                    // Un fundido abajo avisa que hay más (con poco contenido cae sobre el margen vacío).
                    .mask(VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    })
            }
        }
        .onAppear {
            Mezclador.shared.mirar(true)
            Monitores.shared.mirar()
        }
        .onDisappear { Mezclador.shared.mirar(false) }
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: 12) {
            ListaSalidas()
            if conApps { SeccionApps() }
            if conPantallas { SeccionPantallas() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Título chico de cada sección de la columna.
struct TituloSeccionNotch: View {
    let texto: String
    var body: some View {
        Text(texto).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Tema.textoNotchSuave)
    }
}

/// Las salidas de sonido en lista (como en el Centro de control): tocar una pasa el sonido ahí. Con más de dos,
/// se ve solo la elegida y el resto se despliega con "N más" (así el volumen por app entra sin desplazar).
struct ListaSalidas: View {
    @ObservedObject private var sonido = Sonido.shared
    @State private var desplegada = false

    private var plegable: Bool { sonido.salidas.count > 2 }
    private var visibles: [Salida] {
        plegable && !desplegada ? sonido.salidas.filter { $0.id == sonido.actual } : sonido.salidas
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TituloSeccionNotch(texto: T("SALIDA DE SONIDO", "SOUND OUTPUT"))
                Spacer(minLength: 4)
                if plegable {
                    Button { withAnimation(Diseno.cambio) { desplegada.toggle() } } label: {
                        HStack(spacing: 3) {
                            Text(desplegada ? T("Menos", "Less") : T("\(sonido.salidas.count - 1) más", "\(sonido.salidas.count - 1) more"))
                            Image(systemName: "chevron.down").rotationEffect(.degrees(desplegada ? 180 : 0))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tema.textoNotchSuave)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(BotonPresionable())
                    .accessibilityLabel(desplegada ? T("Mostrar solo la salida elegida", "Show only the current output")
                                                   : T("Mostrar todas las salidas", "Show all outputs"))
                }
            }
            ForEach(visibles) { salida in
                let elegida = salida.id == sonido.actual
                Button {
                    sonido.elegir(salida)
                    withAnimation(Diseno.cambio) { desplegada = false }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: VistaAviso.icono(de: salida.tipo))
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(elegida ? Color.black : Tema.textoNotch)
                            .background(elegida ? Tema.acento : Tema.rellenoNotch, in: Circle())
                        Text(salida.nombre).font(.system(size: 12, weight: elegida ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(BotonPresionable())
                .accessibilityAddTraits(elegida ? .isSelected : [])
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Volumen por app

struct SeccionApps: View {
    @ObservedObject private var mezclador = Mezclador.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TituloSeccionNotch(texto: T("VOLUMEN POR APP", "APP VOLUME"))
            if mezclador.permiso == .negado {
                VStack(alignment: .leading, spacing: 6) {
                    Text(T("Para bajar una app, Alero necesita el permiso de Grabación de audio del sistema.",
                           "To lower an app, Alero needs the System Audio Recording permission."))
                        .font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave).fixedSize(horizontal: false, vertical: true)
                    Button(T("Dar permiso", "Allow")) { PermisoAudio.abrirAjustes() }.buttonStyle(BotonPastilla())
                }
            } else if mezclador.apps.isEmpty {
                Text(T("Ninguna app está sonando.", "No app is playing.")).font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave)
            } else {
                ForEach(mezclador.apps) { app in FilaApp(app: app) }
            }
        }
    }
}

struct FilaApp: View {
    let app: AppAudio

    /// Lo que lee VoiceOver en el botón de silencio (dice qué app y qué va a pasar).
    private var etiquetaSilencio: String {
        app.silencio ? T("Volver a escuchar \(app.nombre)", "Unmute \(app.nombre)") : T("Silenciar \(app.nombre)", "Mute \(app.nombre)")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FilaApp.icono(de: app)).resizable().interpolation(.high).frame(width: 22, height: 22)
                .opacity(app.sonando ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(app.nombre).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if app.fallo {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Tema.textoNotchSuave)
                            .help(T("macOS no dejó ajustarla: suena normal. Mové el deslizador para probar de nuevo.",
                                    "macOS didn't allow adjusting it: it plays normally. Move the slider to try again."))
                    } else {
                        Text(app.silencio ? T("silencio", "muted") : "\(Int((app.volumen * 100).rounded())) %")
                            .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Tema.textoNotchSuave)
                    }
                }
                DeslizadorNotch(valor: app.volumen, apagado: app.silencio || app.fallo, etiqueta: T("Volumen de \(app.nombre)", "\(app.nombre) volume")) {
                    Mezclador.shared.cambiar(app.id, volumen: $0)
                }
            }
            Button { Mezclador.shared.alternarSilencio(app.id) } label: {
                Image(systemName: app.silencio ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(app.silencio ? Tema.acento : Tema.textoNotch)
                    .background(app.silencio ? Tema.acentoFondo : Tema.rellenoNotch, in: Circle())
            }
            .buttonStyle(BotonPresionable())
            .help(app.silencio ? T("Volver a escuchar", "Unmute") : T("Silenciar", "Mute"))
            .accessibilityLabel(etiquetaSilencio)
        }
    }

    /// El ícono de la app abierta; si no (capturas de ejemplo), el de su identificador; si no, uno genérico. Se pasa a
    /// un mapa de bits chico y se guarda por app: los íconos de macOS traen todos los tamaños hasta 1024 px y la fila se
    /// redibuja con cada movimiento del deslizador.
    static func icono(de app: AppAudio) -> NSImage {
        if let guardado = iconos.object(forKey: app.id as NSString) { return guardado }
        let original: NSImage
        if let icono = NSRunningApplication(processIdentifier: app.pid)?.icon {
            original = icono
        } else if let bundle = app.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            original = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            original = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        let chico = achicar(original, lado: 22)
        iconos.setObject(chico, forKey: app.id as NSString)
        return chico
    }

    private static let iconos = NSCache<NSString, NSImage>()

    private static func achicar(_ imagen: NSImage, lado: CGFloat) -> NSImage {
        let pixeles = Int(lado * 2)
        guard let mapa = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixeles, pixelsHigh: pixeles, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) else { return imagen }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: mapa)
        imagen.draw(in: NSRect(x: 0, y: 0, width: pixeles, height: pixeles))
        NSGraphicsContext.restoreGraphicsState()
        let chica = NSImage(size: NSSize(width: lado, height: lado))
        chica.addRepresentation(mapa)
        return chica
    }
}

// MARK: - Pantallas

struct SeccionPantallas: View {
    @ObservedObject private var monitores = Monitores.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TituloSeccionNotch(texto: T("PANTALLAS", "DISPLAYS"))
            ForEach(monitores.lista) { monitor in FilaPantalla(monitor: monitor) }
        }
    }
}

struct FilaPantalla: View {
    let monitor: Monitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: monitor.integrada ? "laptopcomputer" : "display")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(Tema.textoNotch)
                .background(Tema.rellenoNotch, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(monitor.nombre).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(detalle).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Tema.textoNotchSuave)
                }
                if monitor.metodo.controlable {
                    DeslizadorNotch(valor: monitor.nivel ?? 1, apagado: false, etiqueta: T("Brillo de \(monitor.nombre)", "\(monitor.nombre) brightness")) {
                        Monitores.shared.poner(monitor.id, nivel: $0)
                    }
                } else {
                    DeslizadorNotch(valor: 0, apagado: true, etiqueta: monitor.nombre) { _ in }.allowsHitTesting(false)
                }
            }
            Image(systemName: "sun.max.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tema.textoNotchSuave)
                .frame(width: 22, height: 22)
        }
        .help(monitor.metodo.nombre)
    }

    private var detalle: String {
        switch monitor.metodo {
        case .buscando: return "…"
        case .ninguno: return T("sin control", "not adjustable")
        default: return monitor.nivel.map { "\(Int(($0 * 100).rounded())) %" } ?? "–"
        }
    }
}

// MARK: - Deslizador

/// Deslizador del notch: una barra gruesa como la del Centro de control, que se agranda un poco mientras se arrastra.
/// Se toca o se arrastra en cualquier punto (sin perilla que apuntar) y con VoiceOver sube y baja de a 10 %.
struct DeslizadorNotch: View {
    let valor: Float
    let apagado: Bool
    let etiqueta: String
    let cambiar: (Float) -> Void
    @State private var arrastrando = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(apagado ? Tema.textoNotchSuave.opacity(0.6) : Tema.textoNotch)
                    .frame(width: geo.size.width * CGFloat(min(max(valor, 0), 1)))
            }
            .frame(height: arrastrando ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesto in
                    arrastrando = true
                    cambiar(Float(min(max(gesto.location.x / max(geo.size.width, 1), 0), 1)))
                }
                .onEnded { _ in arrastrando = false })
        }
        .frame(height: 12)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: arrastrando)
        .accessibilityElement()
        .accessibilityLabel(etiqueta)
        .accessibilityValue("\(Int((valor * 100).rounded())) %")
        .accessibilityAdjustableAction { direccion in
            switch direccion {
            case .increment: cambiar(min(valor + 0.1, 1))
            case .decrement: cambiar(max(valor - 0.1, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Modo capturas

private struct ClaveEnCapturas: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Se dibuja para `--capturas` (sin ScrollView, que el dibujante no muestra).
    var enCapturas: Bool {
        get { self[ClaveEnCapturas.self] }
        set { self[ClaveEnCapturas.self] = newValue }
    }
}
