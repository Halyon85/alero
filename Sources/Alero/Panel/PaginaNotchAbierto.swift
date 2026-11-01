import SwiftUI

// Alero › Notch abierto: la barra de arriba (qué íconos van a cada lado de la cámara y en qué orden: pestañas y
// botones, todos con el mismo formato), las dos tarjetas de Inicio y los botones rápidos que aparecen al deslizar
// sobre el notch cerrado (antes estaban en una página "Atajos" aparte y no se entendía, 01/11/2026). Dónde aparece el notch, su tamaño y el fondo
// están en Alero › Notch. Los cambios se ven en vivo; "Probar en el notch" lo abre unos segundos para mirarlos.

struct PaginaNotchAbierto: View {
    @ObservedObject private var ajustes = Ajustes.shared

    private var capacidad: Int { ReglasBarra.capacidad(anchoAbierto: CGFloat(ajustes.notchAncho), anchoCamara: 200) }

    var body: some View {
        HStack(alignment: .top) {
            TituloPagina(titulo: T("Notch abierto", "Open notch"),
                         subtitulo: T("Elegí qué íconos van arriba, a cada lado de la cámara, y qué muestra Inicio.",
                                      "Pick which icons go on top, on each side of the camera, and what Home shows."))
            Spacer()
            BotonSecundario(texto: T("Probar en el notch", "Try it in the notch"), icono: "rectangle.topthird.inset.filled") {
                ControladorNotch.shared.probar()
            }
        }
        VistaPreviaBarra(izquierda: ajustes.notchBarraIzquierda, derecha: ajustes.notchBarraDerecha)

        lado(T("A la izquierda de la cámara", "Left of the camera"), izquierda: true)
        lado(T("A la derecha de la cámara", "Right of the camera"), izquierda: false)

        Tarjeta(titulo: T("Inicio", "Home")) {
            Fila(titulo: T("A la izquierda", "On the left"), detalle: T("La tarjeta grande.", "The large card.")) {
                selector($ajustes.notchInicioIzquierda)
            }
            Fila(titulo: T("A la derecha", "On the right"), detalle: T("La columna angosta.", "The narrow column."), divisor: false) {
                selector($ajustes.notchInicioDerecha)
            }
        }

        Tarjeta(titulo: T("Botones rápidos al deslizar", "Quick buttons on swipe")) {
            FilaLlave(titulo: T("Mostrar botones al deslizar", "Show buttons on swipe"),
                      detalle: T("Con el notch cerrado, pasá dos dedos de costado sobre él (o girá la rueda del mouse encima) y aparecen estos botones a los lados de la cámara, sin abrir el notch. Otro deslizamiento los esconde.",
                                 "With the notch closed, swipe two fingers sideways over it (or scroll the mouse wheel on it) and these buttons appear beside the camera, without opening the notch. Swipe again to hide them."),
                      divisor: ajustes.notchAtajos, valor: $ajustes.notchAtajos)
            if ajustes.notchAtajos {
                if !ajustes.notchAtajosElegidos.isEmpty {
                    VistaPreviaAtajos(elegidos: ajustes.notchAtajosElegidos).padding(.horizontal, 16).padding(.vertical, 8)
                }
                ForEach(Array(AtajoNotch.allCases.enumerated()), id: \.element) { i, atajo in
                    Fila(titulo: atajo.nombre, detalle: atajo.detalle, divisor: i < AtajoNotch.allCases.count - 1) {
                        Toggle("", isOn: Binding(get: { ajustes.notchAtajosElegidos.contains(atajo) }, set: { elegir(atajo, $0) }))
                            .toggleStyle(.switch).labelsHidden().tint(Tema.acentoVentana)
                    }
                }
            }
        }
    }

    /// Suma o saca un atajo respetando el orden de la lista (así no cambian de lado al prender otro).
    private func elegir(_ atajo: AtajoNotch, _ prender: Bool) {
        var elegidos = Set(ajustes.notchAtajosElegidos)
        if prender { elegidos.insert(atajo) } else { elegidos.remove(atajo) }
        ajustes.notchAtajosElegidos = AtajoNotch.allCases.filter(elegidos.contains)
    }

    // MARK: - Un lado de la barra

