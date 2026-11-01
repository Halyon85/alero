import Foundation

// Qué cuenta como basura segura para "Limpiar la Mac" y qué no se muestra nunca. Sin AppKit ni disco: se prueba en
// `LimpiadorTests`. Las listas salen de estudiar otros limpiadores de código abierto: hay cachés
// que, si se borran, rompen el sonido, cierran sesiones o borran licencias de plugins, y esas no se ofrecen.

enum CategoriaLimpieza: String, CaseIterable, Identifiable {
    case caches, registros, xcode, homebrew, instaladores, capturas

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .caches: return T("Cachés de apps", "App caches")
        case .registros: return T("Registros viejos", "Old logs")
        case .xcode: return T("Xcode y simuladores", "Xcode and simulators")
        case .homebrew: return T("Descargas de Homebrew", "Homebrew downloads")
        case .instaladores: return T("Instaladores viejos en Descargas", "Old installers in Downloads")
        case .capturas: return T("Capturas olvidadas", "Forgotten screenshots")
        }
    }

    var detalle: String {
        switch self {
        case .caches: return T("Las apps las vuelven a armar solas cuando las necesitan.", "Apps rebuild them on their own when needed.")
        case .registros: return T("Registros y reportes de errores de hace más de \(ReglasLimpieza.diasRegistros) días.",
                                  "Logs and crash reports older than \(ReglasLimpieza.diasRegistros) days.")
        case .xcode: return T("DerivedData y cachés de simuladores. Xcode los vuelve a generar al compilar.",
                              "DerivedData and simulator caches. Xcode rebuilds them when you compile.")
        case .homebrew: return T("Lo que Homebrew bajó para instalar. Se baja de nuevo si hace falta.",
                                 "What Homebrew downloaded to install. It downloads again if needed.")
        case .instaladores: return T(".dmg y .pkg que bajaste hace más de \(ReglasLimpieza.diasInstaladores) días. Son tuyos: revisalos.",
                                     ".dmg and .pkg files you downloaded more than \(ReglasLimpieza.diasInstaladores) days ago. They're yours: check them.")
        case .capturas: return T("Capturas del Escritorio de hace más de \(ReglasLimpieza.diasCapturas) días que nunca renombraste.",
                                 "Desktop screenshots older than \(ReglasLimpieza.diasCapturas) days you never renamed.")
        }
    }

    var icono: String {
        switch self {
        case .caches: return "shippingbox"
        case .registros: return "doc.text"
        case .xcode: return "hammer"
        case .homebrew: return "mug"
        case .instaladores: return "arrow.down.circle"
        case .capturas: return "camera.viewfinder"
        }
    }
}

/// Qué hacer con una carpeta de `~/Library/Caches`.
enum DecisionCache: Equatable {
    case ocultar
    /// Se muestra; `elegida` = viene tildada. `nota` explica por qué no viene tildada.
    case mostrar(elegida: Bool, nota: String?)
}

enum ReglasLimpieza {
    static let diasRegistros = 14
    static let diasInstaladores = 30
    static let diasCapturas = 30

    /// Cachés que nunca se muestran (se comparan sin mayúsculas, el nombre exacto o lo que empieza con "nombre.").
    /// Las de Apple (`com.apple.*`) tampoco: macOS las vuelve a armar con ganas (arranques lentos, reindexado).
    static let cachesIntocables: [String] = [
        "CloudKit", "com.apple.bird",                          // iCloud Drive
        "com.apple.coreaudio", "com.apple.audio", "coreaudiod", // salida de sonido
        "com.apple.systempreferences", "com.apple.controlcenter", "com.apple.finder", "com.apple.dock",
        "FontRegistry", "com.apple.ATS", "com.apple.FontRegistry", // fuentes
        "com.apple.akd", "com.apple.AuthKit", "com.apple.AppleAccount", // sesiones de la cuenta de Apple
        "com.paceap", "PACE", "iLok", "com.native-instruments", "Native Instruments", "com.fabfilter", "FabFilter", // licencias de audio
        "com.spotify.client", "Spotify",                       // guarda personalizaciones ahí
        "team.halyon.alero",                                   // la propia
    ]

