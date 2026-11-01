import Foundation
import Darwin

// Estado de la Mac para el notch: uso del procesador, memoria usada y presión de memoria (lo que de verdad importa en
// Apple Silicon: memoria "llena" es normal).
// Mide solo mientras alguien mira (la vista llama a `empezar` y `terminar`): con el notch cerrado no gasta nada.
// Cada medición son unas pocas llamadas al kernel, cada 2 s, fuera del hilo principal.
//
// A propósito no hay botón de "liberar memoria": sin contraseña de administrador no existe (`purge` pide sudo y solo tira
// la caché del disco, que macOS vuelve a llenar). Se sacó a propósito el 01/11/2026.

/// Las cuentas sin el kernel vivo, para probarlas con `swift test`.
enum ReglasEstadoMac {
    /// Ticks del procesador (usuario, sistema, inactivo, nice), en el orden de `host_cpu_load_info`.
    typealias Ticks = (usuario: UInt64, sistema: UInt64, inactivo: UInt64, nice: UInt64)

    /// Uso del procesador entre dos muestras, de 0 a 1. Sin tiempo transcurrido da 0.
    static func uso(antes: Ticks, ahora: Ticks) -> Double {
        let ocupado = Double((ahora.usuario &- antes.usuario) &+ (ahora.sistema &- antes.sistema) &+ (ahora.nice &- antes.nice))
        let total = ocupado + Double(ahora.inactivo &- antes.inactivo)
        return total > 0 ? min(max(ocupado / total, 0), 1) : 0
    }

    /// Memoria usada como la cuenta el Monitor de Actividad: la de las apps (sin lo que se puede descartar), la fija y
    /// la comprimida. Páginas → bytes.
    static func usada(internas: UInt64, purgables: UInt64, fijas: UInt64, comprimidas: UInt64, pagina: UInt64) -> UInt64 {
        let apps = internas > purgables ? internas - purgables : 0
        return (apps + fijas + comprimidas) * pagina
    }
}

final class EstadoMac: ObservableObject {
    static let shared = EstadoMac()

    enum Presion: Equatable { case normal, aviso, critica }

    @Published private(set) var cpu: Double = 0
    @Published private(set) var usada: UInt64 = 0
    let total: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var presion: Presion = .normal
    @Published private(set) var swap: UInt64 = 0

    private let cola = DispatchQueue(label: "alero.estado", qos: .utility)
    private var reloj: Timer?
    /// Cuántas vistas lo están mirando (puede haber un notch por pantalla).
    private var mirando = 0
    /// Solo en `cola`.
    private var ticksAnteriores: ReglasEstadoMac.Ticks?

    /// Lo llama una vista al aparecer. Mide ya y después cada 2 s. Hilo principal.
    func empezar() {
        mirando += 1
        guard reloj == nil else { return }
        medir()
        let nuevo = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.medir() }
        nuevo.tolerance = 0.5
        RunLoop.main.add(nuevo, forMode: .common)
        reloj = nuevo
    }

    /// Lo llama la vista al irse. Con nadie mirando, para el reloj. Hilo principal.
    func terminar() {
        mirando = max(mirando - 1, 0)
        guard mirando == 0 else { return }
        reloj?.invalidate()
        reloj = nil
        cola.async { self.ticksAnteriores = nil }
    }

    /// Solo para `--capturas`: valores de ejemplo, sin medir nada.
    func simular(cpu: Double, usada: UInt64, presion: Presion, swap: UInt64) {
        self.cpu = cpu
        self.usada = usada
        self.presion = presion
        self.swap = swap
    }

    private func medir() {
        cola.async { [weak self] in
            guard let self else { return }
            let cpu = self.leerCPU()
            let memoria = EstadoMac.leerMemoria()
            let presion = EstadoMac.leerPresion()
            let swap = EstadoMac.leerSwap()
            DispatchQueue.main.async {
                if let cpu { self.cpu = cpu }
                if let memoria { self.usada = memoria }
                self.presion = presion
                self.swap = swap
            }
        }
    }

    // MARK: - Lecturas (en `cola`)

    /// La primera muestra no tiene con qué comparar: devuelve nil y la próxima ya da el uso.
    private func leerCPU() -> Double? {
        var info = host_cpu_load_info()
        var cantidad = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let resultado = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cantidad)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cantidad) }
        }
        guard resultado == KERN_SUCCESS else { return nil }
        let ahora: ReglasEstadoMac.Ticks = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
        defer { ticksAnteriores = ahora }
        return ticksAnteriores.map { ReglasEstadoMac.uso(antes: $0, ahora: ahora) }
    }

    private static func leerMemoria() -> UInt64? {
        var info = vm_statistics64()
        var cantidad = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let resultado = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cantidad)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cantidad) }
        }
        guard resultado == KERN_SUCCESS else { return nil }
        return ReglasEstadoMac.usada(internas: UInt64(info.internal_page_count), purgables: UInt64(info.purgeable_count),
                                     fijas: UInt64(info.wire_count), comprimidas: UInt64(info.compressor_page_count),
                                     pagina: UInt64(vm_kernel_page_size))
    }

    /// 1 normal, 2 aviso, 4 crítico (el mismo dato que pinta el gráfico del Monitor de Actividad).
    private static func leerPresion() -> Presion {
        var nivel: Int32 = 0
        var tamano = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &nivel, &tamano, nil, 0) == 0 else { return .normal }
        return nivel >= 4 ? .critica : nivel >= 2 ? .aviso : .normal
    }

    private static func leerSwap() -> UInt64 {
        var uso = xsw_usage()
        var tamano = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &uso, &tamano, nil, 0) == 0 else { return 0 }
        return uso.xsu_used
    }
}
