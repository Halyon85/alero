import Combine
import SwiftUI
import UniformTypeIdentifiers

// La vista raíz del notch: la forma negra que crece y encoge, y adentro lo que toca según el modo.
// Cerrado no dibuja nada más que la forma (y la música o el punto del café en las alas, si hay).

struct VistaNotch: View {
    @ObservedObject var estado: EstadoNotch
    /// En `--capturas` va en false: el dibujante de imágenes no sabe dibujar la zona de soltar archivos.
    var aceptaArchivos = true
    @ObservedObject private var musica = Musica.shared
    @ObservedObject private var cafe = Cafe.shared
    @ObservedObject private var ajustes = Ajustes.shared
    @Environment(\.accessibilityReduceTransparency) private var reducirTransparencia

    private var musicaSonando: Bool { ajustes.notchMusica && musica.pista?.sonando == true }
    /// Vidrio elegido (y macOS sin "Reducir transparencia").
    private var estiloVidrio: Bool { ajustes.notchEstilo == .vidrio && !reducirTransparencia }

    var body: some View {
        if aceptaArchivos {
            forma.onDrop(of: [.fileURL], isTargeted: $estado.sobreZona, perform: soltar)
        } else {
            forma
        }
    }

    @ViewBuilder private var forma: some View {
        let tamano = Diseno.tamano(estado.modo, estado.medidas, musica: musicaSonando, punto: cafe.prendido)
        let radios = Diseno.radios(estado.modo)
        ZStack(alignment: .top) {
            FondoNotch(forma: FormaNotch(hombro: radios.hombro, esquina: radios.esquina), estiloVidrio: estiloVidrio,
                       grande: estado.modo.esGrande, nivel: ajustes.notchVidrio, franja: estado.medidas.alto, alto: tamano.height)
            contenido
                .frame(width: tamano.width, height: tamano.height, alignment: .top)
                .clipped()
        }
        .frame(width: tamano.width + 2 * radios.hombro, height: tamano.height)
        .shadow(color: .black.opacity(estado.modo.conSombra ? 0.5 : 0), radius: 14, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var contenido: some View {
        ZStack(alignment: .top) {
            switch estado.modo {
            case .cerrado:
                if musicaSonando {
                    CerradoMusica(medidas: estado.medidas).transition(.entradaNotch)
                } else if cafe.prendido {
                    CerradoPunto(medidas: estado.medidas).transition(.opacity)
                }
            case .aviso:
                if let aviso = estado.aviso { VistaAviso(aviso: aviso, medidas: estado.medidas).transition(.entradaNotch) }
            case .hud:
                VistaHud(estado: estado).transition(.entradaNotch)
            case .atajos:
                VistaAtajos(estado: estado).transition(.entradaNotch)
            case .abierto:
                VistaAbiertaNotch(estado: estado).transition(.entradaNotch)
            case .estante:
                VistaSoltar(estado: estado).transition(.entradaNotch)
            case .captura:
                VistaCaptura(estado: estado, arrastrable: aceptaArchivos).transition(.entradaNotch)
            case .prompter:
                VistaPrompter(estado: estado).transition(.entradaNotch)
            }
        }
    }

    /// Archivos soltados sobre el notch: van al estante y el notch avisa cuántos sumó.
    private func soltar(_ proveedores: [NSItemProvider]) -> Bool {
        let grupo = DispatchGroup()
        var urls: [URL] = []
        let candado = NSLock()
        for proveedor in proveedores where proveedor.canLoadObject(ofClass: URL.self) {
            grupo.enter()
            _ = proveedor.loadObject(ofClass: URL.self) { url, error in
                if let error { NSLog("Alero: no se pudo leer un archivo soltado: \(error.localizedDescription)") }
                if let url { candado.lock(); urls.append(url); candado.unlock() }
                grupo.leave()
            }
        }
        grupo.notify(queue: .main) {
            let sumados = Estante.shared.agregar(urls)
            estado.cerrar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { estado.mostrar(.estante(sumados: sumados), durante: 2) }
        }
        return true
    }
}

// MARK: - Fondo

/// El fondo del notch: negro, o vidrio con una franja negra arriba que se funde hacia abajo (así no se nota el corte
/// con la cámara).
///
/// El vidrio es el desenfoque de macOS de lo que hay detrás de la ventana (`NSVisualEffectView`), recortado con la misma
/// forma animada del notch: crece junto con el notch desde el primer cuadro. Encima hay una capa negra que se desvanece
/// con la misma animación de abrir y vuelve con la de cerrar (el notch cerrado tiene que seguir igual al de la Mac).
/// Historia (01/11/2026): con el vidrio de SwiftUI se veía primero el vidrio con su tamaño final y después el
/// notch; esperar a que terminara de abrirse lo dejaba un segundo en negro.
struct FondoNotch: View {
    let forma: FormaNotch
    let estiloVidrio: Bool
    /// El notch está abierto (o en el estante): se ve el vidrio.
    let grande: Bool
    /// 0…1: cuánto se ve a través.
    let nivel: Double
    /// Alto de la franja de la cámara (siempre negra).
    let franja: CGFloat
    let alto: CGFloat
    /// En `--capturas` el dibujante no puede dibujar el desenfoque (saldría un cuadro amarillo): va solo el degradé.
    @Environment(\.enCapturas) private var enCapturas

    var body: some View {
        ZStack {
            if estiloVidrio {
                if !enCapturas { DesenfoqueDetras(visible: grande).clipShape(forma) }
                forma.fill(degrade)
            }
            forma.fill(Tema.notch).opacity(estiloVidrio && grande ? 0 : 1)
        }
    }

    /// Negro entero en la franja de la cámara y después, en 28 pt, baja a la opacidad elegida.
    private var degrade: LinearGradient {
        let corte = alto > 0 ? min(franja / alto, 1) : 0
        let fin = alto > 0 ? min((franja + 28) / alto, 1) : 1
        let abajo = Color.black.opacity(1 - nivel * 0.8)
        return LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: corte),
                                      .init(color: abajo, location: fin), .init(color: abajo, location: 1)],
                              startPoint: .top, endPoint: .bottom)
    }
}

