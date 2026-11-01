import CoreAudio
import Foundation

// El "motor" que cambia el volumen de una app (macOS 14.4 o más nuevo). Tres piezas de Core Audio, todas públicas:
//  1. un tap de los procesos de la app, silenciado: su sonido deja de salir por la salida real y Alero lo recibe;
//  2. un agregado privado (solo lo ve Alero) con la salida real adentro y el tap como entrada;
//  3. un proceso de audio sobre ese agregado que copia lo del tap a la salida, con la ganancia elegida.
// Solo existe para las apps que no están al 100 %; destruirlo devuelve la app a su sonido normal.
//
// Lo crea y lo suelta `Mezclador`, siempre fuera del hilo principal (crear tarda y destruir un tap trabado puede no
// volver nunca). La ganancia se cambia desde cualquier hilo.

@available(macOS 14.4, *)
final class MotorVolumen {
    enum Falla: Error, CustomStringConvertible {
        case tap(OSStatus), formatoTap, salida, agregado(OSStatus), proceso(OSStatus), arranque(OSStatus)

        var description: String {
            switch self {
            case .tap(let c): return "no se pudo crear el tap (código \(c))"
            case .formatoTap: return "el tap no viene en Float32"
            case .salida: return "la salida no tiene canales en Float32"
            case .agregado(let c): return "no se pudo crear el agregado (código \(c))"
            case .proceso(let c): return "no se pudo crear el proceso de audio (código \(c))"
            case .arranque(let c): return "no arrancó (código \(c))"
            }
        }
    }

    /// Lo que comparten el motor y el hilo de audio. Son palabras alineadas de 32 y 64 bits: en Apple Silicon leerlas
    /// y escribirlas es atómico, así el hilo de audio nunca espera un candado (a propósito, sin `Atomic`: pide macOS 15).
    private struct Compartido {
        /// Ganancia pedida (ya con la compensación del mixdown).
        var objetivo: Float = 0
        /// La que quedó al final del último buffer (la usa solo el hilo de audio, para la rampa).
        var actual: Float = 0
        /// Ciclos procesados: si no avanza, el motor está colgado (ver `ReglasMezclador.vigilar`).
        var ciclos: UInt64 = 0
    }

    let procesos: Set<AudioObjectID>
    let salida: AudioDeviceID
    private let tap: AudioObjectID
    private let agregado: AudioDeviceID
    private var proceso: AudioDeviceIOProcID?
    private let compartido: UnsafeMutablePointer<Compartido>
    private let compensacion: Float

    var ciclos: UInt64 { compartido.pointee.ciclos }

    /// 0…1 (ver `ReglasMezclador.ganancia`). Cualquier hilo.
    func ponerGanancia(_ ganancia: Float) {
        compartido.pointee.objetivo = ganancia * compensacion
    }

    /// Arma y arranca el motor para estos procesos (los de una app) sobre la salida dada. Si algo falla, deshace lo
    /// que alcanzó a crear y avisa por qué: la app queda sonando normal.
    init(procesos: Set<AudioObjectID>, salida: AudioDeviceID, ganancia: Float) throws {
        self.procesos = procesos
        self.salida = salida
        guard let uidSalida = NucleoAudio.uid(salida), NucleoAudio.salidaEnFloat(salida),
              let mapa = ReglasMezclador.MapaSalida.armar(canales: NucleoAudio.canalesDeSalida(salida), par: NucleoAudio.parEstereo(salida))
        else { throw Falla.salida }
        compensacion = ReglasMezclador.compensacion(canales: mapa.canalesDelStream)

        // 1. El tap: el estéreo de la app, silenciado en la salida real y visible solo para Alero.
        let descripcion = CATapDescription(stereoMixdownOfProcesses: Array(procesos))
        descripcion.uuid = UUID()
        descripcion.name = "Alero"
        descripcion.muteBehavior = .mutedWhenTapped
        descripcion.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let estadoTap = AudioHardwareCreateProcessTap(descripcion, &tap)
        guard estadoTap == noErr, tap != kAudioObjectUnknown else { throw Falla.tap(estadoTap) }
        guard let formato = NucleoAudio.valor(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              NucleoAudio.esFloatIntercalado(formato) else {
            AudioHardwareDestroyProcessTap(tap)
            throw Falla.formatoTap
        }
        self.tap = tap

        // 2. El agregado: la salida real como aparato principal y el tap como entrada. Privado (no aparece en la
        // lista de salidas de nadie) y con compensación de deriva (el reloj del tap y el de la salida no son iguales).
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Alero",
            kAudioAggregateDeviceUIDKey: "team.halyon.alero.mezcla." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uidSalida,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uidSalida]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: descripcion.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var agregado = AudioDeviceID(kAudioObjectUnknown)
        let estadoAgregado = AudioHardwareCreateAggregateDevice(config as CFDictionary, &agregado)
        guard estadoAgregado == noErr, agregado != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            throw Falla.agregado(estadoAgregado)
        }
        self.agregado = agregado

