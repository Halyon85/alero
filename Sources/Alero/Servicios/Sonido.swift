import AudioToolbox
import CoreAudio
import Foundation

// Salidas de sonido (parlantes, auriculares, monitores) y el volumen de la salida actual, con Core Audio (API
// pública, sin permisos). La lista se actualiza sola cuando se conecta o desconecta algo o cambia la salida.
// Se recuerda el UID de cada aparato y no su número: el número cambia cada vez que se reconecta.

struct Salida: Identifiable, Equatable {
    enum Tipo { case parlantes, auriculares, bluetooth, monitor, airplay, otro }
    let id: AudioDeviceID
    let uid: String
    let nombre: String
    let tipo: Tipo
}

final class Sonido: ObservableObject {
    static let shared = Sonido()

    @Published private(set) var salidas: [Salida] = []
    @Published private(set) var actual: AudioDeviceID = 0

    /// Se llama cuando aparece un aparato nuevo y macOS lo elige como salida (ej.: se conectaron los AirPods).
    var alConectarse: ((Salida) -> Void)?

    private let sistema = AudioObjectID(kAudioObjectSystemObject)
    private var escuchando = false

    private init() {
        recargar()
        escuchar()
    }

    var salidaActual: Salida? { salidas.first { $0.id == actual } }

    func elegir(_ salida: Salida) {
        var id = salida.id
        var direccion = Sonido.direccion(kAudioHardwarePropertyDefaultOutputDevice)
        let estado = AudioObjectSetPropertyData(sistema, &direccion, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if estado != noErr { NSLog("Alero: no se pudo cambiar la salida a \(salida.nombre) (código \(estado))") }
        // No se relee al instante: Core Audio avisa con el listener cuando el cambio quedó hecho.
    }

    /// Pasa a la siguiente salida de la lista (atajo del notch).
    func siguiente() {
        guard !salidas.isEmpty else { return }
        let indice = salidas.firstIndex { $0.id == actual } ?? -1
        elegir(salidas[(indice + 1) % salidas.count])
    }

    // MARK: - Volumen de la salida actual (lo usan las teclas de volumen)

    /// 0…1, o nil si la salida no deja cambiar el volumen (ej.: HDMI): ahí las teclas siguen yendo a macOS.
    func volumen() -> Float? {
        var valor: Float32 = 0
        var tamano = UInt32(MemoryLayout<Float32>.size)
        var direccion = Sonido.direccion(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, alcance: kAudioDevicePropertyScopeOutput)
        let dispositivo = salidaPorDefecto()
        guard AudioObjectHasProperty(dispositivo, &direccion),
              AudioObjectGetPropertyData(dispositivo, &direccion, 0, nil, &tamano, &valor) == noErr else { return nil }
        return valor
    }

    /// Devuelve false si no se pudo (la tecla tiene que seguir hacia macOS).
    @discardableResult
    func ponerVolumen(_ nuevo: Float) -> Bool {
        var valor = Float32(min(max(nuevo, 0), 1))
        var direccion = Sonido.direccion(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, alcance: kAudioDevicePropertyScopeOutput)
        let dispositivo = salidaPorDefecto()
        var sePuede: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dispositivo, &direccion, &sePuede) == noErr, sePuede.boolValue else { return false }
        let ok = AudioObjectSetPropertyData(dispositivo, &direccion, 0, nil, UInt32(MemoryLayout<Float32>.size), &valor) == noErr
        // Subir el volumen con la salida silenciada la des-silencia, como hace macOS.
        if ok, valor > 0, silenciado() == true { ponerSilencio(false) }
        return ok
    }

    func silenciado() -> Bool? {
        var valor: UInt32 = 0
        var tamano = UInt32(MemoryLayout<UInt32>.size)
        var direccion = Sonido.direccion(kAudioDevicePropertyMute, alcance: kAudioDevicePropertyScopeOutput)
        let dispositivo = salidaPorDefecto()
        guard AudioObjectHasProperty(dispositivo, &direccion),
              AudioObjectGetPropertyData(dispositivo, &direccion, 0, nil, &tamano, &valor) == noErr else { return nil }
        return valor != 0
    }

