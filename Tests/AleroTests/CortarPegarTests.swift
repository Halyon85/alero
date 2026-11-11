import XCTest
@testable import Alero

// Mover archivos al pegar: que no pise nada (nombre 2, nombre 3…), que no meta una carpeta dentro de sí misma y que
// lo que ya está en la carpeta no se toque. Usa una carpeta temporal que se borra al terminar.

final class CortarPegarTests: XCTestCase {
    private var raiz: URL!

    override func setUpWithError() throws {
        raiz = FileManager.default.temporaryDirectory.appendingPathComponent("alero-pruebas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raiz.appendingPathComponent("destino"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: raiz)
    }

    private func archivo(_ ruta: String, _ texto: String = "hola") throws -> URL {
        let url = raiz.appendingPathComponent(ruta)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(texto.utf8).write(to: url)
        return url
    }

    func testNombreLibre() {
        let ocupados: Set<String> = ["foto.jpg", "foto 2.jpg", "Carpeta", ".zshrc"]
        XCTAssertEqual(MoverArchivos.nombreLibre("nuevo.txt") { ocupados.contains($0) }, "nuevo.txt")
        XCTAssertEqual(MoverArchivos.nombreLibre("foto.jpg") { ocupados.contains($0) }, "foto 3.jpg")
        XCTAssertEqual(MoverArchivos.nombreLibre("Carpeta") { ocupados.contains($0) }, "Carpeta 2")
        XCTAssertEqual(MoverArchivos.nombreLibre(".zshrc") { ocupados.contains($0) }, ".zshrc 2")
    }

    func testMueveSinPisar() throws {
        let destino = raiz.appendingPathComponent("destino", isDirectory: true)
        _ = try archivo("destino/nota.txt", "la que ya estaba")
        let nota = try archivo("origen/nota.txt", "la nueva")
        let otra = try archivo("origen/otra.txt")
        let resultado = MoverArchivos.mover([nota, otra], a: destino)
        XCTAssertEqual(resultado.movidos, 2)
        XCTAssertTrue(resultado.fallidos.isEmpty)
        XCTAssertEqual(try String(contentsOf: destino.appendingPathComponent("nota.txt"), encoding: .utf8), "la que ya estaba")
        XCTAssertEqual(try String(contentsOf: destino.appendingPathComponent("nota 2.txt"), encoding: .utf8), "la nueva")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nota.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destino.appendingPathComponent("otra.txt").path))
    }

    func testNoMeteUnaCarpetaDentroDeSiMisma() throws {
        let carpeta = raiz.appendingPathComponent("origen", isDirectory: true)
        _ = try archivo("origen/adentro/a.txt")
        let resultado = MoverArchivos.mover([carpeta], a: carpeta.appendingPathComponent("adentro", isDirectory: true))
        XCTAssertEqual(resultado.movidos, 0)
        XCTAssertEqual(resultado.fallidos.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: carpeta.appendingPathComponent("adentro/a.txt").path))
    }

    func testLoQueYaEstaEnLaCarpetaNoSeToca() throws {
        let destino = raiz.appendingPathComponent("destino", isDirectory: true)
        let nota = try archivo("destino/nota.txt")
        let resultado = MoverArchivos.mover([nota], a: destino)
        XCTAssertEqual(resultado.movidos, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destino.appendingPathComponent("nota 2.txt").path))
    }

    func testErrorDePermiso() {
        let sinPermiso = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let posix = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertTrue(MoverArchivos.esDePermiso(sinPermiso))
        XCTAssertTrue(MoverArchivos.esDePermiso(posix))
        XCTAssertFalse(MoverArchivos.esDePermiso(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    // La letra de ⌘X y ⌘V se lee del propio evento, sin preguntarle al teclado de macOS: eso solo se puede en el hilo
    // principal y, desde el hilo de eventos, cerraba la app de vez en cuando (09/11 y 11/11/2026). Se prueba acá desde
    // otro hilo, como corre de verdad.
    func testLaLetraSeLeeDelEventoDesdeCualquierHilo() {
        let listo = expectation(description: "leída fuera del hilo principal")
        DispatchQueue.global().async {
            for (texto, esperada) in [("x", "x"), ("V", "v")] {
                guard let evento = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
                let letras = Array(texto.utf16)
                evento.keyboardSetUnicodeString(stringLength: letras.count, unicodeString: letras)
                XCTAssertEqual(CortarPegar.letra(evento), esperada)
            }
            listo.fulfill()
        }
        wait(for: [listo], timeout: 5)
    }
}
