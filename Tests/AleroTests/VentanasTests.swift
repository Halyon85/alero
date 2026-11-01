import CoreGraphics
import XCTest
@testable import Alero

// Cuentas del clic en el Dock y del botón verde: dónde está el Dock, qué ícono se tocó, el orden de las ventanas y
// en qué pantalla vive cada una. Los números salen de una Mac real (monitor de 1700 × 956 con el Dock abajo y la
// MacBook a la derecha).

final class VentanasTests: XCTestCase {
    private let monitor = PantallaCG(marco: CGRect(x: 0, y: 0, width: 1700, height: 956),
                                     visible: CGRect(x: 0, y: 30, width: 1700, height: 848))
    private let macbook = PantallaCG(marco: CGRect(x: 1700, y: 184, width: 1280, height: 832),
                                     visible: CGRect(x: 1700, y: 212, width: 1280, height: 804))

    func testPasarDeAppKitAEventos() {
        // AppKit: origen abajo. La MacBook está 60 pt más abajo que el monitor principal (956 de alto).
        let r = Geometria.aEventos(CGRect(x: 1700, y: -60, width: 1280, height: 832), altoPrincipal: 956)
        XCTAssertEqual(r, CGRect(x: 1700, y: 184, width: 1280, height: 832))
    }

    func testFranjaDelDockSoloDondeHayReserva() {
        let franjas = Geometria.franjasDock([monitor, macbook])
        XCTAssertEqual(franjas, [FranjaDock(zona: CGRect(x: 0, y: 878, width: 1700, height: 78), horizontal: true)])
        // Dock que se oculta solo: no hay reserva y no hay franja (a propósito).
        let sinDock = PantallaCG(marco: monitor.marco, visible: CGRect(x: 0, y: 30, width: 1700, height: 922))
        XCTAssertTrue(Geometria.franjasDock([sinDock]).isEmpty)
        // Dock a la izquierda: franja vertical.
        let izquierda = PantallaCG(marco: monitor.marco, visible: CGRect(x: 70, y: 30, width: 1630, height: 926))
        XCTAssertEqual(Geometria.franjasDock([izquierda]).first?.horizontal, false)
        XCTAssertEqual(Geometria.franjasDock([izquierda]).first?.zona.width, 70)
    }

    func testIconoPorElEjeLargo() {
        // Marcos como los da macOS 27 para los íconos (56 de ancho, empiezan en y = 879).
        let marcos = [CGRect(x: 305, y: 879, width: 56, height: 72), CGRect(x: 361, y: 879, width: 56, height: 72), .null]
        XCTAssertEqual(ClicDock.indiceIcono(marcos, punto: CGPoint(x: 390, y: 930), horizontal: true), 1)
        // Aunque el marco venga corrido en el eje corto, el largo alcanza.
        XCTAssertEqual(ClicDock.indiceIcono(marcos, punto: CGPoint(x: 310, y: 800), horizontal: true), 0)
        XCTAssertNil(ClicDock.indiceIcono(marcos, punto: CGPoint(x: 200, y: 930), horizontal: true))
    }

    func testOrdenDeLasVentanasSegunElServidor() {
        let a = CGRect(x: 0, y: 30, width: 800, height: 600)
        let b = CGRect(x: 100, y: 80, width: 800, height: 600)
        let c = CGRect(x: 2000, y: 300, width: 500, height: 400)
        // Accesibilidad las da en otro orden; el servidor de ventanas dice b adelante, después a. c está en otro escritorio.
        XCTAssertEqual(VentanasApp.ordenar([a, c, b], segun: [b, a]), [2, 0])
        // Dos ventanas con el mismo marco no se emparejan dos veces con la misma.
        XCTAssertEqual(VentanasApp.ordenar([a, a], segun: [a, a]), [0, 1])
    }

    func testPantallaDeUnaVentana() {
        let entreLasDos = CGRect(x: 1500, y: 300, width: 600, height: 400) // 200 pt en el monitor, 400 en la MacBook
        XCTAssertEqual(Geometria.pantalla(de: entreLasDos, en: [monitor, macbook]), macbook)
        XCTAssertNil(Geometria.pantalla(de: CGRect(x: -900, y: 0, width: 100, height: 100), en: [monitor, macbook]))
    }

    func testZonaDelBotonVerde() {
        let ventana = CGRect(x: 200, y: 100, width: 900, height: 600)
        XCTAssertTrue(BotonVerde.enZonaDelVerde(CGPoint(x: 254, y: 114), ventana: ventana))  // barra de título común
        XCTAssertTrue(BotonVerde.enZonaDelVerde(CGPoint(x: 280, y: 126), ventana: ventana))  // barra alta de macOS 26+
        XCTAssertFalse(BotonVerde.enZonaDelVerde(CGPoint(x: 214, y: 114), ventana: ventana)) // botón rojo
        XCTAssertFalse(BotonVerde.enZonaDelVerde(CGPoint(x: 254, y: 200), ventana: ventana)) // contenido
    }

    func testMarcosParecidos() {
        let r = CGRect(x: 0, y: 30, width: 1700, height: 848)
        XCTAssertTrue(Geometria.parecidos(r, CGRect(x: 0, y: 31, width: 1697, height: 848)))
        XCTAssertFalse(Geometria.parecidos(r, CGRect(x: 0, y: 30, width: 1680, height: 848)))
    }
}
