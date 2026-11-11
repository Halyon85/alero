import SwiftUI
import XCTest
@testable import Alero

// Avisos de reunión: 5 minutos antes de cada evento con hora, una sola vez, y nunca con el calendario del notch
// apagado (la opción promete "tus próximas reuniones y un aviso 5 minutos antes": apagada, ni lo uno ni lo otro).
// Antes el aviso salía igual con la opción apagada (auditoría del 01/11/2026).

final class CalendarioTests: XCTestCase {
    private let ahora = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func evento(_ id: String, en minutos: Double, todoElDia: Bool = false) -> Evento {
        let inicio = ahora.addingTimeInterval(minutos * 60)
        return Evento(id: id, titulo: id, inicio: inicio, fin: inicio.addingTimeInterval(1800), todoElDia: todoElDia,
                      color: .blue, enlace: nil)
    }

    func testConLaOpcionApagadaNoAvisaNada() {
        let eventos = [evento("pronto", en: 4)]
        XCTAssertTrue(Calendario.porAvisar(eventos, avisados: [], ahora: ahora, prendido: false).isEmpty)
    }

    func testAvisaLoQueEmpiezaEnCincoMinutosUnaSolaVez() {
        let eventos = [evento("pronto", en: 4), evento("lejos", en: 10), evento("feriado", en: 2, todoElDia: true),
                       evento("ya avisado", en: 3), evento("empezo hace rato", en: -2)]
        let avisar = Calendario.porAvisar(eventos, avisados: ["ya avisado"], ahora: ahora, prendido: true)
        XCTAssertEqual(avisar.map(\.id), ["pronto"])
    }

    // Elegir calendarios (11/11/2026): un evento que está en dos calendarios aparecía dos veces y no había cómo sacar uno.
    func testLosCalendariosApagadosNoSeMuestran() {
        XCTAssertTrue(Calendario.seMuestra("google", ocultos: []))
        XCTAssertFalse(Calendario.seMuestra("icloud", ocultos: ["icloud"]))
        XCTAssertTrue(Calendario.seMuestra("google", ocultos: ["icloud"]))
        XCTAssertTrue(Calendario.seMuestra(nil, ocultos: ["icloud"]))
    }
}
