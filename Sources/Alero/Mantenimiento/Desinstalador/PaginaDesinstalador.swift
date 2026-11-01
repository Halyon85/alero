import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Mantenimiento › Desinstalar una app: arrastrar una o varias apps al cuadro (o elegirlas de la lista o del cuadro
// de abrir), revisar la app y sus restos con ruta y tamaño (con varias, un resumen por app) y confirmar. Si alguna
// está abierta pregunta una sola vez antes de cerrarlas. Todo va a la Papelera; lo de `/Library` solo se muestra.

struct PaginaDesinstalador: View {
    @ObservedObject var modelo: ModeloDesinstalador
    @Environment(\.dibujandoMuestra) private var dibujando
    @State private var confirmar = false
    @State private var sobreCuadro = false
    @State private var busqueda = ""

    var body: some View {
        TituloPagina(titulo: T("Desinstalar una app", "Uninstall an app"),
                     subtitulo: T("La app y lo que deja en tu Mac van a la Papelera. Los restos se buscan por el identificador de la app, nunca por el nombre.",
                                  "The app and what it leaves behind go to the Trash. Leftovers are found by the app's identifier, never by name."))
        if let error = modelo.error { AvisoTarjeta(tono: .error, titulo: error) }
        if modelo.lote.count > 1, modelo.estado != .eligiendo {
            cabeceraVarias
            if modelo.estado == .buscando {
                AvisoTarjeta(tono: .info, titulo: T("Buscando restos…", "Looking for leftovers…")) { ProgressView().controlSize(.small) }
            } else {
                if let resultado = modelo.resultado {
                    ResultadoPapelera(resultado: resultado, ocupado: modelo.estado == .desinstalando) { modelo.pasarAFinder() }
                }
                if modelo.estado != .terminado { resumenVarias }
            }
            rechazos
        } else if let app = modelo.app, modelo.estado != .eligiendo {
            cabecera(app)
            if modelo.estado == .buscando {
                AvisoTarjeta(tono: .info, titulo: T("Buscando restos…", "Looking for leftovers…")) { ProgressView().controlSize(.small) }
            } else {
                if let resultado = modelo.resultado {
                    ResultadoPapelera(resultado: resultado, ocupado: modelo.estado == .desinstalando) { modelo.pasarAFinder() }
                }
                if modelo.estado != .terminado { restos(app) }
                if !modelo.recibos.isEmpty { recibos }
            }
            rechazos
        } else {
            cuadroParaSoltar
            rechazos
            lista
        }
    }

    @ViewBuilder private var rechazos: some View {
        ForEach(Array(modelo.rechazos.enumerated()), id: \.offset) { _, rechazo in
            AvisoTarjeta(tono: .error, titulo: T("\(rechazo.nombre) no se puede desinstalar", "\(rechazo.nombre) can't be uninstalled"),
                         detalle: rechazo.motivo)
        }
    }

    // MARK: - Elegir

    private var cuadroParaSoltar: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.app").font(.system(size: 28, weight: .light)).foregroundStyle(sobreCuadro ? Tema.acentoVentana : Tema.apagado)
            Text(T("Arrastrá una o varias apps acá", "Drop one or more apps here")).font(.titulo(15)).foregroundStyle(Tema.titulo)
            Text(T("o elegila de la lista de abajo", "or pick it from the list below")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
        }
        .frame(maxWidth: .infinity).frame(height: 150)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(sobreCuadro ? Tema.relleno : Tema.tarjeta))
        .overlay(RoundedRectangle(cornerRadius: Tema.radioTarjeta)
            .strokeBorder(sobreCuadro ? Tema.acentoVentana : Tema.bordeSuave, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .animation(.easeOut(duration: 0.15), value: sobreCuadro)
        .onDrop(of: [.fileURL], isTargeted: $sobreCuadro) { proveedores in
            ElegirApps.soltadas(proveedores) { modelo.elegir($0) }
        }
    }

    private var lista: some View {
        let filtradas = ModeloDesinstalador.filtrar(modelo.apps, busqueda)
        return Tarjeta(titulo: T("Aplicaciones", "Applications")) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Tema.apagado)
                TextField(T("Buscar", "Search"), text: $busqueda).textFieldStyle(.plain).font(.system(size: 13))
                BotonSecundario(texto: T("Elegir varias…", "Pick several…"), icono: "folder") {
                    let urls = ElegirApps.conPanel()
                    if !urls.isEmpty { modelo.elegir(urls) }
                }
            }
            .padding(.horizontal, 16).frame(height: 48)
            Rectangle().fill(Tema.bordeSuave).frame(height: 1)
            if modelo.apps.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(T("Leyendo Aplicaciones…", "Reading Applications…")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                }
                    .frame(maxWidth: .infinity).frame(height: 60)
            } else if filtradas.isEmpty {
                Text(T("Ninguna app se llama así.", "No app matches that.")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                    .frame(maxWidth: .infinity).frame(height: 60)
            } else if dibujando {
                VStack(spacing: 0) { ForEach(filtradas) { filaApp($0, ultima: $0 == filtradas.last) } }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(filtradas) { filaApp($0, ultima: $0 == filtradas.last) } }
                }
                .frame(height: min(CGFloat(filtradas.count) * 45, 360))
            }
        }
        .onAppear { modelo.cargarLista() }
    }

    private func filaApp(_ app: ModeloDesinstalador.AppDeLista, ultima: Bool) -> some View {
        VStack(spacing: 0) {
            Button { modelo.elegir(app.url) } label: {
                HStack(spacing: 12) {
                    IconoDeApp(url: app.url, lado: 26)
                    Text(app.nombre).font(.titulo(13, .regular)).foregroundStyle(Tema.titulo).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.apagado)
                }
                .padding(.horizontal, 16).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !ultima { Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 54) }
        }
    }


    // MARK: - Revisar y desinstalar

    private func cabecera(_ app: AppElegida) -> some View {
        let ocupado = modelo.estado == .cerrando || modelo.estado == .desinstalando
        let detalle = [app.version.map { T("Versión \($0)", "Version \($0)") }, app.identificador,
                       app.equipo.map { T("Equipo \($0)", "Team \($0)") }].compactMap { $0 }.joined(separator: " · ")
        return Tarjeta {
            TextoYControles(minimoTexto: 240) {
                HStack(spacing: 14) {
                    IconoDeApp(url: app.url, lado: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.nombre).font(.titulo(17, .semibold)).foregroundStyle(Tema.titulo)
                        Text(detalle).font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                        Text(rutaCorta(app.url)).font(.system(size: 11)).foregroundStyle(Tema.apagado).lineLimit(1).truncationMode(.middle)
                    }
                }
                Fluir(espacio: 8) {
                    BotonSecundario(texto: modelo.estado == .terminado ? T("Desinstalar otra", "Uninstall another") : T("Elegir otra", "Pick another"),
                                    icono: "chevron.left") { modelo.volver() }
                        .disabled(ocupado)
                    if ocupado {
                        ProgressView().controlSize(.small)
                    } else if modelo.estado == .listo {
                        BotonPrimario(texto: T("Desinstalar", "Uninstall")) { confirmar = true }
                    }
                }
            }
            .padding(16)
        }
        .alert(T("¿Desinstalar \(app.nombre)?", "Uninstall \(app.nombre)?"), isPresented: $confirmar) {
            Button(T("Mandar a la Papelera", "Move to Trash"), role: .destructive) { modelo.desinstalar() }
            Button(T("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            let cuantos = modelo.elegidos.count
            Text(T("La app y \(cuantos) restos (\(Papelera.texto(modelo.bytesElegidos)) en total) van a la Papelera. Podés sacarlos de ahí mientras no la vacíes.",
                   "The app and \(cuantos) leftovers (\(Papelera.texto(modelo.bytesElegidos)) in total) go to the Trash. You can take them back until you empty it."))
        }
        .alert(T("\(app.nombre) está abierta", "\(app.nombre) is open"),
               isPresented: Binding(get: { !modelo.porCerrar.isEmpty }, set: { if !$0 { modelo.porCerrar = [] } })) {
            Button(T("Cerrar y desinstalar", "Quit and uninstall")) { modelo.cerrarYSeguir() }
            Button(T("Cancelar", "Cancel"), role: .cancel) { modelo.porCerrar = [] }
        } message: {
            Text(T("Para desinstalarla hay que cerrarla. Si tiene algo sin guardar, te lo va a preguntar.",
                   "It has to quit first. If something isn't saved, it will ask you."))
        }
    }

    private func restos(_ app: AppElegida) -> some View {
        let ocupado = modelo.estado != .listo
        return Tarjeta(titulo: T("Qué se va a la Papelera", "What goes to the Trash")) {
            FilaElemento(nombre: app.url.lastPathComponent, url: app.url, tamano: modelo.tamanoApp, nota: T("La app", "The app"),
                         elegida: true, divisor: !modelo.restos.isEmpty, activa: false) {}
            ForEach(Array(modelo.restos.enumerated()), id: \.element.id) { i, resto in
                FilaElemento(nombre: resto.nombre, url: resto.elemento.url, tamano: resto.elemento.tamano,
                             nota: resto.nota ?? resto.carpeta.titulo, elegida: modelo.elegidos.contains(resto.id),
                             divisor: i < modelo.restos.count - 1, activa: !ocupado && !resto.pideAdministrador) { modelo.alternar(resto) }
            }
        }
        .overlay(alignment: .bottom) {
            if modelo.restos.isEmpty {
                Text(T("No se encontraron restos con su identificador.", "No leftovers with its identifier were found."))
                    .font(.system(size: 12)).foregroundStyle(Tema.apagado).offset(y: 24)
            }
        }
    }
}

