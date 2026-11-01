import XCTest
@testable import Alero

/// Las cuentas de "Acomodar ventanas": zonas, rectángulos, lo libre y las barras.
final class MosaicoTests: XCTestCase {
    // Una pantalla de 1440×900 con la barra de menú (25 pt) y el Dock abajo (75 pt).
    private let pantalla = PantallaCG(marco: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visible: CGRect(x: 0, y: 25, width: 1440, height: 800))

    func testZonaSegunElPuntero() {
        func zona(_ x: CGFloat, _ y: CGFloat) -> ZonaMosaico? { ReglasMosaico.zona(en: CGPoint(x: x, y: y), pantalla: pantalla) }
        XCTAssertEqual(zona(0, 450), .izquierda)
        XCTAssertEqual(zona(1439, 450), .derecha)
        XCTAssertEqual(zona(0, 60), .arribaIzquierda)
        XCTAssertEqual(zona(1439, 800), .abajoDerecha)
        XCTAssertEqual(zona(720, 0), .completa)
        XCTAssertEqual(zona(30, 0), .arribaIzquierda)
        XCTAssertEqual(zona(1400, 899), .abajoDerecha)
        // Abajo en el medio está el Dock, y lejos de los bordes no pasa nada.
        XCTAssertNil(zona(720, 899))
        XCTAssertNil(zona(720, 450))
        // En otra pantalla.
        XCTAssertNil(zona(2000, 450))
    }

    func testMarcoDeCadaZona() {
        let v = pantalla.visible
        XCTAssertEqual(ReglasMosaico.marco(.izquierda, en: v), CGRect(x: 0, y: 25, width: 720, height: 800))
        XCTAssertEqual(ReglasMosaico.marco(.derecha, en: v), CGRect(x: 720, y: 25, width: 720, height: 800))
        XCTAssertEqual(ReglasMosaico.marco(.completa, en: v), v)
        XCTAssertEqual(ReglasMosaico.marco(.abajoDerecha, en: v), CGRect(x: 720, y: 425, width: 720, height: 400))
        // Con la barra vertical corrida al 30 %: la izquierda angosta, la derecha ancha, sin huecos.
        let d = Divisiones(x: 0.3, y: 0.5)
        let izquierda = ReglasMosaico.marco(.izquierda, en: v, divisiones: d)
        let derecha = ReglasMosaico.marco(.derecha, en: v, divisiones: d)
        XCTAssertEqual(izquierda.width, 432)
        XCTAssertEqual(izquierda.maxX, derecha.minX)
        XCTAssertEqual(derecha.maxX, v.maxX)
    }

    func testLoQueQuedaLibre() {
        XCTAssertNil(ReglasMosaico.libre(ocupadas: []))
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.izquierda]), .derecha)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.derecha]), .izquierda)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.arribaIzquierda]), .derecha)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.izquierda, .arribaDerecha]), .abajoDerecha)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.arribaIzquierda, .abajoIzquierda, .arribaDerecha]), .abajoDerecha)
        XCTAssertNil(ReglasMosaico.libre(ocupadas: [.izquierda, .derecha]))
        XCTAssertNil(ReglasMosaico.libre(ocupadas: [.completa]))
    }

    func testZonasQueSePisan() {
        XCTAssertTrue(ReglasMosaico.sePisan(.izquierda, .arribaIzquierda))
        XCTAssertTrue(ReglasMosaico.sePisan(.completa, .abajoDerecha))
        XCTAssertFalse(ReglasMosaico.sePisan(.izquierda, .derecha))
        XCTAssertFalse(ReglasMosaico.sePisan(.arribaDerecha, .abajoDerecha))
    }

    func testBarrasEntreVentanas() {
        let v = pantalla.visible
        let d = Divisiones()
        XCTAssertEqual(ReglasMosaico.barras(ocupadas: [.izquierda], en: v, divisiones: d), [])
        let dos = ReglasMosaico.barras(ocupadas: [.izquierda, .derecha], en: v, divisiones: d)
        XCTAssertEqual(dos, [BarraMosaico(vertical: true, linea: CGRect(x: 720, y: 25, width: 0, height: 800))])
        // Mitad izquierda y dos cuartos a la derecha: la vertical y una horizontal solo en la columna derecha.
        let tres = ReglasMosaico.barras(ocupadas: [.izquierda, .arribaDerecha, .abajoDerecha], en: v, divisiones: d)
        XCTAssertEqual(tres.count, 2)
        XCTAssertEqual(tres[1], BarraMosaico(vertical: false, linea: CGRect(x: 720, y: 425, width: 720, height: 0)))
        let cuatro = ReglasMosaico.barras(ocupadas: [.arribaIzquierda, .abajoIzquierda, .arribaDerecha, .abajoDerecha],
                                          en: v, divisiones: d)
        XCTAssertEqual(cuatro.count, 3)
    }

    func testArrastrarUnaBarraTieneTope() {
        let v = pantalla.visible
        let vertical = BarraMosaico(vertical: true, linea: .zero)
        XCTAssertEqual(ReglasMosaico.fraccion(vertical, hasta: CGPoint(x: 432, y: 0), en: v), 0.3, accuracy: 0.001)
        XCTAssertEqual(ReglasMosaico.fraccion(vertical, hasta: CGPoint(x: 10, y: 0), en: v), 0.15)
        XCTAssertEqual(ReglasMosaico.fraccion(vertical, hasta: CGPoint(x: 1430, y: 0), en: v), 0.85)
        let horizontal = BarraMosaico(vertical: false, linea: .zero)
        XCTAssertEqual(ReglasMosaico.fraccion(horizontal, hasta: CGPoint(x: 0, y: 425), en: v), 0.5, accuracy: 0.001)
    }
}
