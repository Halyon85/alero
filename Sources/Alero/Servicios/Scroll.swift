import AppKit
import Combine
import QuartzCore

// Scroll suave e invertido, solo para la rueda del mouse (el trackpad y el Magic Mouse no se tocan).
// Una sola escucha en el hilo de eventos hace las dos cosas, fuera del hilo principal.
//
// Suave: cada clic de la rueda se traga y se convierte en una ráfaga de movimientos en píxeles, uno por cuadro de
// pantalla, que se van frenando (caída exponencial medida por tiempo: se ve igual a 60 o a 120 Hz). Los movimientos
// se fabrican copiando el evento original (así llegan a la misma ventana) y se mandan directo a la app de destino;
// mandarlos "al sistema" movería el puntero. Necesita Accesibilidad.

/// Planeo de un eje: cuánto falta recorrer y cuánto soltar en cada cuadro. Sin estado de AppKit (se puede probar).
struct MotorPlaneo {
    private(set) var restante: Double = 0
    private var acarreo: Double = 0

    var activo: Bool { restante != 0 }

    /// Suma la distancia de un clic de rueda. Si cambia el sentido, reemplaza lo que faltaba: el primer clic al revés
    /// responde al instante en vez de tener que "frenar" el planeo anterior.
    mutating func sumar(_ distancia: Double) {
        if distancia * restante < 0 { restante = distancia; acarreo = 0 } else { restante += distancia }
    }

    mutating func frenar() { restante = 0; acarreo = 0 }

    /// Píxeles enteros a soltar en este cuadro. `dt` en segundos (se recorta a 1/20 para que una traba no vuelque
    /// todo de golpe); `tau` = qué tan rápido se frena. Las fracciones se acarrean al cuadro siguiente.
    mutating func paso(dt: Double, tau: Double) -> Int {
        guard restante != 0 else { return 0 }
        let tiempo = min(max(dt, 0), 0.05)
        var salida: Double
        if abs(restante) < 1 {
            salida = restante
        } else {
            salida = restante * (1 - exp(-tiempo / tau))
            // Velocidad mínima: la cola del planeo no se arrastra eternamente.
            let minimo = 60 * tiempo
            if abs(salida) < minimo { salida = min(minimo, abs(restante)) * (restante < 0 ? -1 : 1) }
        }
        restante -= salida
        if abs(restante) < 0.01 { restante = 0 }
        acarreo += salida
        var pixeles = Int(acarreo.rounded(.towardZero))
        acarreo -= Double(pixeles)
        // Último cuadro: lo que quedó de fracción se redondea hacia afuera para no aterrizar un píxel corto.
        if restante == 0 {
            if abs(acarreo) >= 0.3 { pixeles += acarreo > 0 ? 1 : -1 }
            acarreo = 0
        }
        return pixeles
    }
}

final class Scroll: NSObject {
    static let shared = Scroll()

    private struct Config {
        var suave = true
        var invertir = false
        var paso: Double = 40
        var tau: Double = 0.08

        var quiereEscucha: Bool { suave || invertir }
    }

    private let candado = NSLock()
    private var config = Config()
    private var suscripciones = Set<AnyCancellable>()
    /// La escucha, del lado del hilo principal (prender y apagar).
    private var escucha: CFMachPort?

    // Estado del planeo: solo se toca en el hilo de eventos (también el reloj de cuadros y la escucha de este lado).
    private var puerto: CFMachPort?
    private var vertical = MotorPlaneo()
    private var horizontal = MotorPlaneo()
    private var plantilla: CGEvent?
    private var destino: Int64 = 0
    private var ultimoConFase: CFTimeInterval = 0
    private var ultimoCuadro: CFTimeInterval = 0
    private var reloj: CADisplayLink?

    func arrancar() {
        let ajustes = Ajustes.shared
        Publishers.CombineLatest4(ajustes.$scrollSuave, ajustes.$scrollInvertir, ajustes.$scrollPaso, ajustes.$scrollRespuesta)
            .sink { [weak self] suave, invertir, paso, respuesta in
                self?.actualizar(suave: suave, invertir: invertir, paso: paso, respuesta: respuesta)
            }
            .store(in: &suscripciones)
    }