extension PaginaDesinstalador {
    // MARK: - Varias apps

    private var cabeceraVarias: some View {
        let ocupado = modelo.estado == .cerrando || modelo.estado == .desinstalando
        let cuantas = modelo.lote.count
        return Tarjeta {
            TextoYControles(minimoTexto: 240) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(T("\(cuantas) apps", "\(cuantas) apps")).font(.titulo(17, .semibold)).foregroundStyle(Tema.titulo)
                    Text(modelo.estado == .terminado
                         ? T("\(modelo.appsMovidas) apps a la Papelera", "\(modelo.appsMovidas) apps moved to the Trash")
                         : T("\(Papelera.texto(modelo.bytesElegidos)) en total con sus restos", "\(Papelera.texto(modelo.bytesElegidos)) in total with their leftovers"))
                        .font(.system(size: 12)).foregroundStyle(Tema.apagado)
                }
                Fluir(espacio: 8) {
                    BotonSecundario(texto: modelo.estado == .terminado ? T("Desinstalar otras", "Uninstall others") : T("Elegir otras", "Pick others"),
                                    icono: "chevron.left") { modelo.volver() }
                        .disabled(ocupado)
                    if ocupado {
                        ProgressView().controlSize(.small)
                    } else if modelo.estado == .listo {
                        BotonPrimario(texto: T("Desinstalar todas", "Uninstall all")) { confirmar = true }
                    }
                }
            }
            .padding(16)
        }
        .alert(T("¿Desinstalar \(cuantas) apps?", "Uninstall \(cuantas) apps?"), isPresented: $confirmar) {
            Button(T("Mandar todo a la Papelera", "Move all to Trash"), role: .destructive) { modelo.desinstalar() }
            Button(T("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(T("Las apps y sus restos (\(Papelera.texto(modelo.bytesElegidos)) en total) van a la Papelera. Podés sacarlos de ahí mientras no la vacíes.",
                   "The apps and their leftovers (\(Papelera.texto(modelo.bytesElegidos)) in total) go to the Trash. You can take them back until you empty it."))
        }
        .alert(T("Hay apps abiertas", "Some apps are open"),
               isPresented: Binding(get: { !modelo.porCerrar.isEmpty }, set: { if !$0 { modelo.porCerrar = [] } })) {
            Button(T("Cerrarlas y seguir", "Quit them and go on")) { modelo.cerrarYSeguir() }
            Button(T("Cancelar", "Cancel"), role: .cancel) { modelo.porCerrar = [] }
        } message: {
            Text(T("\(modelo.porCerrar.joined(separator: ", ")): hay que cerrarlas para desinstalarlas. Si tienen algo sin guardar, te lo van a preguntar.",
                   "\(modelo.porCerrar.joined(separator: ", ")): they have to quit first. If something isn't saved, they will ask you."))
        }
    }

    /// Una fila por app con lo que se va a la Papelera (la app y sus restos tildados).
    private var resumenVarias: some View {
        Tarjeta(titulo: T("Qué se va a la Papelera", "What goes to the Trash")) {
            ForEach(Array(modelo.lote.enumerated()), id: \.element.id) { i, preparada in
                let mandados = preparada.restos.filter { modelo.elegidos.contains($0.id) }.count
                let admin = preparada.restos.filter(\.pideAdministrador).count
                let nota = admin > 0
                    ? T("\(mandados) restos · \(admin) piden administrador", "\(mandados) leftovers · \(admin) need admin")
                    : T("\(mandados) restos", "\(mandados) leftovers")
                FilaElemento(nombre: preparada.app.nombre, url: preparada.app.url, tamano: modelo.tamanoElegido(preparada), nota: nota,
                             elegida: true, divisor: i < modelo.lote.count - 1, activa: false) {}
            }
        }
    }

    /// Los recibos del instalador: solo para saber que existen (borrarlos pide administrador y no libera espacio).
    var recibos: some View {
        Tarjeta(titulo: T("Recibos del instalador", "Installer receipts")) {
            ForEach(Array(modelo.recibos.enumerated()), id: \.offset) { i, recibo in
                Fila(titulo: recibo, detalle: T("Lo anotó el instalador (.pkg). Queda: borrarlo pide administrador y no ocupa lugar.",
                                                "Written by the .pkg installer. It stays: removing it needs admin and it takes no space."),
                     divisor: i < modelo.recibos.count - 1) { EmptyView() }
            }
        }
    }
}

