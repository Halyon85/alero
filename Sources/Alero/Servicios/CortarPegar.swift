import AppKit
import Combine

// Cortar y pegar archivos en Finder: ⌘X marca los archivos elegidos y ⌘V los mueve a la carpeta abierta (Finder solo
// sabe copiar). Solo con Finder al frente y sin estar escribiendo (renombrar, buscar): ahí ⌘X y ⌘V son los de siempre.
// Necesita Accesibilidad (escuchar las teclas) y Automatización de Finder (preguntarle qué está elegido y dónde).
//
// La escucha de teclas existe solo mientras Finder está al frente y la función prendida: el resto del tiempo no
// cuesta nada. Si después de ⌘X se copia otra cosa (⌘C), el corte se olvida y ⌘V pega lo copiado, como en Finder.

final class CortarPegar {
    static let shared = CortarPegar()

    private static let finder = "com.apple.finder"
    private var suscripciones = Set<AnyCancellable>()

    // Main thread.
    private var prendido = false
    private var observador: NSObjectProtocol?
    private var escucha: CFMachPort?
    private var esperandoPermiso = false
    private var cortados: [URL] = []
    private var cuentaPortapapeles = 0
    private let archivos = DispatchQueue(label: "alero.archivos", qos: .userInitiated)

    // Solo en el hilo de eventos.
    /// La escucha, del lado de este hilo (la vuelve a prender si macOS la corta).
    private var puerto: CFMachPort?
    private var hayCortados = false
    /// Teclas cuyo Down se tragó: su Up también se traga.
    private var tragadas = Set<Int64>()

    func arrancar() {
        Ajustes.shared.$finderCortar.removeDuplicates()
            .sink { [weak self] prender in prender ? self?.prender() : self?.apagar() }
            .store(in: &suscripciones)
    }

