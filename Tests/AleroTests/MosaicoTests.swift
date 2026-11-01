import XCTest
@testable import Alero

/// Las cuentas de "Acomodar ventanas": zonas, rectángulos, lo libre, cómo se reacomoda el grupo y las barras.
final class MosaicoTests: XCTestCase {
    // Una pantalla de 1440×900 con la barra de menú (25 pt) y el Dock abajo (75 pt).
    private let pantalla = PantallaCG(marco: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visible: CGRect(x: 0, y: 25, width: 1440, height: 800))
    private let cuatro: [ZonaMosaico] = [.arribaIzquierda, .abajoIzquierda, .arribaDerecha, .abajoDerecha]

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
        // Las ventanas quedan pegadas, sin hueco.
        XCTAssertEqual(ReglasMosaico.marco(.izquierda, en: v), CGRect(x: 0, y: 25, width: 720, height: 800))
        XCTAssertEqual(ReglasMosaico.marco(.derecha, en: v), CGRect(x: 720, y: 25, width: 720, height: 800))
        XCTAssertEqual(ReglasMosaico.marco(.completa, en: v), v)
        XCTAssertEqual(ReglasMosaico.marco(.abajoDerecha, en: v), CGRect(x: 720, y: 425, width: 720, height: 400))
        // Con la barra vertical corrida al 30 %: la izquierda angosta, la derecha ancha.
        let d = Divisiones(x: 0.3)
        let izquierda = ReglasMosaico.marco(.izquierda, en: v, divisiones: d)
        let derecha = ReglasMosaico.marco(.derecha, en: v, divisiones: d)
        XCTAssertEqual(izquierda.width, 432)
        XCTAssertEqual(derecha.minX, izquierda.maxX)
        XCTAssertEqual(derecha.maxX, v.maxX)
        // Con una sola columna partida, cada una tiene su altura.
        let columnas = Divisiones(x: 0.5, yIzquierda: 0.25, yDerecha: 0.75)
        XCTAssertEqual(ReglasMosaico.marco(.arribaIzquierda, en: v, divisiones: columnas).height, 200)
        XCTAssertEqual(ReglasMosaico.marco(.arribaDerecha, en: v, divisiones: columnas).height, 600)
        // Con las dos partidas, la línea es una sola.
        XCTAssertEqual(ReglasMosaico.unificar(columnas, ocupadas: cuatro).yDerecha, 0.25)
        XCTAssertEqual(ReglasMosaico.unificar(columnas, ocupadas: [.izquierda, .arribaDerecha, .abajoDerecha]), columnas)
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
        // La franja que se agarra va centrada en la unión.
        let dos = ReglasMosaico.barras(ocupadas: [.izquierda, .derecha], en: v, divisiones: d)
        XCTAssertEqual(dos, [BarraMosaico(tipo: .vertical, franja: CGRect(x: 714, y: 25, width: 12, height: 800))])
        // Mitad izquierda y dos cuartos a la derecha: la vertical y una horizontal solo en la columna derecha.
        let tres = ReglasMosaico.barras(ocupadas: [.izquierda, .arribaDerecha, .abajoDerecha], en: v, divisiones: d)
        XCTAssertEqual(tres.map(\.tipo), [.vertical, .horizontal(.derecha)])
        XCTAssertEqual(tres[1].franja, CGRect(x: 720, y: 419, width: 720, height: 12))
        // Cuatro: la vertical, una sola horizontal de lado a lado y la perilla del cruce.
        let barras = ReglasMosaico.barras(ocupadas: cuatro, en: v, divisiones: d)
        XCTAssertEqual(barras.map(\.tipo), [.vertical, .horizontal(nil), .cruce])
        XCTAssertEqual(barras[1].franja, CGRect(x: 0, y: 419, width: 1440, height: 12))
        XCTAssertEqual(barras[2].franja, CGRect(x: 705, y: 410, width: 30, height: 30))
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
        // El cruce mueve todo en diagonal; centrarlo vuelve todo al medio.
        let diagonal = ReglasMosaico.mover(Divisiones(), .cruce, hasta: CGPoint(x: 1008, y: 625), en: v)
        XCTAssertEqual(diagonal.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(diagonal.yIzquierda, 0.75, accuracy: 0.001)
        XCTAssertEqual(diagonal.yDerecha, 0.75, accuracy: 0.001)
        XCTAssertEqual(ReglasMosaico.centrar(diagonal, .cruce), Divisiones())
    }

    func testCambiarDeLado() {
        XCTAssertEqual(ReglasMosaico.intercambiar(.izquierda, .vertical), .derecha)
        XCTAssertEqual(ReglasMosaico.intercambiar(.abajoDerecha, .vertical), .abajoIzquierda)
        XCTAssertEqual(ReglasMosaico.intercambiar(.arribaDerecha, .horizontal(.derecha)), .abajoDerecha)
        // La horizontal de una columna no toca la otra.
        XCTAssertEqual(ReglasMosaico.intercambiar(.arribaIzquierda, .horizontal(.derecha)), .arribaIzquierda)
        XCTAssertEqual(ReglasMosaico.intercambiar(.arribaIzquierda, .horizontal(nil)), .abajoIzquierda)
    }

    func testAgrandarUnaVentanaMueveLaBarra() {
        let v = pantalla.visible
        let ocupadas: [ZonaMosaico] = [.izquierda, .derecha]
        // La de la izquierda se estiró desde su borde derecho hasta 1008: la barra la sigue (al 70 %).
        let estirada = CGRect(x: 0, y: 25, width: 1008, height: 800)
        let nuevas = ReglasMosaico.divisiones(siCambio: .izquierda, a: estirada, ocupadas: ocupadas, en: v, divisiones: Divisiones())
        XCTAssertEqual(nuevas?.x ?? 0, 0.7, accuracy: 0.001)
        // Si no se movió el borde de adentro, nada.
        XCTAssertNil(ReglasMosaico.divisiones(siCambio: .izquierda, a: ReglasMosaico.marco(.izquierda, en: v), ocupadas: ocupadas,
                                              en: v, divisiones: Divisiones()))
        // Un cuarto de arriba que se estiró para abajo mueve la horizontal de su columna.
        let cuartos: [ZonaMosaico] = [.izquierda, .arribaDerecha, .abajoDerecha]
        let alto = CGRect(x: 720, y: 25, width: 720, height: 600)
        let otras = ReglasMosaico.divisiones(siCambio: .arribaDerecha, a: alto, ocupadas: cuartos, en: v, divisiones: Divisiones())
        XCTAssertEqual(otras?.yDerecha ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(otras?.x, 0.5)
        // Con cuatro, estirar una en diagonal mueve la vertical y la línea de las dos columnas.
        let esquina = CGRect(x: 0, y: 25, width: 1008, height: 600)
        let diagonal = ReglasMosaico.divisiones(siCambio: .arribaIzquierda, a: esquina, ocupadas: cuatro, en: v, divisiones: Divisiones())
        XCTAssertEqual(diagonal?.x ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(diagonal?.yIzquierda ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(diagonal?.yDerecha ?? 0, 0.75, accuracy: 0.001)
    }
}
