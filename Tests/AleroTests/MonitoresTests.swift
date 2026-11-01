import CoreGraphics
import XCTest
@testable import Alero

// Brillo de monitores: los paquetes DDC/CI con su checksum (calculados a mano según el estándar VESA), leer la
// respuesta y descartar la basura, reconocer cada monitor, elegir la pantalla del puntero y la curva de la gamma.
// Nada de esto le habla a un monitor de verdad.

final class MonitoresTests: XCTestCase {
    func testPaqueteParaPonerElBrillo() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A
        XCTAssertEqual(ProtocoloDDC.pedidoEscritura(vcp: 0x10, valor: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        // Valores de más de un byte (monitores con máximo 1000, por ejemplo).
        let alto = ProtocoloDDC.pedidoEscritura(vcp: 0x10, valor: 0x0123)
        XCTAssertEqual(Array(alto[3...4]), [0x01, 0x23])
        XCTAssertEqual(alto[5], ProtocoloDDC.checksum(Array(alto[0..<5]), semilla: 0x6E ^ 0x51))
    }

    func testPaqueteParaPreguntarElBrillo() {
        // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC
        XCTAssertEqual(ProtocoloDDC.pedidoLectura(vcp: 0x10), [0x82, 0x01, 0x10, 0xAC])
    }

    func testRespuestaDelMonitor() throws {
        // Brillo 50 de 100. Checksum con semilla 0x50: 0xF2.
        let respuesta: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        let brillo = try XCTUnwrap(ProtocoloDDC.leerRespuesta(respuesta, vcp: 0x10))
        XCTAssertEqual(brillo.actual, 50)
        XCTAssertEqual(brillo.maximo, 100)
    }

    func testRespuestasQueNoSeCreen() {
        let buena: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        var checksumMalo = buena
        checksumMalo[10] = 0x00
        XCTAssertNil(ProtocoloDDC.leerRespuesta(checksumMalo, vcp: 0x10))
        // Un adaptador que devuelve ceros.
        XCTAssertNil(ProtocoloDDC.leerRespuesta([UInt8](repeating: 0, count: 11), vcp: 0x10))
        // El monitor contesta "no lo tengo" (resultado 1); el checksum se rehace para que solo falle por eso.
        var sinVCP = buena
        sinVCP[3] = 0x01
        sinVCP[10] = ProtocoloDDC.checksum(Array(sinVCP[0..<10]), semilla: 0x50)
        XCTAssertNil(ProtocoloDDC.leerRespuesta(sinVCP, vcp: 0x10))
        // Habla de otro VCP (contraste).
        XCTAssertNil(ProtocoloDDC.leerRespuesta(buena, vcp: 0x12))
        XCTAssertNil(ProtocoloDDC.leerRespuesta(Array(buena.prefix(8)), vcp: 0x10))
    }

    func testDeslizadorAValorDelMonitor() {
        XCTAssertEqual(ProtocoloDDC.valor(de: 0.5, maximo: 100), 50)
        XCTAssertEqual(ProtocoloDDC.valor(de: 1.2, maximo: 100), 100)
        XCTAssertEqual(ProtocoloDDC.valor(de: 0.333, maximo: 1000), 333)
        XCTAssertEqual(ProtocoloDDC.nivel(de: 75, maximo: 100), 0.75, accuracy: 1e-6)
        XCTAssertEqual(ProtocoloDDC.nivel(de: 120, maximo: 100), 1)
        XCTAssertEqual(ProtocoloDDC.nivel(de: 5, maximo: 0), 0)
    }

    func testFabricantePorLetras() {
        // Un monitor real: "XMI" = 25001 (lo que dice CGDisplayVendorNumber).
        XCTAssertEqual(IdentidadMonitor.fabricante(letras: "XMI"), 25001)
        XCTAssertEqual(IdentidadMonitor.fabricante(letras: "GSM"), 0x1E6D)  // LG
        XCTAssertNil(IdentidadMonitor.fabricante(letras: "X1"))
        XCTAssertNil(IdentidadMonitor.fabricante(letras: "AB3"))
    }

    func testHuellaDelMonitor() {
        XCTAssertEqual(IdentidadMonitor(fabricante: 25001, modelo: 12289, serie: 0).huella, "25001:12289:0")
    }

    func testEmparejarPantallasConCanales() {
        let lg = IdentidadMonitor(fabricante: 7789, modelo: 100, serie: 11)
        let dell = IdentidadMonitor(fabricante: 4268, modelo: 200, serie: 22)
        // Los canales aparecen en otro orden que las pantallas.
        XCTAssertEqual(IdentidadMonitor.emparejar(pantallas: [lg, dell], canales: [dell, lg]), [0: 1, 1: 0])
    }

    func testDosMonitoresIgualesSinSerie() {
        let igual = IdentidadMonitor(fabricante: 1, modelo: 2, serie: 0)
        XCTAssertEqual(IdentidadMonitor.emparejar(pantallas: [igual, igual], canales: [igual, igual]), [0: 0, 1: 1])
    }

    func testLaSerieGanaSobreElOrden() {
        let a = IdentidadMonitor(fabricante: 1, modelo: 2, serie: 5)
        let b = IdentidadMonitor(fabricante: 1, modelo: 2, serie: 6)
        XCTAssertEqual(IdentidadMonitor.emparejar(pantallas: [b, a], canales: [a, b]), [0: 1, 1: 0])
    }

    func testUnoYUnoSinCoincidirSeUnen() {
        // Un adaptador que no copia el EDID: la pantalla dice una cosa y el canal otra, pero son el único par.
        let pantalla = IdentidadMonitor(fabricante: 1, modelo: 2, serie: 3)
        let canal = IdentidadMonitor(fabricante: 9, modelo: 9, serie: 9)
        XCTAssertEqual(IdentidadMonitor.emparejar(pantallas: [pantalla], canales: [canal]), [0: 0])
        // Con dos sin coincidir no se adivina.
        XCTAssertEqual(IdentidadMonitor.emparejar(pantallas: [pantalla, pantalla], canales: [canal, canal]), [:])
    }

    func testPantallaDelPuntero() {
        // Como una Mac real: el monitor a la izquierda (principal) y la MacBook a la derecha, más abajo.
        let pantallas: [(id: CGDirectDisplayID, marco: CGRect)] = [
            (id: 2, marco: CGRect(x: 0, y: 0, width: 1700, height: 956)),
            (id: 1, marco: CGRect(x: 1700, y: 184, width: 1280, height: 832)),
        ]
        XCTAssertEqual(ReglasBrillo.pantallaDelPuntero(CGPoint(x: 800, y: 500), en: pantallas), 2)
        XCTAssertEqual(ReglasBrillo.pantallaDelPuntero(CGPoint(x: 2000, y: 600), en: pantallas), 1)
        // Justo en el borde de la izquierda de la MacBook.
        XCTAssertEqual(ReglasBrillo.pantallaDelPuntero(CGPoint(x: 1700, y: 300), en: pantallas), 1)
        // En el borde de abajo de todo (fuera de los rectángulos): la más cercana.
        XCTAssertEqual(ReglasBrillo.pantallaDelPuntero(CGPoint(x: 2979.5, y: 1016), en: pantallas), 1)
        XCTAssertNil(ReglasBrillo.pantallaDelPuntero(.zero, en: []))
    }

    func testCurvaDeLaGamma() {
        XCTAssertEqual(ReglasBrillo.factorGamma(1), 1)
        XCTAssertEqual(ReglasBrillo.factorGamma(0), ReglasBrillo.pisoGamma)   // nunca a negro
        XCTAssertEqual(ReglasBrillo.escalar([0, 0.5, 1], factor: 0.5), [0, 0.25, 0.5])
        XCTAssertEqual(ReglasBrillo.escalar([1], factor: 3), [1])
    }

    func testAlReconectarNuncaQuedaNegro() {
        XCTAssertEqual(ReglasBrillo.nivelAlReconectar(nil), 1)
        XCTAssertEqual(ReglasBrillo.nivelAlReconectar(0.6), 0.6)
        XCTAssertEqual(ReglasBrillo.nivelAlReconectar(0.05), 0.25)
    }
}
