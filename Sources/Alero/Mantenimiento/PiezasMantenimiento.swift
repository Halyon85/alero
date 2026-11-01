import SwiftUI

// Piezas de las páginas de Mantenimiento (limpiador, desinstalador y Homebrew): la casilla de elegir, la fila de un
// archivo con su ruta y tamaño, los avisos y el resultado de mandar a la Papelera. Mismo sistema que `Piezas.swift`.

/// En `--capturas` las listas van sin ScrollView ni carga diferida (el dibujante de imágenes no las muestra).
private struct ClaveDibujando: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var dibujandoMuestra: Bool {
        get { self[ClaveDibujando.self] }
        set { self[ClaveDibujando.self] = newValue }
    }
}

/// Casilla redonda propia (la de AppKit no sigue el acento de Alero). `mixta`: algunos sí y otros no.
struct Casilla: View {
    let elegida: Bool
    var mixta = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Tema.apagado.opacity(elegida || mixta ? 0 : 0.6), lineWidth: 1.5)
            if elegida || mixta {
                Circle().fill(Tema.acentoVentana)
                Image(systemName: mixta && !elegida ? "minus" : "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Tema.pildoraTexto)
            }
        }
        .frame(width: 18, height: 18)
        .animation(.easeOut(duration: 0.12), value: elegida)
        .accessibilityLabel(elegida ? T("Elegido", "Selected") : T("Sin elegir", "Not selected"))
    }
}

/// Una ruta con la carpeta de la persona abreviada ("~/Library/Caches/…").
func rutaCorta(_ url: URL) -> String {
    let casa = ReglasBorrado.casa
    let ruta = url.path
    return ruta.hasPrefix(casa + "/") ? "~" + ruta.dropFirst(casa.count) : ruta
}

/// Una fila con casilla, nombre, ruta completa, nota y tamaño. Toda la fila se puede tocar.
struct FilaElemento: View {
    let nombre: String
    let url: URL
    let tamano: Int64
    var nota: String? = nil
    let elegida: Bool
    var divisor = true
    var activa = true
    let alternar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: alternar) {
                HStack(spacing: 12) {
                    Casilla(elegida: elegida)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nombre).font(.titulo(13, .regular)).foregroundStyle(Tema.titulo).lineLimit(1).truncationMode(.middle)
                        Text(rutaCorta(url)).font(.system(size: 11)).foregroundStyle(Tema.apagado).lineLimit(1).truncationMode(.middle)
                            .help(url.path)
                    }
                    Spacer(minLength: 8)
                    if let nota {
                        Text(nota).font(.system(size: 11, weight: .medium)).foregroundStyle(Tema.subtitulo)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill(Tema.relleno))
                            .lineLimit(1).fixedSize()
                    }
                    Text(Papelera.texto(tamano)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tema.subtitulo)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!activa)
            if divisor { Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 46) }
        }
    }
}

/// El encabezado de un grupo dentro de una tarjeta: ícono, título, detalle, total y casilla de todo el grupo.
struct EncabezadoGrupo: View {
    let icono: String
    let titulo: String
    let detalle: String
    let tamano: Int64
    let todos: Bool
    let algunos: Bool
    var activo = true
    let alternar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: alternar) {
                HStack(spacing: 12) {
                    Casilla(elegida: todos, mixta: algunos)
                    Image(systemName: icono).font(.system(size: 13, weight: .medium)).foregroundStyle(Tema.titulo)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.rellenoSuave))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titulo).font(.titulo(14)).foregroundStyle(Tema.titulo)
                        Text(detalle).font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(Papelera.texto(tamano)).font(.titulo(13).monospacedDigit()).foregroundStyle(Tema.titulo)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!activo)
            Rectangle().fill(Tema.bordeSuave).frame(height: 1)
        }
    }
}

/// Aviso en una tarjeta: ícono, título, detalle y, opcional, botones a la derecha.
struct AvisoTarjeta<B: View>: View {
    enum Tono { case info, exito, error }
    let tono: Tono
    let titulo: String
    var detalle: String? = nil
    @ViewBuilder var botones: B

    private var icono: String {
        switch tono {
        case .info: return "info.circle.fill"
        case .exito: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch tono {
        case .info: return Tema.acentoVentana
        case .exito: return Tema.exito
        case .error: return Tema.error
        }
    }

    var body: some View {
        TextoYControles(minimoTexto: 260) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icono).font(.system(size: 16)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(titulo).font(.titulo(14)).foregroundStyle(Tema.titulo).fixedSize(horizontal: false, vertical: true)
                    if let detalle {
                        Text(detalle).font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Fluir(espacio: 8) { botones }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .shadow(color: .black.opacity(0.02), radius: 4, y: 2)
    }
}

extension AvisoTarjeta where B == EmptyView {
    init(tono: Tono, titulo: String, detalle: String? = nil) {
        self.init(tono: tono, titulo: titulo, detalle: detalle) { EmptyView() }
    }
}

/// Lo que pasó al mandar a la Papelera: cuánto se liberó, qué no se pudo y por qué. Si hubo cosas que macOS no dejó
/// mover por permisos, ofrece pasárselas a Finder (que pide la contraseña en su cartel).
struct ResultadoPapelera: View {
    let resultado: Papelera.Resultado
    var ocupado = false
    let pasarAFinder: () -> Void

    var body: some View {
        let problemas = resultado.rechazados.count + resultado.sinPermiso.count
        VStack(alignment: .leading, spacing: 12) {
            AvisoTarjeta(tono: problemas == 0 ? .exito : .error,
                         titulo: resultado.movidos.isEmpty
                            ? T("No se movió nada a la Papelera", "Nothing was moved to the Trash")
                            : T("Listo: \(Papelera.texto(resultado.bytes)) a la Papelera", "Done: \(Papelera.texto(resultado.bytes)) moved to the Trash"),
                         detalle: detalle(problemas)) {
                if !resultado.sinPermiso.isEmpty {
                    BotonPrimario(texto: T("Pasárselo a Finder", "Hand it to Finder"), accion: pasarAFinder).disabled(ocupado)
                }
                if !resultado.movidos.isEmpty {
                    BotonSecundario(texto: T("Abrir la Papelera", "Open Trash"), icono: "trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: ReglasBorrado.casa + "/.Trash", isDirectory: true))
                    }
                }
            }
            if problemas > 0 {
                Tarjeta(titulo: T("No se movieron", "Not moved")) {
                    let todos = resultado.sinPermiso.map { ($0, T("macOS pide permiso de administrador.", "macOS needs admin permission.")) }
                        + resultado.rechazados
                    ForEach(Array(todos.enumerated()), id: \.offset) { i, par in
                        Fila(titulo: par.0.url.lastPathComponent, detalle: "\(rutaCorta(par.0.url)) · \(par.1)", divisor: i < todos.count - 1) {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private func detalle(_ problemas: Int) -> String {
        var partes: [String] = []
        if !resultado.movidos.isEmpty {
            partes.append(T("Si algo hace falta, sacalo de la Papelera.", "If you need something back, take it out of the Trash."))
        }
        if problemas > 0 { partes.append(T("\(problemas) no se pudieron mover.", "\(problemas) couldn't be moved.")) }
        if !resultado.sinPermiso.isEmpty {
            partes.append(T("Finder los puede mover pidiéndote la contraseña.", "Finder can move them by asking for your password."))
        }
        return partes.joined(separator: " ")
    }
}
