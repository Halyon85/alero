import Darwin
import Foundation

// Recorre las carpetas de "Limpiar la Mac" y arma la lista de candidatos con su tamaño. Solo lee: no mueve nada.
// Mira únicamente los hijos directos de carpetas fijas (nunca baja a buscar por nombre) y nunca sigue enlaces.
// Recibe la carpeta de la persona como parámetro para poder probarse con una temporal (`LimpiadorTests`).
// Fuera del hilo principal; para entre carpeta y carpeta si se cancela.

struct CandidatoLimpieza: Identifiable, Equatable {
    let elemento: ElementoBorrable
    let categoria: CategoriaLimpieza
    /// Si viene tildado al terminar de buscar.
    let elegido: Bool
    let nota: String?

    var id: String { elemento.id }
    var nombre: String { elemento.url.lastPathComponent }
}

enum EscanerLimpieza {
    struct Opciones {
        var home: String
        var ahora = Date()
        /// Identificadores de las apps abiertas (sus cachés vienen sin tildar).
        var abiertas: Set<String> = []
        /// Dónde buscar capturas olvidadas (el Escritorio y, si son otras, la carpeta de capturas de macOS y la de Alero).
        var carpetasCapturas: [String] = []
        /// Cuándo llegó un archivo a su carpeta. Las pruebas pasan otra (esa fecha no se puede cambiar a mano).
        var fechaDeLlegada: (URL) -> Date? = EscanerLimpieza.fechaDeLlegada
    }

    static func escanear(_ o: Opciones, cancelacion: Cancelacion, avance: (CategoriaLimpieza) -> Void = { _ in }) -> [CandidatoLimpieza] {
        var lista: [CandidatoLimpieza] = []
        for categoria in CategoriaLimpieza.allCases {
            if cancelacion.activa { break }
            avance(categoria)
            lista += buscar(categoria, o, cancelacion)
        }
        return lista
    }

    private static func buscar(_ categoria: CategoriaLimpieza, _ o: Opciones, _ c: Cancelacion) -> [CandidatoLimpieza] {
        let lib = o.home + "/Library"
        let xcodeAbierto = o.abiertas.contains("com.apple.dt.Xcode")
        let notaXcode = xcodeAbierto ? T("Xcode está abierto.", "Xcode is open.") : nil
        switch categoria {
        case .caches:
            return hijos(lib + "/Caches").compactMap { url, identidad in
                guard case let .mostrar(elegida, nota) = ReglasLimpieza.decidirCache(url.lastPathComponent, abiertas: o.abiertas) else { return nil }
                return candidato(url, identidad, raiz: lib + "/Caches", .caches, elegido: elegida, nota: nota, c)
            }
        case .registros:
            var lista = hijos(lib + "/Logs").compactMap { url, identidad -> CandidatoLimpieza? in
                guard url.lastPathComponent != "DiagnosticReports",
                      ReglasLimpieza.esViejo(fechaMasNueva(url, identidad, c), dias: ReglasLimpieza.diasRegistros, ahora: o.ahora) else { return nil }
                return candidato(url, identidad, raiz: lib + "/Logs", .registros, elegido: true, nota: nil, c)
            }
            lista += hijos(lib + "/Logs/DiagnosticReports").compactMap { url, identidad in
                guard identidad.esArchivo,
                      ReglasLimpieza.esViejo(fechaMasNueva(url, identidad, c), dias: ReglasLimpieza.diasRegistros, ahora: o.ahora) else { return nil }
                return candidato(url, identidad, raiz: lib + "/Logs/DiagnosticReports", .registros, elegido: true, nota: nil, c)
            }
            return lista
        case .xcode:
            var lista: [CandidatoLimpieza] = []
            for carpeta in ["/Developer/Xcode/DerivedData", "/Developer/Xcode/DocumentationCache", "/Developer/CoreSimulator/Caches"] {
                lista += hijos(lib + carpeta).compactMap { url, identidad in
                    candidato(url, identidad, raiz: lib + carpeta, .xcode, elegido: !xcodeAbierto, nota: notaXcode, c)
                }
            }
            for sistema in ["iOS", "watchOS", "tvOS", "visionOS"] {
                let carpeta = "/Developer/Xcode/\(sistema) DeviceSupport"
                lista += hijos(lib + carpeta).compactMap { url, identidad in
                    candidato(url, identidad, raiz: lib + carpeta, .xcode, elegido: false,
                              nota: T("Se vuelve a copiar al conectar el aparato.", "It's copied again when you plug in the device."), c)
                }
            }
            // La caché de Xcode es de Apple pero se rearma sola: es la única com.apple.* que se ofrece.
            lista += hijos(lib + "/Caches").filter { $0.0.lastPathComponent == "com.apple.dt.Xcode" }.compactMap { url, identidad in
                candidato(url, identidad, raiz: lib + "/Caches", .xcode, elegido: !xcodeAbierto, nota: notaXcode, c)
            }
            return lista
        case .homebrew:
            return hijos(lib + "/Caches/Homebrew").compactMap { url, identidad in
                // "api" es el catálogo de Homebrew: sin él, el próximo brew tarda en arrancar. No es basura.
                guard url.lastPathComponent != "api" else { return nil }
                return candidato(url, identidad, raiz: lib + "/Caches/Homebrew", .homebrew, elegido: true, nota: nil, c)
            }
        case .instaladores:
            return hijos(o.home + "/Downloads").compactMap { url, identidad in
                guard ReglasLimpieza.esInstalador(url.lastPathComponent),
                      ReglasLimpieza.esViejo(o.fechaDeLlegada(url), dias: ReglasLimpieza.diasInstaladores, ahora: o.ahora) else { return nil }
                return candidato(url, identidad, raiz: o.home + "/Downloads", .instaladores, elegido: false, nota: nil, c)
            }
        case .capturas:
            var vistas = Set<String>()
            return o.carpetasCapturas.flatMap { carpeta -> [CandidatoLimpieza] in
                // Sin resolver enlaces a propósito: si la carpeta es un enlace, `hijos` no devuelve nada.
                let raiz = carpeta.hasSuffix("/") ? String(carpeta.dropLast()) : carpeta
                guard vistas.insert(raiz).inserted else { return [] }
                return hijos(raiz).compactMap { url, identidad in
                    let nombre = ReglasLimpieza.nombreDeCaptura(url.lastPathComponent)
                    guard identidad.esArchivo, nombre.original, nombre.deAlero || tieneMarcaDeCaptura(url),
                          ReglasLimpieza.esViejo(o.fechaDeLlegada(url), dias: ReglasLimpieza.diasCapturas, ahora: o.ahora) else { return nil }
                    return candidato(url, identidad, raiz: raiz, .capturas, elegido: false, nota: nil, c)
                }
            }
        }
    }

