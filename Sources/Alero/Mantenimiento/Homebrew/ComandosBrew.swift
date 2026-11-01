import Foundation

// Lo puro del gestor de Homebrew: dónde está brew, qué argumentos lleva cada operación (siempre separados, nunca
// un texto de shell), qué nombres de paquete se aceptan, cómo se lee el JSON de `brew info` y `brew outdated`, cómo
// se reconoce que brew pide contraseña y cómo se arma el comando para abrirlo en la Terminal. Se prueba en
// `HomebrewTests` sin correr brew.

enum TipoPaquete: String, Equatable {
    case formula, cask

    var bandera: String { self == .formula ? "--formula" : "--cask" }
    var nombre: String { self == .formula ? T("Fórmula", "Formula") : T("App", "App") }
}

struct PaqueteBrew: Identifiable, Equatable {
    let nombre: String
    let tipo: TipoPaquete
    let version: String
    /// La versión nueva, si hay actualización.
    var nueva: String?
    let descripcion: String?
    /// Lo instaló la persona (no es solo una dependencia de otra cosa). Los casks siempre.
    let pedido: Bool
    let fijado: Bool
    /// Lo que ocupa en el disco (solo fórmulas: se calcula después, en segundo plano).
    var tamano: Int64?

    var id: String { tipo.rawValue + "/" + nombre }
}

enum OperacionBrew: Equatable {
    case actualizar(String, TipoPaquete), actualizarTodo, desinstalar(String, TipoPaquete), limpiar, actualizarHomebrew

    /// Los argumentos de brew. Nil si el nombre del paquete no es válido (no se corre nada).
    var argumentos: [String]? {
        switch self {
        case .actualizar(let nombre, let tipo):
            return ComandosBrew.nombreValido(nombre) ? ["upgrade", tipo.bandera, nombre] : nil
        case .desinstalar(let nombre, let tipo):
            return ComandosBrew.nombreValido(nombre) ? ["uninstall", tipo.bandera, nombre] : nil
        case .actualizarTodo: return ["upgrade"]
        case .limpiar: return ["cleanup"]
        case .actualizarHomebrew: return ["update"]
        }
    }

    var titulo: String {
        switch self {
        case .actualizar(let nombre, _): return T("Actualizando \(nombre)", "Upgrading \(nombre)")
        case .desinstalar(let nombre, _): return T("Desinstalando \(nombre)", "Uninstalling \(nombre)")
        case .actualizarTodo: return T("Actualizando todo", "Upgrading everything")
        case .limpiar: return T("Limpiando versiones viejas", "Cleaning up old versions")
        case .actualizarHomebrew: return T("Buscando novedades", "Checking for updates")
        }
    }

    /// Cambia lo instalado: al terminar hay que volver a leer la lista.
    var cambiaLaLista: Bool { self != .limpiar }
}

enum ComandosBrew {
    static let leerVersion = ["--version"]
    static let leerInstalados = ["info", "--json=v2", "--installed"]
    static let leerDesactualizados = ["outdated", "--json=v2"]

