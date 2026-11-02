import AppKit
import os

// La escucha del mouse de toda la Mac para Ventanas (`Mosaico`) y el notch (`ControladorNotch`). Solo mira: nunca frena
// ni cambia un evento. Antes cada uno usaba `NSEvent.addGlobalMonitorForEvents`, que macOS puede dejar de alimentar sin
// avisar: el 02/11/2026, después de cambiar la pantalla de 60 a 120 Hz, Alero seguía andando pero no le llegaba ni un
// movimiento (las formas del botón verde y los bordes de Ventanas no aparecían hasta reiniciarla). Esta es una escucha
// propia, como las de los clics y el scroll: si macOS la apaga, avisa y se vuelve a prender; además se revisa cada 5 s
// y, si no está andando, se la crea de nuevo. Como el monitor global de AppKit, no entrega lo que va a ventanas de
// Alero (eso lo ven los monitores locales de cada función). Si macOS no deja crearla, se usa el monitor global como
// antes. La escucha corre en `HiloEventos`; cada evento pasa al hilo principal, donde se reparte.

final class EscuchaMouse {
    static let shared = EscuchaMouse()

    private let registro = Logger(subsystem: "team.halyon.alero", category: "eventos")

    // Hilo principal.
    private var oyentes: [Int: (tipos: NSEvent.EventTypeMask, manejar: (NSEvent) -> Void)] = [:]
    private var siguiente = 0
    private var reloj: Timer?
    /// El monitor global de AppKit, solo si macOS no dejó crear la escucha propia.
    private var respaldo: Any?

    // Hilo de eventos.
    private var escucha: CFMachPort?
    private var mascaraActual: CGEventMask = 0
    private var mascaraPedida: CGEventMask = 0
    /// La última vez macOS no dejó crearla (se avisa una sola vez, no en cada revisión).
    private var fallo = false

    /// Empieza a recibir esos tipos de eventos, en el hilo principal. Devuelve el número con que se saca. Hilo principal.
    func sumar(_ tipos: NSEvent.EventTypeMask, _ manejar: @escaping (NSEvent) -> Void) -> Int {
        siguiente += 1
        oyentes[siguiente] = (tipos, manejar)
        rearmar()
        return siguiente
    }

    /// Hilo principal.
    func sacar(_ id: Int) {
        oyentes[id] = nil
        rearmar()
    }

    /// La máscara es la unión de lo que pide cada uno; sin nadie, no hay escucha ni revisión.
    private func rearmar() {
        let mascara = EscuchaMouse.mascara(oyentes.values.reduce(NSEvent.EventTypeMask()) { $0.union($1.tipos) })
        HiloEventos.shared.ejecutar { [weak self] in
            self?.mascaraPedida = mascara
            self?.armar()
        }
        if mascara == 0 {
            reloj?.invalidate()
            reloj = nil
        } else if reloj == nil {
            reloj = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                HiloEventos.shared.ejecutar { [weak self] in self?.armar() }
            }
        }
    }

    /// Los tipos de AppKit en la máscara de una escucha de macOS: para el mouse y el teclado son los mismos números
    /// (bit n = evento de tipo n), así que alcanza con quedarse con los primeros 32 bits.
    static func mascara(_ tipos: NSEvent.EventTypeMask) -> CGEventMask {
        CGEventMask(tipos.rawValue & 0xFFFF_FFFF)
    }

    // MARK: - Hilo de eventos

    /// Deja la escucha andando con la máscara pedida: no hace nada si ya lo está; si cambió la máscara, macOS la
    /// invalidó o quedó apagada, la crea de nuevo.
    private func armar() {
        let andando = escucha.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false
        if mascaraPedida == mascaraActual && (mascaraPedida == 0 || andando) { return }
        if escucha != nil && mascaraPedida == mascaraActual {
            registro.notice("La escucha del mouse había dejado de andar: se crea de nuevo")
        }
        if let escucha { HiloEventos.shared.sacarEscucha(escucha) }
        escucha = nil
        mascaraActual = 0
        let mascara = mascaraPedida
        guard mascara != 0 else {
            DispatchQueue.main.async { [weak self] in self?.respaldar(nil) }
            return
        }
        escucha = HiloEventos.shared.agregarEscucha(lugar: .cgAnnotatedSessionEventTap, posicion: .tailAppendEventTap,
                                                    eventos: mascara, opciones: .listenOnly,
                                                    dueno: Unmanaged.passUnretained(self).toOpaque()) { _, tipo, evento, dueno in
            if let dueno { Unmanaged<EscuchaMouse>.fromOpaque(dueno).takeUnretainedValue().recibir(tipo, evento) }
            return Unmanaged.passUnretained(evento)
        }
        let tipos = NSEvent.EventTypeMask(rawValue: UInt64(mascara))
        if escucha == nil {
            // Se vuelve a probar en la próxima revisión; mientras, el monitor global de AppKit.
            if !fallo { registro.error("macOS no dejó crear la escucha del mouse: se usa el monitor global") }
            fallo = true
            DispatchQueue.main.async { [weak self] in self?.respaldar(tipos) }
        } else {
            fallo = false
            mascaraActual = mascara
            DispatchQueue.main.async { [weak self] in self?.respaldar(nil) }
        }
    }

    private func recibir(_ tipo: CGEventType, _ evento: CGEvent) {
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            if let escucha { CGEvent.tapEnable(tap: escucha, enable: true) }
            registro.notice("macOS apagó la escucha del mouse (\(tipo == .tapDisabledByTimeout ? "tardó" : "entrada", privacy: .public)): se volvió a prender")
            return
        }
        // Lo que va a una ventana de Alero no: eso lo ven los monitores locales (como con el monitor global de AppKit).
        guard evento.getIntegerValueField(.eventTargetUnixProcessID) != MarcaPropia.proceso, let copia = evento.copy() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let ns = NSEvent(cgEvent: copia) else { return }
            self.entregar(ns)
        }
    }

    // MARK: - Hilo principal

    private func entregar(_ evento: NSEvent) {
        let tipo = NSEvent.EventTypeMask(type: evento.type)
        for oyente in oyentes.values where oyente.tipos.contains(tipo) { oyente.manejar(evento) }
    }

    /// Con `tipos`, pone el monitor global de AppKit en lugar de la escucha propia; con nil, lo saca.
    private func respaldar(_ tipos: NSEvent.EventTypeMask?) {
        if let respaldo { NSEvent.removeMonitor(respaldo) }
        respaldo = nil
        guard let tipos, !tipos.isEmpty else { return }
        respaldo = NSEvent.addGlobalMonitorForEvents(matching: tipos) { [weak self] evento in self?.entregar(evento) }
    }
}
