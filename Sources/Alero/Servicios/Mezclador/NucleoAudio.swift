import AppKit
import CoreAudio

// Lecturas de Core Audio que usa el mezclador: los procesos que tienen audio (uno por programa, incluidos los
// ayudantes de Chrome o Safari), la salida por defecto y cómo son sus canales. Solo lee: no cambia nada.
// Cualquier hilo (Core Audio no pide el principal).

/// Un proceso con conexión de audio, como lo ve Core Audio.
struct ProcesoAudio: Equatable {
    let objeto: AudioObjectID
    let pid: pid_t
    let bundle: String
    /// Está mandando sonido a una salida ahora mismo.
    let sonando: Bool
}

enum NucleoAudio {
    static let sistema = AudioObjectID(kAudioObjectSystemObject)

    static func direccion(_ selector: AudioObjectPropertySelector,
                          _ alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: alcance, mElement: kAudioObjectPropertyElementMain)
    }

    /// Un valor de tamaño fijo (números, IDs, estructuras). Nil si el objeto no lo tiene o falla.
    static func valor<T: BitwiseCopyable>(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector, _ vacio: T,
                         alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var direccion = direccion(selector, alcance)
        guard AudioObjectHasProperty(objeto, &direccion) else { return nil }
        var valor = vacio
        var tamano = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(objeto, &direccion, 0, nil, &tamano, &valor) == noErr ? valor : nil
    }

    static func texto(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var direccion = direccion(selector)
        guard AudioObjectHasProperty(objeto, &direccion) else { return nil }
        var valor: Unmanaged<CFString>?
        var tamano = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objeto, &direccion, 0, nil, &tamano, &valor) == noErr else { return nil }
        return valor?.takeRetainedValue() as String?
    }

    static func objetos(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var direccion = direccion(selector, alcance)
        var tamano: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objeto, &direccion, 0, nil, &tamano) == noErr, tamano > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(tamano) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(objeto, &direccion, 0, nil, &tamano, &ids) == noErr else { return [] }
        return ids
    }

    // MARK: - Procesos

    /// Los procesos con audio, menos Alero misma (su propio sonido no se mezcla).
    static func procesos() -> [ProcesoAudio] {
        let propio = ProcessInfo.processInfo.processIdentifier
        return objetos(sistema, kAudioHardwarePropertyProcessObjectList).compactMap { objeto in
            guard let pid = valor(objeto, kAudioProcessPropertyPID, pid_t(0)), pid > 0, pid != propio else { return nil }
            let sonando = (valor(objeto, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            return ProcesoAudio(objeto: objeto, pid: pid, bundle: texto(objeto, kAudioProcessPropertyBundleID) ?? "", sonando: sonando)
        }
    }

    /// La app normal (con ícono en el Dock) que es dueña del proceso. Ver `ReglasMezclador.dueno`.
    static func dueno(de pid: pid_t) -> NSRunningApplication? {
        let esApp: (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
        guard let encontrado = ReglasMezclador.dueno(de: pid, responsable: responsable(de:), padre: padre(de:), esApp: esApp) else { return nil }
        return NSRunningApplication(processIdentifier: encontrado)
    }

    private typealias FuncionResponsable = @convention(c) (pid_t) -> pid_t
    /// Función de macOS sin documentar (la usa el Monitor de Actividad para agrupar ayudantes). Si falta, se sigue
    /// solo por los padres.
    private static let funcionResponsable: FuncionResponsable? = {
        guard let simbolo = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(simbolo, to: FuncionResponsable.self)
    }()

    private static func responsable(de pid: pid_t) -> pid_t? {
        guard let funcionResponsable else { return nil }
        let r = funcionResponsable(pid)
        return r > 0 ? r : nil
    }

    private static func padre(de pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var tamano = MemoryLayout<kinfo_proc>.size
        var nombre: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&nombre, 4, &info, &tamano, nil, 0) == 0, tamano > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Salida

    static func salidaPorDefecto() -> AudioDeviceID {
        valor(sistema, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0)) ?? 0
    }

    static func uid(_ dispositivo: AudioDeviceID) -> String? {
        texto(dispositivo, kAudioDevicePropertyDeviceUID)
    }

    /// Cuántos canales tiene cada stream de salida del aparato, en orden.
    static func canalesDeSalida(_ dispositivo: AudioDeviceID) -> [Int] {
        var direccion = direccion(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var tamano: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dispositivo, &direccion, 0, nil, &tamano) == noErr, tamano > 0 else { return [] }
        let memoria = UnsafeMutableRawPointer.allocate(byteCount: Int(tamano), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memoria.deallocate() }
        guard AudioObjectGetPropertyData(dispositivo, &direccion, 0, nil, &tamano, memoria) == noErr else { return [] }
        let lista = UnsafeMutableAudioBufferListPointer(memoria.assumingMemoryBound(to: AudioBufferList.self))
        return lista.map { Int($0.mNumberChannels) }
    }

    /// El par de canales que la salida usa para el estéreo (desde 1). Nil si no lo dice.
    static func parEstereo(_ dispositivo: AudioDeviceID) -> (UInt32, UInt32)? {
        guard let par = valor(dispositivo, kAudioDevicePropertyPreferredChannelsForStereo, (UInt32(0), UInt32(0)),
                              alcance: kAudioObjectPropertyScopeOutput) else { return nil }
        return par
    }

    /// Si todos los streams de salida trabajan en Float32 intercalado (lo único que sabe mezclar el motor).
    static func salidaEnFloat(_ dispositivo: AudioDeviceID) -> Bool {
        let streams = objetos(dispositivo, kAudioDevicePropertyStreams, alcance: kAudioObjectPropertyScopeOutput)
        guard !streams.isEmpty else { return false }
        return streams.allSatisfy { stream in
            guard let formato = valor(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) else { return false }
            return esFloatIntercalado(formato)
        }
    }

    static func esFloatIntercalado(_ formato: AudioStreamBasicDescription) -> Bool {
        formato.mFormatID == kAudioFormatLinearPCM
            && formato.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && formato.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            && formato.mBitsPerChannel == 32
    }
}