    /// Las dos instalaciones oficiales (Apple Silicon e Intel). Nunca se busca brew en el PATH.
    static let ubicaciones = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func ubicacion(ejecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        ubicaciones.first(where: ejecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Un nombre de paquete que se le puede pasar a brew: no arranca con "-" (sería una opción), sin ".." ni "//".
    static func nombreValido(_ nombre: String) -> Bool {
        guard !nombre.isEmpty, nombre.count <= 200, !nombre.hasPrefix("-"), !nombre.contains(".."), !nombre.contains("//") else { return false }
        return nombre.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+@/-]*$"#, options: .regularExpression) != nil
    }

    /// El entorno de brew: lo justo de la persona (casa, usuario, idioma, proxy y sus HOMEBREW_*) más lo de Alero.
    /// A propósito sin auto-actualizar: leer la lista no tiene que cambiar nada; "Buscar novedades" corre `brew update`.
    static func entorno(base: [String: String]) -> [String: String] {
        let deLaPersona = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                           "http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
        var entorno = base.filter { clave, _ in deLaPersona.contains(clave) || clave.hasPrefix("HOMEBREW_") }
        entorno["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        entorno["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        entorno["HOMEBREW_NO_ENV_HINTS"] = "1"
        entorno["HOMEBREW_NO_EMOJI"] = "1"
        entorno["HOMEBREW_NO_COLOR"] = "1"
        entorno["NO_COLOR"] = "1"
        return entorno
    }

    // MARK: - JSON

    private struct Info: Decodable {
        struct Formula: Decodable {
            struct Instalada: Decodable { let version: String; let installed_on_request: Bool? }
            let name: String
            let desc: String?
            let installed: [Instalada]
            let outdated: Bool?
            let pinned: Bool?
        }
        struct Cask: Decodable {
            let token: String
            let desc: String?
            let installed: String?
            let outdated: Bool?
        }
        let formulae: [Formula]
        let casks: [Cask]?
    }

    private struct Desactualizados: Decodable {
        struct Uno: Decodable { let name: String; let current_version: String; let pinned: Bool? }
        let formulae: [Uno]?
        let casks: [Uno]?
    }

    /// Lo instalado, con la versión nueva de lo que tiene actualización. Los nombres que no son válidos se dejan
    /// afuera (no se podrían actualizar ni desinstalar). Lo pedido por la persona primero; dentro, por nombre.
    static func inventario(info: Data, desactualizados: Data?) throws -> [PaqueteBrew] {
        let leido = try JSONDecoder().decode(Info.self, from: info)
        let nuevos = desactualizados.flatMap { try? JSONDecoder().decode(Desactualizados.self, from: $0) }
        let nuevasFormulas = Dictionary((nuevos?.formulae ?? []).map { ($0.name, $0.current_version) }, uniquingKeysWith: { a, _ in a })
        let nuevosCasks = Dictionary((nuevos?.casks ?? []).map { ($0.name, $0.current_version) }, uniquingKeysWith: { a, _ in a })
        var lista: [PaqueteBrew] = []
        for f in leido.formulae where nombreValido(f.name) {
            guard let ultima = f.installed.last else { continue }
            lista.append(PaqueteBrew(nombre: f.name, tipo: .formula, version: ultima.version, nueva: nuevasFormulas[f.name],
                                     descripcion: f.desc, pedido: f.installed.contains { $0.installed_on_request == true },
                                     fijado: f.pinned ?? false, tamano: nil))
        }
        for c in leido.casks ?? [] where nombreValido(c.token) {
            lista.append(PaqueteBrew(nombre: c.token, tipo: .cask, version: c.installed ?? "?", nueva: nuevosCasks[c.token],
                                     descripcion: c.desc, pedido: true, fijado: false, tamano: nil))
        }
        return lista.sorted { ($0.pedido ? 0 : 1, $0.nombre.lowercased()) < ($1.pedido ? 0 : 1, $1.nombre.lowercased()) }
    }

    /// "Homebrew 7.0.11" (la primera línea de `brew --version`).
    static func version(_ salida: Data) -> String? {
        String(data: salida, encoding: .utf8)?.split(separator: "\n").first.map(String.init)
    }

    // MARK: - Salida en vivo

    /// brew necesita una contraseña (un cask con instalador .pkg): Alero no la pide ni la maneja; ofrece la Terminal.
    static func pideContrasena(_ linea: String) -> Bool {
        let l = linea.lowercased()
        return ["sudo:", "a terminal is required", "password is required", "password:", "administrator privileges",
                "contraseña"].contains { l.contains($0) }
    }

    /// Saca los códigos de color de la terminal (por si alguna herramienta los manda igual).
    static func limpiarANSI(_ texto: String) -> String {
        texto.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    // MARK: - Abrir en la Terminal

    /// Comillas simples de shell: 'it'\''s'.
    static func citar(_ argumento: String) -> String {
        "'" + argumento.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// El archivo `.command` que abre la Terminal: se borra a sí mismo y corre brew con los mismos argumentos. La
    /// contraseña, si hace falta, la escribe la persona en su Terminal.
    static func guion(brew: String, argumentos: [String]) -> String {
        """
        #!/bin/zsh -l
        rm -f -- "$0"
        exec \(([brew] + argumentos).map(citar).joined(separator: " "))

        """
    }
}