    private func prender() {
        prendido = true
        guard observador == nil else { return }
        observador = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in self?.revisarFrente() }
        revisarFrente()
    }

    private func apagar() {
        prendido = false
        if let observador { NSWorkspace.shared.notificationCenter.removeObserver(observador) }
        observador = nil
        sacarEscucha()
        olvidar()
    }

    private var finderAlFrente: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CortarPegar.finder }

    private func revisarFrente() {
        guard prendido, finderAlFrente else { sacarEscucha(); return }
        if Permisos.accesibilidad { escuchar(); return }
        guard !esperandoPermiso else { return }
        esperandoPermiso = true
        Permisos.cuandoHayaAccesibilidad { [weak self] in
            self?.esperandoPermiso = false
            self?.revisarFrente()
        }
    }

    private func escuchar() {
        guard escucha == nil else { return }
        let mascara = CGEventType.keyDown.bit | CGEventType.keyUp.bit
        escucha = HiloEventos.shared.agregarEscucha(lugar: .cgSessionEventTap, posicion: .headInsertEventTap, eventos: mascara,
                                                    dueno: Unmanaged.passUnretained(self).toOpaque()) { _, tipo, evento, dueno in
            guard let dueno else { return Unmanaged.passUnretained(evento) }
            return Unmanaged<CortarPegar>.fromOpaque(dueno).takeUnretainedValue().manejar(tipo, evento)
        }
        guard let nueva = escucha else {
            NSLog("Alero: no se pudo escuchar el teclado para cortar y pegar (¿falta Accesibilidad?)")
            return
        }
        HiloEventos.shared.ejecutar { [weak self] in self?.puerto = nueva }
    }

    private func sacarEscucha() {
        if let escucha { HiloEventos.shared.sacarEscucha(escucha) }
        escucha = nil
        HiloEventos.shared.ejecutar { [weak self] in
            self?.puerto = nil
            self?.tragadas = []
        }
    }

    private func olvidar() {
        cortados = []
        HiloEventos.shared.ejecutar { [weak self] in self?.hayCortados = false }
    }

    // MARK: - En el hilo de eventos

    private func manejar(_ tipo: CGEventType, _ evento: CGEvent) -> Unmanaged<CGEvent>? {
        let sigue = Unmanaged.passUnretained(evento)
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            if let puerto { CGEvent.tapEnable(tap: puerto, enable: true) }
            return sigue
        }
        guard !MarcaPropia.esPropio(evento) else { return sigue }
        let codigo = evento.getIntegerValueField(.keyboardEventKeycode)
        if tipo == .keyUp { return tragadas.remove(codigo) != nil ? nil : sigue }
        guard tipo == .keyDown, evento.flags.intersection(Teclado.modificadores) == .maskCommand,
              let letra = NSEvent(cgEvent: evento)?.charactersIgnoringModifiers?.lowercased(), letra == "x" || letra == "v" else { return sigue }
        // ⌘V sin nada cortado es el pegar de Finder de siempre (copia).
        if letra == "v" && !hayCortados && !tragadas.contains(codigo) { return sigue }
        tragadas.insert(codigo)
        // Mantener la tecla apretada no repite la acción.
        if evento.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        DispatchQueue.main.async { [weak self] in
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: CortarPegar.finder).first else { return }
            let pid = finder.processIdentifier
            if letra == "x" { self?.cortar(codigo: CGKeyCode(codigo), pid: pid) } else { self?.pegar(codigo: CGKeyCode(codigo), pid: pid) }
        }
        return nil
    }

    // MARK: - Cortar y pegar (main thread)

    /// Si Finder está escribiendo en un campo (o no se puede saber), ⌘X o ⌘V vuelven a Finder tal cual.
    private func siNoEstaEscribiendo(_ pid: pid_t, codigo: CGKeyCode, hacer: @escaping () -> Void) {
        AX.cola.async {
            let escribiendo = CortarPegar.escribiendoEnCampo(pid)
            DispatchQueue.main.async {
                if escribiendo == false { hacer() } else { Teclado.enviar(codigo: codigo, flags: .maskCommand) }
            }
        }
    }

    private func cortar(codigo: CGKeyCode, pid: pid_t) {
        siNoEstaEscribiendo(pid, codigo: codigo) { [weak self] in
            self?.conPermiso {
                guard let self else { return }
                let elegidos: [URL]
                do { elegidos = try ScriptFinder.seleccion() } catch {
                    self.fallo(error)
                    return
                }
                guard !elegidos.isEmpty else { NSSound.beep(); return }
                self.cortados = elegidos
                self.cuentaPortapapeles = NSPasteboard.general.changeCount
                HiloEventos.shared.ejecutar { self.hayCortados = true }
                self.avisar(.cortar(cantidad: elegidos.count))
            }
        }
    }

    private func pegar(codigo: CGKeyCode, pid: pid_t) {
        // Se copió otra cosa después de cortar: el corte se olvida y ⌘V hace lo de Finder con lo copiado.
        guard !cortados.isEmpty, NSPasteboard.general.changeCount == cuentaPortapapeles else {
            olvidar()
            Teclado.enviar(codigo: codigo, flags: .maskCommand)
            return
        }
        siNoEstaEscribiendo(pid, codigo: codigo) { [weak self] in
            self?.conPermiso {
                guard let self else { return }
                let carpeta: URL
                do { carpeta = try ScriptFinder.carpetaAbierta() } catch {
                    self.fallo(error)
                    return
                }
                let lista = self.cortados
                self.archivos.async {
                    let resultado = MoverArchivos.mover(lista, a: carpeta)
                    DispatchQueue.main.async {
                        // Se olvida todo, también lo que falló: volver a intentar es otro ⌘X (lo que se movió ya no está ahí).
                        self.olvidar()
                        self.avisar(.pegar(movidos: resultado.movidos, fallidos: resultado.fallidos.count, sinPermiso: resultado.sinPermiso))
                    }
                }
            }
        }
    }

    /// Corre `hacer` si Alero puede controlar Finder. La primera vez macOS pregunta (y se espera fuera del hilo
    /// principal). Si la persona dijo que no, se avisa y se abren los ajustes donde se ve el permiso.
    private func conPermiso(_ hacer: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let estado = Permisos.automatizacionFinder(preguntar: true)
            DispatchQueue.main.async {
                if estado == .concedido { hacer(); return }
                self?.faltaPermiso()
            }
        }
    }

    private func faltaPermiso() {
        avisar(.permiso(nombre: T("Controlar Finder", "Control Finder")))
        VentanaAlero.shared.mostrar(.mouse)
    }

    private func fallo(_ error: Error) {
        if (error as? ScriptFinder.Error)?.sinPermiso == true { faltaPermiso(); return }
        NSLog("Alero: cortar y pegar en Finder falló: \(error.localizedDescription)")
        NSSound.beep()
    }

    /// En el notch, si está prendido; si no, con el sonido de error de macOS cuando algo salió mal.
    private func avisar(_ aviso: AvisoNotch) {
        if Ajustes.shared.notchActivo {
            ControladorNotch.shared.estado.mostrar(aviso)
        } else if case .pegar(_, let fallidos, _) = aviso, fallidos > 0 {
            NSSound.beep()
        }
    }

    /// En `AX.cola`. True si lo enfocado en Finder es un campo de texto (renombrar, buscar, "Ir a la carpeta"); nil si
    /// no se puede saber (sin Accesibilidad). Sin nada enfocado (el escritorio) no está escribiendo.
    private static func escribiendoEnCampo(_ pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        guard let foco = AX.elemento(AX.app(pid), kAXFocusedUIElementAttribute) else { return false }
        let rol = AX.texto(foco, kAXRoleAttribute)
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains { $0 == rol }
    }
}

