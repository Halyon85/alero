import XCTest
@testable import Alero

// Las cuentas del estado de la Mac y lo que se saca de los registros de Claude Code y Codex, sin el kernel ni archivos.

final class EstadoYAgentesTests: XCTestCase {
    func testUsoDelProcesador() {
        let antes: ReglasEstadoMac.Ticks = (100, 50, 850, 0)
        let ahora: ReglasEstadoMac.Ticks = (160, 70, 870, 0)
        XCTAssertEqual(ReglasEstadoMac.uso(antes: antes, ahora: ahora), 0.8, accuracy: 0.0001)
        XCTAssertEqual(ReglasEstadoMac.uso(antes: antes, ahora: antes), 0, "sin tiempo transcurrido da 0")
    }

    func testMemoriaUsadaComoElMonitor() {
        // 10 internas − 2 purgables + 3 fijas + 1 comprimida = 12 páginas de 16 KB.
        XCTAssertEqual(ReglasEstadoMac.usada(internas: 10, purgables: 2, fijas: 3, comprimidas: 1, pagina: 16_384), 12 * 16_384)
        XCTAssertEqual(ReglasEstadoMac.usada(internas: 1, purgables: 5, fijas: 0, comprimidas: 0, pagina: 16_384), 0)
    }

    func testProyectoDelUltimoCwd() {
        let texto = #"{"cwd":"/Users/x/viejo"}"# + "\n" + #"{"type":"user","cwd":"\/Volumes\/Mi Disco\/Proyecto","x":1}"#
        XCTAssertEqual(ReglasAgentes.proyecto(en: texto), "Proyecto")
        XCTAssertNil(ReglasAgentes.proyecto(en: "nada"))
    }

    func testCupoDeCodex() {
        let linea = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":47.0,"window_minutes":10080,"resets_at":1793819612},"secondary":null}}}"#
        let cupo = ReglasAgentes.cupoCodex(en: "basura\n" + linea + "\n{\"type\":\"otro\"}")
        XCTAssertEqual(cupo?.usado ?? 0, 0.47, accuracy: 0.0001)
        XCTAssertEqual(cupo?.nombre, "semana")
        XCTAssertEqual(cupo?.reinicia, Date(timeIntervalSince1970: 1_793_819_612))
        XCTAssertNil(ReglasAgentes.cupoCodex(en: #"{"payload":{"rate_limits":null}}"#))
    }

    func testTrabajandoSoloSiEscribioRecien() {
        let ahora = Date()
        XCTAssertTrue(EstadoAgente(ultimo: ahora.addingTimeInterval(-5)).trabajando(ahora))
        XCTAssertFalse(EstadoAgente(ultimo: ahora.addingTimeInterval(-60)).trabajando(ahora))
        XCTAssertFalse(EstadoAgente().trabajando(ahora))
    }
}

final class CupoClaudeTests: XCTestCase {
    func testCuposDeLaBarraDeEstado() {
        let json = #"{"session_id":"x","rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1793819612},"seven_day":{"used_percentage":40,"resets_at":"2026-11-04T10:00:00Z"}}}"#
        let cupos = ReglasAgentes.cuposClaude(en: Data(json.utf8))
        XCTAssertEqual(cupos.count, 2)
        XCTAssertEqual(cupos.first?.usado ?? 0, 0.125, accuracy: 0.0001)
        XCTAssertEqual(cupos.first?.reinicia, Date(timeIntervalSince1970: 1_793_819_612))
        XCTAssertEqual(cupos.last?.usado ?? 0, 0.40, accuracy: 0.0001)
        XCTAssertNotNil(cupos.last?.reinicia, "la fecha ISO también se entiende")
        XCTAssertTrue(ReglasAgentes.cuposClaude(en: Data(#"{"model":"x"}"#.utf8)).isEmpty, "sin cupo (plan sin suscripción): nada")
    }
}

final class AvisosYCafeTests: XCTestCase {
    func testDescargasTerminadas() {
        let antes: Set = ["viejo.pdf"]
        let ahora: Set = ["viejo.pdf", "nuevo.zip", "bajando.crdownload", "safari.download", ".DS_Store", "foto.PART"]
        XCTAssertEqual(ReglasAvisos.terminadas(antes: antes, ahora: ahora), ["nuevo.zip"])
        XCTAssertEqual(ReglasAvisos.terminadas(antes: ["a.crdownload"], ahora: ["a"]), ["a"], "al terminar cambia de nombre")
    }

    func testGuionDeLaTapaSoloConDatosPropios() {
        let guion = CafeTapa.guion(pid: 123)
        XCTAssertTrue(guion.hasPrefix("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1;"), "sin pedir contraseña: solo con la regla")
        XCTAssertTrue(guion.hasSuffix("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"), "siempre termina volviendo a la normalidad")
        XCTAssertTrue(guion.contains("kill -0 123"))
        XCTAssertFalse(guion.contains("\""), "sin comillas dobles: va adentro de un texto de AppleScript")
    }
}

final class ChatAgentesTests: XCTestCase {
    func testChatDeClaude() {
        let cabeza = #"{"type":"agent-name","agentName":"Notch configurable"}"#
        let cola = #"{"type":"user","cwd":"/x"}"# + "\n" +
            #"{"type":"assistant","gitBranch":"main","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":714,"cache_read_input_tokens":456133,"output_tokens":482}}}"#
        let chat = ReglasAgentes.chatClaude(cola: cola, cabeza: cabeza)
        XCTAssertEqual(chat.contexto, 456_849)
        XCTAssertEqual(chat.ventana, 1_000_000)
        XCTAssertEqual(chat.rama, "main")
        XCTAssertEqual(chat.titulo, "Notch configurable", "el título puede estar al comienzo del archivo")
    }

    func testVentanaYNombreDelModelo() {
        XCTAssertEqual(ReglasAgentes.ventanaClaude(modelo: "claude-sonnet-4-5", contexto: 50_000), 200_000)
        XCTAssertEqual(ReglasAgentes.ventanaClaude(modelo: "claude-sonnet-4-5", contexto: 250_000), 1_000_000)
        XCTAssertEqual(ReglasAgentes.nombreModelo("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ReglasAgentes.nombreModelo("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ReglasAgentes.nombreModelo("gpt-5.2-codex"), "gpt-5.2-codex")
    }

    func testChatDeCodex() {
        let cola = #"{"type":"turn_context","payload":{"model":"gpt-5.2-codex"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":38816},"model_context_window":258400}}}"#
        let chat = ReglasAgentes.chatCodex(cola: cola)
        XCTAssertEqual(chat.contexto, 38_816)
        XCTAssertEqual(chat.ventana, 258_400)
        XCTAssertEqual(chat.modelo, "gpt-5.2-codex")
    }
}
