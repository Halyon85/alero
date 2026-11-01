import XCTest
@testable import Alero

// Homebrew sin correr brew: argumentos de cada operación, nombres que se aceptan, lectura del JSON de `brew info` y
// `brew outdated`, contraseña, citado para la Terminal y el entorno. El ejecutor se prueba con un "brew" de mentira
// (un script en una carpeta temporal).

final class HomebrewTests: XCTestCase {
    func testArgumentos() {
        XCTAssertEqual(OperacionBrew.actualizar("cmake", .formula).argumentos, ["upgrade", "--formula", "cmake"])
        XCTAssertEqual(OperacionBrew.actualizar("visual-studio-code", .cask).argumentos, ["upgrade", "--cask", "visual-studio-code"])
        XCTAssertEqual(OperacionBrew.desinstalar("icu4c@78", .formula).argumentos, ["uninstall", "--formula", "icu4c@78"])
        XCTAssertEqual(OperacionBrew.actualizarTodo.argumentos, ["upgrade"])
        XCTAssertEqual(OperacionBrew.limpiar.argumentos, ["cleanup"])
        XCTAssertEqual(OperacionBrew.actualizarHomebrew.argumentos, ["update"])
        // Un nombre que sería una opción o un camino: no se corre nada.
        XCTAssertNil(OperacionBrew.desinstalar("--force", .formula).argumentos)
        XCTAssertNil(OperacionBrew.actualizar("../../etc", .formula).argumentos)
        XCTAssertNil(OperacionBrew.actualizar("a b", .cask).argumentos)
        XCTAssertNil(OperacionBrew.actualizar("x; rm -rf ~", .cask).argumentos)
    }

    func testNombres() {
        for bueno in ["gh", "python@3.13", "gtk+3", "homebrew/cask/firefox", "node_16", "c-ares"] {
            XCTAssertTrue(ComandosBrew.nombreValido(bueno), bueno)
        }
        for malo in ["", "-x", "--cask", "a..b", "a//b", ".oculto", "x$(y)", "x`y`", "año", String(repeating: "a", count: 201)] {
            XCTAssertFalse(ComandosBrew.nombreValido(malo), malo)
        }
    }

    func testInventario() throws {
        let info = """
        {"formulae":[
          {"name":"cmake","full_name":"cmake","desc":"Cross-platform make","outdated":true,"pinned":false,
           "installed":[{"version":"4.4.4","installed_on_request":true}]},
          {"name":"abseil","desc":"C++ libs","outdated":false,"pinned":false,
           "installed":[{"version":"20260817.0","installed_on_request":false}]},
          {"name":"node@20","desc":"JS","outdated":false,"pinned":true,
           "installed":[{"version":"20.1.0","installed_on_request":true}]},
          {"name":"-raro","desc":"no","installed":[{"version":"1"}]}
        ],
        "casks":[{"token":"onyx","name":["OnyX"],"desc":"Verify system files","installed":"5.1.0","outdated":true}]}
        """
        let viejos = """
        {"formulae":[{"name":"cmake","installed_versions":["4.4.4"],"current_version":"4.4.5","pinned":false}],
         "casks":[{"name":"onyx","installed_versions":["5.1.0"],"current_version":"5.1.1"}]}
        """
        let lista = try ComandosBrew.inventario(info: Data(info.utf8), desactualizados: Data(viejos.utf8))
        XCTAssertEqual(lista.map(\.nombre), ["cmake", "node@20", "onyx", "abseil"])   // lo pedido primero; "-raro" afuera
        let cmake = try XCTUnwrap(lista.first { $0.nombre == "cmake" })
        XCTAssertEqual(cmake.version, "4.4.4")
        XCTAssertEqual(cmake.nueva, "4.4.5")
        XCTAssertTrue(cmake.pedido)
        XCTAssertEqual(lista.first { $0.nombre == "onyx" }?.tipo, .cask)
        XCTAssertEqual(lista.first { $0.nombre == "onyx" }?.nueva, "5.1.1")
        XCTAssertEqual(lista.first { $0.nombre == "node@20" }?.fijado, true)
        XCTAssertEqual(lista.first { $0.nombre == "abseil" }?.pedido, false)
        // Sin la lista de desactualizados (falló) se lee igual, sin versiones nuevas.
        XCTAssertTrue(try ComandosBrew.inventario(info: Data(info.utf8), desactualizados: nil).allSatisfy { $0.nueva == nil })
        XCTAssertThrowsError(try ComandosBrew.inventario(info: Data("no es json".utf8), desactualizados: nil))
    }

    func testVersion() {
        XCTAssertEqual(ComandosBrew.version(Data("Homebrew 7.0.11\nHomebrew/homebrew-core (git revision 1)\n".utf8)), "Homebrew 7.0.11")
    }

    func testPideContrasena() {
        XCTAssertTrue(ComandosBrew.pideContrasena("sudo: a terminal is required to read the password"))
        XCTAssertTrue(ComandosBrew.pideContrasena("Password:"))
        XCTAssertTrue(ComandosBrew.pideContrasena("installer: Must be run as root to install this package (administrator privileges)"))
        XCTAssertFalse(ComandosBrew.pideContrasena("==> Pouring cmake--4.4.5.arm64_tahoe.bottle.tar.gz"))
    }

