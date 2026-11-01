import XCTest
@testable import Alero

// Cómo el teleprompter sigue la voz: palabras normalizadas, avanzar sin saltar por palabras cortas y nunca volver.

final class PrompterTests: XCTestCase {
    func testPalabrasNormalizadas() {
        XCTAssertEqual(ReglasPrompter.palabras("¡Hola, amigos! ¿Cómo están? — Bien."), ["hola", "amigos", "como", "estan", "bien"])
    }

    func testAvanzaConLoQueSeDice() {
        let guion = ReglasPrompter.palabras("Hola amigos, hoy vengo a presentarles esta aplicación de la casa")
        XCTAssertEqual(ReglasPrompter.avanzar(0, guion: guion, dichas: ["hola", "amigos"]), 2)
        XCTAssertEqual(ReglasPrompter.avanzar(2, guion: guion, dichas: ["vengo"]), 4, "salteó una palabra: igual avanza")
        XCTAssertEqual(ReglasPrompter.avanzar(4, guion: guion, dichas: ["presentarles", "esta", "aplicacion"]), 8)
    }

    func testPalabraCortaNecesitaLaAnterior() {
        let guion = ReglasPrompter.palabras("la casa de la playa y de la montaña")
        XCTAssertEqual(ReglasPrompter.avanzar(0, guion: guion, dichas: ["de"]), 0, "un 'de' suelto no mueve el guion")
        XCTAssertEqual(ReglasPrompter.avanzar(0, guion: guion, dichas: ["casa", "de"]), 3)
    }

    func testNuncaVuelveNiSeVaLejos() {
        let guion = ReglasPrompter.palabras(Array(repeating: "uno", count: 3).joined(separator: " ") + " " + Array(repeating: "x", count: 20).joined(separator: " ") + " lejos")
        XCTAssertEqual(ReglasPrompter.avanzar(5, guion: guion, dichas: ["uno"]), 5, "no vuelve para atrás")
        XCTAssertEqual(ReglasPrompter.avanzar(3, guion: guion, dichas: ["lejos"]), 3, "más de 12 palabras adelante no salta")
    }
}