/// Lo que se le pregunta a Finder por Apple Events. Main thread (NSAppleScript no se puede usar en otro) y solo con
/// el permiso ya concedido: así nunca espera el cartel de macOS. Finder contesta en unos milisegundos.
enum ScriptFinder {
    struct Error: Swift.Error, LocalizedError {
        let numero: Int
        let mensaje: String
        /// -1743: la persona no dejó que Alero controle Finder.
        var sinPermiso: Bool { numero == -1743 }
        var errorDescription: String? { "\(mensaje) (\(numero))" }
    }

    private static var compilados: [String: NSAppleScript] = [:]

    /// Los archivos y carpetas elegidos en Finder (vacío si no hay nada elegido).
    static func seleccion() throws -> [URL] {
        let resultado = try correr("""
        tell application id "com.apple.finder" to set elegidos to selection as alias list
        set rutas to {}
        repeat with elegido in elegidos
            set end of rutas to POSIX path of elegido
        end repeat
        return rutas
        """)
        guard resultado.numberOfItems > 0 else { return [] }
        return (1...resultado.numberOfItems).compactMap { resultado.atIndex($0)?.stringValue }.map { URL(fileURLWithPath: $0) }
    }

    /// La carpeta donde Finder pondría algo nuevo: la de la ventana del frente, o el escritorio si no hay ventanas.
    static func carpetaAbierta() throws -> URL {
        let resultado = try correr("""
        tell application id "com.apple.finder" to return POSIX path of (insertion location as alias)
        """)
        guard let ruta = resultado.stringValue else { throw Error(numero: 0, mensaje: "Finder no dijo qué carpeta está abierta") }
        return URL(fileURLWithPath: ruta, isDirectory: true)
    }

    private static func correr(_ codigo: String) throws -> NSAppleEventDescriptor {
        let script = compilados[codigo] ?? NSAppleScript(source: codigo)
        guard let script else { throw Error(numero: 0, mensaje: "No se pudo armar el pedido a Finder") }
        compilados[codigo] = script
        var info: NSDictionary?
        let resultado = script.executeAndReturnError(&info)
        if let info {
            let numero = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            throw Error(numero: numero, mensaje: info[NSAppleScript.errorMessage] as? String ?? "Finder no respondió")
        }
        return resultado
    }
}

/// Mover archivos con FileManager. Fuera del hilo principal (entre discos puede tardar).
enum MoverArchivos {
    struct Resultado {
        var movidos = 0
        var fallidos: [(URL, Error)] = []
        /// Alguno falló porque macOS no dejó leerlo o escribir en la carpeta.
        var sinPermiso = false
    }

    struct CarpetaDentroDeSiMisma: Error {}

    static func mover(_ urls: [URL], a carpeta: URL) -> Resultado {
        var resultado = Resultado()
        let destino = carpeta.standardizedFileURL
        for url in urls {
            let origen = url.standardizedFileURL
            // Ya está en esa carpeta: no hay nada que mover (Finder tampoco hace nada).
            if origen.deletingLastPathComponent().path == destino.path { resultado.movidos += 1; continue }
            if destino.path.hasPrefix(origen.path + "/") || destino.path == origen.path {
                resultado.fallidos.append((url, CarpetaDentroDeSiMisma()))
                continue
            }
            // A propósito: si ya hay algo con ese nombre, no se pisa; se usa "nombre 2" como hace Finder al duplicar.
            let nombre = nombreLibre(origen.lastPathComponent) { FileManager.default.fileExists(atPath: destino.appendingPathComponent($0).path) }
            do {
                try FileManager.default.moveItem(at: origen, to: destino.appendingPathComponent(nombre))
                resultado.movidos += 1
            } catch {
                NSLog("Alero: no se pudo mover \(origen.path): \(error.localizedDescription)")
                resultado.fallidos.append((url, error))
                if esDePermiso(error) { resultado.sinPermiso = true }
            }
        }
        return resultado
    }

    /// `nombre` si está libre; si no, "nombre 2.ext", "nombre 3.ext"… (las carpetas y los ocultos sin extensión, igual).
    static func nombreLibre(_ nombre: String, ocupado: (String) -> Bool) -> String {
        guard ocupado(nombre) else { return nombre }
        let base = (nombre as NSString).deletingPathExtension
        let ext = (nombre as NSString).pathExtension
        var n = 2
        while true {
            let candidato = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !ocupado(candidato) { return candidato }
            n += 1
        }
    }

    static func esDePermiso(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) { return true }
        let interno = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return interno?.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(interno?.code ?? 0)
    }
}