/// El desenfoque de lo que hay detrás de la ventana. Con el notch cerrado se esconde (medio segundo después, cuando
/// terminó la animación de cerrar): así macOS no calcula el desenfoque todo el tiempo.
struct DesenfoqueDetras: NSViewRepresentable {
    let visible: Bool

    final class Coordinador { var visible = false }

    func makeCoordinator() -> Coordinador { Coordinador() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let vista = NSVisualEffectView()
        vista.material = .hudWindow
        vista.blendingMode = .behindWindow
        vista.state = .active
        vista.isHidden = !visible
        context.coordinator.visible = visible
        return vista
    }

    func updateNSView(_ vista: NSVisualEffectView, context: Context) {
        let coordinador = context.coordinator
        coordinador.visible = visible
        if visible {
            vista.isHidden = false
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak vista] in
                if !coordinador.visible { vista?.isHidden = true }
            }
        }
    }
}

// MARK: - Alas: lo que va a cada lado de la cámara

/// Reparte el contenido a izquierda y derecha del notch físico (lo que cae sobre la cámara no se ve).
struct Alas<Izquierda: View, Derecha: View>: View {
    let medidas: MedidasNotch
    var margen: CGFloat = 10
    @ViewBuilder let izquierda: Izquierda
    @ViewBuilder let derecha: Derecha

    var body: some View {
        HStack(spacing: 0) {
            izquierda.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: medidas.ancho)
            derecha.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, margen)
        .frame(height: medidas.alto)
    }
}

// MARK: - Cerrado

struct CerradoMusica: View {
    let medidas: MedidasNotch
    @ObservedObject private var musica = Musica.shared

