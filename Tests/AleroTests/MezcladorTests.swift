import CoreAudio
import XCTest
@testable import Alero

// Mezclador por app: la curva del deslizador, la compensación del mixdown por canales, a qué canales va el estéreo,
// la mezcla del hilo de audio (con buffers armados a mano), a qué app pertenece un proceso, qué hacer con un motor
// colgado y los volúmenes recordados. Nada de esto toca el audio de la Mac.

final class MezcladorTests: XCTestCase {
    func testCurvaDelDeslizador() {
        XCTAssertEqual(ReglasMezclador.ganancia(deslizador: 1, silencio: false), 1)
        XCTAssertEqual(ReglasMezclador.ganancia(deslizador: 0.5, silencio: false), 0.25, accuracy: 1e-6)  // −12 dB
        XCTAssertEqual(ReglasMezclador.ganancia(deslizador: 0, silencio: false), 0)
        XCTAssertEqual(ReglasMezclador.ganancia(deslizador: 0.8, silencio: true), 0)
        // Fuera de rango no se pasa de 0…1.
        XCTAssertEqual(ReglasMezclador.ganancia(deslizador: 1.4, silencio: false), 1)
        XCTAssertEqual(ReglasMezclador.ganancia(deslizador: -1, silencio: false), 0)
    }

    func testAlCienPorCientoNoSeCreaNada() {
        XCTAssertTrue(ReglasMezclador.esNeutro(deslizador: 1, silencio: false))
        XCTAssertTrue(ReglasMezclador.esNeutro(deslizador: 0.997, silencio: false))
        XCTAssertFalse(ReglasMezclador.esNeutro(deslizador: 0.99, silencio: false))
        XCTAssertFalse(ReglasMezclador.esNeutro(deslizador: 1, silencio: true))
    }

    func testCompensacionPorCanales() {
        XCTAssertEqual(ReglasMezclador.compensacion(canales: 1), 1)   // mono: nada que compensar
        XCTAssertEqual(ReglasMezclador.compensacion(canales: 2), 1)
        XCTAssertEqual(ReglasMezclador.compensacion(canales: 6), 3)   // 5.1
        XCTAssertEqual(ReglasMezclador.compensacion(canales: 8), 4)   // tele HDMI de 8 canales: llegaba al 25 %
        XCTAssertEqual(ReglasMezclador.compensacion(canales: 16), 4)  // tope
    }

