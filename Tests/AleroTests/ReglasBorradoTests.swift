import XCTest
@testable import Alero

// La última defensa antes de la Papelera: carpetas prohibidas, enlaces (el elemento o alguno del camino), archivos
// que cambiaron entre el escaneo y el borrado, y lo que queda fuera de la carpeta escaneada. Todo sobre una carpeta
// temporal propia y con una Papelera de mentira.

final class ReglasBorradoTests: XCTestCase {
    private var c: CarpetaPrueba!

    override func setUpWithError() throws { c = try CarpetaPrueba() }
    override func tearDown() { c.borrar() }

    func testCarpetasProhibidas() {
        let casa = "/Users/ana"
        let prohibidas = ReglasBorrado.prohibidas(home: casa)
        for ruta in ["/", "/System", "/Applications", "/Users", casa, casa + "/Library", casa + "/Documents",
                     casa + "/Library/Caches", casa + "/Library/Containers", casa + "/Library/LaunchAgents", casa + "/.Trash"] {
            XCTAssertTrue(prohibidas.contains(ruta), ruta)
        }
        XCTAssertFalse(prohibidas.contains(casa + "/Library/Caches/com.foo.App"))
        let nunca = ReglasBorrado.nuncaDentro(home: casa)
        XCTAssertTrue(nunca.contains(casa + "/Library/Mobile Documents"))
        XCTAssertTrue(nunca.contains(casa + "/Library/Keychains"))
        XCTAssertTrue(nunca.contains("/System"))
    }

    func testRechazaLoProhibidoAunqueEsteEnLaRaiz() throws {
        // Una "casa" de prueba: su Library/Caches nunca se puede mover, aunque se la pase como elemento.
        try c.carpeta("casa/Library/Caches/com.foo.App")
        let casa = c.ruta("casa")
        let caches = try XCTUnwrap(c.elemento("casa/Library/Caches", raiz: "casa/Library"))
        XCTAssertEqual(ReglasBorrado.revisar(caches, home: casa), .prohibida)
        let llavero = try c.archivo("casa/Library/Keychains/login.keychain-db")
        let elementoLlavero = ElementoBorrable(url: llavero, raiz: URL(fileURLWithPath: casa + "/Library/Keychains"),
                                               identidad: IdentidadArchivo.leer(llavero)!, tamano: 1)
        XCTAssertEqual(ReglasBorrado.revisar(elementoLlavero, home: casa), .prohibida)
        let app = try XCTUnwrap(c.elemento("casa/Library/Caches/com.foo.App", raiz: "casa/Library/Caches"))
        XCTAssertNil(ReglasBorrado.revisar(app, home: casa))
    }

    func testNoSigueEnlaces() throws {
        try c.archivo("afuera/importante.txt")
        try c.carpeta("raiz")
        try c.enlace("raiz/enlace", a: c.ruta("afuera"))
        let enlace = try XCTUnwrap(c.elemento("raiz/enlace", raiz: "raiz"))
        XCTAssertTrue(enlace.identidad.esEnlace)
        XCTAssertEqual(ReglasBorrado.revisar(enlace, home: "/Users/nadie"), .enlace)
    }

    func testRechazaEnlaceEnElCamino() throws {
        try c.archivo("real/dentro/a.txt")
        let elemento = try XCTUnwrap(c.elemento("real/dentro/a.txt", raiz: "real"))
        // Después del escaneo alguien cambia "dentro" por un enlace a otra carpeta con un archivo del mismo nombre.
        try FileManager.default.moveItem(atPath: c.ruta("real/dentro"), toPath: c.ruta("otra"))
        try c.enlace("real/dentro", a: c.ruta("otra"))
        XCTAssertEqual(ReglasBorrado.revisar(elemento, home: "/Users/nadie"), .enlaceEnElCamino)
    }

    func testRechazaRaizQueEsEnlace() throws {
        try c.archivo("real/a.txt")
        try c.enlace("raizEnlace", a: c.ruta("real"))
        let url = URL(fileURLWithPath: c.ruta("raizEnlace/a.txt"))
        let elemento = ElementoBorrable(url: url, raiz: URL(fileURLWithPath: c.ruta("raizEnlace")), identidad: IdentidadArchivo.leer(url)!, tamano: 1)
        XCTAssertEqual(ReglasBorrado.revisar(elemento, home: "/Users/nadie"), .enlaceEnElCamino)
    }

    func testIdentidadCambia() throws {
        try c.archivo("raiz/nota.txt", "primera")
        let elemento = try XCTUnwrap(c.elemento("raiz/nota.txt", raiz: "raiz"))
        XCTAssertNil(ReglasBorrado.revisar(elemento, home: "/Users/nadie"))
        // Se borra y se crea otro con el mismo nombre: es otro archivo (otro inodo) y no se toca.
        try FileManager.default.removeItem(atPath: c.ruta("raiz/nota.txt"))
        try c.archivo("raiz/otro-antes.txt")   // ocupa el inodo libre, para que el nuevo no lo reuse
        try c.archivo("raiz/nota.txt", "segunda, más larga")
        XCTAssertEqual(ReglasBorrado.revisar(elemento, home: "/Users/nadie"), .cambio)
    }