    private func actualizar(suave: Bool, invertir: Bool, paso: Double, respuesta: Double) {
        candado.lock()
        config = Config(suave: suave, invertir: invertir, paso: paso, tau: 0.16 - 0.12 * min(max(respuesta, 0), 100) / 100)
        candado.unlock()
        if suave || invertir {
            // Si se apagó todo mientras faltaba el permiso, al llegar el permiso no se prende nada.
            Permisos.cuandoHayaAccesibilidad { [weak self] in
                guard let self, self.leerConfig().quiereEscucha else { return }
                self.prender()
            }
        } else {
            apagar()
        }
    }

    private func leerConfig() -> Config {
        candado.lock()
        defer { candado.unlock() }
        return config
    }

    private func prender() {
        guard escucha == nil else { return }
        let mascara = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        escucha = HiloEventos.shared.agregarEscucha(lugar: .cgAnnotatedSessionEventTap, posicion: .headInsertEventTap, eventos: mascara,
                                                    dueno: Unmanaged.passUnretained(self).toOpaque()) { _, tipo, evento, dueno in
            guard let dueno else { return Unmanaged.passUnretained(evento) }
            return Unmanaged<Scroll>.fromOpaque(dueno).takeUnretainedValue().manejar(tipo, evento)
        }
        guard let nueva = escucha else {
            NSLog("Alero: no se pudo escuchar la rueda del mouse (¿falta Accesibilidad?)")
            return
        }
        // El ritmo de los cuadros sale de la pantalla principal. El reloj y la escucha los lee `manejar` en el hilo de
        // eventos: se instalan ahí, nunca desde este hilo (auditoría del 01/11/2026: se escribían desde el principal
        // mientras la rueda ya andaba).
        let pantalla = NSScreen.main ?? NSScreen.screens.first
        let nuevo = pantalla?.displayLink(target: self, selector: #selector(cuadro(_:)))
        nuevo?.isPaused = true
        HiloEventos.shared.ejecutar { [weak self] in
            nuevo?.add(to: .current, forMode: .common)
            self?.reloj = nuevo
            self?.puerto = nueva
        }
    }

    private func apagar() {
        if let escucha { HiloEventos.shared.sacarEscucha(escucha) }
        escucha = nil
        HiloEventos.shared.ejecutar { [weak self] in
            self?.reloj?.invalidate()
            self?.reloj = nil
            self?.puerto = nil
            self?.vertical.frenar()
            self?.horizontal.frenar()
        }
    }

    // MARK: - En el hilo de eventos

    private func manejar(_ tipo: CGEventType, _ evento: CGEvent) -> Unmanaged<CGEvent>? {
        let sigue = Unmanaged.passUnretained(evento)
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            if let puerto { CGEvent.tapEnable(tap: puerto, enable: true) }
            frenar()
            return sigue
        }
        guard tipo == .scrollWheel, !MarcaPropia.esPropio(evento) else { return sigue }
        guard esRuedaDeMouse(evento) else { frenar(); return sigue }
        let cfg = leerConfig()
        // Control + rueda es el zoom de macOS: no se toca.
        if evento.flags.contains(.maskControl) || !cfg.quiereEscucha { return sigue }
        guard cfg.suave else {
            Scroll.invertir(evento)
            return sigue
        }
        planear(evento, cfg)
        return nil
    }

    /// Rueda de mouse o trackpad. Discreto = rueda siempre. Continuo con fase de gesto = trackpad o Magic Mouse.
    /// Continuo sin fase = rueda (hay mouses que mandan píxeles), salvo el evento "huérfano" que el trackpad manda
    /// entre el fin del gesto y la inercia, hasta 1 s después de uno con fase.
    private func esRuedaDeMouse(_ evento: CGEvent) -> Bool {
        let continuo = evento.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        guard continuo else { return true }
        let fase = evento.getIntegerValueField(.scrollWheelEventScrollPhase)
        let inercia = evento.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let ahora = CACurrentMediaTime()
        if fase != 0 || inercia != 0 { ultimoConFase = ahora; return false }
        let huerfano = ahora - ultimoConFase < 1 && evento.getIntegerValueField(.scrollWheelEventScrollCount) != 0
        return !huerfano
    }

