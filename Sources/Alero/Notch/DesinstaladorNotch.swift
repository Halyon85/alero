import AppKit
import SwiftUI

// Desinstalar apps desde el notch (Utilidades, columna derecha, unos 380×140 pt). "Elegir apps…" abre directo el
// cuadro de abrir de macOS en Aplicaciones con selección múltiple; también se pueden soltar una o varias apps
// arrastrando. Muestra un resumen compacto (cuántas, cuánto ocupan en total y una fila por app) y las manda todas
// juntas a la Papelera. Usa `ModelosNotch.desinstalador`, que vive mientras Alero está abierta. Para revisar archivo
// por archivo está "Detalle" (la página de Alero).

struct DesinstaladorNotch: View {
    @ObservedObject private var modelo: ModeloDesinstalador
    @State private var sobre = false
    @Environment(\.enCapturas) private var enCapturas

    /// `modelo` se cambia solo en las capturas (`MuestrasMantenimiento`).
    init(modelo: ModeloDesinstalador = ModelosNotch.desinstalador) {
        _modelo = ObservedObject(wrappedValue: modelo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TituloSeccionNotch(texto: T("DESINSTALAR", "UNINSTALL"))
                Spacer(minLength: 4)
                if !modelo.trabajando {
                    Button(T("Detalle", "Details")) { VentanaAlero.shared.mostrar(.desinstalador) }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Tema.textoNotchSuave)
                }
            }
            switch modelo.estado {
            case .eligiendo: cuadro
            case .buscando: buscando
            case .terminado: terminado
            case .listo, .cerrando, .desinstalando: resumen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(SoltarApps(activo: !enCapturas, sobre: $sobre) { modelo.trabajando ? nil : modelo.elegir })
        .overlay {
            if sobre, modelo.estado != .eligiendo {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tema.acento, lineWidth: 1.2)
            }
        }
        .animation(.easeOut(duration: 0.15), value: sobre)
    }

    // MARK: - Elegir

    private var cuadro: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.app").font(.system(size: 17, weight: .light))
                    .foregroundStyle(sobre ? Tema.acento : Tema.textoNotchSuave)
                Text(T("Soltá una o varias apps", "Drop one or more apps")).font(.system(size: 12, weight: .semibold))
            }
            Button { elegirConPanel() } label: {
                Label(T("Elegir apps…", "Choose apps…"), systemImage: "plus")
            }
            .buttonStyle(BotonPastilla(relleno: true))
            if let rechazo = textoRechazos {
                Text(rechazo).font(.system(size: 10)).foregroundStyle(Self.rojo).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(sobre ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(sobre ? Tema.acento : Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }

    private var buscando: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(modelo.lote.count == 1
                 ? T("Buscando lo que dejó \(modelo.lote[0].app.nombre)…", "Looking for what \(modelo.lote[0].app.nombre) left…")
                 : T("Buscando lo que dejaron \(modelo.lote.count) apps…", "Looking for what \(modelo.lote.count) apps left…"))
                .font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Resumen

    private var resumen: some View {
        VStack(alignment: .leading, spacing: 6) {
            if modelo.lote.count == 1 { una(modelo.lote[0]) } else { varias }
            if let error = modelo.error {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Self.rojo).lineLimit(1).truncationMode(.middle)
            } else if !modelo.porCerrar.isEmpty {
                Text(abiertas).font(.system(size: 10.5)).foregroundStyle(Tema.textoNotchSuave).lineLimit(1).truncationMode(.middle)
            }
            acciones
        }
    }

    /// Una sola app: ícono grande, cuánto ocupa con sus restos y cuántos quedan por pedir administrador.
    private func una(_ preparada: ModeloDesinstalador.AppPreparada) -> some View {
        let mandados = preparada.restos.filter { modelo.elegidos.contains($0.id) }.count
        let admin = preparada.restos.filter(\.pideAdministrador).count
        var detalle = T("\(Papelera.texto(modelo.tamanoElegido(preparada))) con \(mandados) restos",
                        "\(Papelera.texto(modelo.tamanoElegido(preparada))) with \(mandados) leftovers")
        if admin == 1 { detalle += T(" · 1 pide administrador", " · 1 needs admin") }
        if admin > 1 { detalle += T(" · \(admin) piden administrador", " · \(admin) need admin") }
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: preparada.app.url.path)).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(preparada.app.nombre).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(detalle).font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave).lineLimit(1)
                if let primero = modelo.rechazos.first {
                    Text(textoRechazos ?? primero.nombre).font(.system(size: 10)).foregroundStyle(Self.rojo).lineLimit(1)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Varias apps: cuántas, cuánto ocupan en total y una fila por app.
    private var varias: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(titulo).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(Papelera.texto(modelo.bytesElegidos)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tema.textoNotchSuave)
                Spacer(minLength: 4)
                if let primero = modelo.rechazos.first {
                    // Lo que no se aceptó, corto; el porqué al pasar el mouse.
                    Text(modelo.rechazos.count == 1 ? T("\(primero.nombre) no se puede", "\(primero.nombre) can't be removed")
                                                    : T("\(modelo.rechazos.count) no se pueden", "\(modelo.rechazos.count) can't be removed"))
                        .font(.system(size: 10)).foregroundStyle(Self.rojo).lineLimit(1).truncationMode(.middle)
                        .help(textoRechazos ?? "")
                }
            }
            DesplazableNotch {
                VStack(alignment: .leading, spacing: 3) { ForEach(modelo.lote) { fila($0) } }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var titulo: String { T("\(modelo.lote.count) apps", "\(modelo.lote.count) apps") }

    private func fila(_ preparada: ModeloDesinstalador.AppPreparada) -> some View {
        let admin = preparada.restos.filter(\.pideAdministrador).count
        return HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: preparada.app.url.path)).resizable().frame(width: 15, height: 15)
            Text(preparada.app.nombre).font(.system(size: 11)).lineLimit(1)
            if admin > 0 {
                // Lo de `/Library` queda: se ve en "Detalle".
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Tema.textoNotchSuave)
                    .help(T("\(admin) restos piden administrador y quedan", "\(admin) leftovers need admin and stay"))
            }
            Spacer(minLength: 4)
            Text(Papelera.texto(modelo.tamanoElegido(preparada))).font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Tema.textoNotchSuave)
        }
    }

    @ViewBuilder private var acciones: some View {
        HStack(spacing: 6) {
            if !modelo.porCerrar.isEmpty {
                Button(T("Cerrarlas y seguir", "Quit and go on")) { modelo.cerrarYSeguir() }.buttonStyle(BotonPastilla(relleno: true))
                Button(T("Cancelar", "Cancel")) { modelo.porCerrar = [] }.buttonStyle(BotonPastilla())
            } else if modelo.estado == .cerrando || modelo.estado == .desinstalando {
                ProgressView().controlSize(.small)
                Text(modelo.estado == .cerrando ? T("Cerrando…", "Quitting…") : T("Mandando a la Papelera…", "Moving to the Trash…"))
                    .font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave)
            } else {
                Button(modelo.lote.count == 1 ? T("Mandar a la Papelera", "Move to Trash") : T("Mandar todo a la Papelera", "Move all to Trash")) {
                    modelo.desinstalar()
                }
                .buttonStyle(BotonPastilla(relleno: true))
                Button(T("Cancelar", "Cancel")) { modelo.volver() }.buttonStyle(BotonPastilla())
            }
        }
    }

    private var abiertas: String {
        let nombres = modelo.porCerrar.joined(separator: ", ")
        return modelo.porCerrar.count == 1 ? T("\(nombres) está abierta: hay que cerrarla.", "\(nombres) is open: it has to quit.")
                                           : T("Hay que cerrarlas: \(nombres)", "They have to quit: \(nombres)")
    }

    // MARK: - Terminado

    private var terminado: some View {
        let resultado = modelo.resultado ?? Papelera.Resultado()
        let problemas = resultado.rechazados.count + resultado.sinPermiso.count
        let cuantas = modelo.appsMovidas
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: problemas == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(problemas == 0 ? Self.verde : Self.rojo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cuantas == 1 ? T("1 app a la Papelera", "1 app moved to the Trash") : T("\(cuantas) apps a la Papelera", "\(cuantas) apps moved to the Trash"))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(T("\(Papelera.texto(resultado.bytes)) · se pueden recuperar de la Papelera", "\(Papelera.texto(resultado.bytes)) · you can get them back from the Trash"))
                        .font(.system(size: 11)).foregroundStyle(Tema.textoNotchSuave).lineLimit(1)
                }
            }
            if problemas > 0 {
                Text(T("\(problemas) cosas no se movieron. Mirá el detalle.", "\(problemas) items weren't moved. See the details."))
                    .font(.system(size: 10.5)).foregroundStyle(Self.rojo).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if !resultado.sinPermiso.isEmpty {
                    // Una app instalada por el administrador: Finder la mueve con su propio cartel de contraseña.
                    Button(T("Pasársela a Finder", "Hand it to Finder")) { modelo.pasarAFinder() }.buttonStyle(BotonPastilla(relleno: true))
                }
                Button(T("Listo", "Done")) { modelo.volver() }.buttonStyle(BotonPastilla())
            }
        }
    }

    // MARK: - Ayudas

    /// "Safari.app: Las apps de Apple…" o "2 no se pueden: Safari.app, Notas.txt".
    private var textoRechazos: String? {
        guard let primero = modelo.rechazos.first else { return nil }
        if modelo.rechazos.count == 1 { return "\(primero.nombre): \(primero.motivo)" }
        let nombres = modelo.rechazos.map(\.nombre).joined(separator: ", ")
        return T("\(modelo.rechazos.count) no se pueden: \(nombres)", "\(modelo.rechazos.count) can't be removed: \(nombres)")
    }

    private func elegirConPanel() {
        let urls = ElegirApps.conPanel()
        if !urls.isEmpty { modelo.elegir(urls) }
    }

    private static let rojo = Color(nsColor: NSColor(hex: 0xFF8A80))
    private static let verde = Color(nsColor: NSColor(hex: 0x4CD964))
}

/// Soltar apps funciona en todo el bloque (salvo mientras trabaja) y reemplaza lo elegido. En las capturas no se pone:
/// `ImageRenderer` no sabe dibujar la vista de macOS que recibe lo soltado.
private struct SoltarApps: ViewModifier {
    let activo: Bool
    @Binding var sobre: Bool
    /// Nil mientras no acepta (está cerrando o moviendo apps).
    let elegir: () -> (([URL]) -> Void)?

    func body(content: Content) -> some View {
        if activo {
            content.onDrop(of: [.fileURL], isTargeted: $sobre) { proveedores in
                guard let elegir = elegir() else { return false }
                return ElegirApps.soltadas(proveedores, listo: elegir)
            }
        } else {
            content
        }
    }
}
