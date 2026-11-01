import CoreGraphics

// Cuentas de las capturas: pasar rectángulos entre las coordenadas de AppKit (origen abajo a la izquierda de la
// pantalla principal, toda la Mac junta), las de cada pantalla (puntos con origen arriba, lo que pide
// ScreenCaptureKit) y los píxeles de la imagen congelada. Sin pantalla ni permisos: se prueba con `swift test`.

/// Una ventana que se puede capturar con un clic, como la da macOS al empezar (marco en coordenadas de AppKit).
struct VentanaCandidata: Equatable {
    let id: CGWindowID
    let marco: CGRect
    let app: String
}

enum GeometriaCaptura {
    /// Lo mínimo que tiene que medir un área para capturarla: un clic sin arrastrar no captura nada (como macOS).
    static let minimoArea: CGFloat = 4

    /// Rectángulo entre dos puntos del arrastre, sin salirse de `limites` (la pantalla donde empezó: el área no
    /// cruza de una pantalla a otra, igual que en macOS).
    static func seleccion(desde a: CGPoint, hasta b: CGPoint, dentroDe limites: CGRect) -> CGRect {
        let crudo = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let recortado = crudo.intersection(limites)
        return recortado.isNull ? .zero : recortado
    }

    /// De AppKit a la pantalla: puntos con origen arriba a la izquierda de esa pantalla (el `sourceRect` de
    /// ScreenCaptureKit y el recorte de su imagen congelada).
    static func local(_ r: CGRect, enPantalla marco: CGRect) -> CGRect {
        CGRect(x: r.minX - marco.minX, y: marco.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// De puntos de la pantalla a píxeles de su imagen. Se redondea hacia afuera (no se pierde la última fila de
    /// lo elegido) y nunca se sale de la imagen.
    static func pixeles(_ local: CGRect, escala: CGFloat, ancho: Int, alto: Int) -> CGRect {
        let crudo = CGRect(x: local.minX * escala, y: local.minY * escala, width: local.width * escala, height: local.height * escala)
        let limitado = crudo.integral.intersection(CGRect(x: 0, y: 0, width: ancho, height: alto))
        return limitado.isNull ? .zero : limitado
    }

    /// Lo que va a medir el archivo, para el cartelito de medidas ("1280 × 720").
    static func medidas(_ r: CGRect, escala: CGFloat) -> (ancho: Int, alto: Int) {
        (Int((r.width * escala).rounded()), Int((r.height * escala).rounded()))
    }

    /// La ventana de más adelante que tiene al punto. La lista viene de adelante hacia atrás, como la da macOS.
    static func ventana(bajo punto: CGPoint, en ventanas: [VentanaCandidata]) -> VentanaCandidata? {
        ventanas.first { $0.marco.contains(punto) }
    }

    /// Si una ventana de la lista de macOS sirve para el modo Ventana: capa normal (0; menús, Dock y barra van en
    /// otras), visible, no muy chica y de otra app (las de Alero nunca salen en una captura).
    static func esCapturable(capa: Int, alfa: Double, marco: CGRect, pid: Int32, propio: Int32) -> Bool {
        capa == 0 && alfa > 0.01 && marco.width >= 40 && marco.height >= 40 && pid != propio
    }

    /// Lugar alrededor de una ventana para dibujarle la sombra, en píxeles. La sombra cae hacia abajo, así que abajo
    /// hace falta más lugar. Valores parecidos a las capturas de ventana de macOS.
    static func margenesSombra(escala: CGFloat) -> (lado: CGFloat, arriba: CGFloat, abajo: CGFloat) {
        (40 * escala, 26 * escala, 54 * escala)
    }

    /// Dónde va algo de tamaño `tamano` junto al puntero (la lupa): abajo a la derecha; si no entra, del otro lado.
    /// Coordenadas de AppKit (y para arriba), dentro de `limites`.
    static func junto(a puntero: CGPoint, tamano: CGSize, separacion: CGFloat, limites: CGRect) -> CGPoint {
        var x = puntero.x + separacion
        var y = puntero.y - separacion - tamano.height
        if x + tamano.width > limites.maxX { x = puntero.x - separacion - tamano.width }
        if y < limites.minY { y = puntero.y + separacion }
        return CGPoint(x: max(limites.minX, x), y: min(y, limites.maxY - tamano.height))
    }

    /// El cartel de medidas: debajo de la selección, a la derecha; si no entra abajo, adentro de la selección.
    static func cartelMedidas(seleccion s: CGRect, tamano: CGSize, limites: CGRect) -> CGPoint {
        var y = s.minY - tamano.height - 8
        if y < limites.minY + 4 { y = s.minY + 8 }
        let x = min(max(s.maxX - tamano.width, limites.minX + 4), limites.maxX - tamano.width - 4)
        return CGPoint(x: x, y: y)
    }
}
