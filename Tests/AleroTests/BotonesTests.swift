import CoreGraphics
import XCTest
@testable import Alero

// Botones del mouse: cómo se muestra un atajo grabado, qué ítem de menú es "Atrás" y que lo guardado se lea igual.

final class BotonesTests: XCTestCase {
    func testTextoDelAtajoEnElOrdenDeMacOS() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        XCTAssertEqual(AtajoTeclado.texto(flags: flags, tecla: "T"), "⌃⌥⇧⌘T")
        XCTAssertEqual(AtajoTeclado.texto(flags: .maskCommand, tecla: "←"), "⌘←")
    }

    func testNombreDeLasTeclas() {
        XCTAssertEqual(AtajoTeclado.nombreTecla(codigo: 0, caracteres: "a"), "A")
        XCTAssertEqual(AtajoTeclado.nombreTecla(codigo: 123, caracteres: "\u{F702}"), "←")
        XCTAssertEqual(AtajoTeclado.nombreTecla(codigo: 122, caracteres: nil), "F1")
        XCTAssertEqual(AtajoTeclado.nombreTecla(codigo: 200, caracteres: ""), "#200")
        XCTAssertTrue(AtajoTeclado.esTeclaDeFuncion(111))   // F12
        XCTAssertFalse(AtajoTeclado.esTeclaDeFuncion(123))  // flecha
    }

    func testLasModificadorasExtraNoSeGuardan() {
        // macOS le suma "Fn" y "teclado numérico" a las flechas: al mandar el atajo solo van las cuatro de siempre.
        let crudo = CGEventFlags([.maskCommand, .maskSecondaryFn, .maskNumericPad]).rawValue
        let atajo = AtajoTeclado(codigo: 123, modificadores: crudo, texto: "⌘←")
        XCTAssertEqual(atajo.flags, .maskCommand)
    }

    func testItemDeMenuAtras() {
        XCTAssertTrue(MenuApp.coincide(caracter: "[", modificadores: 0, buscado: "["))
        XCTAssertTrue(MenuApp.coincide(caracter: "[", modificadores: nil, buscado: "["))
        XCTAssertFalse(MenuApp.coincide(caracter: "[", modificadores: 1, buscado: "["))  // ⇧⌘[ = otra pestaña
        XCTAssertFalse(MenuApp.coincide(caracter: "]", modificadores: 0, buscado: "["))
        XCTAssertFalse(MenuApp.coincide(caracter: nil, modificadores: 0, buscado: "["))
    }

    func testAtajoSinGrabarNoHaceNada() {
        XCTAssertEqual(ConfigBoton(accion: .atajo, atajo: nil).efectiva, .nada)
        XCTAssertEqual(ConfigBoton(accion: .atras).efectiva, .atras)
    }

    func testLoGuardadoSeLeeIgual() {
        let original = ConfigBoton(accion: .atajo, atajo: AtajoTeclado(codigo: 17, modificadores: CGEventFlags.maskCommand.rawValue, texto: "⌘T"))
        XCTAssertEqual(ConfigBoton.leer(original.datos(), siNo: ConfigBoton()), original)
        // Datos rotos o de una versión vieja: vuelve lo de fábrica en vez de romper.
        XCTAssertEqual(ConfigBoton.leer(Data("{}x".utf8), siNo: ConfigBoton(accion: .atras)), ConfigBoton(accion: .atras))
    }

    func testTeclaQueEscribeEnLaDistribucionActual() {
        // Vale en cualquier distribución latina: la A se escribe sola.
        XCTAssertEqual(Teclado.teclaQueEscribe("a")?.base, "a")
        // Con el teclado latinoamericano "[" pide ⇧ y la tecla sola escribe "{": así figura ⌘[ en los menús.
        if let corchete = Teclado.teclaQueEscribe("[") { print("Tecla de [: \(corchete.codigo), sola escribe \(corchete.base)") }
    }
}
