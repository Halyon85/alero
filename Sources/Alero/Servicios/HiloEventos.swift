import CoreGraphics
import Foundation

// Un hilo propio para las "escuchas" (event taps) de teclado y mouse. Si corrieran en el hilo principal, cada clic
// esperaría a que la app esté libre; acá corren aparte, así la interfaz nunca frena al mouse.
// Todas las escuchas de Alero comparten este único hilo.

final class HiloEventos: Thread {
    static let shared: HiloEventos = {
        let hilo = HiloEventos()
        hilo.name = "alero.eventos"
        hilo.qualityOfService = .userInteractive
        hilo.start()
        hilo.listo.wait()
        return hilo
    }()

    private(set) var bucle: CFRunLoop!
    private let listo = DispatchSemaphore(value: 0)

    override func main() {
        bucle = CFRunLoopGetCurrent()
        // Una fuente vacía para que el bucle no termine mientras no haya escuchas.
        var contexto = CFRunLoopSourceContext()
        let fuente = CFRunLoopSourceCreate(nil, 0, &contexto)
        CFRunLoopAddSource(bucle, fuente, .commonModes)
        listo.signal()
        CFRunLoopRun()
    }

    /// Corre `tarea` dentro del hilo (para crear o sacar escuchas sin carreras con sus callbacks).
    func ejecutar(_ tarea: @escaping () -> Void) {
        CFRunLoopPerformBlock(bucle, CFRunLoopMode.commonModes.rawValue, tarea)
        CFRunLoopWakeUp(bucle)
    }

    /// Crea una escucha (activa, salvo `opciones: .listenOnly`: solo mira) y la suma al hilo. Devuelve nil si macOS no
    /// la deja crear (falta Accesibilidad).
    func agregarEscucha(lugar: CGEventTapLocation, posicion: CGEventTapPlacement, eventos: CGEventMask,
                        opciones: CGEventTapOptions = .defaultTap,
                        dueno: UnsafeMutableRawPointer, callback: @escaping CGEventTapCallBack) -> CFMachPort? {
        guard let puerto = CGEvent.tapCreate(tap: lugar, place: posicion, options: opciones,
                                             eventsOfInterest: eventos, callback: callback, userInfo: dueno) else { return nil }
        let fuente = CFMachPortCreateRunLoopSource(nil, puerto, 0)
        ejecutar { [bucle] in CFRunLoopAddSource(bucle, fuente, .commonModes) }
        return puerto
    }

    func sacarEscucha(_ puerto: CFMachPort) {
        CGEvent.tapEnable(tap: puerto, enable: false)
        CFMachPortInvalidate(puerto)
    }
}

/// Marca que llevan los eventos que fabrica Alero, para que sus propias escuchas no los vuelvan a procesar.
/// Se mira junto con el proceso de origen (la marca sola podría coincidir con la de otra app).
enum MarcaPropia {
    static let valor: Int64 = 0x414C_5245 // "ALRE"
    static let proceso = Int64(ProcessInfo.processInfo.processIdentifier)

    static func esPropio(_ evento: CGEvent) -> Bool {
        evento.getIntegerValueField(.eventSourceUserData) == valor
            && evento.getIntegerValueField(.eventSourceUnixProcessID) == proceso
    }
}
