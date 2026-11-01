import XCTest
@testable import Alero

// El desinstalador: qué apps se aceptan, qué cuenta como resto (solo por identificador, nunca por nombre visible),
// las carpetas sensibles con identificador exacto, los LaunchAgents y los grupos firmados. Apps y carpetas de mentira
// en una carpeta temporal; nada se mueve.

final class DesinstaladorTests: XCTestCase {
    private var c: CarpetaPrueba!

    override func setUpWithError() throws { c = try CarpetaPrueba() }
    override func tearDown() { c.borrar() }

    /// Una app de mentira con su Info.plist (y extensiones adentro, si se piden).
    @discardableResult
    private func app(_ relativa: String, id: String?, embebidas: [String: String] = [:]) throws -> URL {
        let url = try c.carpeta(relativa)
        var info: [String: Any] = ["CFBundleName": url.deletingPathExtension().lastPathComponent, "CFBundleShortVersionString": "1.0"]
        if let id { info["CFBundleIdentifier"] = id }
        try c.carpeta(relativa + "/Contents/MacOS")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        for (nombre, idEmbebida) in embebidas {
            try c.carpeta(relativa + "/Contents/PlugIns/\(nombre)/Contents")
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": idEmbebida], format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/PlugIns/\(nombre)/Contents/Info.plist"))
        }
        return url
    }

    func testAceptaUnaAppComun() throws {
        let url = try app("Applications/Notas.app", id: "com.foo.Notas",
                          embebidas: ["Compartir.appex": "com.foo.Notas.Compartir", "Sparkle.xpc": "org.sparkle-project.Installer"])
        guard case .success(let elegida) = ReglasApp.validar(url, propio: "team.halyon.alero", rutaPropia: "/Applications/Alero.app") else {
            return XCTFail("tenía que aceptarla")
        }
        XCTAssertEqual(elegida.identificador, "com.foo.Notas")
        // Sparkle viene dentro de muchas apps: no es de esta.
        XCTAssertEqual(elegida.identificadores, ["com.foo.Notas", "com.foo.Notas.Compartir"])
    }

    func testRechazos() throws {
        func motivo(_ url: URL) -> RechazoApp? {
            if case .failure(let m) = ReglasApp.validar(url, propio: "team.halyon.alero", rutaPropia: c.ruta("Applications/Alero.app")) { return m }
            return nil
        }
        let real = try app("Applications/Real.app", id: "com.foo.Real")
        try c.enlace("Applications/Enlace.app", a: real.path)
        XCTAssertEqual(motivo(c.url.appendingPathComponent("Applications/Enlace.app")), .enlace)
        let dentro = try app("Applications/Grande.app/Contents/Library/LoginItems/Ayudante.app", id: "com.foo.Grande.Ayudante")
        XCTAssertEqual(motivo(dentro), .dentroDeOtraApp)
        XCTAssertEqual(motivo(try app("Applications/Safari.app", id: "com.apple.Safari")), .deApple)
        XCTAssertEqual(motivo(try app("Applications/SinId.app", id: nil)), .sinIdentificador)
        XCTAssertEqual(motivo(try app("Applications/Alero.app", id: "team.halyon.alero")), .esAlero)
        XCTAssertEqual(motivo(try app("Applications/Copia de Alero.app", id: "team.halyon.alero")), .esAlero)
        XCTAssertEqual(motivo(try c.archivo("Applications/notas.txt")), .noEsApp)
        XCTAssertEqual(motivo(URL(fileURLWithPath: "/System/Applications/Calculator.app")), .delSistema)
    }

    func testIdentificadorEnCadaCarpeta() {
        XCTAssertEqual(CarpetaRestos.preferencias.identificador(en: "com.foo.App.plist"), "com.foo.App")
        XCTAssertNil(CarpetaRestos.preferencias.identificador(en: "com.foo.App"))
        XCTAssertEqual(CarpetaRestos.porEquipo.identificador(en: "com.foo.App.8D1E4F2A-1111-2222-3333-444455556666.plist"), "com.foo.App")
        XCTAssertNil(CarpetaRestos.porEquipo.identificador(en: "com.foo.App.plist"))
        XCTAssertEqual(CarpetaRestos.estado.identificador(en: "com.foo.App.savedState"), "com.foo.App")
        XCTAssertEqual(CarpetaRestos.cookies.identificador(en: "com.foo.App.binarycookies"), "com.foo.App")
        XCTAssertEqual(CarpetaRestos.almacenHTTP.identificador(en: "com.foo.App"), "com.foo.App")
    }

    func testRestosSoloPorIdentificador() {
        let ids = ["com.foo.App", "com.foo.App.Compartir"]
        let grupos = ["AB12CD34EF.com.foo.compartido"]
        func es(_ nombre: String, _ carpeta: CarpetaRestos) -> Bool { ReglasApp.esDeLaApp(nombre, en: carpeta, ids: ids, grupos: grupos) }
        XCTAssertTrue(es("com.foo.App", .soporte))
        XCTAssertTrue(es("com.foo.App.ShipIt", .caches))          // subidentificador: en carpetas comunes, sí
        XCTAssertFalse(es("com.foo.AppViejo", .caches))           // sin punto no es subidentificador
        XCTAssertFalse(es("App", .soporte))                       // nombre visible: nunca
        XCTAssertFalse(es("Foo", .soporte))
        XCTAssertFalse(es("com.foo", .caches))                    // el del fabricante tampoco
        // Sensibles: solo exacto
        XCTAssertTrue(es("com.foo.App.Compartir", .contenedores))
        XCTAssertFalse(es("com.foo.App.Otra", .contenedores))
        XCTAssertTrue(es("com.foo.App.plist", .preferencias))
        XCTAssertFalse(es("com.foo.App.ShipIt.plist", .preferencias))
        // Grupos: solo los firmados
        XCTAssertTrue(es("AB12CD34EF.com.foo.compartido", .grupos))
        XCTAssertFalse(es("AB12CD34EF.com.foo.otro", .grupos))
        XCTAssertFalse(es("com.foo.App", .grupos))
    }

    func testGruposDeLaFirma() {
        let declarados = ["AB12CD34EF.com.foo.compartido", "group.com.foo.app", "ZZZZZZZZZZ.com.ajena", "raro", "group./x"]
        XCTAssertEqual(ReglasApp.gruposValidos(declarados, equipo: "AB12CD34EF"), ["AB12CD34EF.com.foo.compartido", "group.com.foo.app"])
        XCTAssertEqual(ReglasApp.gruposValidos(declarados, equipo: nil), ["group.com.foo.app"])
    }

    func testAgentes() {
        let app = URL(fileURLWithPath: "/Applications/Notas.app")
        let ids = ["com.foo.Notas"]
        XCTAssertEqual(ReglasApp.etiquetaDeAgente(["Label": "com.foo.Notas"], archivo: "com.foo.Notas.plist", app: app, ids: ids), "com.foo.Notas")
        // Etiqueta ajena pero el programa vive dentro de la app: es suyo.
        let deAdentro: [String: Any] = ["Label": "com.foo.actualizador", "ProgramArguments": ["/Applications/Notas.app/Contents/MacOS/act", "--x"]]
        XCTAssertEqual(ReglasApp.etiquetaDeAgente(deAdentro, archivo: "com.foo.actualizador.plist", app: app, ids: ids), "com.foo.actualizador")
        // Programa en otra app con nombre parecido, o trampa con "..": no.
        let parecida: [String: Any] = ["Label": "com.foo.x", "Program": "/Applications/Notas.app2/x"]
        XCTAssertNil(ReglasApp.etiquetaDeAgente(parecida, archivo: "com.foo.x.plist", app: app, ids: ids))
        let trampa: [String: Any] = ["Label": "com.foo.x", "Program": "/Applications/Notas.app/../Otra.app/x"]
        XCTAssertNil(ReglasApp.etiquetaDeAgente(trampa, archivo: "com.foo.x.plist", app: app, ids: ids))
        // El archivo tiene que llamarse como la etiqueta, y la etiqueta no puede ser un argumento.
        XCTAssertNil(ReglasApp.etiquetaDeAgente(["Label": "com.foo.Notas"], archivo: "otro.plist", app: app, ids: ids))
        XCTAssertFalse(ReglasApp.esEtiqueta("-h"))
        XCTAssertFalse(ReglasApp.esEtiqueta("com.foo/../x"))
        XCTAssertTrue(ReglasApp.esEtiqueta("com.foo.Notas-ayudante_2"))
    }

    func testBuscaRestosEnUnaLibraryDeMentira() throws {
        let url = try app("Applications/Notas.app", id: "com.foo.Notas", embebidas: ["Compartir.appex": "com.foo.Notas.Compartir"])
        guard case .success(var elegida) = ReglasApp.validar(url, propio: "x.y", rutaPropia: "/nada") else { return XCTFail() }
        elegida.grupos = ["AB12CD34EF.com.foo.compartido"]
        let lib = "casa/Library/"
        try c.archivo(lib + "Application Support/com.foo.Notas/base.db")
        try c.archivo(lib + "Application Support/Notas/base.db")              // por nombre visible: no
        try c.archivo(lib + "Caches/com.foo.Notas.ShipIt/x")
        try c.archivo(lib + "Caches/com.foo.NotasPro/x")                      // otra app
        try c.archivo(lib + "Preferences/com.foo.Notas.plist")
        try c.archivo(lib + "Preferences/ByHost/com.foo.Notas.8D1E4F2A-1111-2222-3333-444455556666.plist")
        try c.archivo(lib + "Containers/com.foo.Notas.Compartir/Data/x")
        try c.archivo(lib + "Containers/com.foo.Notas.Otra/Data/x")           // sensible y no exacto: no
        try c.archivo(lib + "Group Containers/AB12CD34EF.com.foo.compartido/x")
        try c.archivo(lib + "Saved Application State/com.foo.Notas.savedState/x")
        try c.archivo("afuera/importante.txt")
        try c.enlace(lib + "Caches/com.foo.Notas", a: c.ruta("afuera"))       // enlace: no
        let agente: [String: Any] = ["Label": "com.foo.Notas.ayudante", "Program": url.path + "/Contents/MacOS/ayudante"]
        try PropertyListSerialization.data(fromPropertyList: agente, format: .xml, options: 0)
            .write(to: try c.carpeta(lib + "LaunchAgents").appendingPathComponent("com.foo.Notas.ayudante.plist"))
        let ajeno: [String: Any] = ["Label": "com.otra.cosa", "Program": "/usr/local/bin/cosa"]
        try PropertyListSerialization.data(fromPropertyList: ajeno, format: .xml, options: 0)
            .write(to: c.url.appendingPathComponent(lib + "LaunchAgents/com.otra.cosa.plist"))

        let restos = BuscadorRestos.buscar(elegida, home: c.ruta("casa"), sistema: c.ruta("sistema"), otraCopia: false, cancelacion: Cancelacion())
        XCTAssertEqual(Set(restos.map(\.nombre)), [
            "com.foo.Notas", "com.foo.Notas.ShipIt", "com.foo.Notas.plist",
            "com.foo.Notas.8D1E4F2A-1111-2222-3333-444455556666.plist", "com.foo.Notas.Compartir",
            "AB12CD34EF.com.foo.compartido", "com.foo.Notas.savedState", "com.foo.Notas.ayudante.plist",
        ])
        XCTAssertEqual(restos.first { $0.carpeta == .agentes }?.etiquetaAgente, "com.foo.Notas.ayudante")
        XCTAssertTrue(restos.allSatisfy(\.elegido))
        for resto in restos { XCTAssertNil(ReglasBorrado.revisar(resto.elemento, home: c.ruta("casa")), resto.nombre) }
        // Con otra copia instalada, se muestran sin tildar.
        let conCopia = BuscadorRestos.buscar(elegida, home: c.ruta("casa"), sistema: c.ruta("sistema"), otraCopia: true, cancelacion: Cancelacion())
        XCTAssertTrue(conCopia.allSatisfy { !$0.elegido && $0.nota != nil })
    }

    func testLaAppPasaLaRevisionFinal() throws {
        let url = try app("Applications/Notas.app", id: "com.foo.Notas")
        guard case .success(let elegida) = ReglasApp.validar(url, propio: "x.y", rutaPropia: "/nada") else { return XCTFail() }
        let elemento = ElementoBorrable(url: url, raiz: url.deletingLastPathComponent(), identidad: elegida.identidadApp, tamano: 1)
        XCTAssertNil(ReglasBorrado.revisar(elemento, home: "/Users/nadie"))
        let resultado = Papelera.mandar([elemento], home: "/Users/nadie", mover: try c.papelera())
        XCTAssertEqual(resultado.movidos.count, 1)
        XCTAssertFalse(c.existe("Applications/Notas.app"))
    }

    // MARK: - Lugares nuevos (01/11: "que encuentre todos los paquetes de la app")

    /// Escribe un plist de launchd de mentira.
    private func plist(_ relativa: String, _ datos: [String: Any]) throws {
        let url = c.url.appendingPathComponent(relativa)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: datos, format: .xml, options: 0).write(to: url)
    }

    func testIdentificadorEnLasCarpetasNuevas() {
        XCTAssertEqual(CarpetaRestos.autoguardado.identificador(en: "com.foo.App"), "com.foo.App")
        XCTAssertEqual(CarpetaRestos.autoguardado.identificador(en: "com.foo.App.plist"), "com.foo.App")
        XCTAssertEqual(CarpetaRestos.demoniosSistema.identificador(en: "com.foo.App.ayudante.plist"), "com.foo.App.ayudante")
        XCTAssertEqual(CarpetaRestos.ayudantesSistema.identificador(en: "com.foo.App.ayudante"), "com.foo.App.ayudante")
        XCTAssertTrue(CarpetaRestos.allCases.filter(\.enSistema).allSatisfy(\.sensible))
    }

    func testGruposPorEquipoEIdentificador() {
        var app = AppElegida(url: URL(fileURLWithPath: "/Applications/App.app"), identificador: "com.foo.App", nombre: "App", version: nil,
                             identidadApp: IdentidadArchivo(dispositivo: 1, inodo: 1, tipo: S_IFDIR, modificado: nil, tamano: nil),
                             identidadPlist: IdentidadArchivo(dispositivo: 1, inodo: 2, tipo: S_IFREG, modificado: 1, tamano: 1),
                             identificadores: ["com.foo.App"], equipo: "AB12CD34EF", grupos: ["AB12CD34EF.com.foo.compartido"])
        let grupos = ReglasApp.gruposPosibles(app)
        XCTAssertEqual(Set(grupos), ["AB12CD34EF.com.foo.compartido", "AB12CD34EF.com.foo.App", "group.com.foo.App"])
        func es(_ nombre: String, _ carpeta: CarpetaRestos) -> Bool {
            ReglasApp.esDeLaApp(nombre, en: carpeta, ids: app.identificadores, grupos: grupos)
        }
        XCTAssertTrue(es("AB12CD34EF.com.foo.App", .grupos))
        XCTAssertTrue(es("group.com.foo.App", .grupos))
        XCTAssertFalse(es("ZZZZZZZZZZ.com.foo.App", .grupos))     // otro equipo: no
        XCTAssertFalse(es("AB12CD34EF.com.foo.Otra", .grupos))    // mismo equipo, otra app: no
        XCTAssertTrue(es("AB12CD34EF.com.foo.compartido", .scripts))
        XCTAssertTrue(es("com.foo.App", .scripts))
        XCTAssertFalse(es("AB12CD34EF.com.foo.Otra", .scripts))
        // Sin firma válida no hay equipo: solo "group.<identificador>".
        app.equipo = nil
        app.grupos = []
        XCTAssertEqual(ReglasApp.gruposPosibles(app), ["group.com.foo.App"])
    }

    func testAyudantesConPermisos() throws {
        let url = try app("Applications/Notas.app", id: "com.foo.Notas")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])
        info["SMPrivilegedExecutables"] = ["com.foo.NotasHelper": "anchor apple generic", "-trampa": "x"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try c.archivo("Applications/Notas.app/Contents/Library/LaunchServices/com.foo.NotasHelper")
        try c.archivo("Applications/Notas.app/Contents/Library/LaunchServices/com.foo.Instalador")
        guard case .success(let elegida) = ReglasApp.validar(url, propio: "x.y", rutaPropia: "/nada") else { return XCTFail() }
        XCTAssertEqual(elegida.ayudantes, ["com.foo.NotasHelper", "com.foo.Instalador"])
    }

    func testAgenteQueDeclaraLaApp() {
        let app = URL(fileURLWithPath: "/Applications/Notas.app")
        let asociado: [String: Any] = ["Label": "com.otra.marca.agente", "AssociatedBundleIdentifiers": ["com.foo.Notas"],
                                       "Program": "/usr/local/bin/agente"]
        XCTAssertEqual(ReglasApp.etiquetaDeAgente(asociado, archivo: "com.otra.marca.agente.plist", app: app, ids: ["com.foo.Notas"]),
                       "com.otra.marca.agente")
        let ajeno: [String: Any] = ["Label": "com.otra.marca.agente", "AssociatedBundleIdentifiers": "com.otra.App"]
        XCTAssertNil(ReglasApp.etiquetaDeAgente(ajeno, archivo: "com.otra.marca.agente.plist", app: app, ids: ["com.foo.Notas"]))
    }

    func testRestosNuevosYLoDeLaMacSoloSeInforma() throws {
        let url = try app("Applications/Notas.app", id: "com.foo.Notas")
        guard case .success(var elegida) = ReglasApp.validar(url, propio: "x.y", rutaPropia: "/nada") else { return XCTFail() }
        elegida.equipo = "AB12CD34EF"
        elegida.ayudantes = ["com.foo.NotasHelper"]
        let lib = "casa/Library/"
        try c.archivo(lib + "Autosave Information/com.foo.Notas/sin guardar.rtf")
        try c.archivo(lib + "Autosave Information/Notas/sin guardar.rtf")            // por nombre visible: no
        try c.archivo(lib + "Application Scripts/AB12CD34EF.com.foo.Notas/x")
        try c.archivo(lib + "Group Containers/AB12CD34EF.com.foo.Notas/x")
        try c.archivo(lib + "Group Containers/group.com.foo.Notas/x")
        try c.archivo(lib + "Group Containers/ZZZZZZZZZZ.com.foo.Notas/x")          // otro equipo: no
        try c.archivo(lib + "HTTPStorages/com.foo.Notas.binarycookies")
        try c.archivo(lib + "WebKit/com.foo.Notas/x")
        try c.archivo(lib + "Cookies/com.foo.Notas.binarycookies")
        try c.archivo(lib + "Logs/com.foo.Notas/x.log")
        try c.archivo(lib + "Application Scripts/com.foo.Notas/x")
        // En /Library (de mentira): el ayudante, su servicio, un agente que corre desde la app y datos con el identificador.
        try c.archivo("sistema/PrivilegedHelperTools/com.foo.NotasHelper")
        try c.archivo("sistema/PrivilegedHelperTools/com.otra.Helper")                 // de otra app: no
        try plist("sistema/LaunchDaemons/com.foo.NotasHelper.plist",
                  ["Label": "com.foo.NotasHelper", "Program": "/Library/PrivilegedHelperTools/com.foo.NotasHelper"])
        try plist("sistema/LaunchDaemons/com.otra.Helper.plist", ["Label": "com.otra.Helper", "Program": "/usr/local/bin/x"])
        try plist("sistema/LaunchAgents/com.foo.actualizar.plist", ["Label": "com.foo.actualizar", "Program": url.path + "/Contents/MacOS/act"])
        try c.archivo("sistema/Application Support/com.foo.Notas/x")
        try c.archivo("sistema/Application Support/com.foo.Notas.Viejo/x")           // sensible: solo exacto
        try c.archivo("sistema/Preferences/com.foo.Notas.plist")

        let restos = BuscadorRestos.buscar(elegida, home: c.ruta("casa"), sistema: c.ruta("sistema"), otraCopia: false, cancelacion: Cancelacion())
        let deLaPersona = restos.filter { !$0.pideAdministrador }
        let deLaMac = restos.filter(\.pideAdministrador)
        XCTAssertEqual(Set(deLaPersona.map { $0.carpeta.ruta + "/" + $0.nombre }), [
            "Autosave Information/com.foo.Notas", "Application Scripts/AB12CD34EF.com.foo.Notas",
            "Group Containers/AB12CD34EF.com.foo.Notas", "Group Containers/group.com.foo.Notas",
            "HTTPStorages/com.foo.Notas.binarycookies", "WebKit/com.foo.Notas", "Cookies/com.foo.Notas.binarycookies",
            "Logs/com.foo.Notas", "Application Scripts/com.foo.Notas",
        ])
        XCTAssertEqual(Set(deLaMac.map { $0.carpeta.ruta + "/" + $0.nombre }), [
            "PrivilegedHelperTools/com.foo.NotasHelper", "LaunchDaemons/com.foo.NotasHelper.plist",
            "LaunchAgents/com.foo.actualizar.plist", "Application Support/com.foo.Notas", "Preferences/com.foo.Notas.plist",
        ])
        XCTAssertTrue(deLaPersona.allSatisfy(\.elegido))
        // Lo de la Mac: sin tildar y sin etiqueta (nunca se saca de launchd ni se mueve desde Alero).
        XCTAssertTrue(deLaMac.allSatisfy { !$0.elegido && $0.etiquetaAgente == nil && $0.nota != nil })
    }

    func testRecibosDelInstalador() {
        let salida = "volume: /\npath: /Applications/Tailscale.app/Contents/Info.plist\npackage-id: com.tailscale.ipn.macsys\n"
        let paquetes = ["com.apple.pkg.Core", "io.tailscale.ipn.macsys.extra", "io.tailscale.ipnviejo", "com.otra.cosa", ""]
        XCTAssertEqual(ReglasApp.recibos(infoDelArchivo: salida, paquetes: paquetes, ids: ["io.tailscale.ipn.macsys"]),
                       ["com.tailscale.ipn.macsys", "io.tailscale.ipn.macsys.extra"])
        // Sin instalador: nada (y los de Apple nunca).
        XCTAssertEqual(ReglasApp.recibos(infoDelArchivo: "volume: /\npackage-id: com.apple.pkg.X\n", paquetes: [], ids: ["com.foo"]), [])
    }

    func testLaAppTieneQueSeguirIgual() throws {
        let url = try app("Applications/Notas.app", id: "com.foo.Notas")
        guard case .success(let elegida) = ReglasApp.validar(url, propio: "x.y", rutaPropia: "/nada") else { return XCTFail() }
        XCTAssertTrue(ReglasApp.sigueIgual(elegida, propio: "x.y", rutaPropia: "/nada"))
        // Entre elegirla y borrarla la cambiaron por otra con el mismo nombre: no se toca.
        try FileManager.default.removeItem(at: url)
        try app("Applications/Notas.app", id: "com.foo.Notas")
        XCTAssertFalse(ReglasApp.sigueIgual(elegida, propio: "x.y", rutaPropia: "/nada"))
    }

    // MARK: - Varias apps (sin tocar el disco)

    func testLoQuePideAdministradorNoSeEligeNiSeCuenta() {
        let modelo = ModeloDesinstalador.muestra()
        guard let admin = modelo.restos.first(where: \.pideAdministrador) else { return XCTFail("la muestra trae uno de /Library") }
        XCTAssertFalse(modelo.elegidos.contains(admin.id))
        let antes = modelo.bytesElegidos
        modelo.alternar(admin)
        XCTAssertFalse(modelo.elegidos.contains(admin.id))
        XCTAssertEqual(modelo.bytesElegidos, antes)
        let mandables = modelo.restos.filter { !$0.pideAdministrador }.reduce(0) { $0 + $1.elemento.tamano }
        XCTAssertEqual(antes, modelo.tamanoApp + mandables)
    }

    func testVariasAppsSumanYCuentan() {
        let modelo = ModeloDesinstalador.muestraVarias()
        XCTAssertEqual(modelo.lote.count, 3)
        XCTAssertNil(modelo.app)                                  // con varias no hay "la" app
        XCTAssertEqual(modelo.bytesElegidos, modelo.lote.reduce(0) { $0 + modelo.tamanoElegido($1) })
        XCTAssertEqual(modelo.bytesElegidos, 184_000_000 + 137_000_000 + 412_000_000 + 58_000_000 + 96_000_000 + 3_200_000)
        let terminado = ModeloDesinstalador.muestraVariasTerminado()
        XCTAssertEqual(terminado.appsMovidas, 3)
        XCTAssertTrue(terminado.restos.isEmpty)
    }
}
