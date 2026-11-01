import XCTest
@testable import Alero

// El motor del scroll suave: que suelte exactamente la distancia pedida, que un clic al revés responda al instante
// y que termine (si no termina, el planeo sigue para siempre).

final class MotorPlaneoTests: XCTestCase {
    /// Corre el motor a 120 cuadros por segundo hasta que frena y devuelve el total soltado y los cuadros usados.
    private func correr(_ motor: inout MotorPlaneo, tau: Double = 0.08, maximo: Int = 2_000) -> (total: Int, cuadros: Int) {
        var total = 0
        var cuadros = 0
        while motor.activo && cuadros < maximo {
            total += motor.paso(dt: 1.0 / 120, tau: tau)
            cuadros += 1
        }
        return (total, cuadros)
    }

    func testSueltaLaDistanciaExacta() {
        for distancia in [40.0, -40.0, 120.0, 3.5, -0.7, 1000.0] {
            var motor = MotorPlaneo()
            motor.sumar(distancia)
            let resultado = correr(&motor)
            XCTAssertFalse(motor.activo, "no frenó con \(distancia)")
            XCTAssertLessThanOrEqual(abs(Double(resultado.total) - distancia), 1, "soltó \(resultado.total) en vez de \(distancia)")
        }
    }

    func testTerminaEnUnTiempoRazonable() {
        var motor = MotorPlaneo()
        motor.sumar(400)
        let resultado = correr(&motor)
        // Con tau 0,08 y velocidad mínima de 60 px/s, 400 px terminan bastante antes de 2 segundos.
        XCTAssertLessThan(resultado.cuadros, 240)
    }

    func testIgualA60Y120Cuadros() {
        var lento = MotorPlaneo()
        var rapido = MotorPlaneo()
        lento.sumar(200)
        rapido.sumar(200)
        var totalLento = 0
        var totalRapido = 0
        // A los 0,1 s los dos tienen que haber recorrido casi lo mismo.
        for _ in 0..<6 { totalLento += lento.paso(dt: 1.0 / 60, tau: 0.08) }
        for _ in 0..<12 { totalRapido += rapido.paso(dt: 1.0 / 120, tau: 0.08) }
        XCTAssertLessThanOrEqual(abs(totalLento - totalRapido), 2)
    }

    func testCambiarDeSentidoReemplaza() {
        var motor = MotorPlaneo()
        motor.sumar(300)
        _ = motor.paso(dt: 1.0 / 120, tau: 0.08)
        motor.sumar(-40)
        XCTAssertEqual(motor.restante, -40, "el clic al revés tiene que reemplazar lo que faltaba")
        let primero = motor.paso(dt: 1.0 / 120, tau: 0.08)
        XCTAssertLessThan(primero, 0, "el primer cuadro después del cambio ya va para el otro lado")
    }

    func testUnaTrabaNoVuelcaTodoDeGolpe() {
        var motor = MotorPlaneo()
        motor.sumar(1000)
        let tras1Segundo = motor.paso(dt: 1, tau: 0.08)
        XCTAssertLessThan(tras1Segundo, 1000 / 2, "el dt se recorta a 1/20 s")
    }

    func testRedondeoDeTeclas() {
        XCTAssertEqual(TeclasMedia.redondear(0.49, paso: 1.0 / 16), 0.5)
        XCTAssertEqual(TeclasMedia.redondear(1.05, paso: 1.0 / 16), 1)
        XCTAssertEqual(TeclasMedia.redondear(-0.02, paso: 1.0 / 16), 0)
    }
}
