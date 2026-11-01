import SwiftUI

// Mantenimiento › Limpiar la Mac: buscar basura segura, revisarla por categoría (con ruta y tamaño de cada cosa) y
// mandar lo elegido a la Papelera, con confirmación. Nada se borra para siempre.

struct PaginaLimpiador: View {
    @ObservedObject var modelo: ModeloLimpiador
    @State private var confirmar = false
    @State private var abiertas: Set<CategoriaLimpieza> = []

    /// Cuántas filas se ven por categoría antes de "Ver todas".
    private let visibles = 4

    var body: some View {
        TituloPagina(titulo: T("Limpiar la Mac", "Clean up your Mac"),
                     subtitulo: T("Busca lo que se puede borrar sin problema. Lo revisás antes y va a la Papelera.",
                                  "Finds what can be safely removed. You review it first and it goes to the Trash."))
        switch modelo.estado {
        case .inicio:
            AvisoTarjeta(tono: .info, titulo: T("Todavía no se buscó nada", "Nothing scanned yet"),
                         detalle: T("Cachés, registros viejos, Xcode, Homebrew, instaladores y capturas olvidadas. Solo se lee: no se mueve nada hasta que elijas.",
                                    "Caches, old logs, Xcode, Homebrew, installers and forgotten screenshots. It only reads: nothing moves until you choose.")) {
                BotonPrimario(texto: T("Buscar", "Scan")) { modelo.buscar() }
            }
        case .buscando(let categoria):
            AvisoTarjeta(tono: .info, titulo: T("Buscando…", "Scanning…"), detalle: categoria?.titulo) {
                ProgressView().controlSize(.small)
            }
        case .listo, .moviendo:
            resumen
            if let resultado = modelo.resultado {
                ResultadoPapelera(resultado: resultado, ocupado: modelo.ocupado) { modelo.pasarAFinder() }
            }
            if modelo.candidatos.isEmpty {
                AvisoTarjeta(tono: .exito, titulo: T("No hay nada para limpiar", "Nothing to clean up"),
                             detalle: T("Tu Mac ya está prolija.", "Your Mac is already tidy."))
            }
            ForEach(CategoriaLimpieza.allCases) { categoria in
                let lista = modelo.de(categoria)
                if !lista.isEmpty { tarjeta(categoria, lista) }
            }
        }
    }

    private var resumen: some View {
        let total = modelo.bytes(modelo.candidatos)
        let elegidos = modelo.candidatos.filter { modelo.elegidos.contains($0.id) }.count
        return Tarjeta {
            Fila(titulo: T("Encontrado: \(Papelera.texto(total))", "Found: \(Papelera.texto(total))"),
                 detalle: T("Elegiste \(elegidos) (\(Papelera.texto(modelo.bytesElegidos))).",
                            "\(elegidos) selected (\(Papelera.texto(modelo.bytesElegidos)))."),
                 divisor: false) {
                BotonSecundario(texto: T("Buscar de nuevo", "Scan again"), icono: "arrow.clockwise") { modelo.buscar() }
                    .disabled(modelo.ocupado)
                if modelo.estado == .moviendo {
                    ProgressView().controlSize(.small)
                } else {
                    BotonPrimario(texto: T("Mandar a la Papelera", "Move to Trash")) { confirmar = true }
                        .disabled(elegidos == 0)
                        .opacity(elegidos == 0 ? 0.4 : 1)
                }
            }
        }
        .alert(T("¿Mandar \(elegidos) a la Papelera?", "Move \(elegidos) items to the Trash?"), isPresented: $confirmar) {
            Button(T("Mandar a la Papelera", "Move to Trash"), role: .destructive) { modelo.mandarElegidos() }
            Button(T("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(T("Se liberan \(Papelera.texto(modelo.bytesElegidos)) cuando vacíes la Papelera. Hasta entonces podés sacar lo que quieras.",
                   "\(Papelera.texto(modelo.bytesElegidos)) is freed when you empty the Trash. Until then you can take anything back."))
        }
    }

    private func tarjeta(_ categoria: CategoriaLimpieza, _ lista: [CandidatoLimpieza]) -> some View {
        let todos = lista.allSatisfy { modelo.elegidos.contains($0.id) }
        let algunos = !todos && lista.contains { modelo.elegidos.contains($0.id) }
        let abierta = abiertas.contains(categoria)
        let mostradas = abierta ? lista : Array(lista.prefix(visibles))
        return Tarjeta {
            EncabezadoGrupo(icono: categoria.icono, titulo: categoria.titulo, detalle: categoria.detalle,
                            tamano: modelo.bytes(lista), todos: todos, algunos: algunos, activo: !modelo.ocupado) {
                modelo.alternar(categoria)
            }
            ForEach(Array(mostradas.enumerated()), id: \.element.id) { i, candidato in
                FilaElemento(nombre: candidato.nombre, url: candidato.elemento.url, tamano: candidato.elemento.tamano,
                             nota: candidato.nota, elegida: modelo.elegidos.contains(candidato.id),
                             divisor: i < mostradas.count - 1 || lista.count > visibles, activa: !modelo.ocupado) {
                    modelo.alternar(candidato)
                }
            }
            if lista.count > visibles {
                Button {
                    withAnimation(Tema.expo) { if abierta { abiertas.remove(categoria) } else { abiertas.insert(categoria) } }
                } label: {
                    Text(abierta ? T("Ver menos", "Show less") : T("Ver las \(lista.count)", "Show all \(lista.count)"))
                        .font(.titulo(12)).foregroundStyle(Tema.acentoVentana)
                        .frame(maxWidth: .infinity).frame(height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
