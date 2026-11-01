import Foundation

// Seguimiento de los agentes de IA de la Mac: Claude Code y Codex. Muestra si están trabajando ahora (escribieron su
// registro hace menos de 20 s), en qué proyecto y cuánto cupo usaron (Codex: semanal, de sus registros; Claude: 5 h y
// semana, de su barra de estado si está conectada, ver `CupoClaude`).
//
// Todo sale de los archivos que esos programas ya guardan en la Mac (`~/.claude/projects` y `~/.codex/sessions`):
// no se leen claves ni del Llavero, no se usa internet y no se toca su configuración. (Atoll saca el cupo de Claude
// con el token del Llavero contra un servidor no documentado: descartado a propósito, ver el informe del 01/11/2026.)
//
// Para no revisar miles de archivos a cada rato, macOS avisa cuando cambian (FSEvents): con los agentes quietos no
// hay ningún trabajo. Al empezar se busca una vez el registro más nuevo. Solo corre mientras alguien mira (la vista
// llama a `empezar` y `terminar`).

struct EstadoAgente: Equatable {
    /// Cupo usado de una ventana ("5 h", "semana").
    struct Cupo: Equatable {
        let nombre: String
        let usado: Double
        let reinicia: Date?
    }

    /// Lo del chat activo que sale del registro: título, modelo, contexto usado y rama de git.
    struct Chat: Equatable {
        var titulo: String?
        var modelo: String?
        /// Tokens en el contexto en la última respuesta, y el máximo del modelo.
        var contexto: Int?
        var ventana: Int?
        var rama: String?
    }

    var ultimo: Date?
    var proyecto: String?
    var cupos: [Cupo] = []
    var chat = Chat()

    func trabajando(_ ahora: Date = Date()) -> Bool {
        guard let ultimo else { return false }
        return ahora.timeIntervalSince(ultimo) < 20
    }
}

/// Lo que se saca de la cola de un registro, sin archivos (se prueba con `swift test`).
enum ReglasAgentes {
    /// El último `"cwd":"…"` del texto, como nombre de carpeta (el proyecto).
    static func proyecto(en texto: String) -> String? {
        guard let rango = texto.range(of: "\"cwd\":\"", options: .backwards) else { return nil }
        let resto = texto[rango.upperBound...]
        guard let fin = resto.firstIndex(of: "\"") else { return nil }
        let ruta = String(resto[..<fin]).replacingOccurrences(of: "\\/", with: "/")
        let nombre = (ruta as NSString).lastPathComponent
        return nombre.isEmpty ? nil : nombre
    }

