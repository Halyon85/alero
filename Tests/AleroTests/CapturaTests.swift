import CoreGraphics
import XCTest
@testable import Alero

// Capturas: rectángulos entre pantallas y escalas, píxeles de la imagen congelada, ventanas bajo el puntero,
// nombres de archivo y el atajo de fábrica. Las pantallas son las de una Mac real: un monitor de 1700 × 956 a 1×
// como principal y la MacBook (1512 × 982 a 2×) a la derecha y más abajo.

final class CapturaTests: XCTestCase {
    private let monitor = CGRect(x: 0, y: 0, width: 1700, height: 956)
    /// En AppKit la MacBook queda 60 pt más abajo que el monitor (origen abajo).
    private let macbook = CGRect(x: 1700, y: -60, width: 1512, height: 982)

    func testSeleccionNoSeSaleDeLaPantalla() {
        let r = GeometriaCaptura.seleccion(desde: CGPoint(x: 1600, y: 100), hasta: CGPoint(x: 1800, y: -20), dentroDe: monitor)
        XCTAssertEqual(r, CGRect(x: 1600, y: 0, width: 100, height: 100))
        // Arrastrar hacia arriba a la izquierda da el mismo rectángulo que al revés.
        let alReves = GeometriaCaptura.seleccion(desde: CGPoint(x: 300, y: 400), hasta: CGPoint(x: 100, y: 250), dentroDe: monitor)
        XCTAssertEqual(alReves, CGRect(x: 100, y: 250, width: 200, height: 150))
        // Todo afuera: vacío, no un rectángulo "nulo" que rompa las cuentas de después.
        XCTAssertEqual(GeometriaCaptura.seleccion(desde: CGPoint(x: -50, y: -50), hasta: CGPoint(x: -10, y: -10), dentroDe: monitor), .zero)
    }

    func testDeAppKitALaPantallaConOrigenArriba() {
        // Un área arriba a la izquierda de la MacBook: en AppKit su y es alta; en la pantalla, cerca de 0.
        let area = CGRect(x: 1750, y: 822, width: 200, height: 100)
        XCTAssertEqual(GeometriaCaptura.local(area, enPantalla: macbook), CGRect(x: 50, y: 0, width: 200, height: 100))
        // En el monitor principal, abajo de todo: y local = alto - alto del área.
        XCTAssertEqual(GeometriaCaptura.local(CGRect(x: 0, y: 0, width: 10, height: 6), enPantalla: monitor),
                       CGRect(x: 0, y: 950, width: 10, height: 6))
    }

    func testPixelesConEscalaYRedondeoHaciaAfuera() {
        // Retina (2×): media punto se vuelve un píxel entero y no se pierde.
        let r = GeometriaCaptura.pixeles(CGRect(x: 10.25, y: 5, width: 100.5, height: 50), escala: 2, ancho: 3024, alto: 1964)
        XCTAssertEqual(r, CGRect(x: 20, y: 10, width: 202, height: 100))
        // Nunca se sale de la imagen (el borde derecho de una pantalla de 1512 pt a 2× son 3024 px).
        let borde = GeometriaCaptura.pixeles(CGRect(x: 1500, y: 970, width: 20, height: 20), escala: 2, ancho: 3024, alto: 1964)
        XCTAssertEqual(borde, CGRect(x: 3000, y: 1940, width: 24, height: 24))
        // Monitor a 1×: igual a los puntos.
        XCTAssertEqual(GeometriaCaptura.pixeles(CGRect(x: 3, y: 4, width: 5, height: 6), escala: 1, ancho: 1700, alto: 956),
                       CGRect(x: 3, y: 4, width: 5, height: 6))
    }

    func testMedidasDelCartel() {
        XCTAssertTrue(GeometriaCaptura.medidas(CGRect(x: 0, y: 0, width: 640, height: 360), escala: 2) == (1280, 720))
        XCTAssertTrue(GeometriaCaptura.medidas(CGRect(x: 0, y: 0, width: 100.4, height: 3), escala: 1) == (100, 3))
    }

    func testVentanasDeMacOSPasanAAppKit() {
        // CGWindowList da los marcos con origen arriba: una ventana arriba de todo en la MacBook…
        let cuarzo = CGRect(x: 1800, y: 60, width: 800, height: 600)
        let appKit = Geometria.aEventos(cuarzo, altoPrincipal: 956)
        // …en AppKit queda con su borde de arriba en 956 - 60 = 896.
        XCTAssertEqual(appKit, CGRect(x: 1800, y: 296, width: 800, height: 600))
        XCTAssertEqual(appKit.maxY, 896)
    }

