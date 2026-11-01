import CoreGraphics
import ImageIO
import XCTest
@testable import Alero

// Música: la carátula se guarda achicada al tamaño más grande en que se dibuja (no a lo que mande la app).

final class MusicaTests: XCTestCase {
    /// Un JPEG chico para las pruebas que solo necesitan una carátula cualquiera.
    static func jpegDePrueba() throws -> Data { try MusicaTests().jpeg(lado: 64) }

    /// Un JPEG cuadrado de `lado` px, como los que manda la app que está sonando.
    private func jpeg(lado: Int) throws -> Data {
        let contexto = try XCTUnwrap(CGContext(data: nil, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        contexto.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        contexto.fill(CGRect(x: 0, y: 0, width: lado, height: lado))
        let imagen = try XCTUnwrap(contexto.makeImage())
        let datos = NSMutableData()
        let destino = try XCTUnwrap(CGImageDestinationCreateWithData(datos, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destino, imagen, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destino))
        return datos as Data
    }

    func testCaratulaGrandeSeAchica() throws {
        let caratula = try XCTUnwrap(Musica.caratula(de: jpeg(lado: 1200)))
        let cg = try XCTUnwrap(caratula.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, Musica.ladoCaratula)
        XCTAssertEqual(cg.height, Musica.ladoCaratula)
        // En puntos, la mitad (se dibuja a 2×).
        XCTAssertEqual(caratula.size.width, CGFloat(Musica.ladoCaratula) / 2)
    }

    func testCaratulaChicaNoSeAgranda() throws {
        let caratula = try XCTUnwrap(Musica.caratula(de: jpeg(lado: 100)))
        XCTAssertEqual(caratula.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 100)
    }

    func testDatosQueNoSonImagen() {
        XCTAssertNil(Musica.caratula(de: Data("no es una imagen".utf8)))
    }
}

// Apagar y prender el notch (o la música) con una canción sonando: el adaptador nuevo vuelve a mandar la misma
// carátula, y antes se tomaba como "no cambió" y el notch quedaba sin carátula hasta la canción siguiente
// (auditoría del 01/11/2026).
final class MusicaReaperturaTests: XCTestCase {
    private func linea(caratula: Data) -> Data {
        let carga: [String: Any] = ["title": "Prueba", "artist": "Alero", "playing": true,
                                    "artworkData": caratula.base64EncodedString()]
        let objeto: [String: Any] = ["type": "data", "diff": false, "payload": carga]
        var datos = try! JSONSerialization.data(withJSONObject: objeto)
        datos.append(0x0A)
        return datos
    }

    private func esperar(_ musica: Musica, conCaratula: Bool) {
        let condicion = NSPredicate { _, _ in (musica.caratula != nil) == conCaratula && musica.pista != nil }
        wait(for: [expectation(for: condicion, evaluatedWith: nil)], timeout: 2)
    }

    func testLaCaratulaVuelveAlVolverAPrender() throws {
        let musica = Musica()
        let caratula = try XCTUnwrap(MusicaTests.jpegDePrueba())
        // En las pruebas no está el adaptador: arrancar solo marca que la música está prendida.
        musica.arrancar()
        musica.leer(linea(caratula: caratula))
        esperar(musica, conCaratula: true)

        musica.detener()
        XCTAssertNil(musica.caratula)
        musica.arrancar()
        musica.leer(linea(caratula: caratula))
        esperar(musica, conCaratula: true)
        musica.detener()
    }

    func testMediaLineaDelAdaptadorViejoNoEnsuciaAlNuevo() throws {
        let musica = Musica()
        let caratula = try XCTUnwrap(MusicaTests.jpegDePrueba())
        musica.arrancar()
        // El adaptador viejo se cortó a mitad de una línea.
        musica.leer(Data(#"{"type":"data","diff":false,"payload":{"title":"Vie"#.utf8))
        musica.detener()
        musica.arrancar()
        musica.leer(linea(caratula: caratula))
        esperar(musica, conCaratula: true)
        XCTAssertEqual(musica.pista?.titulo, "Prueba")
        musica.detener()
    }
}
