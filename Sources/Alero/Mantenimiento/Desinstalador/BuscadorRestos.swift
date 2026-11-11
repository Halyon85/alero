import Foundation

// Busca los restos de una app: solo mira los hijos directos de las carpetas de `CarpetaRestos` y se queda con los que
// `ReglasApp` reconoce como de la app (por identificador o, en las carpetas de datos, por su nombre exacto). Los de `~/Library` se pueden mandar a la Papelera; los de `/Library` (agentes,
// servicios y ayudantes de toda la Mac) solo se listan con la nota "pide administrador". Los recibos del instalador
// salen de `pkgutil` y también son solo para informar. Solo lee (y calcula tamaños). Recibe las carpetas como
// parámetros para probarse con temporales. Fuera del hilo principal.

struct RestoApp: Identifiable, Equatable {
    let elemento: ElementoBorrable
    let carpeta: CarpetaRestos
    /// Si es un LaunchAgent: su etiqueta, para sacarlo de launchd antes de mandarlo a la Papelera.
    let etiquetaAgente: String?
    let elegido: Bool
    let nota: String?
    /// Está en `/Library`: moverlo pide administrador. Se muestra, pero nunca se elige ni se manda.
    var pideAdministrador = false

    var id: String { elemento.id }
    var nombre: String { elemento.url.lastPathComponent }
}

enum BuscadorRestos {
    /// `otraCopia`: hay otra copia de la misma app instalada; sus restos se muestran pero sin tildar (son de las dos).
    /// `sistema` es `/Library`; las pruebas pasan una carpeta temporal.
    /// `nombreCompartido`: otra app instalada se llama igual; lo encontrado por nombre va sin tildar (puede ser de ella).
    static func buscar(_ app: AppElegida, home: String, sistema: String = "/Library", otraCopia: Bool,
                       nombreCompartido: Bool = false, cancelacion: Cancelacion) -> [RestoApp] {
        let notaCopia = otraCopia ? T("Hay otra copia de la app.", "Another copy is installed.") : nil
        let notaNombre = nombreCompartido ? T("Otra app se llama igual: revisalo.", "Another app has the same name: check it.")
                                          : T("Por el nombre de la app", "Matched by the app's name")
        let notaAdministrador = T("Pide administrador", "Needs admin")
        let grupos = ReglasApp.gruposPosibles(app)
        // Los ayudantes con permisos se reconocen por su etiqueta también en LaunchDaemons.
        let idsLaunchd = app.identificadores + app.ayudantes
        var restos: [RestoApp] = []
        for carpeta in CarpetaRestos.allCases {
            if cancelacion.activa { return [] }
            let raiz = carpeta.enSistema ? sistema + "/" + carpeta.ruta : home + "/Library/" + carpeta.ruta
            for (url, identidad) in EscanerLimpieza.hijos(raiz) {
                let nombre = url.lastPathComponent
                var etiqueta: String?
                var porNombre = false
                if carpeta.deLaunchd {
                    // Un agente se reconoce por su contenido (etiqueta o programa dentro de la app), no por el nombre.
                    guard identidad.esArchivo, let datos = try? Data(contentsOf: url),
                          let plist = try? PropertyListSerialization.propertyList(from: datos, format: nil) as? [String: Any],
                          let encontrada = ReglasApp.etiquetaDeAgente(plist, archivo: nombre, app: app.url, ids: idsLaunchd) else { continue }
                    etiqueta = encontrada
                } else if !ReglasApp.esDeLaApp(nombre, en: carpeta, ids: app.identificadores, grupos: grupos, ayudantes: app.ayudantes) {
                    guard ReglasApp.esPorNombre(nombre, en: carpeta, nombres: app.nombres) else { continue }
                    porNombre = true
                }
                let tamano = Papelera.tamano(url, cancelacion: cancelacion)
                let elemento = ElementoBorrable(url: url, raiz: URL(fileURLWithPath: raiz, isDirectory: true), identidad: identidad, tamano: tamano)
                let resto: RestoApp
                if carpeta.enSistema {
                    // A propósito sin etiqueta: lo de `/Library` nunca se saca de launchd ni se mueve desde Alero.
                    resto = RestoApp(elemento: elemento, carpeta: carpeta, etiquetaAgente: nil, elegido: false,
                                     nota: notaAdministrador, pideAdministrador: true)
                } else if porNombre {
                    resto = RestoApp(elemento: elemento, carpeta: carpeta, etiquetaAgente: nil,
                                     elegido: !otraCopia && !nombreCompartido, nota: notaCopia ?? notaNombre)
                } else {
                    resto = RestoApp(elemento: elemento, carpeta: carpeta, etiquetaAgente: etiqueta, elegido: !otraCopia, nota: notaCopia)
                }
                restos.append(resto)
            }
        }
        return restos
    }

    /// Los recibos del instalador (.pkg) de la app, solo para informar: borrarlos pide administrador y no libera
    /// espacio. Corre `pkgutil` con argumentos separados (nunca un texto de shell). Si falla, no hay recibos.
    static func recibos(_ app: AppElegida) -> [String] {
        let plist = app.url.appendingPathComponent("Contents/Info.plist").path
        let deArchivo = pkgutil(["--file-info", plist]) ?? ""
        let paquetes = (pkgutil(["--pkgs"]) ?? "").split(separator: "\n").map(String.init)
        return ReglasApp.recibos(infoDelArchivo: deArchivo, paquetes: paquetes, ids: app.identificadores)
    }

    /// La salida de `pkgutil`, o nil si no se pudo correr o terminó mal. Lo corta a los 10 s.
    private static func pkgutil(_ argumentos: [String]) -> String? {
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        proceso.arguments = argumentos
        proceso.standardInput = FileHandle.nullDevice
        proceso.standardError = FileHandle.nullDevice
        let salida = Pipe()
        proceso.standardOutput = salida
        do { try proceso.run() } catch {
            NSLog("Alero: no se pudo correr pkgutil: \(error.localizedDescription)")
            return nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if proceso.isRunning { proceso.terminate() } }
        // Se lee antes de esperar: si la salida llena el caño y nadie la lee, pkgutil se queda trabado.
        let datos = salida.fileHandleForReading.readDataToEndOfFile()
        proceso.waitUntilExit()
        guard proceso.terminationStatus == 0 else {
            NSLog("Alero: pkgutil \(argumentos.first ?? "") terminó con \(proceso.terminationStatus)")
            return nil
        }
        return String(data: datos, encoding: .utf8)
    }
}