    /// Carpetas con nombre común (no de app) que sí son cachés conocidas y se rearman solas.
    static let cachesConocidas: Set<String> = ["pip", "npm", "yarn", "pnpm", "node-gyp", "electron", "electron-builder",
                                                "cypress", "puppeteer", "typescript", "google", "go-build", "deno", "bun"]

    /// Se muestran pero no vienen tildadas: volver a bajarlas lleva mucho.
    static let cachesPesadas: Set<String> = ["ms-playwright"]

    /// "com.empresa.App": dos partes o más separadas por puntos, con letras, números, guiones o guiones bajos.
    static func pareceIdentificador(_ nombre: String) -> Bool {
        let partes = nombre.split(separator: ".", omittingEmptySubsequences: false)
        guard partes.count >= 2, nombre.count <= 255 else { return false }
        return partes.allSatisfy { parte in
            !parte.isEmpty && parte.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
                && parte.unicodeScalars.allSatisfy(\.isASCII)
        }
    }

    static func esIntocable(_ nombre: String) -> Bool {
        let n = nombre.lowercased()
        return n.hasPrefix("com.apple.") || cachesIntocables.contains { regla in
            let r = regla.lowercased()
            return n == r || n.hasPrefix(r + ".")
        }
    }

    /// Qué hacer con `nombre` (un hijo directo de `~/Library/Caches`). `abiertas`: identificadores de las apps que
    /// están corriendo (su caché se muestra, pero sin tildar: borrarla con la app abierta puede confundirla).
    static func decidirCache(_ nombre: String, abiertas: Set<String>) -> DecisionCache {
        if nombre.hasPrefix(".") || nombre.lowercased() == "homebrew" || esIntocable(nombre) { return .ocultar }
        let n = nombre.lowercased()
        if cachesPesadas.contains(n) {
            return .mostrar(elegida: false, nota: T("Pesada de volver a bajar.", "Slow to download again."))
        }
        if cachesConocidas.contains(n) { return .mostrar(elegida: true, nota: nil) }
        guard pareceIdentificador(nombre) else { return .ocultar }
        let abierta = abiertas.contains { id in
            let i = id.lowercased()
            return n == i || n.hasPrefix(i + ".")
        }
        return abierta ? .mostrar(elegida: false, nota: T("La app está abierta.", "The app is open.")) : .mostrar(elegida: true, nota: nil)
    }

    /// Extensiones de instaladores (algunos .pkg son carpetas: también valen).
    static let extensionesInstalador: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    static func esInstalador(_ nombre: String) -> Bool {
        extensionesInstalador.contains((nombre as NSString).pathExtension.lowercased())
    }

    static let extensionesCaptura: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "mov"]

    /// Nombre original de una captura: el de macOS ("Captura de pantalla 2026-10-01 a la(s) 10.22.33", "Screenshot
    /// 2026-10-01 at 10.22.33", "Screen Shot …") o el de Alero ("Captura 2026-10-01 a las 10.22.33"). Si la persona la
    /// renombró, la decisión fue suya y no se ofrece. `deAlero` = el nombre de Alero (no lleva la marca de macOS).
    static func nombreDeCaptura(_ nombre: String) -> (original: Bool, deAlero: Bool) {
        guard extensionesCaptura.contains((nombre as NSString).pathExtension.lowercased()) else { return (false, false) }
        let base = (nombre as NSString).deletingPathExtension
        let fecha = #"\d{4}-\d{2}-\d{2}"#
        let hora = #"\d{1,2}\.\d{2}\.\d{2}"#
        let macOS = #"^(Captura de pantalla|Screenshot|Screen Shot) "# + fecha + #" (a la\(s\)|a las|at) "# + hora
            + #"( (a\. ?m\.|p\. ?m\.|AM|PM))?( \(\d+\))?$"#
        let alero = #"^Captura "# + fecha + #" a las "# + hora + #"( \d+)?$"#
        if base.range(of: alero, options: .regularExpression) != nil { return (true, true) }
        return (base.range(of: macOS, options: .regularExpression) != nil, false)
    }

    /// Más viejo que `dias` días de calendario antes de `ahora`. Sin fecha no es viejo (no se ofrece).
    static func esViejo(_ fecha: Date?, dias: Int, ahora: Date) -> Bool {
        guard let fecha, let limite = Calendar.current.date(byAdding: .day, value: -dias, to: ahora) else { return false }
        return fecha < limite
    }
}
