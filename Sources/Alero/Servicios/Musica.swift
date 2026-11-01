import AppKit
import SwiftUI

// Lo que está sonando (cualquier app: Spotify, Música, Chrome, YouTube…) y sus controles.
// Desde macOS 15.4 solo los programas de Apple pueden leerlo. El adaptador MediaRemote Adapter (BSD-3, viaja en
// Resources) carga un framework chiquito dentro de /usr/bin/perl, que sí puede, y escribe una línea JSON por cada
// cambio. Si el adaptador no está o deja de andar, `disponible` queda en false y el notch no muestra el reproductor.

struct Pista: Equatable {
    var titulo: String
    var artista: String
    var album: String
    var duracion: Double
    /// Segundos transcurridos en el momento `marca` (el reloj sigue corriendo si está sonando).
    var transcurrido: Double
    var marca: Date
    var sonando: Bool

    func transcurridoAhora(_ ahora: Date = Date()) -> Double {
        let extra = sonando ? ahora.timeIntervalSince(marca) : 0
        return min(max(transcurrido + extra, 0), max(duracion, 0))
    }
}

final class Musica: ObservableObject {
    static let shared = Musica()

    @Published private(set) var pista: Pista?
    @Published private(set) var caratula: NSImage?
    /// Color promedio de la carátula, aclarado para que se vea sobre negro.
    @Published private(set) var color: Color = Tema.acento
    @Published private(set) var disponible = false
    /// La app que está sonando (la "madre" si suena desde una pestaña o un ayudante: Chrome, no su proceso de video).
    @Published private(set) var aplicacion: String?

    private var proceso: Process?
    private var datos: [String: Any] = [:]
    private var pendiente = Data()
    private var detenida = true
    private var espera: TimeInterval = 2
    private let cola = DispatchQueue(label: "alero.musica")
    private var ultimaCaratula: String?

    private var recursos: (script: String, framework: String)? {
        guard let carpeta = Bundle.main.resourcePath else { return nil }
        let script = carpeta + "/mediaremote-adapter.pl"
        let framework = carpeta + "/MediaRemoteAdapter.framework"
        let fm = FileManager.default
        return fm.fileExists(atPath: script) && fm.fileExists(atPath: framework) ? (script, framework) : nil
    }

    func arrancar() {
        guard detenida else { return }
        detenida = false
        if let recursos { Musica.cerrarHuerfanos(script: recursos.script) }
        lanzar()
    }

