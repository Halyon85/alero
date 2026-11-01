import XCTest
@testable import Alero

// "Limpiar la Mac": qué cachés se ofrecen y cuáles nunca, registros viejos, Xcode, Homebrew, instaladores y capturas.
// Se arma una carpeta de persona de mentira en una carpeta temporal y se escanea esa (solo lectura).

final class LimpiadorTests: XCTestCase {
    private var c: CarpetaPrueba!

    override func setUpWithError() throws { c = try CarpetaPrueba() }
    override func tearDown() { c.borrar() }

    func testCachesQueSeOfrecenYCualesNo() {
        let nada: Set<String> = []
        XCTAssertEqual(ReglasLimpieza.decidirCache("com.google.Chrome", abiertas: nada), .mostrar(elegida: true, nota: nil))
        XCTAssertEqual(ReglasLimpieza.decidirCache("pip", abiertas: nada), .mostrar(elegida: true, nota: nil))
        if case .mostrar(let elegida, _) = ReglasLimpieza.decidirCache("ms-playwright", abiertas: nada) { XCTAssertFalse(elegida) } else { XCTFail() }
        // Nunca: Apple, iCloud, sonido, sesiones, licencias de audio, Spotify, Homebrew (tiene su categoría) y nombres comunes.
        for nombre in ["com.apple.Safari", "CloudKit", "com.apple.bird", "FontRegistry", "com.apple.akd", "com.paceap.eden",
                       "com.native-instruments.NativeAccess", "com.fabfilter.Pro-Q.3", "com.spotify.client", "Homebrew",
                       "Carpeta Cualquiera", ".oculta", "team.halyon.alero", "Spotify"] {
            XCTAssertEqual(ReglasLimpieza.decidirCache(nombre, abiertas: nada), .ocultar, nombre)
        }
        // La app abierta: se muestra sin tildar (también su ayudante).
        if case .mostrar(let elegida, let nota) = ReglasLimpieza.decidirCache("com.tinyspeck.slackmacgap.ShipIt",
                                                                               abiertas: ["com.tinyspeck.slackmacgap"]) {
            XCTAssertFalse(elegida)
            XCTAssertNotNil(nota)
        } else { XCTFail() }
    }

    func testPareceIdentificador() {
        XCTAssertTrue(ReglasLimpieza.pareceIdentificador("com.foo.App"))
        XCTAssertTrue(ReglasLimpieza.pareceIdentificador("org.mozilla.firefox"))
        XCTAssertFalse(ReglasLimpieza.pareceIdentificador("Firefox"))
        XCTAssertFalse(ReglasLimpieza.pareceIdentificador("com..foo"))
        XCTAssertFalse(ReglasLimpieza.pareceIdentificador("com.foo bar"))
        XCTAssertFalse(ReglasLimpieza.pareceIdentificador(".com.foo"))
        XCTAssertFalse(ReglasLimpieza.pareceIdentificador("com.fóo.app"))
    }

    func testNombresDeCaptura() {
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Captura de pantalla 2026-09-02 a la(s) 10.14.22.png").original, true)
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Screenshot 2026-09-02 at 10.14.22.png").original, true)
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Screen Shot 2020-01-02 at 9.04.11 PM.png").original, true)
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Captura 2026-09-02 a las 10.14.22.png").deAlero, true)
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Captura de pantalla 2026-09-02 a la(s) 10.14.22.png").deAlero, false)
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Factura de la luz.png").original, false)
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Screenshot 2026-09-02 at 10.14.22 logo final.png").original, false)
        XCTAssertEqual(ReglasLimpieza.nombreDeCaptura("Screenshot 2026-09-02 at 10.14.22.pdf").original, false)
    }

    func testEsViejoUsaElCalendario() {
        let ahora = Date()
        let hace40 = Calendar.current.date(byAdding: .day, value: -40, to: ahora)!
        let hace3 = Calendar.current.date(byAdding: .day, value: -3, to: ahora)!
        XCTAssertTrue(ReglasLimpieza.esViejo(hace40, dias: 30, ahora: ahora))
        XCTAssertFalse(ReglasLimpieza.esViejo(hace3, dias: 30, ahora: ahora))
        XCTAssertFalse(ReglasLimpieza.esViejo(nil, dias: 30, ahora: ahora))
    }

