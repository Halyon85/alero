import Foundation
import Security

// Qué app se puede desinstalar y qué cuenta como resto suyo. Los restos se buscan por identificadores que la app
// declara (el suyo y los de sus extensiones y ayudantes) y por los grupos de su firma. Desde el 11/11/2026 también por
// el nombre exacto de la app, pero solo en carpetas de datos, cachés, registros e informes de errores (`porNombre`):
// muchas apps guardan ahí lo más pesado ("Application Support/Slack") y antes quedaba. Un nombre lo puede compartir
// otra app: si pasa, esos restos se muestran sin tildar. Las carpetas sensibles (las que arrancan programas o guardan
// las preferencias) solo aceptan el identificador exacto, nunca el nombre. Lo que está en `/Library`
// (agentes y ayudantes del sistema) y los recibos del instalador solo se informan: moverlos pide administrador.
// Se prueba en `DesinstaladorTests` con apps de mentira en una carpeta temporal.

/// La app elegida, con lo que se leyó al elegirla. Se vuelve a leer y comparar justo antes de desinstalar.
struct AppElegida: Equatable {
    let url: URL
    let identificador: String
    let nombre: String
    let version: String?
    let identidadApp: IdentidadArchivo
    let identidadPlist: IdentidadArchivo
    /// El identificador de la app más los de sus extensiones y ayudantes que viven bajo él ("com.foo.App.Helper").
    let identificadores: [String]
    var equipo: String? = nil
    /// Grupos de app firmados ("TEAMID.com.foo.compartido" o "group.com.foo"): sus Group Containers son de la app.
    var grupos: [String] = []
    /// Etiquetas de sus ayudantes con permisos de administrador (`SMPrivilegedExecutables` y lo que trae en
    /// `Contents/Library/LaunchServices`): al instalarse quedan en `/Library/PrivilegedHelperTools` y `LaunchDaemons`.
    var ayudantes: [String] = []
    /// Cómo se llama la app (el archivo sin ".app", su nombre visible y su ejecutable), para los restos por nombre.
    var nombres: [String] = []
}

enum RechazoApp: Error, Equatable {
    case noEsApp, enlace, dentroDeOtraApp, sinIdentificador, delSistema, deApple, esAlero

    var explicacion: String {
        switch self {
        case .noEsApp: return T("No es una app (tiene que terminar en .app).", "That's not an app (it must end in .app).")
        case .enlace: return T("Es un alias o un enlace. Elegí la app de verdad.", "That's an alias or a link. Pick the real app.")
        case .dentroDeOtraApp: return T("Está dentro de otra app: se va con ella.", "It lives inside another app: it goes with it.")
        case .sinIdentificador: return T("No tiene identificador: no se puede saber qué es suyo.",
                                         "It has no identifier: there's no way to tell what's its own.")
        case .delSistema: return T("Es parte de macOS y no se puede quitar.", "It's part of macOS and can't be removed.")
        case .deApple: return T("Las apps de Apple no se desinstalan desde Alero.", "Apple apps aren't uninstalled from Alero.")
        case .esAlero: return T("Alero no se puede desinstalar a sí misma desde acá.", "Alero can't uninstall itself from here.")
        }
    }
}

/// Las carpetas de `~/Library` (y las de `/Library` que solo se informan) donde quedan restos, y cómo se llama ahí
/// lo de una app.
enum CarpetaRestos: String, CaseIterable, Identifiable {
    case soporte, caches, preferencias, porEquipo, contenedores, grupos, estado, almacenHTTP, webKit, agentes, registros, cookies, scripts
    case autoguardado
    // Informes de errores: archivos que empiezan con el nombre de la app ("Slack_<id>.plist", "Slack-2026-….ips").
    case informes, diagnosticos
    // En `/Library`: son de todas las cuentas y moverlos pide administrador. Solo se listan.
    case agentesSistema, demoniosSistema, ayudantesSistema, soporteSistema, preferenciasSistema

    var id: String { rawValue }

    /// Si está en `/Library` (de toda la Mac) en vez de en la `Library` de la persona.
    var enSistema: Bool {
        switch self {
        case .agentesSistema, .demoniosSistema, .ayudantesSistema, .soporteSistema, .preferenciasSistema: return true
        default: return false
        }
    }

    /// Las que tienen archivos de launchd: se reconocen por lo que dicen adentro, no por el nombre.
    var deLaunchd: Bool { self == .agentes || self == .agentesSistema || self == .demoniosSistema }

