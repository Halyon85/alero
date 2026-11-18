import XCTest
@testable import Alero

// «Abrir al iniciar sesión» tiene que abrir la copia de Aplicaciones. El 17/11/2026 el arranque había quedado
// apuntando a una copia vieja en otro disco, con otra firma, y macOS volvía a pedir los permisos en cada reinicio.

final class InicioSesionTests: XCTestCase {
    private let instalada = "/Applications/Alero.app"
    private let casa = "/Users/ana"

    func testCorrigeSiElArranqueLoRegistroOtraCopia() {
        XCTAssertTrue(InicioSesion.hayQueCorregir(prendido: true, ruta: instalada,
                                                  registradaEn: "/Volumes/Disco/Notch/build/Alero.app", casa: casa))
    }

    func testCorrigeUnaVezSiVieneDeUnaVersionQueNoAnotabaLaRuta() {
        XCTAssertTrue(InicioSesion.hayQueCorregir(prendido: true, ruta: instalada, registradaEn: nil, casa: casa))
    }

    func testNoTocaNadaSiYaApuntaAEstaCopia() {
        XCTAssertFalse(InicioSesion.hayQueCorregir(prendido: true, ruta: instalada, registradaEn: instalada, casa: casa))
    }

    func testNoPrendeElArranqueSiLaPersonaLoTieneApagado() {
        XCTAssertFalse(InicioSesion.hayQueCorregir(prendido: false, ruta: instalada, registradaEn: nil, casa: casa))
    }

    func testUnaCopiaDePruebaNoLeSacaElArranqueALaInstalada() {
        let dePrueba = "/Volumes/Disco/Alero-github/build/Alero.app"
        XCTAssertFalse(InicioSesion.hayQueCorregir(prendido: true, ruta: dePrueba, registradaEn: instalada, casa: casa))
    }

    func testLaCarpetaAplicacionesDeLaPersonaTambienCuenta() {
        XCTAssertTrue(InicioSesion.estaInstalada("/Users/ana/Applications/Alero.app", casa: casa))
        XCTAssertFalse(InicioSesion.estaInstalada("/Users/ana/Downloads/Alero.app", casa: casa))
    }
}