    @discardableResult
    func ponerSilencio(_ silencio: Bool) -> Bool {
        var valor: UInt32 = silencio ? 1 : 0
        var direccion = Sonido.direccion(kAudioDevicePropertyMute, alcance: kAudioDevicePropertyScopeOutput)
        let dispositivo = salidaPorDefecto()
        guard AudioObjectHasProperty(dispositivo, &direccion) else { return false }
        return AudioObjectSetPropertyData(dispositivo, &direccion, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valor) == noErr
    }

    // MARK: - Lista de salidas

    private func recargar() {
        let anteriores = Set(salidas.map(\.uid))
        let nuevas = listarSalidas()
        let nuevaActual = salidaPorDefecto()
        let huboAntes = !salidas.isEmpty
        salidas = nuevas
        actual = nuevaActual
        // Un aparato que recién apareció y quedó como salida = "se conectaron los auriculares".
        if huboAntes, let elegida = nuevas.first(where: { $0.id == nuevaActual }), !anteriores.contains(elegida.uid) {
            alConectarse?(elegida)
        }
    }

    private func escuchar() {
        guard !escuchando else { return }
        escuchando = true
        let alCambiar: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.recargar() }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var direccion = Sonido.direccion(selector)
            let estado = AudioObjectAddPropertyListenerBlock(sistema, &direccion, .main, alCambiar)
            if estado != noErr { NSLog("Alero: no se pudo escuchar cambios de sonido (código \(estado))") }
        }
    }

    private func salidaPorDefecto() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var tamano = UInt32(MemoryLayout<AudioDeviceID>.size)
        var direccion = Sonido.direccion(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(sistema, &direccion, 0, nil, &tamano, &id)
        return id
    }

    private func listarSalidas() -> [Salida] {
        var direccion = Sonido.direccion(kAudioHardwarePropertyDevices)
        var tamano: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sistema, &direccion, 0, nil, &tamano) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(tamano) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sistema, &direccion, 0, nil, &tamano, &ids) == noErr else { return [] }
        return ids.compactMap(salida(de:))
    }

    /// Solo aparatos con salida, visibles y que macOS acepta como salida principal.
    private func salida(de id: AudioDeviceID) -> Salida? {
        var flujos = Sonido.direccion(kAudioDevicePropertyStreams, alcance: kAudioDevicePropertyScopeOutput)
        var tamano: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &flujos, 0, nil, &tamano) == noErr, tamano > 0 else { return nil }
        if entero(id, kAudioDevicePropertyIsHidden) == 1 { return nil }
        if entero(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, alcance: kAudioDevicePropertyScopeOutput) == 0 { return nil }
        guard let uid = texto(id, kAudioDevicePropertyDeviceUID), let nombre = texto(id, kAudioObjectPropertyName) else { return nil }
        return Salida(id: id, uid: uid, nombre: nombre, tipo: tipo(de: id))
    }

    private func tipo(de id: AudioDeviceID) -> Salida.Tipo {
        switch entero(id, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn:
            // La salida integrada cambia de "fuente" cuando enchufás auriculares con cable.
            let fuente = entero(id, kAudioDevicePropertyDataSource, alcance: kAudioDevicePropertyScopeOutput)
            return fuente == 0x6864_706E ? .auriculares : .parlantes // 'hdpn'
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .monitor
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        default: return .otro
        }
    }

    // MARK: - Ayudas de Core Audio

    static func direccion(_ selector: AudioObjectPropertySelector,
                          alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: alcance, mElement: kAudioObjectPropertyElementMain)
    }

    private func entero(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var direccion = Sonido.direccion(selector, alcance: alcance)
        guard AudioObjectHasProperty(id, &direccion) else { return nil }
        var valor: UInt32 = 0
        var tamano = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &direccion, 0, nil, &tamano, &valor) == noErr ? valor : nil
    }

    private func texto(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var direccion = Sonido.direccion(selector)
        var valor: Unmanaged<CFString>?
        var tamano = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &direccion, 0, nil, &tamano, &valor) == noErr,
              let cadena = valor?.takeRetainedValue() else { return nil }
        return cadena as String
    }
}