    var body: some View {
        Alas(medidas: medidas, margen: 8) {
            Caratula(imagen: musica.caratula, lado: 22, radio: 5)
        } derecha: {
            Barras(color: musica.color, sonando: musica.pista?.sonando == true)
        }
    }
}

/// El café prendido con el notch cerrado: una tacita celeste a la derecha de la cámara (antes era un punto y no se
/// entendía qué era, 01/11/2026).
struct CerradoPunto: View {
    let medidas: MedidasNotch
    var body: some View {
        Alas(medidas: medidas, margen: 7) {
            EmptyView()
        } derecha: {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tema.acento)
                .help(T("Café prendido: la Mac no se duerme", "Coffee on: the Mac stays awake"))
        }
    }
}

/// Cuatro barritas que "bailan" con el color de la carátula. No leen el audio (eso pediría grabarlo): se mueven
/// al azar mientras suena, como en el iPhone. El reloj existe solo mientras se ven.
struct Barras: View {
    let color: Color
    let sonando: Bool
    @State private var alturas: [CGFloat] = [0.5, 0.85, 0.4, 0.7]
    private let reloj = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(color).frame(width: 3, height: 14 * (sonando ? alturas[i] : 0.25))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .onReceive(reloj) { _ in
            guard sonando else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                alturas = (0..<4).map { _ in .random(in: 0.35...1) }
            }
        }
    }
}

struct Caratula: View {
    let imagen: NSImage?
    let lado: CGFloat
    let radio: CGFloat

    var body: some View {
        ZStack {
            if let imagen {
                Image(nsImage: imagen).resizable().aspectRatio(contentMode: .fill)
            } else {
                Tema.rellenoNotch
                Image(systemName: "music.note").font(.system(size: lado * 0.42, weight: .semibold)).foregroundStyle(Tema.textoNotchSuave)
            }
        }
        .frame(width: lado, height: lado)
        .clipShape(RoundedRectangle(cornerRadius: radio, style: .continuous))
    }
}

// MARK: - Avisos

struct VistaAviso: View {
    let aviso: AvisoNotch
    let medidas: MedidasNotch

