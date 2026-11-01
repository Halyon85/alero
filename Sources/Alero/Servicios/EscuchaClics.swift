import AppKit
import CoreGraphics

// Una sola escucha para los clics de toda la Mac (botón izquierdo y botones extra), compartida por el clic en el
// Dock, el botón verde y los botones del mouse. Una sola escucha para todo, fuera del hilo principal.
// Acá la máscara es la unión de lo que pide cada función: con todas apagadas no hay escucha. Corre en `HiloEventos`.

/// Lo que hace un manejador con un evento: dejarlo seguir hacia la app o tragárselo.
enum DecisionClic { case seguir, tragar }

/// Una función que mira los clics. Todo lo suyo se toca solo en el hilo de eventos (también sus ajustes: se los
/// cambia con `HiloEventos.shared.ejecutar`), así no hacen falta candados.
protocol ManejadorClics: AnyObject {
    /// Eventos que quiere ver ahora. Si se tragó un Down y la función se apagó antes del Up, sigue pidiendo el Up
    /// ("drenaje"): si no, la app de abajo recibiría medio clic.
    var mascara: CGEventMask { get }
    /// Tiene que volver rápido: macOS corta la escucha si tarda. Lo pesado (Accesibilidad) va a `AX.cola`.
    /// `proxy` sirve para meter un evento justo antes del que se está procesando (`tapPostEvent`).
    func manejar(_ tipo: CGEventType, _ evento: CGEvent, proxy: CGEventTapProxy) -> DecisionClic
    /// macOS apagó la escucha un rato (tardó o hubo entrada del usuario): un clic a medio tragar puede haber
    /// perdido su Up.
    func alReanudar()
}

extension CGEventType {
    var bit: CGEventMask { CGEventMask(1) << rawValue }
}

final class EscuchaClics {
    static let shared = EscuchaClics()

    // Solo en el hilo de eventos.
    private var manejadores: [ManejadorClics] = []
    private var escucha: CFMachPort?
    private var mascaraActual: CGEventMask = 0
    private var esperandoPermiso = false

    /// Suma un manejador (una vez, al arrancar la función). Cualquier hilo.
    func sumar(_ manejador: ManejadorClics) {
        HiloEventos.shared.ejecutar { [weak self] in
            self?.manejadores.append(manejador)
            self?.rearmar()
        }
    }

    /// Vuelve a calcular qué escuchar: al prender o apagar una función y al terminar un drenaje. Cualquier hilo.
    /// Corre después de lo que ya se mandó al hilo de eventos (el orden se respeta).
    func revisar() {
        HiloEventos.shared.ejecutar { [weak self] in self?.rearmar() }
    }

    /// Una escucha de macOS no cambia de máscara: si cambió, se crea otra y se saca la vieja.
    private func rearmar() {
        let mascara = manejadores.reduce(CGEventMask(0)) { $0 | $1.mascara }
        if mascara == mascaraActual && (mascara == 0 || escucha != nil) { return }
        if let escucha { HiloEventos.shared.sacarEscucha(escucha) }
        escucha = nil
        mascaraActual = 0
        guard mascara != 0 else { return }
        guard AXIsProcessTrusted() else { esperarPermiso(); return }
        escucha = HiloEventos.shared.agregarEscucha(lugar: .cgSessionEventTap, posicion: .headInsertEventTap, eventos: mascara,
                                                    dueno: Unmanaged.passUnretained(self).toOpaque()) { proxy, tipo, evento, dueno in
            guard let dueno else { return Unmanaged.passUnretained(evento) }
            return Unmanaged<EscuchaClics>.fromOpaque(dueno).takeUnretainedValue().manejar(proxy, tipo, evento)
        }
        if escucha == nil {
            NSLog("Alero: no se pudo escuchar los clics (¿falta Accesibilidad?)")
        } else {
            mascaraActual = mascara
        }
    }

    private func esperarPermiso() {
        guard !esperandoPermiso else { return }
        esperandoPermiso = true
        DispatchQueue.main.async { [weak self] in
            Permisos.cuandoHayaAccesibilidad {
                HiloEventos.shared.ejecutar {
                    self?.esperandoPermiso = false
                    self?.rearmar()
                }
            }
        }
    }

    private func manejar(_ proxy: CGEventTapProxy, _ tipo: CGEventType, _ evento: CGEvent) -> Unmanaged<CGEvent>? {
        let sigue = Unmanaged.passUnretained(evento)
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            if let escucha { CGEvent.tapEnable(tap: escucha, enable: true) }
            manejadores.forEach { $0.alReanudar() }
            return sigue
        }
        // Lo que fabrica Alero (un Down devuelto, un atajo) sigue de largo: si no, se lo volvería a tragar.
        guard !MarcaPropia.esPropio(evento) else { return sigue }
        for manejador in manejadores where manejador.mascara & tipo.bit != 0 {
            if manejador.manejar(tipo, evento, proxy: proxy) == .tragar { return nil }
        }
        return sigue
    }
}

extension MarcaPropia {
    /// Le pone a un evento fabricado por Alero la marca que reconocen sus escuchas.
    static func marcar(_ evento: CGEvent) {
        evento.setIntegerValueField(.eventSourceUserData, value: valor)
        evento.setIntegerValueField(.eventSourceUnixProcessID, value: proceso)
    }
}

/// Copia marcada de un clic tragado, para devolvérselo a la app (o al Dock) tal cual lo hubiera recibido.
func copiaMarcada(_ evento: CGEvent, tipo: CGEventType, en punto: CGPoint? = nil) -> CGEvent? {
    guard let copia = evento.copy() else { return nil }
    copia.type = tipo
    if let punto { copia.location = punto }
    // Hora de ahora en el mismo reloj que usa macOS para los eventos (se la "presta" un evento vacío nuevo).
    if let ahora = CGEvent(source: nil) { copia.timestamp = ahora.timestamp }
    MarcaPropia.marcar(copia)
    return copia
}
