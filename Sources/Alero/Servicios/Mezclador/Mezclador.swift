import AppKit
import Combine
import CoreAudio

// El volumen de cada app (macOS 14.4 o más nuevo; antes, la función no se muestra). Lista las apps que están
// sonando y, para cada una que no está al 100 %, arma un `MotorVolumen`. Volver al 100 % lo destruye: la app vuelve a
// su sonido normal y no queda nada corriendo para ella.
//
// Liviano a propósito: con la función apagada no escucha nada. Prendida, solo escucha a Core Audio (sin consultar a
// cada rato) mientras la columna de sonido está a la vista, haya apps ajustadas o volúmenes recordados. Sigue los
// cambios de salida (rehace los motores en la salida nueva, primero el nuevo y después suelta el viejo) y, al
// despertar la Mac, revisa que ningún motor haya quedado colgado (si no, la app quedaría muda).
//
// Main thread. Las lecturas de Core Audio van en una cola propia (con un aparato reconfigurándose pueden tardar) y
// armar y desarmar motores, en otras dos.

/// Lo que el mezclador necesita de un motor (así la lista no depende de la versión de macOS).
protocol MotorDeApp: AnyObject {
    var procesos: Set<AudioObjectID> { get }
    var ciclos: UInt64 { get }
    func ponerGanancia(_ ganancia: Float)
    func detener()
    func desarmar()
}

@available(macOS 14.4, *)
extension MotorVolumen: MotorDeApp {}

/// Una app en la lista del mezclador.
struct AppAudio: Identifiable, Equatable {
    /// El identificador de la app dueña o, si no tiene, "pid:N".
    let id: String
    let pid: pid_t
    let bundle: String?
    let nombre: String
    var volumen: Float
    var silencio: Bool
    var sonando: Bool
    /// macOS no dejó ajustarla (o el motor se colgó dos veces): suena normal, al 100 %.
    var fallo: Bool
}

final class Mezclador: ObservableObject {
    static let shared = Mezclador()

    static var disponible: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    @Published private(set) var apps: [AppAudio] = []
    @Published private(set) var permiso: PermisoAudio.Estado = .desconocido

    private struct Ajuste { var volumen: Float = 1; var silencio = false }

    /// Una app con audio: sus procesos (la app y sus ayudantes) agrupados.
    private struct Grupo {
        let clave: String
        let pid: pid_t
        let bundle: String?
        let nombre: String
        var objetos: Set<AudioObjectID> = []
        var sonando = false
    }

    private struct EnUso {
        let motor: MotorDeApp
        /// La salida tal como era al armarlo (aparato, canales y par estéreo): si cambia, se rehace.
        let firma: String
        let rehecho: Bool
    }

    private struct EnCamino {
        let generacion: Int
        let objetos: Set<AudioObjectID>
        let firma: String
    }

    private struct Dueno { let pid: pid_t; let clave: String; let bundle: String?; let nombre: String }

    private var suscripciones = Set<AnyCancellable>()
    private var observadorDespertar: NSObjectProtocol?
    private var activo = false
    private var visibles = 0
    private var simulado = false
    private var ajustes: [String: Ajuste] = [:]
    private var motores: [String: EnUso] = [:]
    private var enCamino: [String: EnCamino] = [:]
    private var generacion = 0
    private var fallidas: Set<String> = []
    private var grupos: [String: Grupo] = [:]
    private var salida: AudioDeviceID = 0
    private var firmaSalida = ""
    private var pidiendoPermiso = false

    // Escuchas de Core Audio (con función C: las de bloque no se pueden sacar, Core Audio dice que sí y siguen vivas).
    private var escuchandoSistema = false
    private var procesosEscuchados: Set<AudioObjectID> = []
    private var salidaEscuchada: AudioDeviceID = 0

    // Revisión: una a la vez; si llegan avisos mientras corre, se hace una más al terminar.
    private var revisando = false
    private var otraRevision = false

    private let colaLectura = DispatchQueue(label: "alero.mezclador.lectura", qos: .userInitiated)
    private let colaArmado = DispatchQueue(label: "alero.mezclador.armado", qos: .userInitiated)
    private let colaDesarmado = DispatchQueue(label: "alero.mezclador.desarmado", qos: .utility)
    /// Solo la usa `colaLectura`.
    private var cacheDuenos: [pid_t: Dueno?] = [:]