    var body: some View {
        Alas(medidas: medidas, margen: 14) {
            HStack(spacing: 7) {
                Image(systemName: icono).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tema.acento)
                Text(izquierda).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
        } derecha: {
            Text(derecha).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tema.acento).lineLimit(1)
        }
        .foregroundStyle(Tema.textoNotch)
    }

    private var icono: String {
        switch aviso {
        case .reunion: return "calendar"
        case .salida(let tipo, _): return VistaAviso.icono(de: tipo)
        case .cafe: return "cup.and.saucer.fill"
        case .estante: return "tray.and.arrow.down.fill"
        case .cortar: return "scissors"
        case .pegar(_, let fallidos, _): return fallidos == 0 ? "folder.fill" : "exclamationmark.triangle.fill"
        case .permiso: return "hand.raised.fill"
        case .capturaFallo: return "exclamationmark.triangle.fill"
        case .corriente(let enchufada, let porcentaje):
            if enchufada { return "bolt.fill" }
            let p = porcentaje ?? 100
            return p > 75 ? "battery.100percent" : p > 50 ? "battery.75percent" : p > 25 ? "battery.50percent" : "battery.25percent"
        case .descarga: return "arrow.down.circle.fill"
        }
    }

    private var izquierda: String {
        switch aviso {
        case .reunion(let titulo, _): return titulo
        case .salida(_, let nombre): return nombre
        case .cafe: return T("Café", "Coffee")
        case .estante: return T("Estante", "Shelf")
        case .cortar: return T("Cortado", "Cut")
        case .pegar(let movidos, let fallidos, _):
            if fallidos == 0 { return T("Movido", "Moved") }
            return movidos == 0 ? T("No se movió", "Not moved") : T("Movidos \(movidos)", "Moved \(movidos)")
        case .permiso: return T("Falta permiso", "Permission needed")
        case .capturaFallo: return T("No se guardó", "Not saved")
        case .corriente(let enchufada, _): return enchufada ? T("Cargando", "Charging") : T("Con batería", "On battery")
        case .descarga(let nombre): return nombre
        }
    }

    private var derecha: String {
        switch aviso {
        case .reunion(_, let minutos): return minutos <= 0 ? T("ahora", "now") : T("en \(minutos) min", "in \(minutos) min")
        case .salida: return T("Conectado", "Connected")
        case .cafe(let prendido): return prendido ? T("Prendido", "On") : T("Apagado", "Off")
        case .estante(let sumados): return sumados > 0 ? "+\(sumados)" : T("Ya estaba", "Already there")
        case .cortar(let cantidad): return VistaAviso.archivos(cantidad)
        case .pegar(let movidos, let fallidos, let sinPermiso):
            if fallidos == 0 { return VistaAviso.archivos(movidos) }
            return sinPermiso ? T("Sin permiso", "No access") : T("\(fallidos) con error", "\(fallidos) failed")
        case .permiso(let nombre): return nombre
        case .capturaFallo(let copiada): return copiada ? T("Quedó copiada", "Copied anyway") : T("Probá de nuevo", "Try again")
        case .corriente(_, let porcentaje): return porcentaje.map { "\($0) %" } ?? ""
        case .descarga: return T("Descargado", "Downloaded")
        }
    }

    static func archivos(_ cantidad: Int) -> String {
        cantidad == 1 ? T("1 archivo", "1 file") : T("\(cantidad) archivos", "\(cantidad) files")
    }

    static func icono(de tipo: Salida.Tipo) -> String {
        switch tipo {
        case .parlantes: return "laptopcomputer"
        case .auriculares, .bluetooth: return "headphones"
        case .monitor: return "display"
        case .airplay: return "airplayaudio"
        case .otro: return "hifispeaker"
        }
    }
}

struct VistaHud: View {
    @ObservedObject var estado: EstadoNotch