    /// Relativa a `~/Library` o, si `enSistema`, a `/Library`.
    var ruta: String {
        switch self {
        case .soporte: return "Application Support"
        case .caches: return "Caches"
        case .preferencias: return "Preferences"
        case .porEquipo: return "Preferences/ByHost"
        case .contenedores: return "Containers"
        case .grupos: return "Group Containers"
        case .estado: return "Saved Application State"
        case .almacenHTTP: return "HTTPStorages"
        case .webKit: return "WebKit"
        case .agentes: return "LaunchAgents"
        case .registros: return "Logs"
        case .cookies: return "Cookies"
        case .scripts: return "Application Scripts"
        case .autoguardado: return "Autosave Information"
        case .informes: return "Application Support/CrashReporter"
        case .diagnosticos: return "Logs/DiagnosticReports"
        case .agentesSistema: return "LaunchAgents"
        case .demoniosSistema: return "LaunchDaemons"
        case .ayudantesSistema: return "PrivilegedHelperTools"
        case .soporteSistema: return "Application Support"
        case .preferenciasSistema: return "Preferences"
        }
    }

    var titulo: String {
        switch self {
        case .soporte: return T("Datos de la app", "App data")
        case .caches: return T("Cachés", "Caches")
        case .preferencias, .porEquipo: return T("Preferencias", "Preferences")
        case .contenedores: return T("Contenedor", "Container")
        case .grupos: return T("Contenedor compartido", "Group container")
        case .estado: return T("Ventanas guardadas", "Saved windows")
        case .almacenHTTP, .webKit, .cookies: return T("Datos web", "Web data")
        case .agentes: return T("Programa al iniciar sesión", "Login agent")
        case .registros: return T("Registros", "Logs")
        case .scripts: return T("Scripts", "Scripts")
        case .autoguardado: return T("Autoguardado", "Autosave")
        case .informes, .diagnosticos: return T("Informes de errores", "Crash reports")
        case .agentesSistema: return T("Agente de la Mac", "System agent")
        case .demoniosSistema: return T("Servicio de la Mac", "System daemon")
        case .ayudantesSistema: return T("Ayudante con permisos", "Privileged helper")
        case .soporteSistema: return T("Datos de la Mac", "System data")
        case .preferenciasSistema: return T("Preferencias de la Mac", "System preferences")
        }
    }

    /// Las que arrancan programas o guardan los datos de la app: solo el identificador exacto (ni subidentificadores).
    var sensible: Bool {
        switch self {
        case .preferencias, .porEquipo, .contenedores, .grupos, .agentes, .scripts: return true
        default: return enSistema
        }
    }

    /// Las carpetas donde también vale el nombre de la app: datos, cachés, registros e informes. Nunca las sensibles.
    var porNombre: Bool {
        switch self {
        case .soporte, .caches, .registros, .webKit, .almacenHTTP, .informes, .diagnosticos: return true
        default: return false
        }
    }

    /// El identificador que hay en `nombre` (un hijo de esta carpeta), sin envoltorios: "com.foo.App.plist" →
    /// "com.foo.App". Nil si el nombre no tiene la forma que usa macOS en esa carpeta.
    func identificador(en nombre: String) -> String? {
        func sinFinal(_ final: String) -> String? { nombre.hasSuffix(final) ? String(nombre.dropLast(final.count)) : nil }
        switch self {
        case .preferencias, .agentes, .agentesSistema, .demoniosSistema, .preferenciasSistema: return sinFinal(".plist")
        case .autoguardado: return sinFinal(".plist") ?? nombre
        case .porEquipo:
            // "com.foo.App.<UUID o número del equipo>.plist"
            guard let base = sinFinal(".plist"), let punto = base.lastIndex(of: ".") else { return nil }
            let equipo = base[base.index(after: punto)...]
            let hexa = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
            guard equipo.count >= 8, equipo.unicodeScalars.allSatisfy(hexa.contains) else { return nil }
            return String(base[..<punto])
        case .estado: return sinFinal(".savedState")
        case .cookies: return sinFinal(".binarycookies")
        case .almacenHTTP: return sinFinal(".binarycookies") ?? nombre
        default: return nombre
        }
    }
}