    /// Cierra el adaptador y olvida lo leído. Al volver a arrancar, el adaptador nuevo manda todo de nuevo: si quedara
    /// la carátula anterior anotada, la misma carátula se tomaba como "no cambió" y el notch quedaba sin ella, y media
    /// línea del adaptador viejo arruinaba la primera del nuevo (auditoría del 01/11/2026).
    func detener() {
        detenida = true
        if let viejo = proceso {
            (viejo.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            viejo.terminate()
        }
        proceso = nil
        pista = nil
        caratula = nil
        cola.async { [weak self] in self?.olvidarLectura() }
    }

    func alternar() { enviar(2) }
    func siguiente() { enviar(4) }
    func anterior() { enviar(5) }

    /// Solo para `--capturas`: muestra una canción de ejemplo sin abrir el adaptador.
    func simular(_ ejemplo: Pista?, caratula: NSImage?, color: Color) {
        pista = ejemplo
        self.caratula = caratula
        self.color = color
        disponible = true
    }

    // MARK: - Proceso del adaptador

    private func lanzar() {
        // Un reintento que llega con otro adaptador ya andando (se detuvo y se volvió a arrancar) no abre un segundo.
        guard !detenida, proceso == nil else { return }
        guard let recursos else {
            NSLog("Alero: falta el adaptador de música en la app; el reproductor queda apagado")
            disponible = false
            return
        }
        let nuevo = Process()
        nuevo.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        nuevo.arguments = [recursos.script, recursos.framework, "stream", "--debounce=60"]
        let salida = Pipe()
        nuevo.standardOutput = salida
        nuevo.standardError = FileHandle.nullDevice
        salida.fileHandleForReading.readabilityHandler = { [weak self] archivo in
            let bloque = archivo.availableData
            guard !bloque.isEmpty else { return }
            self?.leer(bloque)
        }
        nuevo.terminationHandler = { [weak self] cerrado in
            DispatchQueue.main.async { self?.seCerro(cerrado) }
        }
        do {
            try nuevo.run()
            proceso = nuevo
            disponible = true
        } catch {
            NSLog("Alero: no se pudo abrir el adaptador de música: \(error.localizedDescription)")
            reintentar()
        }
    }

    /// El adaptador no se entera si Alero se cierra de golpe (un cuelgue, `kill -9`): queda huérfano, colgado de
    /// launchd, con ~6,5 MB, para siempre. El 01/11/2026 había cinco vivos de arranques anteriores (~33 MB).
    /// Al arrancar se cierran los de esta misma copia de Alero (mismo script) cuyo padre ya es launchd: nunca el de
    /// otra copia que esté andando (ese tiene a su Alero de padre). Solo los del usuario actual.
    private static func cerrarHuerfanos(script: String) {
        let lugar = Int(proc_listallpids(nil, 0)) + 32
        var pids = [pid_t](repeating: 0, count: lugar)
        let cantidad = Int(proc_listallpids(&pids, Int32(lugar * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(cantidad, 0)) where pid > 1 {
            var info = proc_bsdinfo()
            let tamano = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, tamano) == tamano,
                  info.pbi_ppid == 1, info.pbi_uid == getuid(),
                  argumentos(de: pid).dropFirst().first == script else { continue }
            NSLog("Alero: se cierra un adaptador de música que quedó de un arranque anterior (pid \(pid))")
            kill(pid, SIGTERM)
        }
    }

    /// Los argumentos con que arrancó un proceso (`perl script framework stream …`), leídos del kernel.
    private static func argumentos(de pid: pid_t) -> [String] {
        var pedido: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var tamano = 0
        guard sysctl(&pedido, 3, nil, &tamano, nil, 0) == 0, tamano > MemoryLayout<Int32>.size else { return [] }
        var bytes = [UInt8](repeating: 0, count: tamano)
        guard sysctl(&pedido, 3, &bytes, &tamano, nil, 0) == 0 else { return [] }
        // Formato: cantidad de argumentos (Int32), la ruta del ejecutable, ceros de relleno y los argumentos
        // separados por ceros.
        let cuantos = bytes.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        let partes = bytes[MemoryLayout<Int32>.size..<tamano].split(separator: 0, omittingEmptySubsequences: true)
        return partes.dropFirst().prefix(cuantos).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Solo cuenta el adaptador de ahora: uno viejo que termina tarde (después de detener y volver a arrancar) no
    /// borra al nuevo ni abre otro más.
    private func seCerro(_ cerrado: Process) {
        guard cerrado === proceso else { return }
        proceso = nil
        reintentar()
    }

    // Si el adaptador se cierra solo, se reabre esperando cada vez más (hasta 1 minuto) para no quedar en un bucle.
    private func reintentar() {
        guard !detenida else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + espera) { [weak self] in self?.lanzar() }
        espera = min(espera * 2, 60)
    }

    private func enviar(_ comando: Int) {
        guard let recursos else { return }
        let orden = Process()
        orden.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        orden.arguments = [recursos.script, recursos.framework, "send", String(comando)]
        orden.standardOutput = FileHandle.nullDevice
        orden.standardError = FileHandle.nullDevice
        do { try orden.run() } catch { NSLog("Alero: no se pudo mandar la orden \(comando) al reproductor: \(error.localizedDescription)") }
    }

    // MARK: - Lectura (en la cola propia)

    /// Lo que escribió el adaptador, tal cual llega (puede traer media línea). Cualquier hilo: pasa a la cola propia.
    /// No es privada para que las pruebas le puedan dar líneas armadas a mano.
    func leer(_ bloque: Data) {
        cola.async { [weak self] in self?.recibir(bloque) }
    }

    private func olvidarLectura() {
        datos = [:]
        pendiente = Data()
        ultimaCaratula = nil
    }

    private func recibir(_ bloque: Data) {
        pendiente.append(bloque)
        while let fin = pendiente.firstIndex(of: 0x0A) {
            let linea = pendiente.subdata(in: pendiente.startIndex..<fin)
            pendiente.removeSubrange(pendiente.startIndex...fin)
            procesar(linea)
        }
    }

    /// Cada línea trae `payload` completo (`diff` false) o solo lo que cambió (`diff` true; null = se borró).
    private func procesar(_ linea: Data) {
        // A propósito: una línea que no es JSON (un aviso del adaptador) se saltea; la próxima trae el estado.
        guard let objeto = try? JSONSerialization.jsonObject(with: linea) as? [String: Any],
              let carga = objeto["payload"] as? [String: Any] else { return }
        if (objeto["diff"] as? Bool) == true {
            for (clave, valor) in carga {
                if valor is NSNull { datos.removeValue(forKey: clave) } else { datos[clave] = valor }
            }
        } else {
            datos = carga
        }
        espera = 2
        let nueva = Musica.pista(de: datos)
        let app = (datos["parentApplicationBundleIdentifier"] as? String) ?? (datos["bundleIdentifier"] as? String)
        let base64 = datos["artworkData"] as? String
        let cambioCaratula = base64 != ultimaCaratula
        ultimaCaratula = base64
        let imagen = cambioCaratula ? base64.flatMap { Data(base64Encoded: $0) }.flatMap(Musica.caratula(de:)) : nil
        let tono = imagen.map(Musica.colorPromedio)
        DispatchQueue.main.async { [weak self] in
            // Lo que se leyó justo antes de detener no vuelve a mostrar una canción con la música apagada.
            guard let self, !self.detenida else { return }
            self.pista = nueva
            self.aplicacion = app
            if cambioCaratula {
                self.caratula = imagen
                self.color = tono ?? Tema.acento
            }
        }
    }

    // MARK: - Ir a la app que suena

    /// Navegadores con AppleScript para elegir pestaña (Chrome y los que comparten su diccionario, y Safari).
    private static let tipoChrome: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser",
                                                   "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

    /// Un clic en la carátula o el título del notch abierto: trae adelante la app que está sonando. Si es un
    /// navegador, también la pestaña que suena (la que tiene el título en su nombre: "Video - YouTube"); la primera
    /// vez macOS pide permiso para controlar ese navegador. Si no la encuentra, trae el navegador igual.
    /// Main thread (NSAppleScript no se puede usar en otro).
    func mostrarApp() {
        guard let id = aplicacion, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        if app.isHidden { app.unhide() }
        if let titulo = pista?.titulo, Musica.elegirPestana(titulo, en: id) { return }
        app.activate()
    }

    private static func elegirPestana(_ titulo: String, en id: String) -> Bool {
        let buscado = titulo.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let codigo: String
        if tipoChrome.contains(id) {
            codigo = """
            tell application id "\(id)"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if title of t contains "\(buscado)" then
                            set active tab index of w to i
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        } else if id == "com.apple.Safari" {
            codigo = """
            tell application id "com.apple.Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if name of t contains "\(buscado)" then
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        } else {
            return false
        }
        var error: NSDictionary?
        let resultado = NSAppleScript(source: codigo)?.executeAndReturnError(&error)
        return error == nil && resultado?.booleanValue == true
    }

    /// Lo más grande que se dibuja la carátula: 96 pt en el notch abierto, en pantallas Retina (2×).
    static let ladoCaratula = 192

    /// La carátula achicada a `ladoCaratula` al leerla (nunca se agranda). Las apps la mandan de 600 a 1400 px y se
    /// guarda mientras suena: con una de 1200 px, la app pesaba 1,8 MB más (medido el 01/11/2026).
    static func caratula(de datos: Data) -> NSImage? {
        let opciones: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: ladoCaratula,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceShouldCacheImmediately: true]
        guard let fuente = CGImageSourceCreateWithData(datos as CFData, nil),
              let chica = CGImageSourceCreateThumbnailAtIndex(fuente, 0, opciones as CFDictionary) else { return nil }
        return NSImage(cgImage: chica, size: NSSize(width: CGFloat(chica.width) / 2, height: CGFloat(chica.height) / 2))
    }

    private static let lectorFecha = ISO8601DateFormatter()

    private static func pista(de datos: [String: Any]) -> Pista? {
        guard let titulo = datos["title"] as? String, !titulo.isEmpty else { return nil }
        let marca = (datos["timestamp"] as? String).flatMap(lectorFecha.date(from:)) ?? Date()
        return Pista(titulo: titulo,
                     artista: datos["artist"] as? String ?? "",
                     album: datos["album"] as? String ?? "",
                     duracion: datos["duration"] as? Double ?? 0,
                     transcurrido: datos["elapsedTime"] as? Double ?? 0,
                     marca: marca,
                     sonando: datos["playing"] as? Bool ?? false)
    }

    /// Promedio de la carátula achicada a 8×8 (rápido) y llevado a un brillo mínimo para que se lea sobre negro.
    private static func colorPromedio(_ imagen: NSImage) -> Color {
        let lado = 8
        guard let cg = imagen.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let contexto = CGContext(data: nil, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: lado * 4,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixeles = contexto.data else { return Tema.acento }
        contexto.interpolationQuality = .medium
        contexto.draw(cg, in: CGRect(x: 0, y: 0, width: lado, height: lado))
        let bytes = pixeles.bindMemory(to: UInt8.self, capacity: lado * lado * 4)
        var suma = (r: 0.0, g: 0.0, b: 0.0)
        for i in 0..<(lado * lado) {
            suma.r += Double(bytes[i * 4]); suma.g += Double(bytes[i * 4 + 1]); suma.b += Double(bytes[i * 4 + 2])
        }
        let total = Double(lado * lado) * 255
        var color = NSColor(srgbRed: suma.r / total, green: suma.g / total, blue: suma.b / total, alpha: 1)
        var (h, s, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        color = NSColor(hue: h, saturation: min(s * 1.15, 1), brightness: max(b, 0.62), alpha: 1)
        return Color(nsColor: color)
    }
}