    private func lado(_ titulo: String, izquierda: Bool) -> some View {
        let lista = izquierda ? ajustes.notchBarraIzquierda : ajustes.notchBarraDerecha
        let usados = Set(ajustes.notchBarraIzquierda + ajustes.notchBarraDerecha)
        let libres = ElementoBarra.todos.filter { !usados.contains($0) }
        return Tarjeta(titulo: titulo) {
            ForEach(Array(lista.enumerated()), id: \.element) { i, elemento in
                Fila(titulo: elemento.nombre, detalle: elemento.detalle, divisor: true) {
                    HStack(spacing: 6) {
                        BotonChico(icono: "chevron.up", etiqueta: T("Subir", "Move up"), activo: i > 0) { mover(elemento, -1, izquierda) }
                        BotonChico(icono: "chevron.down", etiqueta: T("Bajar", "Move down"), activo: i < lista.count - 1) {
                            mover(elemento, 1, izquierda)
                        }
                        BotonChico(icono: izquierda ? "arrow.right" : "arrow.left",
                                   etiqueta: izquierda ? T("Pasar a la derecha", "Move to the right") : T("Pasar a la izquierda", "Move to the left"),
                                   activo: true) { cambiarDeLado(elemento, desdeIzquierda: izquierda) }
                        BotonChico(icono: "minus", etiqueta: T("Sacar", "Remove"),
                                   activo: ReglasBarra.sePuedeSacar(elemento, izquierda: ajustes.notchBarraIzquierda,
                                                                    derecha: ajustes.notchBarraDerecha)) { sacar(elemento) }
                    }
                }
            }
            Fila(titulo: lista.count > capacidad
                 ? T("No entran todos: se ven los primeros \(capacidad)", "Not all fit: the first \(capacidad) show")
                 : T("\(lista.count) de \(capacidad) lugares", "\(lista.count) of \(capacidad) spots"),
                 divisor: false) {
                Menu {
                    Section(T("Pestañas", "Tabs")) {
                        ForEach(libres.filter(\.esEspacio)) { elemento in
                            Button { agregar(elemento, izquierda) } label: { Label(elemento.nombre, systemImage: elemento.icono) }
                        }
                    }
                    Section(T("Botones", "Buttons")) {
                        ForEach(libres.filter { !$0.esEspacio }) { elemento in
                            Button { agregar(elemento, izquierda) } label: { Label(elemento.nombre, systemImage: elemento.icono) }
                        }
                    }
                } label: {
                    Label(T("Agregar", "Add"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(libres.isEmpty)
            }
        }
    }

    private func selector(_ valor: Binding<TarjetaNotch>) -> some View {
        Picker("", selection: valor) {
            ForEach(TarjetaNotch.allCases) { Text($0.nombre).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden().frame(width: 170)
    }

    // MARK: - Cambios

    private func mover(_ elemento: ElementoBarra, _ paso: Int, _ izquierda: Bool) {
        withAnimation(Tema.expo) {
            if izquierda {
                ajustes.notchBarraIzquierda = ReglasBarra.mover(elemento, paso, en: ajustes.notchBarraIzquierda)
            } else {
                ajustes.notchBarraDerecha = ReglasBarra.mover(elemento, paso, en: ajustes.notchBarraDerecha)
            }
        }
    }

    /// Lo pasa al final del otro lado (desde la izquierda) o al principio (desde la derecha): queda pegado a la cámara.
    private func cambiarDeLado(_ elemento: ElementoBarra, desdeIzquierda: Bool) {
        withAnimation(Tema.expo) {
            if desdeIzquierda {
                ajustes.notchBarraIzquierda.removeAll { $0 == elemento }
                ajustes.notchBarraDerecha.insert(elemento, at: 0)
            } else {
                ajustes.notchBarraDerecha.removeAll { $0 == elemento }
                ajustes.notchBarraIzquierda.append(elemento)
            }
        }
    }

    private func sacar(_ elemento: ElementoBarra) {
        guard ReglasBarra.sePuedeSacar(elemento, izquierda: ajustes.notchBarraIzquierda, derecha: ajustes.notchBarraDerecha) else { return }
        withAnimation(Tema.expo) {
            ajustes.notchBarraIzquierda.removeAll { $0 == elemento }
            ajustes.notchBarraDerecha.removeAll { $0 == elemento }
        }
    }

    private func agregar(_ elemento: ElementoBarra, _ izquierda: Bool) {
        withAnimation(Tema.expo) {
            if izquierda { ajustes.notchBarraIzquierda.append(elemento) } else { ajustes.notchBarraDerecha.append(elemento) }
        }
    }
}

extension ElementoBarra {
    var esEspacio: Bool { if case .espacio = self { return true } else { return false } }
}

/// La barra como se ve en el notch: los íconos de cada lado y la cámara en el medio.
struct VistaPreviaBarra: View {
    let izquierda: [ElementoBarra]
    let derecha: [ElementoBarra]

    var body: some View {
        HStack(spacing: 0) {
            fila(izquierda).frame(maxWidth: .infinity, alignment: .trailing)
            Capsule().fill(Color.white.opacity(0.06)).frame(width: 120, height: 8).padding(.horizontal, 16)
            fila(derecha).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Tema.notch, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous))
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private func fila(_ lista: [ElementoBarra]) -> some View {
        HStack(spacing: 2) {
            ForEach(lista) { elemento in
                Image(systemName: elemento.icono).font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 22).foregroundStyle(Tema.textoNotchSuave)
            }
        }
        .padding(2)
        .background(Color.white.opacity(lista.isEmpty ? 0 : 0.05), in: Capsule())
    }
}

/// Botoncito cuadrado para ordenar filas (subir, bajar, cambiar de lado, sacar).
private struct BotonChico: View {
    let icono: String
    let etiqueta: String
    let activo: Bool
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: icono).font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Tema.rellenoSuave))
                .foregroundStyle(activo ? Tema.titulo : Tema.apagado.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!activo)
        .help(etiqueta)
        .accessibilityLabel(etiqueta)
    }
}

/// El notch con los atajos elegidos, como se ven al deslizar: la primera mitad a la izquierda de la cámara.
private struct VistaPreviaAtajos: View {
    let elegidos: [AtajoNotch]

    var body: some View {
        let mitad = (elegidos.count + 1) / 2
        HStack(spacing: 0) {
            HStack(spacing: 4) { ForEach(elegidos.prefix(mitad)) { icono($0) } }
            Spacer(minLength: 0).frame(width: 150)
            HStack(spacing: 4) { ForEach(elegidos.dropFirst(mitad)) { icono($0) } }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Tema.notch, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private func icono(_ atajo: AtajoNotch) -> some View {
        Image(systemName: atajo.icono)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 24)
            .foregroundStyle(Tema.textoNotch)
            .background(Tema.rellenoNotch, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
