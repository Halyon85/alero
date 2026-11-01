import AppKit
import Combine

// Teclas de volumen y brillo: Alero las atrapa antes que macOS, cambia el valor y lo muestra en el notch (así no
// aparece el cartel del centro de la pantalla). Necesita Accesibilidad. Si la salida no deja cambiar el volumen
// (ej.: HDMI) o el brillo no se puede leer, la tecla sigue hacia macOS como siempre.
// El brillo va a la pantalla donde está el puntero (opción de Alero › Sonido y brillo): la de la MacBook por
// DisplayServices y los monitores externos por `Monitores`, con el aviso en el notch de esa pantalla.
// ⌘ + las teclas de brillo (y las teclas de luz del teclado, en las Mac que las tienen) cambian la luz del teclado.

final class TeclasMedia {
    static let shared = TeclasMedia()

    /// La escucha, del lado del hilo principal (prender y apagar).
    private var escucha: CFMachPort?
    /// La misma, del lado del hilo de eventos (la vuelve a prender si macOS la corta). Cada hilo toca solo la suya.
    private var puerto: CFMachPort?
    private var suscripciones = Set<AnyCancellable>()
    /// Lo que pide Ajustes ahora (main thread): el permiso de Accesibilidad puede llegar mucho después.
    private var pedido = false
    /// Teclas cuya bajada atrapamos: su subida también se atrapa (si no, macOS ve una subida suelta).
    private var atrapadas = Set<Int>()
    /// Copia de `Ajustes.brilloTeclasPuntero` para el hilo de eventos (Ajustes es del hilo principal).
    private let candado = NSLock()
    private var brilloEnPuntero = true

    // Códigos de tecla de sistema (NX_KEYTYPE_*): no hay constantes públicas en Swift.
    private enum Tecla: Int {
        case subirVolumen = 0, bajarVolumen = 1, subirBrillo = 2, bajarBrillo = 3, silencio = 7
        case subirLuzTeclado = 21, bajarLuzTeclado = 22
    }

    func arrancar() {
        let ajustes = Ajustes.shared
        ajustes.$notchTeclas.combineLatest(ajustes.$notchActivo).map { $0 && $1 }.removeDuplicates()
            .sink { [weak self] prender in
                self?.pedido = prender
                guard prender else { self?.apagar(); return }
                // Si la opción se apagó mientras faltaba el permiso, al llegar el permiso no se prende nada.
                Permisos.cuandoHayaAccesibilidad { if self?.pedido == true { self?.prender() } }
            }
            .store(in: &suscripciones)
        ajustes.$brilloTeclasPuntero.sink { [weak self] valor in
            self?.candado.lock()
            self?.brilloEnPuntero = valor
            self?.candado.unlock()
        }
        .store(in: &suscripciones)
    }

    private func prender() {
        guard escucha == nil else { return }
        let mascara = CGEventMask(1) << 14 // NSEvent.EventType.systemDefined
        escucha = HiloEventos.shared.agregarEscucha(lugar: .cgSessionEventTap, posicion: .headInsertEventTap, eventos: mascara,
                                                    dueno: Unmanaged.passUnretained(self).toOpaque()) { _, tipo, evento, dueno in
            guard let dueno else { return Unmanaged.passUnretained(evento) }
            let yo = Unmanaged<TeclasMedia>.fromOpaque(dueno).takeUnretainedValue()
            return yo.manejar(tipo, evento)
        }
        guard let nueva = escucha else {
            NSLog("Alero: no se pudo escuchar las teclas de volumen y brillo (¿falta Accesibilidad?)")
            return
        }
        HiloEventos.shared.ejecutar { [weak self] in self?.puerto = nueva }
    }

    private func apagar() {
        if let escucha { HiloEventos.shared.sacarEscucha(escucha) }
        escucha = nil
        HiloEventos.shared.ejecutar { [weak self] in self?.puerto = nil }
    }