    func testVentanaBajoElPunteroEsLaDeAdelante() {
        let adelante = VentanaCandidata(id: 7, marco: CGRect(x: 100, y: 100, width: 300, height: 200), app: "Notas")
        let atras = VentanaCandidata(id: 3, marco: CGRect(x: 0, y: 0, width: 800, height: 600), app: "Safari")
        let lista = [adelante, atras]
        XCTAssertEqual(GeometriaCaptura.ventana(bajo: CGPoint(x: 150, y: 150), en: lista), adelante)
        XCTAssertEqual(GeometriaCaptura.ventana(bajo: CGPoint(x: 700, y: 500), en: lista), atras)
        XCTAssertNil(GeometriaCaptura.ventana(bajo: CGPoint(x: 900, y: 900), en: lista))
    }

    func testQueVentanasSeOfrecen() {
        let marco = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertTrue(GeometriaCaptura.esCapturable(capa: 0, alfa: 1, marco: marco, pid: 10, propio: 99))
        XCTAssertFalse(GeometriaCaptura.esCapturable(capa: 25, alfa: 1, marco: marco, pid: 10, propio: 99))   // menú / Dock
        XCTAssertFalse(GeometriaCaptura.esCapturable(capa: 0, alfa: 0, marco: marco, pid: 10, propio: 99))    // invisible
        XCTAssertFalse(GeometriaCaptura.esCapturable(capa: 0, alfa: 1, marco: CGRect(x: 0, y: 0, width: 20, height: 300),
                                                     pid: 10, propio: 99))
        XCTAssertFalse(GeometriaCaptura.esCapturable(capa: 0, alfa: 1, marco: marco, pid: 99, propio: 99))    // de Alero
    }

    func testLupaYCartelNoSeSalen() {
        let pantalla = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tam = CGSize(width: 120, height: 120)
        // En el medio: abajo a la derecha del puntero.
        XCTAssertEqual(GeometriaCaptura.junto(a: CGPoint(x: 500, y: 400), tamano: tam, separacion: 20, limites: pantalla),
                       CGPoint(x: 520, y: 260))
        // Contra la esquina de abajo a la derecha: se pasa arriba a la izquierda.
        XCTAssertEqual(GeometriaCaptura.junto(a: CGPoint(x: 950, y: 50), tamano: tam, separacion: 20, limites: pantalla),
                       CGPoint(x: 810, y: 70))
        // Selección pegada abajo: el cartel entra adentro.
        let cartel = GeometriaCaptura.cartelMedidas(seleccion: CGRect(x: 100, y: 0, width: 300, height: 200),
                                                    tamano: CGSize(width: 90, height: 22), limites: pantalla)
        XCTAssertEqual(cartel, CGPoint(x: 310, y: 8))
    }

    func testNombreDeArchivoConFechaYHora() {
        let zona = TimeZone(identifier: "America/Argentina/Buenos_Aires")!
        // 31/10/2026 23:05:09 en Buenos Aires = 1 de noviembre 02:05:09 UTC.
        let fecha = Date(timeIntervalSince1970: 1_793_498_709)
        XCTAssertEqual(NombreCaptura.nombre(fecha: fecha, formato: .png, castellano: true, zona: zona),
                       "Captura 2026-10-31 a las 23.05.09.png")
        XCTAssertEqual(NombreCaptura.nombre(fecha: fecha, formato: .jpg, castellano: false, zona: zona),
                       "Screenshot 2026-10-31 at 23.05.09.jpg")
        // Dos capturas en el mismo segundo no se pisan (misma regla que cortar y pegar).
        let libre = MoverArchivos.nombreLibre("Captura 2026-10-31 a las 23.05.09.png") { $0 == "Captura 2026-10-31 a las 23.05.09.png" }
        XCTAssertEqual(libre, "Captura 2026-10-31 a las 23.05.09 2.png")
    }

    func testFormatoPorExtension() {
        XCTAssertEqual(FormatoCaptura.de(URL(fileURLWithPath: "/tmp/a.JPEG")), .jpg)
        XCTAssertEqual(FormatoCaptura.de(URL(fileURLWithPath: "/tmp/a.png")), .png)
    }

    func testAtajoDeFabricaYSinAtajo() {
        let fabrica = AtajoTeclado.capturaPorDefecto
        XCTAssertEqual(fabrica.flags, [.maskShift, .maskCommand])
        XCTAssertEqual(fabrica.teclaSola, "2")
        XCTAssertEqual(AtajoTeclado.leer(AtajoTeclado.datos(fabrica)), fabrica)
        // "Sin atajo" se guarda vacío y se lee como nil (no vuelve el de fábrica).
        XCTAssertNil(AtajoTeclado.leer(AtajoTeclado.datos(nil)))
        XCTAssertEqual(AtajoTeclado(codigo: 122, modificadores: 0, texto: "F1").teclaSola, "F1")
    }

    func testModificadorasParaCarbon() {
        XCTAssertEqual(AtajosGlobales.modificadorasCarbon([.maskShift, .maskCommand]), 0x0100 | 0x0200)
        XCTAssertEqual(AtajosGlobales.modificadorasCarbon([.maskControl, .maskAlternate]), 0x1000 | 0x0800)
        XCTAssertEqual(AtajosGlobales.modificadorasCarbon([]), 0)
    }
}