    /// Del final de un registro de Claude Code: la última respuesta (`message.usage` y `model`), la rama y el título del
    /// chat (`agentName` o `customTitle`, que puede estar más arriba: por eso también se mira el comienzo del archivo).
    static func chatClaude(cola: String, cabeza: String) -> EstadoAgente.Chat {
        var chat = EstadoAgente.Chat()
        for linea in cola.split(separator: "\n").reversed() where chat.contexto == nil {
            guard linea.contains("\"usage\""), let objeto = json(linea), objeto["type"] as? String == "assistant",
                  let mensaje = objeto["message"] as? [String: Any], let uso = mensaje["usage"] as? [String: Any] else { continue }
            let partes = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].map { uso[$0] as? Int ?? 0 }
            chat.contexto = partes.reduce(0, +)
            chat.modelo = mensaje["model"] as? String
            chat.rama = objeto["gitBranch"] as? String
        }
        chat.titulo = titulo(en: cola) ?? titulo(en: cabeza)
        if let contexto = chat.contexto { chat.ventana = ventanaClaude(modelo: chat.modelo ?? "", contexto: contexto) }
        return chat
    }

    /// El máximo de contexto: 1 M con los modelos de la familia 5 o "[1m]"; si no, 200 mil. Si ya se usó más de 200
    /// mil, es de 1 M seguro.
    static func ventanaClaude(modelo: String, contexto: Int) -> Int {
        // La versión grande es el primer número después de la familia: "claude-opus-5-5" → 5, "claude-sonnet-4-5" → 4.
        let partes = modelo.replacingOccurrences(of: "[1m]", with: "").split(separator: "-")
        let mayor = partes.count > 2 ? Int(partes[2]) ?? 0 : 0
        let grande = modelo.contains("[1m]") || mayor >= 5 || contexto > 200_000
        return grande ? 1_000_000 : 200_000
    }

    /// Del final de un registro de Codex: el contexto de la última respuesta (`last_token_usage.input_tokens`), el
    /// máximo (`model_context_window`) y el modelo.
    static func chatCodex(cola: String) -> EstadoAgente.Chat {
        var chat = EstadoAgente.Chat()
        for linea in cola.split(separator: "\n").reversed() where linea.contains("\"last_token_usage\"") {
            guard let objeto = json(linea), let carga = objeto["payload"] as? [String: Any], let info = carga["info"] as? [String: Any],
                  let ultimo = info["last_token_usage"] as? [String: Any] else { continue }
            chat.contexto = ultimo["input_tokens"] as? Int
            chat.ventana = info["model_context_window"] as? Int
            break
        }
        if let rango = cola.range(of: "\"model\":\"", options: .backwards) {
            let resto = cola[rango.upperBound...]
            chat.modelo = resto.firstIndex(of: "\"").map { String(resto[..<$0]) }
        }
        return chat
    }

    /// "claude-opus-5-5" → "Opus 5.5". Lo que no es de Claude queda como está.
    static func nombreModelo(_ modelo: String) -> String {
        let limpio = modelo.replacingOccurrences(of: "[1m]", with: "")
        guard limpio.hasPrefix("claude-") else { return limpio }
        let partes = limpio.dropFirst(7).split(separator: "-")
        guard let familia = partes.first else { return limpio }
        let version = partes.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return familia.prefix(1).uppercased() + familia.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    private static func titulo(en texto: String) -> String? {
        for linea in texto.split(separator: "\n").reversed() where linea.contains("\"agentName\"") || linea.contains("\"customTitle\"") {
            guard let objeto = json(linea) else { continue }
            if let titulo = (objeto["customTitle"] as? String) ?? (objeto["agentName"] as? String), !titulo.isEmpty { return titulo }
        }
        return nil
    }

    private static func json(_ linea: Substring) -> [String: Any]? {
        guard let datos = linea.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any]
    }

    /// El cupo de la última línea de Codex que lo trae (`payload.rate_limits.primary`).
    static func cupoCodex(en texto: String) -> EstadoAgente.Cupo? {
        for linea in texto.split(separator: "\n").reversed() where linea.contains("\"rate_limits\"") {
            guard let datos = linea.data(using: .utf8),
                  let objeto = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
                  let carga = objeto["payload"] as? [String: Any],
                  let limites = carga["rate_limits"] as? [String: Any],
                  let primario = limites["primary"] as? [String: Any],
                  let usado = primario["used_percent"] as? Double else { continue }
            let reinicia = (primario["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return EstadoAgente.Cupo(nombre: T("semana", "week"), usado: usado / 100, reinicia: reinicia)
        }
        return nil
    }
}

final class Agentes: ObservableObject {
    static let shared = Agentes()

    enum Cual: CaseIterable { case claude, codex }

    @Published private(set) var claude = EstadoAgente()
    @Published private(set) var codex = EstadoAgente()

    private let cola = DispatchQueue(label: "alero.agentes", qos: .utility)
    private var flujo: FSEventStreamRef?
    private var mirando = 0
    /// Solo en `cola`: cuándo se leyó por última vez la cola de cada registro (se lee como mucho cada 5 s).
    private var ultimaLectura: [String: Date] = [:]

    private static let carpetaClaude = NSHomeDirectory() + "/.claude/projects"
    private static let carpetaCodex = NSHomeDirectory() + "/.codex/sessions"

    /// Solo para `--capturas`: estados de ejemplo, sin leer archivos.
    func simular(claude: EstadoAgente, codex: EstadoAgente) {
        self.claude = claude
        self.codex = codex
    }

    /// Lo llama una vista al aparecer. Hilo principal.
    func empezar() {
        mirando += 1
        guard mirando == 1 else { return }
        cola.async {
            for cual in Cual.allCases {
                if let archivo = Agentes.masNuevo(en: Agentes.carpeta(cual)) { self.leer(archivo.ruta, de: cual, fecha: archivo.fecha) }
            }
            self.leerCupoClaude()
        }
        escuchar()
    }

    /// Lo llama la vista al irse. Hilo principal.
    func terminar() {
        mirando = max(mirando - 1, 0)
        guard mirando == 0, let flujo else { return }
        FSEventStreamStop(flujo)
        FSEventStreamInvalidate(flujo)
        FSEventStreamRelease(flujo)
        self.flujo = nil
    }

    private static func carpeta(_ cual: Cual) -> String { cual == .claude ? carpetaClaude : carpetaCodex }

    // MARK: - Avisos de macOS

    private func escuchar() {
        let carpetas = (Cual.allCases.map(Agentes.carpeta) + [CupoClaude.carpeta]).filter { FileManager.default.fileExists(atPath: $0) }
        guard flujo == nil, !carpetas.isEmpty else { return }
        var contexto = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let alCambiar: FSEventStreamCallback = { _, info, cantidad, rutas, _, _ in
            guard let info else { return }
            let yo = Unmanaged<Agentes>.fromOpaque(info).takeUnretainedValue()
            let lista = unsafeBitCast(rutas, to: NSArray.self) as? [String] ?? []
            yo.cambiaron(Array(lista.prefix(cantidad)))
        }
        // Latencia de 2 s: macOS junta los cambios (un agente escribe varias veces por segundo).
        let banderas = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        guard let nuevo = FSEventStreamCreate(nil, alCambiar, &contexto, carpetas as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, banderas) else { return }
        FSEventStreamSetDispatchQueue(nuevo, cola)
        FSEventStreamStart(nuevo)
        flujo = nuevo
    }

    /// En `cola`. Solo cuentan los registros (`.jsonl`).
    private func cambiaron(_ rutas: [String]) {
        let ahora = Date()
        if rutas.contains(where: { $0.hasSuffix("/claude-estado.json") }) { leerCupoClaude() }
        for ruta in rutas where ruta.hasSuffix(".jsonl") {
            let cual: Cual = ruta.hasPrefix(Agentes.carpetaClaude) ? .claude : .codex
            leer(ruta, de: cual, fecha: ahora)
        }
    }

    // MARK: - Lectura (en `cola`)

    /// Anota la actividad y, si pasaron 5 s desde la última vez, lee el final del registro (proyecto y cupo).
    private func leer(_ ruta: String, de cual: Cual, fecha: Date) {
        var proyecto: String?
        var cupo: EstadoAgente.Cupo?
        var chat = EstadoAgente.Chat()
        var leido = false
        if Date().timeIntervalSince(ultimaLectura[ruta] ?? .distantPast) > 5, let cola = Agentes.final(de: ruta) {
            ultimaLectura[ruta] = Date()
            proyecto = ReglasAgentes.proyecto(en: cola)
            if cual == .codex {
                cupo = ReglasAgentes.cupoCodex(en: cola)
                chat = ReglasAgentes.chatCodex(cola: cola)
            } else {
                chat = ReglasAgentes.chatClaude(cola: cola, cabeza: Agentes.comienzo(de: ruta) ?? "")
            }
            leido = true
        }
        DispatchQueue.main.async {
            var estado = cual == .claude ? self.claude : self.codex
            if fecha > (estado.ultimo ?? .distantPast) { estado.ultimo = fecha }
            if leido {
                if let proyecto { estado.proyecto = proyecto }
                if let cupo { estado.cupos = [cupo] }
                // Otro chat (otro archivo) arranca de cero; el mismo solo pisa lo que se pudo leer.
                if chat.contexto != nil || chat.titulo != nil {
                    if estado.chat.titulo != nil, chat.titulo == nil, estado.chat.contexto != nil { chat.titulo = estado.chat.titulo }
                    estado.chat = chat
                }
            }
            if cual == .claude { self.claude = estado } else { self.codex = estado }
        }
    }

    /// En `cola`. El cupo de Claude que dejó la barra de estado de Alero (si está conectada).
    private func leerCupoClaude() {
        guard let datos = FileManager.default.contents(atPath: CupoClaude.estado) else { return }
        let cupos = ReglasAgentes.cuposClaude(en: datos)
        guard !cupos.isEmpty else { return }
        DispatchQueue.main.async { self.claude.cupos = cupos }
    }

    /// Los últimos 256 KB de un registro (pueden pesar cientos de MB: nunca se leen enteros).
    private static func final(de ruta: String) -> String? {
        guard let archivo = FileHandle(forReadingAtPath: ruta) else { return nil }
        defer { try? archivo.close() }
        guard let tamano = try? archivo.seekToEnd() else { return nil }
        try? archivo.seek(toOffset: tamano > 262_144 ? tamano - 262_144 : 0)
        guard let datos = try? archivo.readToEnd() else { return nil }
        return String(decoding: datos, as: UTF8.self)
    }

    /// Los primeros 128 KB (ahí suele estar el título del chat).
    private static func comienzo(de ruta: String) -> String? {
        guard let archivo = FileHandle(forReadingAtPath: ruta) else { return nil }
        defer { try? archivo.close() }
        guard let datos = try? archivo.read(upToCount: 131_072) else { return nil }
        return String(decoding: datos, as: UTF8.self)
    }

    /// El registro modificado más recientemente, mirando solo carpetas tocadas en la última semana.
    private static func masNuevo(en carpeta: String) -> (ruta: String, fecha: Date)? {
        let raiz = URL(fileURLWithPath: carpeta)
        let claves: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let recorrido = FileManager.default.enumerator(at: raiz, includingPropertiesForKeys: claves,
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let haceUnaSemana = Date().addingTimeInterval(-7 * 86_400)
        var mejor: (ruta: String, fecha: Date)?
        for case let url as URL in recorrido {
            guard let valores = try? url.resourceValues(forKeys: Set(claves)), let fecha = valores.contentModificationDate else { continue }
            if valores.isDirectory == true {
                // Una carpeta sin cambios en la semana no tiene registros nuevos adentro: no se recorre.
                if fecha < haceUnaSemana { recorrido.skipDescendants() }
                continue
            }
            guard url.pathExtension == "jsonl", fecha > (mejor?.fecha ?? .distantPast) else { continue }
            mejor = (url.path, fecha)
        }
        return mejor
    }
}