    private func planear(_ evento: CGEvent, _ cfg: Config) {
        let continuo = evento.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var dy: Double
        var dx: Double
        if continuo {
            // Mouse que manda píxeles: se respeta su distancia, escalada por el paso elegido.
            dy = Double(evento.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * cfg.paso / 40
            dx = Double(evento.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * cfg.paso / 40
        } else {
            // Las ruedas de alta resolución mandan fracciones en el campo de punto fijo y 0 en el entero.
            let fijoY = evento.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let fijoX = evento.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            dy = (fijoY != 0 ? fijoY : Double(evento.getIntegerValueField(.scrollWheelEventDeltaAxis1))) * cfg.paso
            dx = (fijoX != 0 ? fijoX : Double(evento.getIntegerValueField(.scrollWheelEventDeltaAxis2))) * cfg.paso
        }
        if cfg.invertir { dy = -dy; dx = -dx }
        // Con Mayúsculas, macOS convierte la rueda vertical en horizontal dentro de la app, pero no lo hace con los
        // eventos en píxeles que mandamos nosotros: la conversión se hace acá.
        if evento.flags.contains(.maskShift), dx == 0 { dx = dy; dy = 0 }

        let pid = evento.getIntegerValueField(.eventTargetUnixProcessID)
        if pid != destino { frenar(); destino = pid }
        plantilla = evento.copy()
        vertical.sumar(dy)
        horizontal.sumar(dx)
        if reloj?.isPaused != false {
            ultimoCuadro = CACurrentMediaTime()
            reloj?.isPaused = false
            if reloj == nil { emitir(dx: Int(dx.rounded()), dy: Int(dy.rounded())); frenar() }
        }
    }

    @objc private func cuadro(_ link: CADisplayLink) {
        let ahora = CACurrentMediaTime()
        let dt = ahora - ultimoCuadro
        ultimoCuadro = ahora
        let tau = leerConfig().tau
        let dy = vertical.paso(dt: dt, tau: tau)
        let dx = horizontal.paso(dt: dt, tau: tau)
        if dx != 0 || dy != 0 { emitir(dx: dx, dy: dy) }
        if !vertical.activo && !horizontal.activo { link.isPaused = true }
    }

    private func frenar() {
        vertical.frenar()
        horizontal.frenar()
        reloj?.isPaused = true
    }

    private static let campos: [CGEventField] = [
        .scrollWheelEventIsContinuous, .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount,
    ]
    private static let camposFijos: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]

    /// Copia el evento original (que sabe a qué ventana va) y le pone los valores de un evento en píxeles nuevo.
    private func emitir(dx: Int, dy: Int) {
        guard let plantilla, let copia = plantilla.copy(),
              let pixeles = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) else { return }
        for campo in Scroll.campos { copia.setIntegerValueField(campo, value: pixeles.getIntegerValueField(campo)) }
        for campo in Scroll.camposFijos { copia.setDoubleValueField(campo, value: pixeles.getDoubleValueField(campo)) }
        copia.setIntegerValueField(.eventSourceUserData, value: MarcaPropia.valor)
        copia.setIntegerValueField(.eventSourceUnixProcessID, value: MarcaPropia.proceso)
        copia.timestamp = pixeles.timestamp
        if destino > 0 { copia.postToPid(pid_t(destino)) } else { copia.post(tap: .cgSessionEventTap) }
    }

    /// Invierte un evento sin suavizarlo. Hay que leer los seis valores antes de escribir: escribir el de líneas
    /// hace que macOS recalcule los otros dos.
    static func invertir(_ evento: CGEvent) {
        let lineas = (evento.getIntegerValueField(.scrollWheelEventDeltaAxis1), evento.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let puntos = (evento.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), evento.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        let fijos = (evento.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), evento.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        evento.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lineas.0)
        evento.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -lineas.1)
        evento.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -puntos.0)
        evento.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -puntos.1)
        evento.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fijos.0)
        evento.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fijos.1)
    }
}
