import SwiftUI

// Qué está mostrando el notch y por cuánto tiempo. Lo cambian el controlador (mouse, arrastre, gestos) y los
// servicios (avisos, teclas). Main thread. Cada cambio de modo anima con la curva que corresponde: abrir o cerrar.

enum AvisoNotch: Equatable {
    case reunion(titulo: String, minutos: Int)
    case salida(tipo: Salida.Tipo, nombre: String)
    case cafe(prendido: Bool)
    case estante(sumados: Int)
    /// Finder: ⌘X marcó archivos para mover.
    case cortar(cantidad: Int)
    /// Finder: ⌘V movió los archivos marcados. `sinPermiso`: alguno falló porque macOS no dejó tocarlo.
    case pegar(movidos: Int, fallidos: Int, sinPermiso: Bool)
    /// Falta un permiso para lo que se acaba de pedir (por ejemplo, controlar Finder).
    case permiso(nombre: String)
    /// La captura no se pudo guardar (ni en la carpeta elegida ni en el Escritorio). `copiada`: igual quedó en el
    /// portapapeles.
    case capturaFallo(copiada: Bool)
    /// Se enchufó o desenchufó el cargador, con el porcentaje de batería.
    case corriente(enchufada: Bool, porcentaje: Int?)
    /// Terminó una descarga (el nombre del archivo, o "N archivos").
    case descarga(nombre: String)
}

enum TipoHud: Equatable { case volumen, brillo, teclado }

final class EstadoNotch: ObservableObject {
    @Published private(set) var modo: ModoNotch = .cerrado
    @Published private(set) var aviso: AvisoNotch?
    @Published private(set) var hudTipo: TipoHud = .volumen
    @Published private(set) var hudValor: Float = 0
    @Published private(set) var hudSilencio = false
    /// El espacio (pestaña) que se ve con el notch abierto.
    @Published var espacio: EspacioNotch = .inicio
    @Published var medidas: MedidasNotch = .deRelleno
    /// El archivo que se arrastra está encima de la zona de soltar.
    @Published var sobreZona = false
    /// La última captura, mientras se muestra su aviso (la miniatura es chica: hasta 360 px).
    @Published private(set) var captura: CapturaLista?

    private var vuelta: DispatchWorkItem?

    /// Sin espacio, abre en el primero de los elegidos (el Inicio, salvo que se haya movido).
    func abrir(_ pedido: EspacioNotch? = nil) {
        espacio = ReglasBarra.elegido(pedido, entre: Ajustes.shared.notchEspacios)
        cambiar(a: .abierto)
    }

    func abrirEstante() { cambiar(a: .estante) }

    func cerrar() {
        sobreZona = false
        cambiar(a: .cerrado)
    }

    func mostrarAtajos() { cambiar(a: .atajos, volverEn: 4) }

    func mostrarPrompter() { cambiar(a: .prompter) }

    /// Los avisos no interrumpen al notch abierto: si la persona lo está usando, el aviso se descarta.
    func mostrar(_ nuevo: AvisoNotch, durante segundos: TimeInterval = 3.5) {
        guard !modo.esGrande else { return }
        aviso = nuevo
        cambiar(a: .aviso, volverEn: segundos)
    }

    /// El aviso de captura lista (con la miniatura). A diferencia de los otros avisos, aparece aunque el notch esté
    /// abierto: la persona acaba de pedirla.
    func mostrarCaptura(_ nueva: CapturaLista, durante segundos: TimeInterval = 6) {
        captura = nueva
        cambiar(a: .captura, volverEn: segundos)
    }

    func mostrarHud(_ tipo: TipoHud, valor: Float, silencio: Bool = false) {
        guard !modo.esGrande else { return }
        hudTipo = tipo
        hudSilencio = silencio
        if modo == .hud {
            withAnimation(.smooth(duration: 0.16)) { hudValor = valor }
            programarVuelta(1.5)
        } else {
            hudValor = valor
            cambiar(a: .hud, volverEn: 1.5)
        }
    }

    private func cambiar(a nuevo: ModoNotch, volverEn segundos: TimeInterval? = nil) {
        vuelta?.cancel()
        if nuevo != modo {
            let curva = nuevo == .cerrado ? Diseno.cerrar : Diseno.abrir
            withAnimation(curva) { modo = nuevo }
        }
        if let segundos { programarVuelta(segundos) }
    }

    private func programarVuelta(_ segundos: TimeInterval) {
        vuelta?.cancel()
        let tarea = DispatchWorkItem { [weak self] in self?.cerrar() }
        vuelta = tarea
        DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: tarea)
    }

    /// Solo para `--capturas`: deja el notch en un modo fijo, sin animar ni volver solo.
    func forzar(_ nuevo: ModoNotch, aviso: AvisoNotch? = nil, hud: (TipoHud, Float)? = nil, espacio: EspacioNotch = .inicio,
                captura: CapturaLista? = nil) {
        modo = nuevo
        self.aviso = aviso
        self.captura = captura
        self.espacio = espacio
        if let hud { hudTipo = hud.0; hudValor = hud.1 }
    }

    /// Mientras el mouse está encima de un aviso o de los atajos, no se cierran solos.
    func detenerVuelta() { vuelta?.cancel() }

    func reanudarVuelta() {
        if modo.esPasajero { programarVuelta(modo == .captura ? 3 : 1.5) }
    }
}