    var body: some View {
        Alas(medidas: estado.medidas, margen: 14) {
            Image(systemName: icono).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tema.textoNotch)
                .frame(width: 20, alignment: .leading)
        } derecha: {
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Tema.textoNotch).frame(width: geo.size.width * CGFloat(estado.hudSilencio ? 0 : estado.hudValor))
                    }
                }
                .frame(width: 72, height: 5)
                Text("\(Int((estado.hudSilencio ? 0 : estado.hudValor) * 100))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tema.textoNotchSuave)
                    .frame(width: 24, alignment: .trailing)
            }
        }
    }

    private var icono: String {
        if estado.hudTipo == .brillo { return "sun.max.fill" }
        if estado.hudTipo == .teclado { return estado.hudValor == 0 ? "light.min" : "light.max" }
        if estado.hudSilencio || estado.hudValor == 0 { return "speaker.slash.fill" }
        return estado.hudValor < 0.34 ? "speaker.wave.1.fill" : estado.hudValor < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

// MARK: - Atajos (al deslizar sobre el notch)

/// Los atajos que elegiste en Ajustes, repartidos a los dos lados de la cámara (la primera mitad a la izquierda).
struct VistaAtajos: View {
    @ObservedObject var estado: EstadoNotch
    @ObservedObject private var ajustes = Ajustes.shared

    var body: some View {
        let elegidos = ajustes.notchAtajosElegidos
        let mitad = (elegidos.count + 1) / 2
        Alas(medidas: estado.medidas, margen: 8) {
            HStack(spacing: 4) { ForEach(elegidos.prefix(mitad)) { BotonDeAtajo(atajo: $0, estado: estado) } }
        } derecha: {
            HStack(spacing: 4) { ForEach(elegidos.dropFirst(mitad)) { BotonDeAtajo(atajo: $0, estado: estado) } }
        }
    }
}

/// Un atajo como botón, en los atajos al deslizar. Qué hace cada uno está en `AccionesNotch`.
struct BotonDeAtajo: View {
    let atajo: AtajoNotch
    @ObservedObject var estado: EstadoNotch
    @ObservedObject private var ajustes = Ajustes.shared
    @ObservedObject private var cafe = Cafe.shared
    @ObservedObject private var sonido = Sonido.shared

    var body: some View {
        BotonAtajo(icono: AccionesNotch.icono(atajo), etiqueta: AccionesNotch.etiqueta(atajo), activo: AccionesNotch.activo(atajo, estado: estado)) {
            AccionesNotch.ejecutar(atajo, estado: estado)
        }
    }
}

/// Qué hace cada atajo, cuándo se ve activo y con qué ícono: lo mismo en los atajos al deslizar y en la barra del notch
/// abierto. Las vistas que los usan observan Café, Sonido y Ajustes para redibujarse.
enum AccionesNotch {
    static func icono(_ atajo: AtajoNotch) -> String {
        switch atajo {
        case .cafe: return Cafe.shared.prendido ? "cup.and.saucer.fill" : "cup.and.saucer"
        case .salida: return VistaAviso.icono(de: Sonido.shared.salidaActual?.tipo ?? .otro)
        case .iconoBarra: return Ajustes.shared.iconoBarra ? "menubar.rectangle" : "menubar.dock.rectangle"
        default: return atajo.icono
        }
    }

    /// El nombre y, si sirve, el estado ("Café hasta 15:30").
    static func etiqueta(_ atajo: AtajoNotch) -> String {
        let cafe = Cafe.shared
        if atajo == .cafe, cafe.prendido, let hasta = cafe.hasta {
            return T("Café hasta las \(hasta.formatted(date: .omitted, time: .shortened))", "Coffee until \(hasta.formatted(date: .omitted, time: .shortened))")
        }
        if atajo == .salida, let salida = Sonido.shared.salidaActual { return atajo.nombre + ": " + salida.nombre }
        return atajo.nombre
    }

    static func activo(_ atajo: AtajoNotch, estado: EstadoNotch) -> Bool {
        switch atajo {
        case .cafe: return Cafe.shared.prendido
        case .silencio: return Sonido.shared.silenciado() == true
        case .iconoBarra: return !Ajustes.shared.iconoBarra
        default: return false
        }
    }

    static func ejecutar(_ atajo: AtajoNotch, estado: EstadoNotch) {
        switch atajo {
        case .cafe:
            let cafe = Cafe.shared
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { cafe.alternar() }
            if estado.modo != .abierto { estado.mostrar(.cafe(prendido: cafe.prendido), durante: 1.8) }
        case .estante:
            withAnimation(Diseno.cambio) { estado.abrir(.estante) }
        case .captura:
            estado.cerrar()
            Capturador.shared.empezar(.area)
        case .prompter:
            ControladorNotch.shared.abrirPrompter(en: estado)
        case .salida:
            Sonido.shared.siguiente()
        case .silencio:
            let sonido = Sonido.shared
            let silencio = !(sonido.silenciado() ?? false)
            sonido.ponerSilencio(silencio)
            if estado.modo != .abierto { estado.mostrarHud(.volumen, valor: sonido.volumen() ?? 0, silencio: silencio) }
        case .iconoBarra:
            Ajustes.shared.iconoBarra.toggle()
        case .ajustes:
            estado.cerrar()
            VentanaAlero.shared.mostrar()
        }
    }
}

struct BotonAtajo: View {
    let icono: String
    let etiqueta: String
    let activo: Bool
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: icono)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 24)
                .foregroundStyle(activo ? Tema.acento : Tema.textoNotch)
                .background(activo ? Tema.acentoFondo : Tema.rellenoNotch, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(BotonPresionable())
        .help(etiqueta)
        .accessibilityLabel(etiqueta)
    }
}

/// Botón que se achica un poco al apretarlo (respuesta táctil sin háptica).
struct BotonPresionable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