    func arrancar() {
        guard Self.disponible else { return }
        Ajustes.shared.$mezcladorActivo.removeDuplicates().sink { [weak self] prender in
            prender ? self?.prender() : self?.apagar()
        }.store(in: &suscripciones)
    }

    private func prender() {
        guard !activo, !simulado else { return }
        activo = true
        permiso = PermisoAudio.estado
        observadorDespertar = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                                 queue: .main) { [weak self] _ in
            // Core Audio tarda en volver: se espera un poco antes de mirar si algún motor quedó colgado.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.alDespertar() }
        }
        revisar()
    }

    private func apagar() {
        guard activo else { return }
        activo = false
        if let observadorDespertar { NSWorkspace.shared.notificationCenter.removeObserver(observadorDespertar) }
        observadorDespertar = nil
        ajustes = [:]
        fallidas = []
        enCamino = [:]
        for clave in Array(motores.keys) { soltar(clave) }
        dejarDeEscuchar()
        apps = []
    }

    /// La columna de sonido del notch avisa cuando aparece y cuando se va (puede haber un notch por pantalla).
    func mirar(_ visible: Bool) {
        visibles = max(0, visibles + (visible ? 1 : -1))
        guard activo else { return }
        if visible { permiso = PermisoAudio.estado }
        revisar()
    }

    /// Al cerrar Alero: para los motores al toque (macOS destruye solo lo privado de un proceso que termina).
    func terminar() {
        for uso in motores.values { uso.motor.detener() }
        motores = [:]
    }

    // MARK: - Lo que pide la persona

    func cambiar(_ id: String, volumen: Float) {
        var ajuste = ajustes[id] ?? Ajuste()
        ajuste.volumen = min(max(volumen, 0), 1)
        aplicar(ajuste, a: id)
    }

    func alternarSilencio(_ id: String) {
        var ajuste = ajustes[id] ?? Ajuste()
        ajuste.silencio.toggle()
        aplicar(ajuste, a: id)
    }

    private func aplicar(_ ajuste: Ajuste, a id: String) {
        guard !simulado else { return }
        ajustes[id] = ajuste
        fallidas.remove(id)
        if let i = apps.firstIndex(where: { $0.id == id }) {
            apps[i].volumen = ajuste.volumen
            apps[i].silencio = ajuste.silencio
            apps[i].fallo = false
            if let bundle = apps[i].bundle { Ajustes.shared.recordarVolumen(ajuste.volumen, de: bundle) }
        }
        let ganancia = ReglasMezclador.ganancia(deslizador: ajuste.volumen, silencio: ajuste.silencio)
        if let uso = motores[id] { uso.motor.ponerGanancia(ganancia) }
        if ReglasMezclador.esNeutro(deslizador: ajuste.volumen, silencio: ajuste.silencio) {
            // Al 100 % se suelta la app, con un respiro: arrastrando el deslizador se pasa por el 100 % sin querer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let actual = self.ajustes[id], ReglasMezclador.esNeutro(deslizador: actual.volumen, silencio: actual.silencio) else { return }
                self.ajustes.removeValue(forKey: id)
                self.soltar(id)
                self.revisar()
            }
        } else if motores[id] == nil, let grupo = grupos[id] {
            asegurarMotor(grupo, ganancia: ganancia, rehecho: false)
        }
    }

    // MARK: - Revisión (procesos, grupos y motores)

    /// Lee los procesos con audio y deja cada app como corresponde. Se llama con cada aviso de Core Audio.
    func revisar() {
        guard activo, !simulado else { return }
        if revisando { otraRevision = true; return }
        revisando = true
        colaLectura.async { [weak self] in
            guard let self else { return }
            let procesos = NucleoAudio.procesos()
            let salida = NucleoAudio.salidaPorDefecto()
            let firma = Self.firma(de: salida)
            let duenos = self.duenos(de: procesos)
            DispatchQueue.main.async {
                self.revisando = false
                self.aplicar(procesos: procesos, duenos: duenos, salida: salida, firma: firma)
                if self.otraRevision { self.otraRevision = false; self.revisar() }
            }
        }
    }

    private static func firma(de salida: AudioDeviceID) -> String {
        let par = NucleoAudio.parEstereo(salida).map { "\($0.0),\($0.1)" } ?? "-"
        return "\(NucleoAudio.uid(salida) ?? "?")|\(NucleoAudio.canalesDeSalida(salida))|\(par)"
    }

    /// Solo en `colaLectura`. Recuerda el dueño de cada proceso (no cambia mientras el proceso vive).
    private func duenos(de procesos: [ProcesoAudio]) -> [pid_t: Dueno] {
        let vivos = Set(procesos.map(\.pid))
        cacheDuenos = cacheDuenos.filter { vivos.contains($0.key) }
        var resultado: [pid_t: Dueno] = [:]
        for proceso in procesos {
            if cacheDuenos[proceso.pid] == nil {
                cacheDuenos[proceso.pid] = NucleoAudio.dueno(de: proceso.pid).map { app in
                    let bundle = app.bundleIdentifier
                    return Dueno(pid: app.processIdentifier, clave: bundle ?? "pid:\(app.processIdentifier)", bundle: bundle,
                                 nombre: app.localizedName ?? bundle ?? "App")
                }
            }
            if let dueno = cacheDuenos[proceso.pid] ?? nil { resultado[proceso.pid] = dueno }
        }
        return resultado
    }

    private func aplicar(procesos: [ProcesoAudio], duenos: [pid_t: Dueno], salida: AudioDeviceID, firma: String) {
        guard activo else { return }
        self.salida = salida
        firmaSalida = firma
        var nuevos: [String: Grupo] = [:]
        for proceso in procesos {
            guard let dueno = duenos[proceso.pid] else { continue }
            var grupo = nuevos[dueno.clave] ?? Grupo(clave: dueno.clave, pid: dueno.pid, bundle: dueno.bundle, nombre: dueno.nombre)
            grupo.objetos.insert(proceso.objeto)
            grupo.sonando = grupo.sonando || proceso.sonando
            nuevos[dueno.clave] = grupo
        }
        grupos = nuevos

        // Volúmenes recordados: se aplican cuando la app empieza a sonar (antes no hace falta armar nada).
        for grupo in nuevos.values where grupo.sonando && ajustes[grupo.clave] == nil {
            if let bundle = grupo.bundle, let recordado = Ajustes.shared.volumenRecordado(bundle) {
                ajustes[grupo.clave] = Ajuste(volumen: recordado)
            }
        }

        for (clave, ajuste) in ajustes {
            if ReglasMezclador.esNeutro(deslizador: ajuste.volumen, silencio: ajuste.silencio) { continue }
            guard let grupo = nuevos[clave] else {
                // La app se cerró. Lo de esta sesión se guarda por identificador (vuelve si la abrís de nuevo);
                // si no tiene identificador, el número de proceso se recicla y no sirve de nada guardarlo.
                soltar(clave)
                if clave.hasPrefix("pid:") { ajustes.removeValue(forKey: clave) }
                continue
            }
            if fallidas.contains(clave) { soltar(clave); continue }
            asegurarMotor(grupo, ganancia: ReglasMezclador.ganancia(deslizador: ajuste.volumen, silencio: ajuste.silencio), rehecho: false)
        }
        for clave in motores.keys where ajustes[clave] == nil { soltar(clave) }

        apps = nuevos.values.filter { $0.sonando || ajustes[$0.clave] != nil }
            .map { grupo in
                let ajuste = ajustes[grupo.clave] ?? Ajuste()
                return AppAudio(id: grupo.clave, pid: grupo.pid, bundle: grupo.bundle, nombre: grupo.nombre, volumen: ajuste.volumen,
                                silencio: ajuste.silencio, sonando: grupo.sonando, fallo: fallidas.contains(grupo.clave))
            }
            .sorted { $0.nombre.localizedCaseInsensitiveCompare($1.nombre) == .orderedAscending }
        actualizarEscuchas(procesos)
    }

    // MARK: - Motores

    /// Deja un motor andando para la app, con sus procesos de ahora y en la salida de ahora. Si ya hay uno igual, solo
    /// cambia la ganancia. Si hay uno distinto (cambió la salida o la app sumó un proceso), arma el nuevo y recién
    /// cuando arrancó suelta el viejo: el sonido nunca vuelve al 100 % en el medio.
    private func asegurarMotor(_ grupo: Grupo, ganancia: Float, rehecho: Bool) {
        guard #available(macOS 14.4, *) else { return }
        let clave = grupo.clave
        if let uso = motores[clave], uso.motor.procesos == grupo.objetos, uso.firma == firmaSalida {
            uso.motor.ponerGanancia(ganancia)
            return
        }
        if let camino = enCamino[clave], camino.objetos == grupo.objetos, camino.firma == firmaSalida { return }
        guard permisoListo() else { return }
        generacion += 1
        let numero = generacion
        let objetos = grupo.objetos
        let firma = firmaSalida
        let salida = self.salida
        enCamino[clave] = EnCamino(generacion: numero, objetos: objetos, firma: firma)
        let anterior = motores[clave]?.motor
        colaArmado.async { [weak self] in
            do {
                let nuevo = try MotorVolumen(procesos: objetos, salida: salida, ganancia: ganancia)
                // Cruce: el viejo baja mientras sube el nuevo (si no, suenan los dos un instante).
                anterior?.ponerGanancia(0)
                DispatchQueue.main.async { self?.instalar(nuevo, clave: clave, numero: numero, firma: firma, rehecho: rehecho) }
            } catch {
                DispatchQueue.main.async { self?.fallo(clave: clave, numero: numero, error: error) }
            }
        }
    }

    private func instalar(_ motor: MotorDeApp, clave: String, numero: Int, firma: String, rehecho: Bool) {
        // Un armado viejo que llega tarde se descarta: si no, habría dos taps sobre la misma app y sonaría doble.
        guard activo, enCamino[clave]?.generacion == numero, let ajuste = ajustes[clave],
              !ReglasMezclador.esNeutro(deslizador: ajuste.volumen, silencio: ajuste.silencio) else {
            desarmarEnFondo(motor)
            return
        }
        enCamino.removeValue(forKey: clave)
        if let viejo = motores[clave] { desarmarEnFondo(viejo.motor) }
        motor.ponerGanancia(ReglasMezclador.ganancia(deslizador: ajuste.volumen, silencio: ajuste.silencio))
        motores[clave] = EnUso(motor: motor, firma: firma, rehecho: rehecho)
        // El primer agregado a veces nace muerto: se mira enseguida, sin esperar otro aviso de Core Audio.
        vigilar(clave, motor)
    }

    private func fallo(clave: String, numero: Int, error: Error) {
        guard enCamino[clave]?.generacion == numero else { return }
        enCamino.removeValue(forKey: clave)
        NSLog("Alero: no se pudo ajustar el volumen de \(clave): \(error)")
        permiso = PermisoAudio.estado
        fallidas.insert(clave)
        if let i = apps.firstIndex(where: { $0.id == clave }) { apps[i].fallo = true }
    }

    private func soltar(_ clave: String) {
        enCamino.removeValue(forKey: clave)
        if let uso = motores.removeValue(forKey: clave) { desarmarEnFondo(uso.motor) }
    }

    /// Parar el proceso de audio devuelve el sonido a la app al instante y va en una cola cualquiera; destruir el tap
    /// puede colgarse si Core Audio quedó trabado, así que va en una cola propia, de a uno, sin trabar a las demás.
    private func desarmarEnFondo(_ motor: MotorDeApp) {
        let colaDesarmado = colaDesarmado
        DispatchQueue.global(qos: .userInitiated).async {
            motor.detener()
            colaDesarmado.async { motor.desarmar() }
        }
    }

    /// Mira en 1,5 s si el motor sigue procesando audio. Si no, lo rehace una vez; si tampoco, suelta la app.
    private func vigilar(_ clave: String, _ motor: MotorDeApp) {
        let antes = motor.ciclos
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let uso = self.motores[clave], uso.motor === motor else { return }
            switch ReglasMezclador.vigilar(ciclosAntes: antes, ciclosAhora: motor.ciclos, yaRehecho: uso.rehecho) {
            case .bien:
                break
            case .rehacer:
                NSLog("Alero: el motor de \(clave) no procesa audio; se rehace")
                self.soltar(clave)
                if let grupo = self.grupos[clave], let ajuste = self.ajustes[clave] {
                    self.asegurarMotor(grupo, ganancia: ReglasMezclador.ganancia(deslizador: ajuste.volumen, silencio: ajuste.silencio), rehecho: true)
                }
            case .soltar:
                NSLog("Alero: el motor de \(clave) sigue sin andar; la app queda sonando normal")
                self.soltar(clave)
                self.fallidas.insert(clave)
                if let i = self.apps.firstIndex(where: { $0.id == clave }) { self.apps[i].fallo = true }
            }
        }
    }

    private func alDespertar() {
        guard activo else { return }
        for (clave, uso) in motores { vigilar(clave, uso.motor) }
        revisar()
    }

    /// Sin permiso de Grabación de audio del sistema no se arma nada (el tap daría silencio y la app quedaría muda).
    /// La primera vez muestra el cartel de macOS y, si la persona acepta, vuelve a revisar.
    private func permisoListo() -> Bool {
        let estado = PermisoAudio.estado
        permiso = estado
        switch estado {
        case .concedido, .desconocido:
            return true
        case .negado:
            return false
        case .sinPedir:
            if !pidiendoPermiso {
                pidiendoPermiso = true
                PermisoAudio.pedir { [weak self] _ in
                    self?.pidiendoPermiso = false
                    self?.permiso = PermisoAudio.estado
                    self?.revisar()
                }
            }
            return false
        }
    }

    // MARK: - Escuchas de Core Audio

    /// Escucha solo mientras sirve: la columna a la vista, apps ajustadas o volúmenes recordados por aplicar.
    private var hayQueEscuchar: Bool {
        activo && (visibles > 0 || !ajustes.isEmpty || Ajustes.shared.hayVolumenesRecordados)
    }

    private func actualizarEscuchas(_ procesos: [ProcesoAudio]) {
        guard hayQueEscuchar else { dejarDeEscuchar(); return }
        if !escuchandoSistema {
            escuchandoSistema = true
            for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
                agregarEscucha(NucleoAudio.sistema, selector)
            }
        }
        let actuales = Set(procesos.map(\.objeto))
        for objeto in actuales.subtracting(procesosEscuchados) { agregarEscucha(objeto, kAudioProcessPropertyIsRunningOutput) }
        for objeto in procesosEscuchados.subtracting(actuales) { sacarEscucha(objeto, kAudioProcessPropertyIsRunningOutput) }
        procesosEscuchados = actuales
        // La salida: si cambian sus canales, los motores se rehacen (la firma cambia).
        if salidaEscuchada != salida {
            if salidaEscuchada != 0 { sacarEscucha(salidaEscuchada, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput) }
            salidaEscuchada = salida
            if salida != 0 { agregarEscucha(salida, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput) }
        }
    }

    private func dejarDeEscuchar() {
        if escuchandoSistema {
            for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
                sacarEscucha(NucleoAudio.sistema, selector)
            }
        }
        escuchandoSistema = false
        for objeto in procesosEscuchados { sacarEscucha(objeto, kAudioProcessPropertyIsRunningOutput) }
        procesosEscuchados = []
        if salidaEscuchada != 0 { sacarEscucha(salidaEscuchada, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput) }
        salidaEscuchada = 0
    }

    private func agregarEscucha(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var direccion = NucleoAudio.direccion(selector, alcance)
        let estado = AudioObjectAddPropertyListener(objeto, &direccion, avisoDeCoreAudio, nil)
        if estado != noErr { NSLog("Alero: el mezclador no pudo escuchar a Core Audio (código \(estado))") }
    }

    private func sacarEscucha(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              _ alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var direccion = NucleoAudio.direccion(selector, alcance)
        // Si el objeto ya no existe (el proceso terminó), Core Audio devuelve error y no hay nada que sacar.
        _ = AudioObjectRemovePropertyListener(objeto, &direccion, avisoDeCoreAudio, nil)
    }

    // MARK: - Capturas

    /// Solo para `--capturas`: muestra apps de ejemplo sin tocar Core Audio.
    func simular(_ ejemplo: [AppAudio], permiso: PermisoAudio.Estado = .concedido) {
        simulado = true
        apps = ejemplo
        self.permiso = permiso
    }
}

/// Aviso de Core Audio (corre en un hilo suyo): se pasa al principal y se revisa todo.
private func avisoDeCoreAudio(_ objeto: AudioObjectID, _ cantidad: UInt32, _ direcciones: UnsafePointer<AudioObjectPropertyAddress>,
                              _ contexto: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { Mezclador.shared.revisar() }
    return noErr
}
