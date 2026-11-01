import XCTest
@testable import Alero

// La salida del modo limpieza: 5 Esc seguidos, otra tecla corta la cuenta, mantener Esc no suma y una pausa larga
// vuelve a empezar.

final class TrabaTecladoTests: XCTestCase {
    func testCincoEscSeguidosSalen() {
        var salida = SalidaTraba()
        for i in 1...4 {
            XCTAssertEqual(salida.tecla(esEsc: true, repite: false, ahora: Double(i)), i)
            XCTAssertFalse(salida.completa)
        }
        XCTAssertEqual(salida.tecla(esEsc: true, repite: false, ahora: 5), 5)
        XCTAssertTrue(salida.completa)
    }

    func testOtraTeclaCortaLaCuenta() {
        var salida = SalidaTraba()
        for i in 1...4 { _ = salida.tecla(esEsc: true, repite: false, ahora: Double(i)) }
        XCTAssertEqual(salida.tecla(esEsc: false, repite: false, ahora: 4.5), 0)
        XCTAssertEqual(salida.tecla(esEsc: true, repite: false, ahora: 5), 1)
        salida.reiniciar()   // una modificadora o una tecla de brillo
        XCTAssertEqual(salida.cuenta, 0)
    }

    func testMantenerEscNoSuma() {
        var salida = SalidaTraba()
        _ = salida.tecla(esEsc: true, repite: false, ahora: 1)
        for t in stride(from: 1.1, to: 3, by: 0.1) { XCTAssertEqual(salida.tecla(esEsc: true, repite: true, ahora: t), 1) }
        XCTAssertFalse(salida.completa)
    }

    func testPausaLargaVuelveAEmpezar() {
        var salida = SalidaTraba()
        _ = salida.tecla(esEsc: true, repite: false, ahora: 0)
        _ = salida.tecla(esEsc: true, repite: false, ahora: 5.9)   // dentro de los 6 s
        XCTAssertEqual(salida.cuenta, 2)
        XCTAssertEqual(salida.tecla(esEsc: true, repite: false, ahora: 12.5), 1)
    }

    func testTopes() {
        XCTAssertEqual(TopeTraba.allCases.map(\.rawValue), [0, 60, 120, 300])
        XCTAssertNil(TopeTraba(rawValue: 45))
    }
}