    func testCitadoYGuion() {
        XCTAssertEqual(ComandosBrew.citar("gh"), "'gh'")
        XCTAssertEqual(ComandosBrew.citar("it's"), #"'it'\''s'"#)
        let guion = ComandosBrew.guion(brew: "/opt/homebrew/bin/brew", argumentos: ["upgrade", "--cask", "zoom"])
        XCTAssertTrue(guion.hasPrefix("#!/bin/zsh -l\n"))
        XCTAssertTrue(guion.contains("rm -f -- \"$0\""))
        XCTAssertTrue(guion.contains("exec '/opt/homebrew/bin/brew' 'upgrade' '--cask' 'zoom'"))
    }

    func testEntorno() {
        let base = ["HOME": "/Users/ana", "PATH": "/raro", "HOMEBREW_GITHUB_API_TOKEN": "x", "https_proxy": "http://p",
                    "SECRETO": "no", "HOMEBREW_NO_AUTO_UPDATE": "0", "DYLD_INSERT_LIBRARIES": "/malo.dylib"]
        let entorno = ComandosBrew.entorno(base: base)
        XCTAssertEqual(entorno["HOME"], "/Users/ana")
        XCTAssertEqual(entorno["https_proxy"], "http://p")
        XCTAssertEqual(entorno["HOMEBREW_GITHUB_API_TOKEN"], "x")
        XCTAssertNil(entorno["SECRETO"])
        XCTAssertNil(entorno["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(entorno["HOMEBREW_NO_AUTO_UPDATE"], "1")   // leer nunca actualiza Homebrew por su cuenta
        XCTAssertTrue(entorno["PATH"]!.hasPrefix("/opt/homebrew/bin:"))
    }

    func testANSI() {
        XCTAssertEqual(ComandosBrew.limpiarANSI("\u{1B}[34m==>\u{1B}[0m \u{1B}[1mPouring\u{1B}[0m x"), "==> Pouring x")
    }

    func testUbicacion() {
        XCTAssertEqual(ComandosBrew.ubicacion { $0 == "/usr/local/bin/brew" }?.path, "/usr/local/bin/brew")
        XCTAssertEqual(ComandosBrew.ubicacion { _ in true }?.path, "/opt/homebrew/bin/brew")
        XCTAssertNil(ComandosBrew.ubicacion { _ in false })
    }

    // MARK: - Ejecutor con un brew de mentira

    private func brewDeMentira(_ c: CarpetaPrueba, _ guion: String) throws -> URL {
        let url = try c.archivo("brew", "#!/bin/sh\n" + guion + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testLeerDevuelveLoQueEscribe() throws {
        let c = try CarpetaPrueba()
        defer { c.borrar() }
        let brew = try brewDeMentira(c, #"echo "aviso" >&2; printf '{"ok":%s}' "$1""#)
        let datos = try ProcesoBrew.leer(brew: brew, argumentos: ["true"]).get()
        XCTAssertEqual(String(decoding: datos, as: UTF8.self), #"{"ok":true}"#)
        let falla = try brewDeMentira(c, "echo 'Error: no' >&2; exit 2")
        if case .failure(.fallo(let codigo, let mensaje)) = ProcesoBrew.leer(brew: falla, argumentos: []) {
            XCTAssertEqual(codigo, 2)
            XCTAssertTrue(mensaje.contains("Error: no"))
        } else { XCTFail("tenía que fallar") }
    }

    func testCorrerMandaLineasYCodigo() throws {
        let c = try CarpetaPrueba()
        defer { c.borrar() }
        let brew = try brewDeMentira(c, #"echo "uno"; printf 'dos\r'; echo "tres" >&2; echo "$HOMEBREW_NO_AUTO_UPDATE $1"; exit 3"#)
        let fin = expectation(description: "termina")
        var lineas: [String] = []
        var final: ProcesoBrew.Fin?
        let proceso = ProcesoBrew(brew: brew, argumentos: ["hola"], alLinea: { lineas.append($0) }, alTerminar: { final = $0; fin.fulfill() })
        proceso.empezar()
        wait(for: [fin], timeout: 10)
        XCTAssertEqual(final, .fallo(3))
        XCTAssertEqual(Set(lineas), ["uno", "dos", "tres", "1 hola"])
    }

    func testCancelar() throws {
        let c = try CarpetaPrueba()
        defer { c.borrar() }
        let brew = try brewDeMentira(c, "echo empieza; sleep 30")
        let fin = expectation(description: "termina")
        var final: ProcesoBrew.Fin?
        let proceso = ProcesoBrew(brew: brew, argumentos: [], alLinea: { _ in }, alTerminar: { final = $0; fin.fulfill() })
        proceso.empezar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proceso.cancelar() }
        wait(for: [fin], timeout: 10)
        XCTAssertEqual(final, .cancelado)
    }
}
