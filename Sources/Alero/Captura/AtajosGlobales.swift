import Carbon.HIToolbox
import CoreGraphics

// Atajos de teclado de toda la Mac con Carbon (`RegisterEventHotKey`): macOS avisa solo cuando se aprieta la
// combinación, sin escuchar el teclado y sin pedir Accesibilidad. Sin atajos registrados no corre nada. Main thread.
//
// Trampas: cada atajo se reconoce por firma Y número, y lo que no es nuestro se
// devuelve sin tocar (`eventNotHandledErr`). Mientras se graba un atajo en Ajustes, se sueltan todos: si no, grabar
// la misma combinación dispararía la captura en vez de llegar al grabador.

final class AtajosGlobales {
    static let shared = AtajosGlobales()

    /// "ALRC": la firma de los atajos de Alero.
    private static let firma: OSType = 0x414C_5243

    private struct Registro {
        let atajo: AtajoTeclado
        let accion: () -> Void
        var referencia: EventHotKeyRef?
    }

    private var registros: [UInt32: Registro] = [:]
    private var manejador: EventHandlerRef?
    private var pausado = false

    /// Pone (o saca, con `atajo` nil) el atajo número `numero`. Devuelve false si macOS no lo dejó registrar
    /// (otra app ya usa esa combinación); en ese caso queda anotado y se reintenta al reanudar.
    @discardableResult
    func poner(_ numero: UInt32, atajo: AtajoTeclado?, accion: @escaping () -> Void) -> Bool {
        soltar(numero)
        registros[numero] = nil
        guard let atajo else { return true }
        instalarManejador()
        var registro = Registro(atajo: atajo, accion: accion)
        let ok = pausado || registrar(numero, &registro)
        registros[numero] = registro
        return ok
    }

    /// Mientras el grabador de atajos escucha (ver arriba).
    func pausar() {
        guard !pausado else { return }
        pausado = true
        registros.keys.forEach(soltar)
    }

    /// Vuelve a registrar todo. Devuelve los números que no se pudieron registrar.
    @discardableResult
    func reanudar() -> Set<UInt32> {
        guard pausado else { return [] }
        pausado = false
        var fallidos = Set<UInt32>()
        for numero in Array(registros.keys) {
            guard var registro = registros[numero] else { continue }
            if !registrar(numero, &registro) { fallidos.insert(numero) }
            registros[numero] = registro
        }
        return fallidos
    }

    /// Las modificadoras de un atajo grabado (banderas de CGEvent) en el formato de Carbon.
    static func modificadorasCarbon(_ flags: CGEventFlags) -> UInt32 {
        var carbon = 0
        if flags.contains(.maskCommand) { carbon |= cmdKey }
        if flags.contains(.maskShift) { carbon |= shiftKey }
        if flags.contains(.maskAlternate) { carbon |= optionKey }
        if flags.contains(.maskControl) { carbon |= controlKey }
        return UInt32(carbon)
    }

    // MARK: - Carbon

    private func registrar(_ numero: UInt32, _ registro: inout Registro) -> Bool {
        var referencia: EventHotKeyRef?
        let id = EventHotKeyID(signature: AtajosGlobales.firma, id: numero)
        let estado = RegisterEventHotKey(UInt32(registro.atajo.codigo), AtajosGlobales.modificadorasCarbon(registro.atajo.flags),
                                         id, GetApplicationEventTarget(), 0, &referencia)
        guard estado == noErr, let referencia else {
            NSLog("Alero: no se pudo registrar el atajo \(registro.atajo.texto) (error \(estado))")
            return false
        }
        registro.referencia = referencia
        return true
    }

    private func soltar(_ numero: UInt32) {
        guard let referencia = registros[numero]?.referencia else { return }
        UnregisterEventHotKey(referencia)
        registros[numero]?.referencia = nil
    }

    /// Un solo manejador para todos los atajos, instalado la primera vez que hace falta.
    private func instalarManejador() {
        guard manejador == nil else { return }
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let estado = InstallEventHandler(GetApplicationEventTarget(), { _, evento, _ in
            AtajosGlobales.shared.recibir(evento)
        }, 1, &tipo, nil, &manejador)
        if estado != noErr { NSLog("Alero: no se pudo escuchar los atajos (error \(estado))") }
    }

    private func recibir(_ evento: EventRef?) -> OSStatus {
        var id = EventHotKeyID()
        let estado = GetEventParameter(evento, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard estado == noErr, id.signature == AtajosGlobales.firma, let registro = registros[id.id] else {
            return OSStatus(eventNotHandledErr)
        }
        registro.accion()
        return noErr
    }
}