        // 3. El proceso de audio. Arranca desde cero y sube en el primer buffer (sin "clic" al aparecer).
        compartido = .allocate(capacity: 1)
        compartido.initialize(to: Compartido(objetivo: ganancia * compensacion))
        let estado = compartido
        let bloque: AudioDeviceIOBlock = { _, entrada, _, salidaBuffers, _ in
            let desde = estado.pointee.actual
            let hasta = estado.pointee.objetivo
            ReglasMezclador.mezclar(entrada: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: entrada)),
                                    salida: UnsafeMutableAudioBufferListPointer(salidaBuffers), mapa: mapa, desde: desde, hasta: hasta)
            estado.pointee.actual = hasta
            estado.pointee.ciclos &+= 1
        }
        var proceso: AudioDeviceIOProcID?
        let estadoProceso = AudioDeviceCreateIOProcIDWithBlock(&proceso, agregado, nil, bloque)
        guard estadoProceso == noErr, let proceso else {
            Self.destruir(agregado: agregado, tap: tap, compartido: compartido)
            throw Falla.proceso(estadoProceso)
        }
        self.proceso = proceso
        Self.usarSoloElTap(agregado: agregado, proceso: proceso)
        let estadoArranque = AudioDeviceStart(agregado, proceso)
        guard estadoArranque == noErr else {
            AudioDeviceDestroyIOProcID(agregado, proceso)
            self.proceso = nil
            Self.destruir(agregado: agregado, tap: tap, compartido: compartido)
            throw Falla.arranque(estadoArranque)
        }
    }

    /// Para el proceso de audio: con eso el tap deja de silenciar y la app vuelve a sonar sola. Es rápido; lo lento
    /// (destruir el agregado y el tap) va en `desarmar`.
    func detener() {
        guard let proceso else { return }
        AudioDeviceStop(agregado, proceso)
        AudioDeviceDestroyIOProcID(agregado, proceso)
        self.proceso = nil
    }

    /// Destruye todo. Puede tardar (o colgarse, si Core Audio quedó trabado): nunca en el hilo principal.
    func desarmar() {
        detener()
        Self.destruir(agregado: agregado, tap: tap, compartido: compartido)
    }

    private static func destruir(agregado: AudioDeviceID, tap: AudioObjectID, compartido: UnsafeMutablePointer<Compartido>?) {
        AudioHardwareDestroyAggregateDevice(agregado)
        AudioHardwareDestroyProcessTap(tap)
        compartido?.deinitialize(count: 1)
        compartido?.deallocate()
    }

    /// Le dice a Core Audio que el proceso no usa las entradas de la salida (por ejemplo el micrófono de unos
    /// auriculares USB), solo el tap, que va al final. Así no se prende el micrófono ni su luz naranja. Si no se
    /// puede, se sigue igual: la mezcla ignora esas entradas.
    private static func usarSoloElTap(agregado: AudioDeviceID, proceso: AudioDeviceIOProcID) {
        let entradas = NucleoAudio.objetos(agregado, kAudioDevicePropertyStreams, alcance: kAudioObjectPropertyScopeInput).count
        guard entradas > 1 else { return }
        let tamano = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)! + entradas * MemoryLayout<UInt32>.size
        let memoria = UnsafeMutableRawPointer.allocate(byteCount: tamano, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { memoria.deallocate() }
        let uso = memoria.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        uso.pointee.mIOProc = unsafeBitCast(proceso, to: UnsafeMutableRawPointer.self)
        uso.pointee.mNumberStreams = UInt32(entradas)
        let prendidos = (memoria + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).bindMemory(to: UInt32.self, capacity: entradas)
        for i in 0..<entradas { prendidos[i] = i == entradas - 1 ? 1 : 0 }
        var direccion = NucleoAudio.direccion(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let estado = AudioObjectSetPropertyData(agregado, &direccion, 0, nil, UInt32(tamano), memoria)
        if estado != noErr { NSLog("Alero: no se pudieron apagar las entradas sobrantes del mezclador (código \(estado))") }
    }
}
