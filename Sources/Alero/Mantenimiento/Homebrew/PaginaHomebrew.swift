import SwiftUI

// Mantenimiento › Homebrew: lo instalado (fórmulas y apps), lo que tiene actualización, buscar, y actualizar uno o
// todo, desinstalar, limpiar versiones viejas y buscar novedades. La salida de brew se ve en vivo. Si Homebrew no
// está, lo dice con el link a brew.sh. Una operación a la vez.

struct PaginaHomebrew: View {
    @ObservedObject var modelo: ModeloHomebrew
    @Environment(\.dibujandoMuestra) private var dibujando
    @State private var aDesinstalar: PaqueteBrew?
    @State private var confirmarLimpiar = false

    var body: some View {
        TituloPagina(titulo: "Homebrew", subtitulo: T("Lo que instalaste desde la Terminal con Homebrew, al día.",
                                                      "What you installed from Terminal with Homebrew, up to date."))
        Group {
            switch modelo.estado {
            case .sinLeer, .leyendo:
                AvisoTarjeta(tono: .info, titulo: T("Leyendo lo instalado…", "Reading what's installed…")) { ProgressView().controlSize(.small) }
            case .sinHomebrew:
                AvisoTarjeta(tono: .info, titulo: T("Homebrew no está instalado", "Homebrew isn't installed"),
                             detalle: T("Es la forma más usada de instalar programas desde la Terminal en la Mac. Se instala desde su página.",
                                        "It's the most popular way to install programs from Terminal on a Mac. Install it from its website.")) {
                    BotonPrimario(texto: T("Abrir brew.sh", "Open brew.sh")) { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                }
            case .errorLectura(let mensaje):
                AvisoTarjeta(tono: .error, titulo: T("No se pudo leer Homebrew", "Couldn't read Homebrew"), detalle: mensaje) {
                    BotonSecundario(texto: T("Probar de nuevo", "Try again"), icono: "arrow.clockwise") { modelo.cargar() }
                }
            case .listo:
                encabezado
                if modelo.enCurso != nil || modelo.terminada != nil { estadoYSalida }
                filtros
                lista
            }
        }
        .onAppear { if modelo.estado == .sinLeer { modelo.cargar() } }
        .alert(T("¿Desinstalar \(aDesinstalar?.nombre ?? "")?", "Uninstall \(aDesinstalar?.nombre ?? "")?"),
               isPresented: Binding(get: { aDesinstalar != nil }, set: { if !$0 { aDesinstalar = nil } })) {
            Button(T("Desinstalar", "Uninstall"), role: .destructive) {
                if let p = aDesinstalar { modelo.correr(.desinstalar(p.nombre, p.tipo)) }
                aDesinstalar = nil
            }
            Button(T("Cancelar", "Cancel"), role: .cancel) { aDesinstalar = nil }
        } message: {
            Text(T("Lo borra Homebrew directamente (no pasa por la Papelera). Se puede volver a instalar con brew.",
                   "Homebrew removes it directly (it doesn't go to the Trash). You can install it again with brew."))
        }
        .alert(T("¿Limpiar Homebrew?", "Clean up Homebrew?"), isPresented: $confirmarLimpiar) {
            Button(T("Limpiar", "Clean up"), role: .destructive) { modelo.correr(.limpiar) }
            Button(T("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(T("Corre `brew cleanup`: borra las versiones viejas y las descargas que ya no se usan. Lo borra Homebrew, sin Papelera.",
                   "Runs `brew cleanup`: removes old versions and downloads no longer used. Homebrew deletes them, no Trash."))
        }
    }

    private var ocupado: Bool { modelo.enCurso != nil }

    private var encabezado: some View {
        let cuantos = modelo.paquetes.count
        let nuevos = modelo.actualizables
        return Tarjeta {
            Fila(titulo: modelo.version,
                 detalle: T("\(cuantos) instalados · \(nuevos) con actualización", "\(cuantos) installed · \(nuevos) outdated"), divisor: false) {
                BotonSecundario(texto: T("Buscar novedades", "Check for updates"), icono: "arrow.triangle.2.circlepath") {
                    modelo.correr(.actualizarHomebrew)
                }
                .disabled(ocupado)
                BotonSecundario(texto: T("Limpiar", "Clean up"), icono: "sparkles") { confirmarLimpiar = true }.disabled(ocupado)
                if nuevos > 0 {
                    BotonPrimario(texto: T("Actualizar todo (\(nuevos))", "Upgrade all (\(nuevos))")) { modelo.correr(.actualizarTodo) }
                        .disabled(ocupado).opacity(ocupado ? 0.4 : 1)
                }
            }
        }
    }

    private var estadoYSalida: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                iconoEstado
                VStack(alignment: .leading, spacing: 2) {
                    Text(tituloEstado).font(.titulo(14)).foregroundStyle(Tema.titulo)
                    if let detalle = detalleEstado { Text(detalle).font(.system(size: 12)).foregroundStyle(Tema.apagado) }
                }
                Spacer()
                if ocupado {
                    BotonSecundario(texto: T("Cancelar", "Cancel"), icono: "stop.fill", peligro: true) { modelo.cancelar() }
                } else if modelo.terminada?.pideContrasena == true {
                    BotonPrimario(texto: T("Abrir en la Terminal", "Open in Terminal")) { modelo.abrirEnTerminal() }
                }
            }
            .padding(16)
            SalidaBrew(lineas: modelo.salida, desplazable: !dibujando)
                .padding([.horizontal, .bottom], 12)
        }
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .shadow(color: .black.opacity(0.02), radius: 4, y: 2)
    }

    @ViewBuilder private var iconoEstado: some View {
        if ocupado {
            ProgressView().controlSize(.small).frame(width: 18)
        } else if modelo.terminada?.fin == .bien {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Tema.exito)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(Tema.error)
        }
    }

    private var tituloEstado: String {
        if let enCurso = modelo.enCurso { return enCurso.titulo + "…" }
        guard let terminada = modelo.terminada else { return "" }
        switch terminada.fin {
        case .bien: return T("Listo", "Done")
        case .cancelado: return T("Cancelado", "Cancelled")
        case .colgado: return T("Se cortó: no respondía", "Stopped: it wasn't responding")
        case .fallo(let codigo): return T("Homebrew terminó con un error (\(codigo))", "Homebrew ended with an error (\(codigo))")
        case .noArranco(let mensaje): return T("No arrancó: \(mensaje)", "Didn't start: \(mensaje)")
        }
    }

    private var detalleEstado: String? {
        if modelo.enCurso != nil { return T("Podés cerrar la ventana: sigue hasta terminar.", "You can close the window: it keeps going until done.") }
        if modelo.terminada?.pideContrasena == true {
            return T("Pide la contraseña de administrador. Alero no la maneja: abrilo en la Terminal y escribila ahí.",
                     "It needs the admin password. Alero doesn't handle it: open it in Terminal and type it there.")
        }
        return modelo.terminada.map { $0.operacion.titulo }
    }

    private var filtros: some View {
        HStack(spacing: 12) {
            Segmentos(valor: $modelo.vista, opciones: ModeloHomebrew.Vista.allCases) { $0.nombre }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Tema.apagado)
                TextField(T("Buscar", "Search"), text: $modelo.busqueda).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tema.relleno))
        }
    }

    private var lista: some View {
        let visibles = modelo.visibles
        return Tarjeta {
            if visibles.isEmpty {
                Text(modelo.vista == .actualizables ? T("Todo está al día.", "Everything is up to date.") : T("Nada coincide.", "Nothing matches."))
                    .font(.system(size: 12)).foregroundStyle(Tema.apagado).frame(maxWidth: .infinity).frame(height: 60)
            }
            ForEach(Array(visibles.enumerated()), id: \.element.id) { i, paquete in
                filaPaquete(paquete, divisor: i < visibles.count - 1)
            }
        }
    }

    private func filaPaquete(_ p: PaqueteBrew, divisor: Bool) -> some View {
        let version = p.nueva.map { "\(p.version) → \($0)" } ?? p.version
        let tamano = p.tamano.map { " · " + Papelera.texto($0) } ?? ""
        return Fila(titulo: p.nombre, detalle: [p.descripcion, version + tamano].compactMap { $0 }.joined(separator: "\n"),
                    divisor: divisor, minimoTexto: 260) {
            Text(p.fijado ? T("Fijada", "Pinned") : (p.pedido ? p.tipo.nombre : T("Dependencia", "Dependency")))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Tema.subtitulo)
                .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Tema.relleno))
            if p.nueva != nil && !p.fijado {
                BotonSecundario(texto: T("Actualizar", "Upgrade"), icono: "arrow.up.circle") { modelo.correr(.actualizar(p.nombre, p.tipo)) }
                    .disabled(ocupado)
            }
            BotonSecundario(texto: "", icono: "trash", peligro: true) { aDesinstalar = p }
                .disabled(ocupado)
                .help(T("Desinstalar", "Uninstall"))
                .accessibilityLabel(T("Desinstalar \(p.nombre)", "Uninstall \(p.nombre)"))
        }
    }
}

/// La salida de brew: letra de terminal sobre fondo oscuro, siempre mostrando lo último.
private struct SalidaBrew: View {
    let lineas: [String]
    let desplazable: Bool

    var body: some View {
        Group {
            if desplazable {
                ScrollViewReader { lector in
                    ScrollView {
                        texto.id("fin")
                    }
                    .onChange(of: lineas.count) { _, _ in lector.scrollTo("fin", anchor: .bottom) }
                    .onAppear { lector.scrollTo("fin", anchor: .bottom) }
                }
            } else {
                texto
            }
        }
        .frame(height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: NSColor(hex: 0x141414))))
    }

    private var texto: some View {
        Text(lineas.suffix(400).joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(nsColor: NSColor(hex: 0xD8D4D0)))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}
