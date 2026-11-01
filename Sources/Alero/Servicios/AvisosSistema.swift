import Foundation
import IOKit.ps

// Dos avisos chicos para el notch cerrado: cuando enchufás o desenchufás el cargador (con el porcentaje de batería) y
// cuando termina una descarga en la carpeta Descargas. Los dos se enteran por avisos de macOS (IOPowerSources y
// FSEvents): sin cambios no hay ningún trabajo. Se prenden y apagan desde Alero › Notch cerrado. Main thread.

/// Las reglas sin el sistema vivo (se prueban con `swift test`).
enum ReglasAvisos {
    /// Extensiones de descargas a medio bajar (Safari, Chrome, Firefox, Edge y otros): todavía no son un archivo.
    static let enCurso: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload", "filepart"]

    /// Los nombres nuevos que ya son descargas terminadas: ni ocultos ni a medio bajar.
    static func terminadas(antes: Set<String>, ahora: Set<String>) -> [String] {
        ahora.subtracting(antes)
            .filter { !$0.hasPrefix(".") && !enCurso.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }
}

final class Corriente {
    static let shared = Corriente()

    /// Se llama al enchufar (true) o desenchufar (false), con el porcentaje de batería si lo hay.
    var alCambiar: ((Bool, Int?) -> Void)?
    private var fuente: CFRunLoopSource?
    private var enchufada: Bool?

    func arrancar() {
        guard fuente == nil else { return }
        enchufada = Corriente.leer().enchufada
        let contexto = Unmanaged.passUnretained(self).toOpaque()
        guard let nueva = IOPSNotificationCreateRunLoopSource({ contexto in
            guard let contexto else { return }
            Unmanaged<Corriente>.fromOpaque(contexto).takeUnretainedValue().cambio()
        }, contexto)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), nueva, .defaultMode)
        fuente = nueva
    }

    func detener() {
        guard let fuente else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), fuente, .defaultMode)
        self.fuente = nil
    }

    /// macOS avisa también cuando cambia el porcentaje: solo cuenta el cambio de enchufada a batería o al revés.
    private func cambio() {
        let ahora = Corriente.leer()
        guard let enchufadaAhora = ahora.enchufada, enchufadaAhora != enchufada else { return }
        enchufada = enchufadaAhora
        alCambiar?(enchufadaAhora, ahora.porcentaje)
    }

    /// Si está enchufada (nil en una Mac sin batería) y el porcentaje.
    static func leer() -> (enchufada: Bool?, porcentaje: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let lista = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil) }
        for fuente in lista {
            guard let datos = IOPSGetPowerSourceDescription(info, fuente)?.takeUnretainedValue() as? [String: Any],
                  datos[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let estado = datos[kIOPSPowerSourceStateKey] as? String
            let actual = datos[kIOPSCurrentCapacityKey] as? Int
            let maximo = datos[kIOPSMaxCapacityKey] as? Int
            let porcentaje = actual.flatMap { a in maximo.map { m in m > 0 ? a * 100 / m : a } }
            return (estado == kIOPSACPowerValue, porcentaje)
        }
        return (nil, nil)
    }
}

final class Descargas {
    static let shared = Descargas()

    /// Se llama con los nombres de las descargas que terminaron.
    var alTerminar: (([String]) -> Void)?
    private let carpeta = NSHomeDirectory() + "/Downloads"
    private var flujo: FSEventStreamRef?
    private var conocidos = Set<String>()

    func arrancar() {
        guard flujo == nil, let actuales = leer() else { return }
        conocidos = actuales
        var contexto = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let alCambiar: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let yo = Unmanaged<Descargas>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { yo.revisar() }
        }
        guard let nuevo = FSEventStreamCreate(nil, alCambiar, &contexto, [carpeta] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5,
                                              UInt32(kFSEventStreamCreateFlagIgnoreSelf)) else { return }
        FSEventStreamSetDispatchQueue(nuevo, .main)
        FSEventStreamStart(nuevo)
        flujo = nuevo
    }

    func detener() {
        guard let flujo else { return }
        FSEventStreamStop(flujo)
        FSEventStreamInvalidate(flujo)
        FSEventStreamRelease(flujo)
        self.flujo = nil
    }

    private func revisar() {
        guard let actuales = leer() else { return }
        let nuevas = ReglasAvisos.terminadas(antes: conocidos, ahora: actuales)
        conocidos = actuales
        // Muchos de golpe es que se movió una carpeta adentro, no una descarga: no se avisa.
        if !nuevas.isEmpty, nuevas.count <= 3 { alTerminar?(nuevas) }
    }

    /// Los nombres de la carpeta (solo el primer nivel). Nil si macOS no deja leerla (falta el permiso de Descargas).
    private func leer() -> Set<String>? {
        do { return Set(try FileManager.default.contentsOfDirectory(atPath: carpeta)) } catch {
            NSLog("Alero: no se pudo leer Descargas para avisar las descargas: \(error.localizedDescription)")
            return nil
        }
    }
}