    /// Los hijos directos de `carpeta`, sin enlaces ni ocultos ("." al principio). Vacío si la carpeta no existe, no
    /// se puede leer o es (o pasa por) un enlace: ante la duda, no se ofrece nada.
    static func hijos(_ carpeta: String) -> [(URL, IdentidadArchivo)] {
        guard let real = ReglasBorrado.realpath(carpeta), real == carpeta,
              IdentidadArchivo.leer(URL(fileURLWithPath: carpeta))?.esCarpeta == true,
              let nombres = try? FileManager.default.contentsOfDirectory(atPath: carpeta) else { return [] }
        return nombres.sorted().compactMap { nombre in
            guard !nombre.hasPrefix(".") else { return nil }
            let url = URL(fileURLWithPath: carpeta, isDirectory: false).appendingPathComponent(nombre, isDirectory: false)
            guard let identidad = IdentidadArchivo.leer(url), !identidad.esEnlace else { return nil }
            return (url, identidad)
        }
    }

    private static func candidato(_ url: URL, _ identidad: IdentidadArchivo, raiz: String, _ categoria: CategoriaLimpieza,
                                  elegido: Bool, nota: String?, _ c: Cancelacion) -> CandidatoLimpieza? {
        guard !c.activa else { return nil }
        let tamano = Papelera.tamano(url, cancelacion: c)
        // Una carpeta vacía no libera nada: es ruido en la lista.
        guard tamano > 0 else { return nil }
        let elemento = ElementoBorrable(url: url, raiz: URL(fileURLWithPath: raiz, isDirectory: true), identidad: identidad, tamano: tamano)
        return CandidatoLimpieza(elemento: elemento, categoria: categoria, elegido: elegido, nota: nota)
    }

    /// La fecha más nueva de un archivo o de lo que tiene adentro una carpeta (una carpeta de registros con algo de
    /// ayer no es vieja). Revisa hasta 5.000 cosas: si hay más, la toma como nueva para no ofrecerla de más.
    static func fechaMasNueva(_ url: URL, _ identidad: IdentidadArchivo, _ c: Cancelacion) -> Date? {
        let propia = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard identidad.esCarpeta else { return propia }
        guard let recorrido = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: [], errorHandler: { _, _ in true }) else { return propia }
        var masNueva = propia
        var vistos = 0
        for case let hijo as URL in recorrido {
            vistos += 1
            if vistos > 5_000 || c.activa { return Date() }
            if let fecha = (try? hijo.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               fecha > (masNueva ?? .distantPast) {
                masNueva = fecha
            }
        }
        return masNueva
    }

    /// Cuándo llegó a su carpeta (al bajarlo o al guardarlo); si macOS no lo sabe, cuándo se creó.
    static func fechaDeLlegada(_ url: URL) -> Date? {
        let valores = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return valores?.addedToDirectoryDate ?? valores?.creationDate
    }

    /// macOS marca sus capturas con este atributo; un archivo cualquiera con el mismo nombre no lo tiene.
    static func tieneMarcaDeCaptura(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0
    }
}
