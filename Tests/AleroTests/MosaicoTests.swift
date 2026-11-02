import XCTest
@testable import Alero

/// Las cuentas de "Acomodar ventanas": zonas, rectángulos, lo libre, cómo se reacomoda el grupo y las barras.
final class MosaicoTests: XCTestCase {
    // Una pantalla de 1440×900 con la barra de menú (25 pt) y el Dock abajo (75 pt).
    private let pantalla = PantallaCG(marco: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visible: CGRect(x: 0, y: 25, width: 1440, height: 800))
    private let cuatro: [ZonaMosaico] = [.arribaIzquierda, .abajoIzquierda, .arribaDerecha, .abajoDerecha]

    /// La 0.1.1 se cerraba cada vez que aparecía una tarjeta de vidrio ("¿Qué va acá?" o el selector de formas):
    /// reacomodar el borde al agregar el contenido volvía a agregar y no terminaba nunca.
    func testTarjetaDeVidrioSinBucleYConElBordeEncima() {
        let tarjeta = TarjetaVidrio(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let contenido = NSView()
        tarjeta.poner(contenido)
        tarjeta.poner(NSView())
        XCTAssertEqual(tarjeta.subviews.count, 3)
        XCTAssertTrue(tarjeta.subviews.last is BordeTarjeta)
        XCTAssertEqual(contenido.frame, tarjeta.bounds)
        // Los clics pasan a lo de abajo del borde.
        XCTAssertFalse(tarjeta.hitTest(CGPoint(x: 150, y: 100)) is BordeTarjeta)
        // El selector la crea sin tamaño y se lo da después: el borde la acompaña.
        let chica = TarjetaVidrio(radio: 16)
        chica.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
        chica.poner(NSView())
        XCTAssertEqual(chica.subviews.last?.frame, chica.bounds)
    }

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

    func testLoLibreSegunLaFormaElegida() {
        // Con cuatro cuartos, después del primero se ofrece otro cuarto (no la mitad).
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.arribaIzquierda], plantilla: FormaMosaico.cuartos.zonas), .arribaDerecha)
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.arribaIzquierda, .arribaDerecha], plantilla: FormaMosaico.cuartos.zonas), .abajoIzquierda)
        // Mitad y dos cuartos, empezando por un cuarto de la derecha.
        XCTAssertEqual(ReglasMosaico.libre(ocupadas: [.abajoDerecha], plantilla: FormaMosaico.mitadYCuartos.zonas), .izquierda)
        XCTAssertNil(ReglasMosaico.libre(ocupadas: [.izquierda, .derecha], plantilla: FormaMosaico.mitades.zonas))
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

    func testDondeSumarOtraApp() {
        // Con lugar libre, ahí.
        XCTAssertEqual(ReglasMosaico.dondeSumar(ocupadas: [.izquierda], divisiones: Divisiones()), .derecha)
        // Dos mitades: se parte la más ancha (con la barra al medio, la derecha).
        XCTAssertEqual(ReglasMosaico.dondeSumar(ocupadas: [.izquierda, .derecha], divisiones: Divisiones()), .abajoDerecha)
        XCTAssertEqual(ReglasMosaico.dondeSumar(ocupadas: [.izquierda, .derecha], divisiones: Divisiones(x: 0.7)), .abajoIzquierda)
        // Tres: queda la columna que todavía es una mitad.
        XCTAssertEqual(ReglasMosaico.dondeSumar(ocupadas: [.izquierda, .arribaDerecha, .abajoDerecha], divisiones: Divisiones()), .abajoIzquierda)
        // Cuatro, o la pantalla entera: no hay lugar.
        XCTAssertNil(ReglasMosaico.dondeSumar(ocupadas: cuatro, divisiones: Divisiones()))
        XCTAssertNil(ReglasMosaico.dondeSumar(ocupadas: [.completa], divisiones: Divisiones()))
    }

    func testQuitarUnaApp() {
        // De cuatro a tres: el cuarto que queda solo en su columna pasa a ser la mitad.
        XCTAssertEqual(ReglasMosaico.quitar(.abajoDerecha, quedan: [.arribaIzquierda, .abajoIzquierda, .arribaDerecha]),
                       [.arribaIzquierda, .abajoIzquierda, .derecha])
        // De tres a dos: mitad izquierda y dos cuartos, sale uno de la derecha.
        XCTAssertEqual(ReglasMosaico.quitar(.arribaDerecha, quedan: [.izquierda, .abajoDerecha]), [.izquierda, .derecha])
        // Sale la mitad: los dos cuartos del otro lado pasan a ser las dos mitades.
        XCTAssertEqual(ReglasMosaico.quitar(.izquierda, quedan: [.arribaDerecha, .abajoDerecha]), [.izquierda, .derecha])
        // De dos mitades queda una sola: no se toca (el grupo se termina).
        XCTAssertEqual(ReglasMosaico.quitar(.derecha, quedan: [.izquierda]), [.izquierda])
    }

    func testCambiarDeLado() {
        XCTAssertEqual(ReglasMosaico.intercambiar(.izquierda, .vertical), .derecha)
        XCTAssertEqual(ReglasMosaico.intercambiar(.abajoDerecha, .vertical), .abajoIzquierda)
        XCTAssertEqual(ReglasMosaico.intercambiar(.arribaDerecha, .horizontal(.derecha)), .abajoDerecha)
        // La horizontal de una columna no toca la otra.
        XCTAssertEqual(ReglasMosaico.intercambiar(.arribaIzquierda, .horizontal(.derecha)), .arribaIzquierda)
        XCTAssertEqual(ReglasMosaico.intercambiar(.arribaIzquierda, .horizontal(nil)), .abajoIzquierda)
    }

    func testAppConTamanoMinimoCorreLaBarra() {
        // MacBook Air de 13": 1470 pt de ancho. WhatsApp a la derecha no se deja angostar menos de 800.
        let v = CGRect(x: 0, y: 25, width: 1470, height: 900)
        let ocupadas: [ZonaMosaico] = [.izquierda, .derecha]
        let destino = ReglasMosaico.marco(.derecha, en: v)
        let quedo = CGRect(x: destino.minX, y: 25, width: 800, height: 900)   // se sale por la derecha
        let minimo = ReglasMosaico.minimo(quedo: quedo, pedido: destino, antes: .zero, en: v)
        XCTAssertEqual(minimo, CGSize(width: 800, height: 0))
        let r = ReglasMosaico.respetar(Divisiones(), minimos: [.derecha: minimo], ocupadas: ocupadas, en: v)
        XCTAssertTrue(r.entra)
        let corrida = ReglasMosaico.marco(.derecha, en: v, divisiones: r.divisiones)
        XCTAssertEqual(corrida.width, 800, accuracy: 1)
        XCTAssertEqual(corrida.maxX, v.maxX)
        // A la izquierda, lo mismo para el otro lado.
        let otras = ReglasMosaico.respetar(Divisiones(), minimos: [.izquierda: CGSize(width: 800, height: 0)], ocupadas: ocupadas, en: v)
        XCTAssertEqual(ReglasMosaico.marco(.izquierda, en: v, divisiones: otras.divisiones).width, 800, accuracy: 1)
        // Si entra, la barra no se toca.
        XCTAssertEqual(ReglasMosaico.respetar(Divisiones(), minimos: [.derecha: CGSize(width: 500, height: 0)],
                                              ocupadas: ocupadas, en: v).divisiones, Divisiones())
        // Un "mínimo" de casi toda la pantalla es una app que todavía no terminó de achicarse: no se cree.
        let tarde = ReglasMosaico.minimo(quedo: CGRect(x: 0, y: 25, width: 1400, height: 900), pedido: destino, antes: .zero, en: v)
        XCTAssertEqual(tarde, .zero)
    }

    /// Lo que le pasó a Maxi: Claude a la izquierda y WhatsApp a la derecha en una pantalla de 1700×956 (848 pt
    /// visibles). Al sumar Chrome abajo a la derecha, WhatsApp no bajó de 578 pt de alto y Chrome (que no baja de 272)
    /// quedó colgando debajo de la pantalla. Ahora: en esa columna no entran las dos, así que Chrome pasa abajo a la
    /// izquierda, debajo de Claude.
    func testDosAltasNoEntranEnUnaColumnaYLaNuevaPasaALaOtra() {
        let v = CGRect(x: 0, y: 30, width: 1700, height: 848)
        let zonas: [ZonaMosaico] = [.izquierda, .arribaDerecha, .abajoDerecha]   // Claude, WhatsApp, Chrome (la nueva)
        // Primero se sabe lo de WhatsApp: la línea baja lo justo para que entre.
        let soloWhatsApp = ReglasMosaico.respetar(Divisiones(), minimos: [.arribaDerecha: CGSize(width: 0, height: 578)],
                                                  ocupadas: zonas, en: v)
        XCTAssertTrue(soloWhatsApp.entra)
        XCTAssertEqual(ReglasMosaico.marco(.arribaDerecha, en: v, divisiones: soloWhatsApp.divisiones).height, 578, accuracy: 1)
        // Después lo de Chrome: no entran.
        let minimos: [ZonaMosaico: CGSize] = [.arribaDerecha: CGSize(width: 0, height: 578), .abajoDerecha: CGSize(width: 400, height: 272)]
        XCTAssertFalse(ReglasMosaico.respetar(soloWhatsApp.divisiones, minimos: minimos, ocupadas: zonas, en: v).entra)
        // Chrome se muda: Claude arriba a la izquierda, Chrome abajo a la izquierda, WhatsApp toda la derecha.
        XCTAssertEqual(ReglasMosaico.mudar(2, ocupadas: zonas), [.arribaIzquierda, .derecha, .abajoIzquierda])
        // Arriba en la otra columna, también arriba.
        XCTAssertEqual(ReglasMosaico.mudar(1, ocupadas: [.izquierda, .arribaDerecha, .abajoDerecha]),
                       [.abajoIzquierda, .arribaIzquierda, .derecha])
        // Si la otra columna ya está partida (o la nueva es una mitad), no hay a dónde ir.
        XCTAssertNil(ReglasMosaico.mudar(3, ocupadas: cuatro))
        XCTAssertNil(ReglasMosaico.mudar(1, ocupadas: [.izquierda, .derecha]))
        // Y ninguna queda debajo del Dock: la que no entra se corre para arriba.
        let chrome = ReglasMosaico.marco(.abajoDerecha, en: v, divisiones: soloWhatsApp.divisiones)
        let adentro = ReglasMosaico.dentro(chrome, minimo: CGSize(width: 400, height: 272), en: v)
        XCTAssertEqual(adentro.maxY, v.maxY)
        XCTAssertEqual(adentro.height, 272)
        XCTAssertEqual(ReglasMosaico.dentro(chrome, minimo: .zero, en: v), chrome)
    }

    func testDondeSumarEvitaLaColumnaDeUnaAppAlta() {
        let ocupadas: [ZonaMosaico] = [.izquierda, .derecha]
        // Sin saber nada, la derecha (como siempre); si WhatsApp a la derecha no baja del 68 % del alto, la izquierda.
        XCTAssertEqual(ReglasMosaico.dondeSumar(ocupadas: ocupadas, divisiones: Divisiones(), minimos: [:], alto: 848), .abajoDerecha)
        XCTAssertEqual(ReglasMosaico.dondeSumar(ocupadas: ocupadas, divisiones: Divisiones(),
                                                minimos: [.derecha: CGSize(width: 0, height: 578)], alto: 848), .abajoIzquierda)
        // Si las dos son altas, igual se ofrece la más ancha.
        let altas: [ZonaMosaico: CGSize] = [.derecha: CGSize(width: 0, height: 700), .izquierda: CGSize(width: 0, height: 700)]
        XCTAssertEqual(ReglasMosaico.dondeSumar(ocupadas: ocupadas, divisiones: Divisiones(), minimos: altas, alto: 848), .abajoDerecha)
    }

    func testLaLineaUnicaRespetaLasDosColumnas() {
        let v = pantalla.visible
        // Con cuatro, la línea es una sola: tiene que dejar lugar a la más alta de arriba y a la más alta de abajo.
        let minimos: [ZonaMosaico: CGSize] = [.arribaIzquierda: CGSize(width: 0, height: 500), .abajoDerecha: CGSize(width: 0, height: 250)]
        let r = ReglasMosaico.respetar(Divisiones(), minimos: minimos, ocupadas: cuatro, en: v)
        XCTAssertTrue(r.entra)
        XCTAssertEqual(r.divisiones.yIzquierda, 500.0 / 800, accuracy: 0.001)
        XCTAssertEqual(r.divisiones.yDerecha, r.divisiones.yIzquierda)
        // Dos que no entran a lo ancho: la barra queda a mitad de camino y avisa.
        let anchas: [ZonaMosaico: CGSize] = [.izquierda: CGSize(width: 900, height: 0), .derecha: CGSize(width: 900, height: 0)]
        let r2 = ReglasMosaico.respetar(Divisiones(), minimos: anchas, ocupadas: [.izquierda, .derecha], en: v)
        XCTAssertFalse(r2.entra)
        XCTAssertEqual(r2.divisiones.x, 0.5, accuracy: 0.001)
    }

    /// Qué hacer cuando ventanas de un grupo dejan de verse. Antes, cambiar de escritorio desarmaba el grupo (todas
    /// "se habían ido") y una app que tardaba en contestar contaba como cerrada.
    func testVentanasQueDejanDeVerse() {
        let ids: [CGWindowID] = [1, 2, 3]
        // Se cerró una: sale, las demás siguen.
        var que = Mosaico.decidir(ids, estados: [3: .cerrada])
        XCTAssertEqual(que.quitar, [3]); XCTAssertFalse(que.dormir); XCTAssertFalse(que.fuera)
        // Se minimizó una: se duerme todo, nadie sale.
        que = Mosaico.decidir(ids, estados: [2: .minimizada])
        XCTAssertEqual(que.quitar, []); XCTAssertTrue(que.dormir)
        // Se cambió de escritorio: ninguna a la vista y todas en otro lado. El grupo espera, entero.
        que = Mosaico.decidir(ids, estados: [1: .otroLado, 2: .otroLado, 3: .otroLado])
        XCTAssertEqual(que.quitar, []); XCTAssertTrue(que.fuera)
        // Llevaron una sola a otro escritorio (o a pantalla completa): esa sale.
        que = Mosaico.decidir(ids, estados: [2: .otroLado])
        XCTAssertEqual(que.quitar, [2]); XCTAssertFalse(que.fuera)
        // Una app que no contestó: no se hace nada hasta la próxima.
        que = Mosaico.decidir(ids, estados: [1: .otroLado, 2: .noSe, 3: .otroLado])
        XCTAssertEqual(que.quitar, []); XCTAssertFalse(que.fuera); XCTAssertFalse(que.dormir)
        XCTAssertEqual(Mosaico.decidir(ids, estados: [1: .noSe]).quitar, [])
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