    func testArchivoModificadoCuentaComoCambio() throws {
        try c.archivo("raiz/nota.txt", "uno")
        let elemento = try XCTUnwrap(c.elemento("raiz/nota.txt", raiz: "raiz"))
        let manija = try FileHandle(forWritingTo: elemento.url)
        try manija.seekToEnd()
        try manija.write(contentsOf: Data(" y dos".utf8))
        try manija.close()
        XCTAssertEqual(ReglasBorrado.revisar(elemento, home: "/Users/nadie"), .cambio)
    }

    func testCarpetaQueCambiaPorDentroSigueSiendoLaMisma() throws {
        try c.archivo("raiz/cache/a")
        let elemento = try XCTUnwrap(c.elemento("raiz/cache", raiz: "raiz"))
        try c.archivo("raiz/cache/b")   // la app escribió algo nuevo en su caché
        XCTAssertNil(ReglasBorrado.revisar(elemento, home: "/Users/nadie"))
    }

    func testFueraDeLaRaizYNombresRaros() throws {
        try c.archivo("raiz/a.txt")
        try c.archivo("otra/b.txt")
        let fuera = try XCTUnwrap(c.elemento("otra/b.txt", raiz: "raiz"))
        XCTAssertEqual(ReglasBorrado.revisar(fuera, home: "/Users/nadie"), .fueraDeLugar)
        let url = URL(fileURLWithPath: c.ruta("raiz/../otra/b.txt"))
        let trampa = ElementoBorrable(url: url, raiz: c.url.appendingPathComponent("raiz"), identidad: IdentidadArchivo.leer(url)!, tamano: 1)
        XCTAssertEqual(ReglasBorrado.revisar(trampa, home: "/Users/nadie"), .fueraDeLugar)
        try c.archivo("raiz/.localized")
        let localizado = try XCTUnwrap(c.elemento("raiz/.localized", raiz: "raiz"))
        XCTAssertEqual(ReglasBorrado.revisar(localizado, home: "/Users/nadie"), .nombreRaro)
    }

    func testMandarMueveSoloLoQuePasaLaRevision() throws {
        try c.archivo("raiz/bien.txt")
        try c.archivo("raiz/cambia.txt", "uno")
        try c.archivo("afuera/x.txt")
        try c.enlace("raiz/enlace", a: c.ruta("afuera"))
        let bien = try XCTUnwrap(c.elemento("raiz/bien.txt", raiz: "raiz"))
        let cambia = try XCTUnwrap(c.elemento("raiz/cambia.txt", raiz: "raiz"))
        let enlace = try XCTUnwrap(c.elemento("raiz/enlace", raiz: "raiz"))
        try c.archivo("raiz/cambia.txt", "otro contenido")
        let resultado = Papelera.mandar([bien, cambia, enlace], home: "/Users/nadie", mover: try c.papelera())
        XCTAssertEqual(resultado.movidos.map(\.url.lastPathComponent), ["bien.txt"])
        XCTAssertEqual(resultado.rechazados.count, 2)
        XCTAssertFalse(c.existe("raiz/bien.txt"))
        XCTAssertTrue(c.existe("raiz/cambia.txt"))
        XCTAssertTrue(c.existe("raiz/enlace"))
        XCTAssertTrue(c.existe("afuera/x.txt"))
    }

    func testCarpetaYSuHijoSeMuevenUnaVez() throws {
        try c.archivo("raiz/cache/a.txt")
        let carpeta = try XCTUnwrap(c.elemento("raiz/cache", raiz: "raiz"))
        let hijo = try XCTUnwrap(c.elemento("raiz/cache/a.txt", raiz: "raiz/cache"))
        let resultado = Papelera.mandar([hijo, carpeta], home: "/Users/nadie", mover: try c.papelera())
        XCTAssertEqual(resultado.movidos.count, 1)
        XCTAssertTrue(resultado.rechazados.isEmpty)
        XCTAssertFalse(c.existe("raiz/cache"))
    }

    func testSinPermisoQuedaParaFinder() throws {
        try c.archivo("raiz/protegido.txt")
        let elemento = try XCTUnwrap(c.elemento("raiz/protegido.txt", raiz: "raiz"))
        let resultado = Papelera.mandar([elemento], home: "/Users/nadie") { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        XCTAssertEqual(resultado.sinPermiso.map(\.id), [elemento.id])
        XCTAssertTrue(resultado.movidos.isEmpty)
    }

    func testTamanoNoSigueEnlaces() throws {
        try c.archivo("grande/a.bin", String(repeating: "x", count: 100_000))
        try c.archivo("raiz/chico.txt", "hola")
        try c.enlace("raiz/enlace", a: c.ruta("grande"))
        let tamano = Papelera.tamano(c.url.appendingPathComponent("raiz"))
        XCTAssertGreaterThan(tamano, 0)
        XCTAssertLessThan(tamano, 50_000)
        XCTAssertEqual(Papelera.tamano(c.url.appendingPathComponent("raiz/enlace")), 0)
    }

    func testNoEstaSoloSiNoExiste() throws {
        XCTAssertTrue(Papelera.noEsta(c.url.appendingPathComponent("nada")))
        XCTAssertFalse(Papelera.noEsta(try c.archivo("algo.txt")))
    }
}