    func testEscaneoDeUnaCasaDeMentira() throws {
        // Cachés
        try c.archivo("casa/Library/Caches/com.foo.App/datos.bin", "x")
        try c.archivo("casa/Library/Caches/com.apple.Safari/datos.bin", "x")
        try c.archivo("casa/Library/Caches/CloudKit/datos.bin", "x")
        try c.archivo("casa/Library/Caches/Cosas Mias/datos.bin", "x")
        try c.archivo("casa/Library/Caches/pip/http/x", "x")
        try c.carpeta("casa/Library/Caches/com.vacia.App")                  // vacía: no libera nada
        try c.archivo("afuera/importante.txt")
        try c.enlace("casa/Library/Caches/com.enlace.App", a: c.ruta("afuera"))
        // Homebrew
        try c.archivo("casa/Library/Caches/Homebrew/downloads/abc--cmake.bottle.tar.gz", "x")
        try c.archivo("casa/Library/Caches/Homebrew/api/formula.jws.json", "x")
        // Registros: uno viejo, uno nuevo, una carpeta con algo nuevo adentro y un reporte viejo
        try c.archivo("casa/Library/Logs/viejo.log", "x", dias: 40)
        try c.archivo("casa/Library/Logs/nuevo.log", "x", dias: 1)
        try c.archivo("casa/Library/Logs/App/hoy.log", "x", dias: 0)
        try c.archivo("casa/Library/Logs/DiagnosticReports/Safari.ips", "x", dias: 30)
        // Xcode
        try c.archivo("casa/Library/Developer/Xcode/DerivedData/Alero-abc/Build/x.o", "x")
        try c.archivo("casa/Library/Developer/Xcode/iOS DeviceSupport/18.0/x", "x")
        try c.archivo("casa/Library/Developer/Xcode/Archives/2026-10-01/App.xcarchive/x", "x") // nunca
        // Descargas
        try c.archivo("casa/Downloads/Viejo.dmg", "x", dias: 60)
        try c.archivo("casa/Downloads/Nuevo.dmg", "x", dias: 2)
        try c.archivo("casa/Downloads/Contrato.pdf", "x", dias: 90)
        // Escritorio: una captura de Alero vieja, una de macOS sin la marca (no cuenta), una renombrada y una nueva
        try c.archivo("casa/Desktop/Captura 2026-01-02 a las 10.11.12.png", "x", dias: 60)
        try c.archivo("casa/Desktop/Screenshot 2026-01-02 at 10.11.12.png", "x", dias: 60)
        try c.archivo("casa/Desktop/Logo final.png", "x", dias: 60)
        try c.archivo("casa/Desktop/Captura 2026-10-30 a las 10.11.12.png", "x", dias: 1)

        let casa = c.ruta("casa")
        var opciones = EscanerLimpieza.Opciones(home: casa, abiertas: [], carpetasCapturas: [casa + "/Desktop"])
        opciones.fechaDeLlegada = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        let lista = EscanerLimpieza.escanear(opciones, cancelacion: Cancelacion())
        let nombres = Dictionary(grouping: lista, by: \.categoria).mapValues { Set($0.map(\.nombre)) }

        XCTAssertEqual(nombres[.caches], ["com.foo.App", "pip"])
        XCTAssertEqual(nombres[.homebrew], ["downloads"])
        XCTAssertEqual(nombres[.registros], ["viejo.log", "Safari.ips"])
        XCTAssertEqual(nombres[.xcode], ["Alero-abc", "18.0"])
        XCTAssertEqual(nombres[.instaladores], ["Viejo.dmg"])
        XCTAssertEqual(nombres[.capturas], ["Captura 2026-01-02 a las 10.11.12.png"])
        // Lo de la persona viene sin tildar; las cachés, tildadas.
        XCTAssertTrue(lista.filter { $0.categoria == .caches }.allSatisfy(\.elegido))
        XCTAssertTrue(lista.filter { $0.categoria == .instaladores || $0.categoria == .capturas }.allSatisfy { !$0.elegido })
        XCTAssertFalse(lista.first { $0.nombre == "18.0" }!.elegido)
        // Cada candidato pasa la revisión final tal como quedó escaneado.
        for candidato in lista { XCTAssertNil(ReglasBorrado.revisar(candidato.elemento, home: casa), candidato.nombre) }
    }

    func testCarpetaRaizEnlazadaNoSeEscanea() throws {
        try c.archivo("otra/com.foo.App/x", "x")
        try c.carpeta("casa/Library")
        try c.enlace("casa/Library/Caches", a: c.ruta("otra"))
        let opciones = EscanerLimpieza.Opciones(home: c.ruta("casa"))
        XCTAssertTrue(EscanerLimpieza.escanear(opciones, cancelacion: Cancelacion()).isEmpty)
    }

    func testCancelarFrena() throws {
        try c.archivo("casa/Library/Caches/com.foo.App/x", "x")
        let cancelacion = Cancelacion()
        cancelacion.cancelar()
        XCTAssertTrue(EscanerLimpieza.escanear(EscanerLimpieza.Opciones(home: c.ruta("casa")), cancelacion: cancelacion).isEmpty)
    }
}