/// Elegir apps sin pasos de más: el cuadro de abrir de macOS en Aplicaciones (con ⌘ o ⇧ se eligen varias) y las que
/// se sueltan arrastrando. Lo usan la página y el notch. Las URL van tal cual al modelo, que las valida.
enum ElegirApps {
    /// A propósito no resuelve alias: si la persona elige uno, se rechaza con su explicación. Alero puede no tener
    /// ventana al frente (desde el notch): se activa para que el cuadro aparezca arriba. Vacío si cancela.
    @MainActor
    static func conPanel() -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = T("Elegí las apps que querés desinstalar (con ⌘ elegís varias).", "Pick the apps to uninstall (hold ⌘ for several).")
        panel.prompt = T("Elegir", "Choose")
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Junta las URL de todo lo soltado y las entrega juntas en el hilo principal. Devuelve si había algo.
    static func soltadas(_ proveedores: [NSItemProvider], listo: @escaping ([URL]) -> Void) -> Bool {
        guard !proveedores.isEmpty else { return false }
        let grupo = DispatchGroup()
        let candado = NSLock()
        var urls: [URL] = []
        for proveedor in proveedores {
            grupo.enter()
            _ = proveedor.loadObject(ofClass: URL.self) { url, error in
                if let url {
                    candado.lock()
                    urls.append(url)
                    candado.unlock()
                } else if let error {
                    NSLog("Alero: no se pudo leer lo que se soltó: \(error.localizedDescription)")
                }
                grupo.leave()
            }
        }
        grupo.notify(queue: .main) { if !urls.isEmpty { listo(urls) } }
        return true
    }
}

/// El ícono de una app como lo muestra Finder (sin ícono, el genérico de macOS).
struct IconoDeApp: View {
    let url: URL
    let lado: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable().interpolation(.high)
            .frame(width: lado, height: lado)
    }
}