    func testMapaDeCanales() throws {
        let estereo = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [2], par: (1, 2)))
        XCTAssertEqual(estereo.izquierda, .init(buffer: 0, canal: 0))
        XCTAssertEqual(estereo.derecha, .init(buffer: 0, canal: 1))
        XCTAssertFalse(estereo.mono)

        // Auricular de llamada: un solo canal = mono.
        let mono = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [1], par: nil))
        XCTAssertTrue(mono.mono)

        // Interfaz con el par estéreo en los canales 3 y 4, repartidos en dos streams de 2.
        let interfaz = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [2, 2], par: (3, 4)))
        XCTAssertEqual(interfaz.izquierda, .init(buffer: 1, canal: 0))
        XCTAssertEqual(interfaz.derecha, .init(buffer: 1, canal: 1))
        XCTAssertEqual(interfaz.canalesDelStream, 2)

        // Un par inválido (canal 9 en una salida de 8) cae en los dos primeros.
        let tele = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [8], par: (9, 10)))
        XCTAssertEqual(tele.izquierda, .init(buffer: 0, canal: 0))
        XCTAssertEqual(tele.canalesDelStream, 8)

        XCTAssertNil(ReglasMezclador.MapaSalida.armar(canales: [], par: nil))
    }

    func testMezclaEstereoConGanancia() throws {
        let mapa = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [2], par: nil))
        let salida = mezclar(entrada: [1, -1, 0.5, -0.5], canalesEntrada: 2, salida: [2], mapa: mapa, desde: 0.5, hasta: 0.5)
        XCTAssertEqual(salida[0], [0.5, -0.5, 0.25, -0.25])
    }

    func testMezclaMonoJuntaLosDosLados() throws {
        let mapa = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [1], par: nil))
        let salida = mezclar(entrada: [1, 0, 0.4, 0.2], canalesEntrada: 2, salida: [1], mapa: mapa, desde: 1, hasta: 1)
        XCTAssertEqual(salida[0][0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(salida[0][1], 0.3, accuracy: 1e-6)
    }

    func testMezclaEnUnaSalidaDeOchoCanalesDejaElRestoEnSilencio() throws {
        let mapa = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [8], par: (1, 2)))
        // La salida viene con basura: todo lo que no es el par estéreo tiene que quedar en cero.
        let salida = mezclar(entrada: [1, 1], canalesEntrada: 2, salida: [8], mapa: mapa, desde: 1, hasta: 1, basura: 9)
        XCTAssertEqual(salida[0], [1, 1, 0, 0, 0, 0, 0, 0])
    }

    func testRampaDeGananciaSinSaltos() throws {
        let mapa = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [2], par: nil))
        let salida = mezclar(entrada: [Float](repeating: 1, count: 8), canalesEntrada: 2, salida: [2], mapa: mapa, desde: 0, hasta: 1)
        // Cuatro cuadros: la ganancia sube de a 0,25 y termina justo en la pedida.
        XCTAssertEqual(salida[0].enumerated().filter { $0.offset % 2 == 0 }.map(\.element), [0.25, 0.5, 0.75, 1])
    }

    func testSinEntradaQuedaSilencio() throws {
        let mapa = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [2], par: nil))
        let salida = mezclar(entrada: nil, canalesEntrada: 2, salida: [2], mapa: mapa, desde: 1, hasta: 1, basura: 7)
        XCTAssertEqual(salida[0], [0, 0, 0, 0])
    }

    func testElTapEsElUltimoBufferDeEntrada() throws {
        // Un agregado sobre unos auriculares USB trae primero el micrófono (1 canal) y al final el tap (2 canales).
        let mapa = try XCTUnwrap(ReglasMezclador.MapaSalida.armar(canales: [2], par: nil))
        let salida = mezclar(entradas: [[0.9, 0.9], [0.2, 0.4, 0.2, 0.4]], canalesEntradas: [1, 2], salida: [2], mapa: mapa)
        XCTAssertEqual(salida[0], [0.2, 0.4, 0.2, 0.4])
    }

    func testDuenoDeUnProcesoAyudante() {
        // 200 = Chrome (app), 300 = su ayudante de sonido (lanzado por launchd, responsable: Chrome).
        let apps: Set<pid_t> = [200]
        let esApp: (pid_t) -> Bool = { apps.contains($0) }
        XCTAssertEqual(ReglasMezclador.dueno(de: 200, responsable: { _ in nil }, padre: { _ in 1 }, esApp: esApp), 200)
        XCTAssertEqual(ReglasMezclador.dueno(de: 300, responsable: { _ in 200 }, padre: { _ in 1 }, esApp: esApp), 200)
        // Sin "responsable": se sube por los padres (300 → 250 → 200).
        let padres: [pid_t: pid_t] = [300: 250, 250: 200]
        XCTAssertEqual(ReglasMezclador.dueno(de: 300, responsable: { _ in nil }, padre: { padres[$0] }, esApp: esApp), 200)
        // Un servicio de macOS (sin app arriba) no es de nadie: no se muestra.
        XCTAssertNil(ReglasMezclador.dueno(de: 400, responsable: { $0 }, padre: { _ in 1 }, esApp: esApp))
    }

    func testMotorColgado() {
        XCTAssertEqual(ReglasMezclador.vigilar(ciclosAntes: 10, ciclosAhora: 55, yaRehecho: false), .bien)
        XCTAssertEqual(ReglasMezclador.vigilar(ciclosAntes: 10, ciclosAhora: 10, yaRehecho: false), .rehacer)
        // El reemplazo tampoco anda: se suelta la app (vuelve a sonar normal).
        XCTAssertEqual(ReglasMezclador.vigilar(ciclosAntes: 0, ciclosAhora: 0, yaRehecho: true), .soltar)
    }

    func testVolumenesRecordados() {
        var guardados = ReglasMezclador.recordar(0.4, de: "com.spotify.client", en: [:])
        XCTAssertEqual(guardados["com.spotify.client"] ?? 0, 0.4, accuracy: 1e-6)
        // Al 100 % se olvida (no hay nada que recordar).
        guardados = ReglasMezclador.recordar(1, de: "com.spotify.client", en: guardados)
        XCTAssertNil(guardados["com.spotify.client"])
        // Con el tope lleno no entran apps nuevas, pero las que estaban se actualizan.
        let llenos = ReglasMezclador.recordar(0.3, de: "a", en: ["a": 0.5, "b": 0.5], tope: 2)
        XCTAssertEqual(llenos["a"] ?? 0, 0.3, accuracy: 1e-6)
        XCTAssertNil(ReglasMezclador.recordar(0.3, de: "c", en: llenos, tope: 2)["c"])
    }

    // MARK: - Ayudas

    private func mezclar(entrada: [Float]?, canalesEntrada: Int, salida: [Int], mapa: ReglasMezclador.MapaSalida,
                         desde: Float, hasta: Float, basura: Float = 0) -> [[Float]] {
        mezclar(entradas: entrada.map { [$0] } ?? [], canalesEntradas: [canalesEntrada], salida: salida, mapa: mapa,
                desde: desde, hasta: hasta, basura: basura)
    }

    /// Arma listas de buffers como las de Core Audio (Float32 intercalado), corre la mezcla y devuelve la salida.
    private func mezclar(entradas: [[Float]], canalesEntradas: [Int], salida canales: [Int], mapa: ReglasMezclador.MapaSalida,
                         desde: Float = 1, hasta: Float = 1, basura: Float = 0) -> [[Float]] {
        let cuadros = entradas.last.map { $0.count / max(canalesEntradas[entradas.count - 1], 1) } ?? 2
        var memoria: [UnsafeMutablePointer<Float>] = []
        defer { memoria.forEach { $0.deallocate() } }

        let listaEntrada = AudioBufferList.allocate(maximumBuffers: max(entradas.count, 1))
        defer { free(listaEntrada.unsafeMutablePointer) }
        for (i, datos) in entradas.enumerated() {
            let puntero = UnsafeMutablePointer<Float>.allocate(capacity: datos.count)
            puntero.initialize(from: datos, count: datos.count)
            memoria.append(puntero)
            listaEntrada[i] = AudioBuffer(mNumberChannels: UInt32(canalesEntradas[i]), mDataByteSize: UInt32(datos.count * 4), mData: puntero)
        }
        let listaSalida = AudioBufferList.allocate(maximumBuffers: canales.count)
        defer { free(listaSalida.unsafeMutablePointer) }
        for (i, n) in canales.enumerated() {
            let puntero = UnsafeMutablePointer<Float>.allocate(capacity: n * cuadros)
            puntero.initialize(repeating: basura, count: n * cuadros)
            memoria.append(puntero)
            listaSalida[i] = AudioBuffer(mNumberChannels: UInt32(n), mDataByteSize: UInt32(n * cuadros * 4), mData: puntero)
        }
        ReglasMezclador.mezclar(entrada: entradas.isEmpty ? nil : listaEntrada, salida: listaSalida, mapa: mapa, desde: desde, hasta: hasta)
        return listaSalida.map { buffer in
            let n = Int(buffer.mDataByteSize) / 4
            return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: n))
        }
    }
}
