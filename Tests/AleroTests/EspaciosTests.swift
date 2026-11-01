import XCTest
@testable import Alero

// Las reglas de la barra del notch abierto (nunca queda sin pestañas, no se repiten, se ordenan sin perder ninguna)
// y las de la terminal (cd, colores, carpeta corta).

final class EspaciosTests: XCTestCase {
    func testSiempreHayAlMenosUnaPestana() {
        XCTAssertEqual(ReglasBarra.espacios(izquierda: [], derecha: [.accion(.cafe)]), [.inicio])
        XCTAssertEqual(ReglasBarra.espacios(izquierda: [.espacio(.utilidades), .accion(.cafe)], derecha: [.espacio(.sonido), .espacio(.utilidades)]),
                       [.utilidades, .sonido], "izquierda primero, sin repetidas")
    }

    func testAbreElPedidoSoloSiEstaEnLaBarra() {
        XCTAssertEqual(ReglasBarra.elegido(.estante, entre: [.inicio, .estante]), .estante)
        XCTAssertEqual(ReglasBarra.elegido(.estante, entre: [.sonido, .inicio]), .sonido, "si no está: la primera")
    }

    func testMoverNoPierdeNiRepite() {
        let lista: [ElementoBarra] = [.espacio(.inicio), .accion(.cafe), .espacio(.terminal)]
        XCTAssertEqual(ReglasBarra.mover(.accion(.cafe), -1, en: lista), [.accion(.cafe), .espacio(.inicio), .espacio(.terminal)])
        XCTAssertEqual(ReglasBarra.mover(.espacio(.terminal), 1, en: lista), lista, "el último no baja más")
    }

    func testLaUltimaPestanaNoSeSaca() {
        XCTAssertFalse(ReglasBarra.sePuedeSacar(.espacio(.inicio), izquierda: [.espacio(.inicio)], derecha: [.accion(.cafe)]))
        XCTAssertTrue(ReglasBarra.sePuedeSacar(.accion(.cafe), izquierda: [.espacio(.inicio)], derecha: [.accion(.cafe)]))
        XCTAssertTrue(ReglasBarra.sePuedeSacar(.espacio(.inicio), izquierda: [.espacio(.inicio)], derecha: [.espacio(.sonido)]))
    }

    func testClavesIdaYVuelta() {
        for elemento in ElementoBarra.todos { XCTAssertEqual(ElementoBarra(clave: elemento.clave), elemento) }
        XCTAssertNil(ElementoBarra(clave: "e:noexiste"))
        XCTAssertNil(ElementoBarra(clave: "basura"))
    }

    func testCapacidadDeCadaLado() {
        // 600 de ancho, 200 de cámara: (600−200)/2 − 18 = 182 → (182−4)/28 = 6 íconos.
        XCTAssertEqual(ReglasBarra.capacidad(anchoAbierto: 600, anchoCamara: 200), 6)
        XCTAssertEqual(ReglasBarra.capacidad(anchoAbierto: 100, anchoCamara: 200), 1, "nunca menos de uno")
    }

    func testCdDeLaTerminal() {
        let casa = "/Users/x"
        XCTAssertEqual(ReglasTerminal.destinoCd("cd", desde: "/tmp", casa: casa), casa)
        XCTAssertEqual(ReglasTerminal.destinoCd("cd ~/Proyectos", desde: "/tmp", casa: casa), "/Users/x/Proyectos")
        XCTAssertEqual(ReglasTerminal.destinoCd("cd ..", desde: "/Users/x/a", casa: casa), "/Users/x")
        XCTAssertEqual(ReglasTerminal.destinoCd("cd \"Mi Disco\"", desde: "/Volumes", casa: casa), "/Volumes/Mi Disco")
        XCTAssertNil(ReglasTerminal.destinoCd("ls -la", desde: "/tmp", casa: casa))
        XCTAssertNil(ReglasTerminal.destinoCd("cdx", desde: "/tmp", casa: casa))
    }

    func testColoresYCarpetaCorta() {
        XCTAssertEqual(ReglasTerminal.sinColores("\u{1B}[1;32mlisto\u{1B}[0m"), "listo")
        XCTAssertEqual(ReglasTerminal.corta("/Users/x/Notch", casa: "/Users/x"), "~/Notch")
        XCTAssertEqual(ReglasTerminal.corta("/Users/x", casa: "/Users/x"), "~")
        XCTAssertEqual(ReglasTerminal.corta("/Users/xy", casa: "/Users/x"), "/Users/xy")
    }
}

final class BarraYEstanteTests: XCTestCase {
    func testLosBotonesRepetidosNoEntranALaBarra() {
        XCTAssertNil(ElementoBarra(clave: "a:estante"), "el estante ya es una pestaña")
        XCTAssertNil(ElementoBarra(clave: "a:prompter"), "el teleprompter ya es una pestaña")
        XCTAssertFalse(ElementoBarra.todos.contains(.accion(.estante)))
        XCTAssertTrue(ElementoBarra.todos.contains(.accion(.cafe)))
    }

    func testTemporalesDelEstante() {
        XCTAssertTrue(Estante.esTemporal(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("foto.png")))
        XCTAssertTrue(Estante.esTemporal(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/x/y.pdf")))
        XCTAssertFalse(Estante.esTemporal(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/factura.pdf")))
        XCTAssertFalse(Estante.esTemporal(URL(fileURLWithPath: "/Volumes/Mi Disco/Proyecto/README.md")))
    }
}