    /// Corre en el hilo de eventos. Tiene que ser rápido: macOS corta la escucha si tarda.
    private func manejar(_ tipo: CGEventType, _ evento: CGEvent) -> Unmanaged<CGEvent>? {
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            if let puerto { CGEvent.tapEnable(tap: puerto, enable: true) }
            return Unmanaged.passUnretained(evento)
        }
        guard let sistema = NSEvent(cgEvent: evento), sistema.subtype.rawValue == 8 else { return Unmanaged.passUnretained(evento) }
        let datos = sistema.data1
        let codigo = (datos & 0xFFFF_0000) >> 16
        let bajando = ((datos & 0xFF00) >> 8) == 0xA
        guard let tecla = Tecla(rawValue: codigo) else { return Unmanaged.passUnretained(evento) }
        if !bajando {
            return atrapadas.remove(codigo) != nil ? nil : Unmanaged.passUnretained(evento)
        }
        // Opción + Mayúsculas: pasos finos, como en macOS.
        let fino = sistema.modifierFlags.contains(.option) && sistema.modifierFlags.contains(.shift)
        let paso: Float = fino ? 1 / 64 : 1 / 16
        // ⌘ + brillo: la luz del teclado (las MacBook nuevas no tienen teclas propias para eso).
        let conComando = sistema.modifierFlags.contains(.command)
        let elegida: Tecla
        switch tecla {
        case .subirBrillo where conComando: elegida = .subirLuzTeclado
        case .bajarBrillo where conComando: elegida = .bajarLuzTeclado
        default: elegida = tecla
        }
        guard aplicar(elegida, paso: paso) else { return Unmanaged.passUnretained(evento) }
        atrapadas.insert(codigo)
        return nil
    }

    private func aplicar(_ tecla: Tecla, paso: Float) -> Bool {
        let sonido = Sonido.shared
        switch tecla {
        case .subirVolumen, .bajarVolumen:
            guard let actual = sonido.volumen() else { return false }
            let nuevo = Self.redondear(actual + (tecla == .subirVolumen ? paso : -paso), paso: paso)
            guard sonido.ponerVolumen(nuevo) else { return false }
            mostrar(.volumen, nuevo, silencio: false)
        case .silencio:
            guard let silenciado = sonido.silenciado(), sonido.ponerSilencio(!silenciado) else { return false }
            mostrar(.volumen, sonido.volumen() ?? 0, silencio: !silenciado)
        case .subirBrillo, .bajarBrillo:
            let delta = tecla == .subirBrillo ? paso : -paso
            // Un monitor externo bajo el puntero (si Alero lo puede manejar); si no, la pantalla de la MacBook.
            if let externa = pantallaExternaDelPuntero(), let nuevo = Monitores.shared.pasoTecla(externa, delta: delta, paso: paso) {
                mostrar(.brillo, nuevo, silencio: false, en: externa)
                return true
            }
            guard let actual = Brillo.actual() else { return false }
            let nuevo = Self.redondear(actual + delta, paso: paso)
            guard Brillo.poner(nuevo) else { return false }
            mostrar(.brillo, nuevo, silencio: false, en: Self.integrada())
        case .subirLuzTeclado, .bajarLuzTeclado:
            guard let actual = BrilloTeclado.actual() else { return false }
            let nuevo = Self.redondear(actual + (tecla == .subirLuzTeclado ? paso : -paso), paso: paso)
            guard BrilloTeclado.poner(nuevo) else { return false }
            mostrar(.teclado, nuevo, silencio: false, en: Self.integrada())
        }
        return true
    }

    /// La pantalla bajo el puntero si no es la de la MacBook y la opción está prendida. Cualquier hilo.
    private func pantallaExternaDelPuntero() -> CGDirectDisplayID? {
        candado.lock()
        let prendido = brilloEnPuntero
        candado.unlock()
        guard prendido, let puntero = CGEvent(source: nil)?.location else { return nil }
        let id = ReglasBrillo.pantallaDelPuntero(puntero, en: Self.pantallas())
        return id.flatMap { CGDisplayIsBuiltin($0) == 0 ? $0 : nil }
    }

    private static func pantallas() -> [(id: CGDirectDisplayID, marco: CGRect)] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var cantidad: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &cantidad) == .success else { return [] }
        return ids.prefix(Int(cantidad)).map { (id: $0, marco: CGDisplayBounds($0)) }
    }

    private static func integrada() -> CGDirectDisplayID? {
        pantallas().first { CGDisplayIsBuiltin($0.id) != 0 }?.id
    }

    /// El aviso va al notch de la pantalla dada (el brillo) o al de la pantalla del puntero (el volumen).
    private func mostrar(_ tipo: TipoHud, _ valor: Float, silencio: Bool, en pantalla: CGDirectDisplayID? = nil) {
        DispatchQueue.main.async {
            ControladorNotch.shared.mostrarHud(tipo, valor: valor, silencio: silencio, en: pantalla)
        }
    }

    /// Lleva el valor al escalón más cercano (así 16 toques van de 0 a 100 exacto) y lo deja entre 0 y 1.
    static func redondear(_ valor: Float, paso: Float) -> Float {
        min(max((valor / paso).rounded() * paso, 0), 1)
    }
}
