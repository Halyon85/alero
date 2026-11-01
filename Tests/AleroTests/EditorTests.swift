import CoreGraphics
import XCTest
@testable import Alero

// Editor de capturas: deshacer, recortar, que lo exportado mida lo recortado y tenga las marcas, la sombra de las
// ventanas y que el archivo guarde su densidad (144 ppp en Retina). Con imágenes armadas acá, sin pantalla.

final class EditorTests: XCTestCase {
    /// Imagen lisa de `ancho` × `alto` píxeles (gris claro).
    private func imagen(_ ancho: Int, _ alto: Int, alfa: CGImageAlphaInfo = .premultipliedLast) -> CGImage {
        let ctx = ImagenCaptura.contexto(CGSize(width: ancho, height: alto), como: nil, alfa: alfa)!
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ancho, height: alto))
        return ctx.makeImage()!
    }

    /// Color del píxel (x, y) contando desde arriba, como componentes de 0 a 255.
    private func pixel(_ imagen: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(imagen, in: CGRect(x: -x, y: -(imagen.height - 1 - y), width: imagen.width, height: imagen.height))
        let datos = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { datos[$0] }
    }

    func testDeshacerVuelveAlPasoAnterior() {
        let modelo = ModeloEditor(imagen: imagen(200, 100), escala: 2, url: nil)
        XCTAssertFalse(modelo.puedeDeshacer)
        modelo.sumar(.rectangulo(CGRect(x: 10, y: 10, width: 50, height: 30), color: .rojo))
        modelo.recortar(CGRect(x: 0, y: 0, width: 120, height: 80))
        XCTAssertEqual(modelo.edicion.anotaciones.count, 1)
        XCTAssertEqual(modelo.visible, CGRect(x: 0, y: 0, width: 120, height: 80))
        modelo.deshacer()
        XCTAssertNil(modelo.edicion.recorte)
        XCTAssertEqual(modelo.edicion.anotaciones.count, 1)
        modelo.deshacer()
        XCTAssertTrue(modelo.edicion.anotaciones.isEmpty)
        XCTAssertFalse(modelo.puedeDeshacer)
    }

    func testUnRecorteChiquitoOAfueraNoCuenta() {
        let modelo = ModeloEditor(imagen: imagen(200, 100), escala: 2, url: nil)
        modelo.recortar(CGRect(x: 10, y: 10, width: 3, height: 40))
        XCTAssertNil(modelo.edicion.recorte)
        // Arrastrado al revés y pasado del borde: se normaliza y se recorta a la imagen.
        modelo.recortar(CGRect(x: 190, y: 90, width: -60, height: 50))
        XCTAssertEqual(modelo.edicion.recorte, CGRect(x: 130, y: 90, width: 60, height: 10))
        // Un segundo recorte no se puede salir del primero.
        modelo.recortar(CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(modelo.visible, CGRect(x: 130, y: 90, width: 60, height: 10))
    }

    func testExportarMideLoRecortadoYLlevaLasMarcas() throws {
        let modelo = ModeloEditor(imagen: imagen(200, 100), escala: 1, url: nil)
        modelo.color = .negro
        // Un rectángulo arriba a la izquierda (origen arriba, en píxeles de la imagen).
        modelo.sumar(.rectangulo(CGRect(x: 20, y: 10, width: 60, height: 40), color: .negro))
        modelo.recortar(CGRect(x: 10, y: 0, width: 100, height: 60))
        let final = try XCTUnwrap(modelo.exportar())
        XCTAssertEqual(final.width, 100)
        XCTAssertEqual(final.height, 60)
        // El borde de arriba del rectángulo (y = 10) cae en x = 50 - 10 del recorte: oscuro. El medio sigue gris.
        XCTAssertLessThan(pixel(final, 40, 10)[0], 80)
        XCTAssertGreaterThan(pixel(final, 40, 30)[0], 200)
    }

    func testSombraDeVentanaAgrandaElLienzo() throws {
        let ventana = imagen(300, 200)
        let conSombra = try XCTUnwrap(ImagenCaptura.conSombra(ventana, escala: 2))
        let margen = GeometriaCaptura.margenesSombra(escala: 2)
        XCTAssertEqual(conSombra.width, 300 + Int(2 * margen.lado))
        XCTAssertEqual(conSombra.height, 200 + Int(margen.arriba + margen.abajo))
        // La esquina queda transparente; el medio, la ventana.
        XCTAssertEqual(pixel(conSombra, 0, 0)[3], 0)
        XCTAssertEqual(pixel(conSombra, conSombra.width / 2, conSombra.height / 2)[3], 255)
    }

    func testCopiaRecortadaNoDependeDeLaFotoGrande() throws {
        let grande = imagen(400, 300)
        let parte = try XCTUnwrap(ImagenCaptura.copia(grande, recorte: CGRect(x: 10, y: 20, width: 30, height: 40)))
        XCTAssertEqual(parte.width, 30)
        XCTAssertEqual(parte.height, 40)
        // Es una imagen nueva con su propia memoria (no un recorte que mantenga viva la foto entera).
        XCTAssertEqual(parte.bytesPerRow >= 30 * 4, true)
        XCTAssertLessThan(parte.bytesPerRow, grande.bytesPerRow)
    }

    func testArchivoGuardaLaDensidadYSeLeeIgual() throws {
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent("alero-pruebas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: carpeta) }
        for formato in FormatoCaptura.allCases {
            let datos = try XCTUnwrap(ImagenCaptura.codificar(imagen(64, 32), formato: formato, escala: 2))
            let url = carpeta.appendingPathComponent("prueba.\(formato.extensionArchivo)")
            try datos.write(to: url)
            let leida = try XCTUnwrap(ImagenCaptura.leer(url))
            XCTAssertEqual(leida.escala, 2, "\(formato)")
            XCTAssertEqual(leida.imagen.width, 64)
            XCTAssertNotNil(ImagenCaptura.miniatura(de: datos, escala: 2))
        }
    }
}
