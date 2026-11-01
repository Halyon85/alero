import XCTest
@testable import Alero

/// Las cuentas de "Acomodar ventanas": zonas, rectángulos, lo libre, cómo se reacomoda el grupo y las barras.
final class MosaicoTests: XCTestCase {
    // Una pantalla de 1440×900 con la barra de menú (25 pt) y el Dock abajo (75 pt).
    private let pantalla = PantallaCG(marco: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visible: CGRect(x: 0, y: 25, width: 1440, height: 800))

    func testZonaSegunElPuntero() {
        func zona(_ x: CGFloat, _ y: CGFloat) -> ZonaMosaico? { ReglasMosaico.zona(en: CGPoint(x: x, y: y), pantalla: pantalla)?.zona }
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
        XCTAssertNil(zona(1420, 450))
        // En otra pantalla.
        XCTAssertNil(zona(2000, 450))
    }

    func testBordeQueDaAOtraPantalla() {
        let segunda = PantallaCG(marco: CGRect(x: 1440, y: 100, width: 1280, height: 800),
                                 visible: CGRect(x: 1440, y: 125, width: 1280, height: 775))
        let lados = LadosCompartidos.de(pantalla, entre: [pantalla, segunda])
        XCTAssertEqual(lados, LadosCompartidos(izquierda: false, derecha: true, arriba: false, abajo: false))
        XCTAssertEqual(LadosCompartidos.de(segunda, entre: [pantalla, segunda]).izquierda, true)
        // Del lado compartido la franja es más ancha y avisa que hay que quedarse un momento.
        let toque = ReglasMosaico.zona(en: CGPoint(x: 1420, y: 450), pantalla: pantalla, compartidos: lados)
        XCTAssertEqual(toque, ToqueMosaico(zona: .derecha, compartido: true))
        XCTAssertEqual(ReglasMosaico.zona(en: CGPoint(x: 0, y: 450), pantalla: pantalla, compartidos: lados),
                       ToqueMosaico(zona: .izquierda, compartido: false))
    }

    func testMarcoDeCadaZona() {
        let v = pantalla.visible
        // Contra los bordes de la pantalla llega justo; en el medio queda un hueco de 10 pt para la barra.
        XCTAssertEqual(ReglasMosaico.marco(.izquierda, en: v), CGRect(x: 0, y: 25, width: 715, height: 800))
        XCTAssertEqual(ReglasMosaico.marco(.derecha, en: v), CGRect(x: 725, y: 25, width: 715, height: 800))
        XCTAssertEqual(ReglasMosaico.marco(.completa, en: v), v)
        XCTAssertEqual(ReglasMosaico.marco(.abajoDerecha, en: v), CGRect(x: 725, y: 430, width: 715, height: 395))
        // Con la barra vertical corrida al 30 %: la izquierda angosta, la derecha ancha.
        let d = Divisiones(x: 0.3)
        let izquierda = ReglasMosaico.marco(.izquierda, en: v, divisiones: d)
        let derecha = ReglasMosaico.marco(.derecha, en: v, divisiones: d)
        XCTAssertEqual(izquierda.width, 427)
        XCTAssertEqual(derecha.minX - izquierda.maxX, ReglasMosaico.separacion)
        XCTAssertEqual(derecha.maxX, v.maxX)
        // Cada columna tiene su barra horizontal.
        let columnas = Divisiones(x: 0.5, yIzquierda: 0.25, yDerecha: 0.75)
        XCTAssertEqual(ReglasMosaico.marco(.arribaIzquierda, en: v, divisiones: columnas).height, 195)
        XCTAssertEqual(ReglasMosaico.marco(.arribaDerecha, en: v, divisiones: columnas).height, 595)
    }

