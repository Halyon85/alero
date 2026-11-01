import Foundation
import IOKit

// El cable hasta cada monitor externo, para DDC/CI (Apple Silicon). macOS expone un "servicio AV" por salida externa
// (`DCPAVServiceProxy`, ubicación "External") con funciones para mandar y recibir bytes por I2C. Esas funciones no
// están documentadas: se cargan con dlsym de IOKit y, si en un macOS futuro faltan, no hay canales y los monitores van
// por gamma. La pantalla de la MacBook es "Embedded" y no se toca.
//
// Todas las órdenes van en una sola cola, de a una, con 50 ms como mínimo entre dos órdenes al mismo monitor
// (más rápido, algunos monitores se desconectan y vuelven a conectar).

/// Un canal DDC y lo que dice el EDID del monitor enchufado ahí (para emparejarlo con su pantalla).
struct CanalMonitor {
    let servicio: CFTypeRef
    let identidad: IdentidadMonitor
    let nombre: String?
}

enum CanalDDC {
    static let cola = DispatchQueue(label: "alero.ddc", qos: .userInitiated)

    private typealias Crear = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transferir = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let biblioteca = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let crear: Crear? = simbolo("IOAVServiceCreateWithService")
    private static let escribirI2C: Transferir? = simbolo("IOAVServiceWriteI2C")
    private static let leerI2C: Transferir? = simbolo("IOAVServiceReadI2C")

    private static func simbolo<F>(_ nombre: String) -> F? {
        guard let biblioteca, let puntero = dlsym(biblioteca, nombre) else { return nil }
        return unsafeBitCast(puntero, to: F.self)
    }

    /// Solo en `cola`: cuándo fue la última orden a cada monitor.
    private static var ultimaOrden: [String: TimeInterval] = [:]

    // MARK: - Buscar los canales

    /// Los canales de las salidas externas, cada uno con el monitor que tiene enchufado. Cualquier hilo.
    static func canales() -> [CanalMonitor] {
        guard let crear else { return [] }
        var iterador: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterador) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterador) }
        var resultado: [CanalMonitor] = []
        while case let servicio = IOIteratorNext(iterador), servicio != 0 {
            defer { IOObjectRelease(servicio) }
            guard propiedad(servicio, "Location") as? String == "External",
                  let monitor = monitorEnchufado(junto: servicio),
                  let av = crear(kCFAllocatorDefault, servicio)?.takeRetainedValue() else { continue }
            resultado.append(CanalMonitor(servicio: av, identidad: monitor.0, nombre: monitor.1))
        }
        return resultado
    }

    /// El servicio AV cuelga del mismo puerto de pantalla (`dispextN`) que el framebuffer, que es el que sabe qué
    /// monitor hay enchufado: se sube hasta el puerto y se busca el framebuffer entre sus hijos.
    private static func monitorEnchufado(junto servicio: io_service_t) -> (IdentidadMonitor, String?)? {
        var actual = servicio
        IOObjectRetain(actual)
        defer { IOObjectRelease(actual) }
        for _ in 0..<16 {
            var padre: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(actual, kIOServicePlane, &padre) == KERN_SUCCESS else { return nil }
            IOObjectRelease(actual)
            actual = padre
            if IOObjectConformsTo(actual, "AppleARMIODevice") != 0 { return framebuffer(bajo: actual) }
        }
        return nil
    }

    private static func framebuffer(bajo puerto: io_registry_entry_t) -> (IdentidadMonitor, String?)? {
        var iterador: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(puerto, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterador) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterador) }
        while case let hijo = IOIteratorNext(iterador), hijo != 0 {
            defer { IOObjectRelease(hijo) }
            guard let atributos = propiedad(hijo, "DisplayAttributes") as? [String: Any],
                  let producto = atributos["ProductAttributes"] as? [String: Any] else { continue }
            let fabricante = (producto["LegacyManufacturerID"] as? NSNumber)?.uint32Value
                ?? (producto["ManufacturerID"] as? String).flatMap(IdentidadMonitor.fabricante(letras:)) ?? 0
            let identidad = IdentidadMonitor(fabricante: fabricante, modelo: (producto["ProductID"] as? NSNumber)?.uint32Value ?? 0,
                                             serie: (producto["SerialNumber"] as? NSNumber)?.uint32Value ?? 0)
            return (identidad, producto["ProductName"] as? String)
        }
        return nil
    }

    private static func propiedad(_ entrada: io_registry_entry_t, _ nombre: String) -> Any? {
        IORegistryEntryCreateCFProperty(entrada, nombre as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: - Órdenes (solo en `cola`)

    /// El brillo actual y el máximo del monitor. Hasta 3 intentos; nil si no contesta bien (dormido, un adaptador que
    /// no deja pasar DDC, o un monitor que acepta órdenes pero no contesta).
    static func leerBrillo(_ canal: CanalMonitor) -> (actual: UInt16, maximo: UInt16)? {
        dispatchPrecondition(condition: .onQueue(cola))
        guard let escribirI2C, let leerI2C else { return nil }
        let huella = canal.identidad.huella
        for _ in 0..<3 {
            esperarTurno(huella)
            var pedido = ProtocoloDDC.pedidoLectura(vcp: ProtocoloDDC.brillo)
            let enviado = pedido.withUnsafeMutableBytes {
                escribirI2C(canal.servicio, ProtocoloDDC.direccionMonitor, ProtocoloDDC.direccionOrigen, $0.baseAddress!, UInt32($0.count))
            }
            guard enviado == KERN_SUCCESS else { marcar(huella); continue }
            // DDC/CI: el monitor necesita unos 40 ms para preparar la respuesta.
            usleep(50_000)
            var respuesta = [UInt8](repeating: 0, count: 11)
            let leido = respuesta.withUnsafeMutableBytes {
                leerI2C(canal.servicio, ProtocoloDDC.direccionMonitor, ProtocoloDDC.direccionOrigen, $0.baseAddress!, UInt32($0.count))
            }
            marcar(huella)
            if leido == KERN_SUCCESS, let brillo = ProtocoloDDC.leerRespuesta(respuesta, vcp: ProtocoloDDC.brillo) { return brillo }
        }
        return nil
    }

    /// Pone el brillo (0…máximo). Devuelve si el canal aceptó la orden: es el único indicio confiable de que el DDC
    /// anda (hay monitores que no contestan lecturas y adaptadores que "contestan" bytes viejos).
    static func escribirBrillo(_ canal: CanalMonitor, valor: UInt16) -> Bool {
        dispatchPrecondition(condition: .onQueue(cola))
        guard let escribirI2C else { return false }
        let huella = canal.identidad.huella
        esperarTurno(huella)
        var pedido = ProtocoloDDC.pedidoEscritura(vcp: ProtocoloDDC.brillo, valor: valor)
        let estado = pedido.withUnsafeMutableBytes {
            escribirI2C(canal.servicio, ProtocoloDDC.direccionMonitor, ProtocoloDDC.direccionOrigen, $0.baseAddress!, UInt32($0.count))
        }
        marcar(huella)
        return estado == KERN_SUCCESS
    }

    private static func esperarTurno(_ huella: String) {
        let falta = (ultimaOrden[huella] ?? 0) + ProtocoloDDC.esperaEntreOrdenes - ProcessInfo.processInfo.systemUptime
        if falta > 0 { usleep(useconds_t(falta * 1_000_000)) }
    }

    private static func marcar(_ huella: String) {
        ultimaOrden[huella] = ProcessInfo.processInfo.systemUptime
    }
}
