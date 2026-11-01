import AppKit

// `Alero --ensayo-memoria`: arranca normal y, sin tocar el mouse, abre y cierra lo que más memoria usa (cada página
// de Ajustes, cada sección de Mantenimiento, el editor con una captura del tamaño de una pantalla Retina, una imagen
// fijada, una canción con carátula grande y el notch abierto y cerrado varias veces). Al terminar lo anota en el
// registro ("ensayo de memoria terminado") y sigue andando: sirve para medir desde afuera (`footprint`, `heap`,
// `leaks`) que todo vuelva al reposo. Lo usa quien revisa el rendimiento; la app no lo abre nunca sola.
//
// Opciones (todas con su valor después):
//   --ensayo-memoria-vueltas N      cuántas veces se repite todo (de fábrica 3).
//   --ensayo-memoria-solo PARTE     solo una parte: ajustes, ajustes-<página> (ej. ajustes-sonido), mantenimiento,
//                                   editor, fijada, musica, notch o nada (mide lo que cuesta el ensayo mismo).
//   --ensayo-memoria-imagen RUTA    una captura armada afuera. Conviene para medir: armarla acá (codificar un PNG de
//                                   24 MB) deja su propio rastro en la memoria y se confunde con lo que se quiere ver.
//   --ensayo-memoria-caratula RUTA  un JPEG para la canción de ejemplo (sin esto, la parte musica no corre).
//   --ensayo-memoria-paso S         segundos entre paso y paso (de fábrica 1,2). Largo, para medir con todo abierto.

enum EnsayoMemoria {
    static var pedido: Bool { CommandLine.arguments.contains("--ensayo-memoria") }

    private static func valor(_ opcion: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: opcion), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    private static func toca(_ parte: String) -> Bool {
        guard let elegida = valor("--ensayo-memoria-solo") else { return true }
        return elegida == parte
    }

    static func empezar() {
        let deAfuera = valor("--ensayo-memoria-imagen").map { URL(fileURLWithPath: $0) }
        guard let captura = deAfuera ?? guardarImagenDePrueba() else {
            NSLog("Alero: el ensayo de memoria no pudo armar su imagen")
            return
        }
        let vueltas = max(valor("--ensayo-memoria-vueltas").flatMap(Int.init) ?? 3, 1)
        var pasos: [() -> Void] = []
        for _ in 0..<vueltas {
            for seccion in SeccionAlero.allCases where toca("ajustes") || toca("ajustes-\(seccion.rawValue)") {
                pasos.append { VentanaAlero.shared.mostrar(seccion) }
                pasos.append(cerrarVentanas)
            }
            if toca("mantenimiento") {
                for seccion in SeccionAlero.allCases where seccion.grupo == .mantenimiento {
                    pasos.append { VentanaAlero.shared.mostrar(seccion) }
                }
                pasos.append(cerrarVentanas)
            }
            if toca("editor") {
                pasos.append { VentanaEditor.abrir(captura) }
                pasos.append(cerrarVentanas)
            }
            if toca("fijada") {
                // Leída del archivo en el momento, como cuando la persona fija una captura: el ensayo no retiene nada.
                pasos.append { if let leida = ImagenCaptura.leer(captura) { VentanaFijada.fijar(leida.imagen, escala: leida.escala) } }
                pasos.append { NSApp.windows.filter { $0 is VentanaFijada }.forEach { $0.close() } }
            }
            if toca("musica"), let ruta = valor("--ensayo-memoria-caratula"), let datos = FileManager.default.contents(atPath: ruta) {
                pasos.append {
                    let pista = Pista(titulo: "Ensayo", artista: "Alero", album: "", duracion: 200, transcurrido: 10,
                                      marca: Date(), sonando: true)
                    // Leída como la lee `Musica` con lo que manda la app que suena.
                    Musica.shared.simular(pista, caratula: Musica.caratula(de: datos), color: Tema.acento)
                }
                pasos.append { ControladorNotch.shared.estado.abrir() }
                pasos.append { ControladorNotch.shared.estado.cerrar() }
                // Sin canción, como estaba: si no, las barritas del notch cerrado siguen bailando (y gastando).
                pasos.append { Musica.shared.simular(nil, caratula: nil, color: Tema.acento) }
            }
            if toca("notch") {
                for _ in 0..<5 {
                    pasos.append { ControladorNotch.shared.estado.abrir() }
                    pasos.append { ControladorNotch.shared.estado.cerrar() }
                }
            }
        }
        let espera = valor("--ensayo-memoria-paso").flatMap(Double.init) ?? 1.2
        correr(pasos[...], cada: espera) { if deAfuera == nil { try? FileManager.default.removeItem(at: captura) } }
    }

    /// Un paso cada `espera` segundos: da tiempo a que SwiftUI arme cada pantalla y termine las animaciones.
    private static func correr(_ pasos: ArraySlice<() -> Void>, cada espera: TimeInterval, al terminar: @escaping () -> Void) {
        guard let paso = pasos.first else {
            terminar()
            NSLog("Alero: ensayo de memoria terminado")
            return
        }
        paso()
        DispatchQueue.main.asyncAfter(deadline: .now() + espera) { correr(pasos.dropFirst(), cada: espera, al: terminar) }
    }

    /// Las ventanas con título (Ajustes, Mantenimiento, editor); nunca la de la barra de menú ni el notch.
    private static func cerrarVentanas() {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.forEach { $0.close() }
    }

    /// Una "captura" de 3024 × 1964 (una pantalla Retina de 14") con un degradé, guardada en la carpeta temporal.
    private static func guardarImagenDePrueba() -> URL? {
        let ancho = 3024, alto = 1964
        guard let contexto = CGContext(data: nil, width: ancho, height: alto, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colores = [CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)]
        if let degrade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colores as CFArray, locations: nil) {
            contexto.drawLinearGradient(degrade, start: .zero, end: CGPoint(x: ancho, y: alto), options: [])
        }
        guard let imagen = contexto.makeImage(),
              let datos = ImagenCaptura.codificar(imagen, formato: .png, escala: 2) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alero-ensayo-memoria.png")
        do { try datos.write(to: url) } catch { return nil }
        return url
    }
}