    func testLoQueQuedaLibre() {
        XCTAssertNil(ReglasMosaico.libre(ocupadas: []))
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.izquierda]), .derecha)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.derecha]), .izquierda)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.arribaIzquierda]), .derecha)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.izquierda, .arribaDerecha]), .abajoDerecha)
        XCTAssertNil(ReglasMosaico.libre(ocupadas: [.izquierda, .derecha]))
        XCTAssertNil(ReglasMosaico.libre(ocupadas: [.completa]))
    }

    func testSumarUnaTerceraApp() {
        // Dos mitades y una nueva arriba a la derecha: la de la derecha baja al cuarto de abajo.
        XCTAssertEqual(ReglasMosaico.acomodar(.arribaDerecha, entre: [.izquierda, .derecha]), [.izquierda, .abajoDerecha])
        XCTAssertEqual(ReglasMosaico.acomodar(.abajoIzquierda, entre: [.izquierda, .derecha]), [.arribaIzquierda, .derecha])
        // Una nueva en una mitad ocupada: la de antes sale.
        XCTAssertEqual(ReglasMosaico.acomodar(.izquierda, entre: [.izquierda, .derecha]), [nil, .derecha])
        // Una nueva en una mitad con dos cuartos: salen los dos.
        XCTAssertEqual(ReglasMosaico.acomodar(.derecha, entre: [.izquierda, .arribaDerecha, .abajoDerecha]), [.izquierda, nil, nil])
        // La pantalla entera saca a todas.
        XCTAssertEqual(ReglasMosaico.acomodar(.completa, entre: [.izquierda, .derecha]), [nil, nil])
    }

    func testBarrasEntreVentanas() {
        let v = pantalla.visible
        let d = Divisiones()
        XCTAssertEqual(ReglasMosaico.barras(ocupadas: [.izquierda], en: v, divisiones: d), [])
        let dos = ReglasMosaico.barras(ocupadas: [.izquierda, .derecha], en: v, divisiones: d)
        XCTAssertEqual(dos, [BarraMosaico(tipo: .vertical, franja: CGRect(x: 715, y: 25, width: 10, height: 800))])
        // Mitad izquierda y dos cuartos a la derecha: la vertical y una horizontal solo en la columna derecha.
        let tres = ReglasMosaico.barras(ocupadas: [.izquierda, .arribaDerecha, .abajoDerecha], en: v, divisiones: d)
        XCTAssertEqual(tres.map(\.tipo), [.vertical, .horizontal(.derecha)])
        XCTAssertEqual(tres[1].franja, CGRect(x: 725, y: 420, width: 715, height: 10))
        let cuatro = ReglasMosaico.barras(ocupadas: [.arribaIzquierda, .abajoIzquierda, .arribaDerecha, .abajoDerecha],
                                          en: v, divisiones: d)
        XCTAssertEqual(cuatro.map(\.tipo), [.vertical, .horizontal(.izquierda), .horizontal(.derecha)])
    }

    func testMoverYCentrarUnaBarra() {
        let v = pantalla.visible
        var d = ReglasMosaico.mover(Divisiones(), .vertical, hasta: CGPoint(x: 432, y: 0), en: v)
        XCTAssertEqual(d.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(ReglasMosaico.mover(d, .vertical, hasta: CGPoint(x: 10, y: 0), en: v).x, 0.15)
        XCTAssertEqual(ReglasMosaico.mover(d, .vertical, hasta: CGPoint(x: 1430, y: 0), en: v).x, 0.85)
        // La horizontal de una columna no mueve la de la otra.
        d = ReglasMosaico.mover(d, .horizontal(.derecha), hasta: CGPoint(x: 0, y: 225), en: v)
        XCTAssertEqual(d.yDerecha, 0.25, accuracy: 0.001)
        XCTAssertEqual(d.yIzquierda, 0.5)
        XCTAssertEqual(ReglasMosaico.centrar(d, .vertical).x, 0.5)
    }

    func testAgrandarUnaVentanaMueveLaBarra() {
        let v = pantalla.visible
        let ocupadas: [ZonaMosaico] = [.izquierda, .derecha]
        // La de la izquierda se estiró desde su borde derecho hasta 1005: la barra la sigue (al 70 %).
        let estirada = CGRect(x: 0, y: 25, width: 1003, height: 800)
        let nuevas = ReglasMosaico.divisiones(siCambio: .izquierda, a: estirada, ocupadas: ocupadas, en: v, divisiones: Divisiones())
        XCTAssertEqual(nuevas?.x ?? 0, 0.7, accuracy: 0.001)
        // Si no se movió el borde de adentro, nada.
        XCTAssertNil(ReglasMosaico.divisiones(siCambio: .izquierda, a: ReglasMosaico.marco(.izquierda, en: v), ocupadas: ocupadas,
                                              en: v, divisiones: Divisiones()))
        // Un cuarto de arriba que se estiró para abajo mueve la horizontal de su columna.
        let cuartos: [ZonaMosaico] = [.izquierda, .arribaDerecha, .abajoDerecha]
        let alto = CGRect(x: 725, y: 25, width: 715, height: 595)
        let otras = ReglasMosaico.divisiones(siCambio: .arribaDerecha, a: alto, ocupadas: cuartos, en: v, divisiones: Divisiones())
        XCTAssertEqual(otras?.yDerecha ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(otras?.x, 0.5)
    }
}