enum ReglasApp {
    /// Revisa la app elegida (arrastrada o de la lista). No lee la firma (eso va aparte: tarda un poco).
    static func validar(_ url: URL, propio: String = Bundle.main.bundleIdentifier ?? "team.halyon.alero",
                        rutaPropia: String = Bundle.main.bundlePath) -> Result<AppElegida, RechazoApp> {
        let ruta = url.path
        guard url.pathExtension.lowercased() == "app" else { return .failure(.noEsApp) }
        guard let identidad = IdentidadArchivo.leer(url) else { return .failure(.noEsApp) }
        if identidad.esEnlace { return .failure(.enlace) }
        guard identidad.esCarpeta else { return .failure(.noEsApp) }
        let partes = (ruta as NSString).pathComponents
        if partes.contains(".") || partes.contains("..") { return .failure(.noEsApp) }
        if partes.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) { return .failure(.dentroDeOtraApp) }
        if ruta.hasPrefix("/System/") || ruta.hasPrefix("/Library/Apple/") || ruta.hasPrefix("/usr/") { return .failure(.delSistema) }
        if ruta == rutaPropia { return .failure(.esAlero) }
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let identidadPlist = IdentidadArchivo.leer(plist), identidadPlist.esArchivo,
              let datos = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: datos, format: nil) as? [String: Any],
              let identificador = info["CFBundleIdentifier"] as? String, ReglasLimpieza.pareceIdentificador(identificador) else {
            return .failure(.sinIdentificador)
        }
        if identificador == propio { return .failure(.esAlero) }
        if identificador.lowercased().hasPrefix("com.apple.") { return .failure(.deApple) }
        let nombre = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let ids = [identificador] + embebidos(url, principal: identificador)
        return .success(AppElegida(url: url, identificador: identificador, nombre: nombre,
                                   version: info["CFBundleShortVersionString"] as? String,
                                   identidadApp: identidad, identidadPlist: identidadPlist, identificadores: ids,
                                   ayudantes: ayudantesPrivilegiados(url, info: info), nombres: nombresDe(url, info: info)))
    }

    /// Justo antes de desinstalar: la app tiene que ser la misma que se eligió (ni reemplazada, ni cambiada por un
    /// enlace, ni con otro identificador). La llama `ModeloDesinstalador.desinstalar` por cada app del lote.
    static func sigueIgual(_ app: AppElegida, propio: String = Bundle.main.bundleIdentifier ?? "team.halyon.alero",
                           rutaPropia: String = Bundle.main.bundlePath) -> Bool {
        guard case .success(let ahora) = validar(app.url, propio: propio, rutaPropia: rutaPropia) else { return false }
        return ahora.identidadApp == app.identidadApp && ahora.identidadPlist == app.identidadPlist
            && ahora.identificador == app.identificador
    }

    /// Las etiquetas de los ayudantes con permisos que instala la app (SMJobBless): las claves de
    /// `SMPrivilegedExecutables` y los archivos de `Contents/Library/LaunchServices` (macOS los copia con ese nombre a
    /// `/Library/PrivilegedHelperTools`). Solo sirven para reconocer lo que dejó en `/Library`, que nunca se mueve.
    static func ayudantesPrivilegiados(_ app: URL, info: [String: Any]) -> [String] {
        var etiquetas = (info["SMPrivilegedExecutables"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
        let carpeta = app.appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
        let archivos = (try? FileManager.default.contentsOfDirectory(atPath: carpeta.path)) ?? []
        for nombre in archivos.sorted() where IdentidadArchivo.leer(carpeta.appendingPathComponent(nombre))?.esArchivo == true {
            etiquetas.append(nombre)
        }
        var unicas: [String] = []
        for etiqueta in etiquetas where esEtiqueta(etiqueta) && ReglasLimpieza.pareceIdentificador(etiqueta) && !unicas.contains(etiqueta) {
            unicas.append(etiqueta)
        }
        return unicas
    }

    /// Identificadores de extensiones y ayudantes de adentro que viven bajo el de la app ("com.foo.App.Share").
    /// A propósito se ignoran los ajenos (Sparkle y otras piezas que traen muchas apps): sus datos no son de esta.
    static func embebidos(_ app: URL, principal: String) -> [String] {
        let carpetas = ["Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices", "Contents/Library/LoginItems",
                        "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions", "Contents/Library/QuickLook",
                        "Contents/Library/Spotlight", "Contents/Helpers", "Contents/Frameworks", "Contents/Applications"]
        var ids: [String] = []
        for carpeta in carpetas {
            let base = app.appendingPathComponent(carpeta, isDirectory: true)
            guard let nombres = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { continue }
            for nombre in nombres {
                let plist = base.appendingPathComponent(nombre).appendingPathComponent("Contents/Info.plist")
                guard IdentidadArchivo.leer(base.appendingPathComponent(nombre))?.esEnlace == false,
                      let datos = try? Data(contentsOf: plist),
                      let info = try? PropertyListSerialization.propertyList(from: datos, format: nil) as? [String: Any],
                      let id = info["CFBundleIdentifier"] as? String,
                      id.hasPrefix(principal + "."), ReglasLimpieza.pareceIdentificador(id), !ids.contains(id) else { continue }
                ids.append(id)
            }
        }
        return ids
    }

    /// Equipo (Team ID) y grupos de app de la firma. Solo si la firma de la app es válida; si no, nada (los restos
    /// se buscan entonces solo por identificador). No revisa todos los archivos de la app (eso tarda segundos).
    static func firma(_ app: URL) -> (equipo: String?, grupos: [String]) {
        var codigo: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &codigo) == errSecSuccess, let codigo,
              SecStaticCodeCheckValidity(codigo, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess else {
            return (nil, [])
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(codigo, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let datos = info as? [String: Any] else { return (nil, []) }
        let equipo = datos[kSecCodeInfoTeamIdentifier as String] as? String
        let derechos = datos[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let declarados = derechos?["com.apple.security.application-groups"] as? [String] ?? []
        return (equipo, gruposValidos(declarados, equipo: equipo))
    }

    /// Los nombres de grupo que son de la app: los firmados y, además, "TEAMID.<identificador>" (con el equipo de la
    /// firma válida) y "group.<identificador>". Los dos últimos llevan el identificador de la app: ninguna otra app
    /// puede tener un grupo con ese nombre. Se usa en Group Containers y en Application Scripts.
    static func gruposPosibles(_ app: AppElegida) -> [String] {
        var todos = app.grupos
        let deEquipo = app.equipo.map { equipo in app.identificadores.map { equipo + "." + $0 } } ?? []
        for grupo in deEquipo + app.identificadores.map({ "group." + $0 }) where !todos.contains(grupo) { todos.append(grupo) }
        return todos
    }

    /// Un grupo cuenta solo si es del mismo equipo que firmó ("TEAMID.algo") o del estilo "group.algo".
    static func gruposValidos(_ declarados: [String], equipo: String?) -> [String] {
        declarados.filter { grupo in
            let deEquipo = equipo.map { grupo.hasPrefix($0 + ".") } ?? false
            return (deEquipo || grupo.hasPrefix("group.")) && grupo.count > 6 && !grupo.contains("/")
        }
    }

    /// Si `nombre` (un hijo de `carpeta`) es de la app. Sensibles: identificador exacto (o grupo firmado exacto).
    /// El resto también acepta subidentificadores ("com.foo.App.ShipIt" en Cachés). Nunca por nombre visible.
    /// `grupos` son los de `gruposPosibles`; `ayudantes`, las etiquetas de `ayudantesPrivilegiados`.
    static func esDeLaApp(_ nombre: String, en carpeta: CarpetaRestos, ids: [String], grupos: [String], ayudantes: [String] = []) -> Bool {
        guard let id = carpeta.identificador(en: nombre), !id.isEmpty else { return false }
        if carpeta == .grupos { return grupos.contains(id) }
        // Application Scripts también tiene carpetas por grupo ("TEAMID.com.foo.compartido").
        if carpeta == .scripts, grupos.contains(id) { return true }
        if carpeta == .ayudantesSistema, ayudantes.contains(id) { return true }
        if ids.contains(id) { return true }
        guard !carpeta.sensible, ReglasLimpieza.pareceIdentificador(id) else { return false }
        return ids.contains { id.hasPrefix($0 + ".") }
    }

    /// Nombres demasiado comunes para buscar por ellos: carpetas de fabricantes (adentro hay cosas de varias apps) y
    /// palabras genéricas.
    private static let nombresComunes: Set<String> = [
        "google", "microsoft", "adobe", "apple", "mozilla", "jetbrains", "electron", "helper", "app", "application",
        "update", "updater", "cache", "caches", "logs", "data", "temp", "tmp", "default", "user", "shared", "common",
        "crashreporter", "diagnosticreports", "java", "python", "node", "desktop", "launcher", "installer", "setup",
    ]

    /// Los nombres de la app que sirven para buscar restos: el archivo sin ".app", el nombre visible y el ejecutable.
    /// En minúsculas, sin repetir, de 3 letras o más y sin los demasiado comunes. Lo usa `validar`.
    static func nombresDe(_ app: URL, info: [String: Any]) -> [String] {
        let crudos = [app.deletingPathExtension().lastPathComponent, info["CFBundleName"] as? String,
                      info["CFBundleDisplayName"] as? String, info["CFBundleExecutable"] as? String]
        var nombres: [String] = []
        for crudo in crudos {
            guard let nombre = crudo?.trimmingCharacters(in: .whitespaces).lowercased(), nombre.count >= 3,
                  !nombre.contains("/"), !nombre.hasPrefix("."), !nombresComunes.contains(nombre),
                  !nombres.contains(nombre) else { continue }
            nombres.append(nombre)
        }
        return nombres
    }

    /// Si `nombre` (un hijo de `carpeta`) es de la app por cómo se llama. Solo en las carpetas `porNombre`. En datos,
    /// cachés y registros el nombre tiene que ser exactamente el de la app ("Slack"); en los informes de errores, el
    /// archivo empieza con el nombre y sigue con lo que le agrega macOS ("Slack_<id>.plist", "Slack-2026-11-11-….ips").
    static func esPorNombre(_ nombre: String, en carpeta: CarpetaRestos, nombres: [String]) -> Bool {
        guard carpeta.porNombre, !nombres.isEmpty else { return false }
        let archivo = nombre.lowercased()
        switch carpeta {
        case .informes:
            guard archivo.hasSuffix(".plist") else { return false }
            return nombres.contains { archivo.hasPrefix($0 + "_") }
        case .diagnosticos:
            guard [".ips", ".crash", ".diag", ".hang", ".spin"].contains(where: archivo.hasSuffix) else { return false }
            // Después del nombre viene la fecha ("-2026-…" o "_2026-…"): así "Notas" no se lleva lo de "Notas Pro".
            return nombres.contains { archivo.hasPrefix($0 + "-20") || archivo.hasPrefix($0 + "_20") }
        default:
            return nombres.contains(archivo)
        }
    }

    /// Un LaunchAgent (o LaunchDaemon) es de la app si su etiqueta es un identificador de la app (o de un ayudante
    /// suyo), si declara la app en `AssociatedBundleIdentifiers` (así lo muestra macOS en Ítems de inicio) o si el
    /// programa que arranca está dentro de la app. Devuelve la etiqueta (para sacarlo con `launchctl bootout`), o nil.
    static func etiquetaDeAgente(_ plist: [String: Any], archivo: String, app: URL, ids: [String]) -> String? {
        guard let etiqueta = plist["Label"] as? String, esEtiqueta(etiqueta), archivo == etiqueta + ".plist" else { return nil }
        if ids.contains(etiqueta) { return etiqueta }
        let asociados = (plist["AssociatedBundleIdentifiers"] as? [String])
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        if asociados.contains(where: ids.contains) { return etiqueta }
        let programa = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        guard let programa, (programa as NSString).pathComponents.contains("..") == false else { return nil }
        return programa.hasPrefix(app.path + "/") ? etiqueta : nil
    }

    /// Los recibos del instalador (.pkg) de la app, para informar: el que instaló su Info.plist (salida de
    /// `pkgutil --file-info`) y los de `pkgutil --pkgs` que llevan un identificador suyo. Los de Apple nunca.
    static func recibos(infoDelArchivo: String, paquetes: [String], ids: [String]) -> [String] {
        var lista: [String] = []
        func sumar(_ texto: Substring) {
            let paquete = texto.trimmingCharacters(in: .whitespaces)
            guard ReglasLimpieza.pareceIdentificador(paquete), !paquete.lowercased().hasPrefix("com.apple."),
                  !lista.contains(paquete) else { return }
            lista.append(paquete)
        }
        let marca = "package-id:"
        for linea in infoDelArchivo.split(separator: "\n") where linea.hasPrefix(marca) { sumar(linea.dropFirst(marca.count)) }
        for paquete in paquetes {
            let limpio = paquete.trimmingCharacters(in: .whitespaces)
            if ids.contains(where: { limpio == $0 || limpio.hasPrefix($0 + ".") }) { sumar(Substring(limpio)) }
        }
        return lista
    }

    /// Una etiqueta de launchd que se puede pasar a `launchctl` sin sorpresas.
    static func esEtiqueta(_ texto: String) -> Bool {
        !texto.isEmpty && texto.count <= 200 && !texto.hasPrefix("-") && !texto.hasPrefix(".")
            && texto.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }
}
