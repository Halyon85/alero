import AppKit

// La superficie de selección de una pantalla: la foto congelada (o nada, en vivo), el oscurecido con el hueco de lo
// elegido, el borde, el cartel de medidas y el resalte de la ventana o la pantalla bajo el puntero. Todo con capas
// de Core Animation: mover el mouse solo cambia unos caminos, nunca redibuja la foto entera. Main thread.

final class VistaSeleccion: NSView {
    weak var sesion: SesionCaptura?
    let numero: CGDirectDisplayID
    /// Marco de la pantalla en coordenadas de AppKit (la vista usa las mismas, corridas a su origen).
    let marcoPantalla: CGRect
    let escala: CGFloat
    private(set) var foto: CGImage?

    private let capaFoto = CALayer()
    private let capaOscura = CAShapeLayer()
    private let capaResalte = CAShapeLayer()
    private let capaBorde = CAShapeLayer()
    private let capaCartel = CALayer()
    private let textoCartel = CATextLayer()

    /// Arrastre del modo Área, en coordenadas de la vista.
    private var inicio: CGPoint?
    private(set) var seleccion: CGRect = .zero

    convenience init(pantalla: NSScreen, foto: CGImage?) {
        self.init(numero: pantalla.numero, marco: pantalla.frame, escala: pantalla.backingScaleFactor, foto: foto)
    }

    /// Sin NSScreen: para dibujar muestras en `--capturas`.
    init(numero: CGDirectDisplayID, marco: CGRect, escala: CGFloat, foto: CGImage?) {
        self.numero = numero
        marcoPantalla = marco
        self.escala = escala
        self.foto = foto
        super.init(frame: NSRect(origin: .zero, size: marco.size))
        // Vista dueña de sus capas: AppKit no las toca y no hay dibujo en `draw`.
        let raiz = CALayer()
        layer = raiz
        wantsLayer = true
        armarCapas(raiz)
    }

    required init?(coder: NSCoder) { nil }

    private func armarCapas(_ raiz: CALayer) {
        capaFoto.frame = bounds
        capaFoto.contents = foto
        capaFoto.contentsGravity = .resize
        capaOscura.fillRule = .evenOdd
        capaOscura.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        capaResalte.fillColor = NSColor(hex: 0x8FD8FF, alfa: 0.16).cgColor
        capaResalte.strokeColor = NSColor(hex: 0x8FD8FF).cgColor
        capaResalte.lineWidth = 2
        capaBorde.fillColor = nil
        capaBorde.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        capaBorde.lineWidth = 1
        capaBorde.shadowColor = NSColor.black.cgColor
        capaBorde.shadowOpacity = 0.5
        capaBorde.shadowRadius = 1.5
        capaBorde.shadowOffset = .zero
        capaCartel.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        capaCartel.cornerRadius = 7
        capaCartel.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        capaCartel.borderWidth = 0.5
        textoCartel.contentsScale = escala
        textoCartel.alignmentMode = .center
        capaCartel.addSublayer(textoCartel)
        for capa in [capaFoto, capaOscura, capaResalte, capaBorde, capaCartel] { raiz.addSublayer(capa) }
        sinAnimar { actualizar() }
    }

    /// Suelta la foto (puede pesar decenas de MB) apenas se cierra la superficie.
    func soltarFoto() {
        capaFoto.contents = nil
        foto = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { ponerCursor(event) }

    /// Cruz para elegir un área; flecha en los otros modos y encima de la barra.
    private func ponerCursor(_ evento: NSEvent) {
        let punto = superview?.convert(evento.locationInWindow, from: nil) ?? .zero
        let sobreOtra = superview?.hitTest(punto).map { $0 !== self } ?? false
        (sesion?.modo == .area && !sobreOtra ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    // MARK: - Mouse y teclado

    override func mouseMoved(with event: NSEvent) {
        ponerCursor(event)
        sesion?.puntero(en: global(event), desde: self)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        sesion?.punteroSalio(de: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let sesion else { return }
        let punto = convert(event.locationInWindow, from: nil)
        switch sesion.modo {
        case .area:
            inicio = punto
            seleccion = .zero
            sesion.empezoArrastre()
        case .ventana:
            sesion.puntero(en: global(event), desde: self)
            if let ventana = sesion.ventanaResaltada {
                // Con ⌥, sin sombra (como en macOS).
                sesion.elegir(.ventana(ventana, sombra: !event.modifierFlags.contains(.option)))
            }
        case .pantalla:
            sesion.elegir(.pantalla(numero))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard sesion?.modo == .area, let inicio else { return }
        let punto = convert(event.locationInWindow, from: nil)
        seleccion = GeometriaCaptura.seleccion(desde: inicio, hasta: punto, dentroDe: bounds)
        sesion?.puntero(en: global(event), desde: self)
        sinAnimar { actualizar() }
    }

    override func mouseUp(with event: NSEvent) {
        guard sesion?.modo == .area, inicio != nil else { return }
        inicio = nil
        let elegido = seleccion
        let minimo = GeometriaCaptura.minimoArea
        guard elegido.width >= minimo, elegido.height >= minimo else {
            // Un clic sin arrastrar no captura: se sigue eligiendo.
            seleccion = .zero
            sesion?.terminoArrastre()
            sinAnimar { actualizar() }
            return
        }
        sesion?.elegir(.area(elegido.offsetBy(dx: marcoPantalla.minX, dy: marcoPantalla.minY), pantalla: numero))
    }

    override func keyDown(with event: NSEvent) {
        if sesion?.tecla(event) != true { super.keyDown(with: event) }
    }

    /// Al cambiar de modo se olvida el arrastre a medias.
    func reiniciar() {
        inicio = nil
        seleccion = .zero
    }

    private func global(_ evento: NSEvent) -> CGPoint {
        let p = convert(evento.locationInWindow, from: nil)
        return CGPoint(x: p.x + marcoPantalla.minX, y: p.y + marcoPantalla.minY)
    }

    // MARK: - Dibujo

    /// Pone las capas según el modo y lo resaltado. Lo llama la sesión cuando algo cambia.
    func actualizar() {
        guard let sesion else { return }
        pintar(modo: sesion.modo, ventana: sesion.ventanaResaltada, pantalla: sesion.pantallaResaltada)
    }

    /// Solo para `--capturas`: deja un área elegida como si se hubiera arrastrado.
    func simular(seleccion nueva: CGRect) { seleccion = nueva }

    func pintar(modo: ModoCaptura, ventana resaltada: VentanaCandidata?, pantalla: CGDirectDisplayID?) {
        var hueco: CGRect?
        var resalte: CGRect?
        var radioResalte: CGFloat = 0
        var cartel: (texto: String, centro: Bool)?
        switch modo {
        case .area:
            if seleccion.width > 0, seleccion.height > 0 {
                hueco = seleccion
                let medidas = GeometriaCaptura.medidas(seleccion, escala: escala)
                cartel = ("\(medidas.ancho) × \(medidas.alto)", false)
            }
        case .ventana:
            if let ventana = resaltada {
                let local = ventana.marco.offsetBy(dx: -marcoPantalla.minX, dy: -marcoPantalla.minY)
                if local.intersects(bounds) {
                    hueco = local
                    resalte = local.insetBy(dx: 1, dy: 1)
                    radioResalte = 12
                    let medidas = GeometriaCaptura.medidas(ventana.marco, escala: escala)
                    let nombre = ventana.app.isEmpty ? "" : "\(ventana.app)  ·  "
                    cartel = ("\(nombre)\(medidas.ancho) × \(medidas.alto)", true)
                }
            }
        case .pantalla:
            if pantalla == numero {
                hueco = bounds
                resalte = bounds.insetBy(dx: 2, dy: 2)
                radioResalte = 6
                let medidas = GeometriaCaptura.medidas(bounds, escala: escala)
                cartel = (T("Clic para capturar · \(medidas.ancho) × \(medidas.alto)", "Click to capture · \(medidas.ancho) × \(medidas.alto)"), true)
            }
        }

        let oscura = CGMutablePath()
        oscura.addRect(bounds)
        // En el modo Ventana el hueco va redondeado como la ventana (si no, se ven las esquinas sin oscurecer).
        if let hueco { oscura.addPath(CGPath(roundedRect: hueco, cornerWidth: radioResalte, cornerHeight: radioResalte, transform: nil)) }
        capaOscura.path = oscura
        capaBorde.path = modo == .area ? hueco.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) } : nil
        capaResalte.path = resalte.map { CGPath(roundedRect: $0, cornerWidth: radioResalte, cornerHeight: radioResalte, transform: nil) }
        ponerCartel(cartel, junto: hueco ?? .zero)
    }

    private func ponerCartel(_ cartel: (texto: String, centro: Bool)?, junto a: CGRect) {
        guard let cartel else { capaCartel.isHidden = true; return }
        let fuente = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let texto = NSAttributedString(string: cartel.texto, attributes: [.font: fuente, .foregroundColor: NSColor.white])
        let medida = texto.size()
        let tamano = CGSize(width: ceil(medida.width) + 18, height: 24)
        let origen: CGPoint
        if cartel.centro {
            let visible = a.intersection(bounds)
            origen = CGPoint(x: visible.midX - tamano.width / 2, y: visible.midY - tamano.height / 2)
        } else {
            origen = GeometriaCaptura.cartelMedidas(seleccion: a, tamano: tamano, limites: bounds)
        }
        capaCartel.isHidden = false
        capaCartel.frame = CGRect(origin: origen, size: tamano)
        textoCartel.string = texto
        textoCartel.frame = CGRect(x: 0, y: (tamano.height - ceil(medida.height)) / 2, width: tamano.width, height: ceil(medida.height))
    }

    func sinAnimar(_ hacer: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hacer()
        CATransaction.commit()
    }
}

/// La lupa del modo Área: los píxeles alrededor del puntero, grandes y sin suavizar, con el del medio marcado.
/// Se dibuja recortando la foto congelada (no copia nada: el recorte comparte la memoria de la foto).
final class VistaLupa: NSView {
    static let lado: CGFloat = 116
    /// Píxeles que se ven de lado a lado (impar, así hay un píxel en el medio).
    private static let pixeles = 23

    private var foto: CGImage?
    private var centro = CGPoint.zero

    init(foto: CGImage) {
        self.foto = foto
        super.init(frame: NSRect(x: 0, y: 0, width: VistaLupa.lado, height: VistaLupa.lado))
        wantsLayer = true
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowPath = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func soltarFoto() { foto = nil }

    /// `pixel`: el píxel de la foto bajo el puntero (origen arriba).
    func mostrar(pixel: CGPoint) {
        centro = CGPoint(x: floor(pixel.x), y: floor(pixel.y))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let foto, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let n = VistaLupa.pixeles
        let k = bounds.width / CGFloat(n)
        let origen = CGPoint(x: centro.x - CGFloat(n / 2), y: centro.y - CGFloat(n / 2))
        let circulo = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ctx.saveGState()
        ctx.addPath(circulo)
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        let pedido = CGRect(origin: origen, size: CGSize(width: n, height: n))
        let real = pedido.intersection(CGRect(x: 0, y: 0, width: foto.width, height: foto.height))
        if !real.isNull, let recorte = foto.cropping(to: real) {
            ctx.interpolationQuality = .none
            // La foto cuenta las filas desde arriba y la vista desde abajo.
            let destino = CGRect(x: (real.minX - origen.x) * k, y: (origen.y + CGFloat(n) - real.maxY) * k,
                                 width: real.width * k, height: real.height * k)
            ctx.draw(recorte, in: destino)
        }
        // El píxel del medio.
        let medio = CGRect(x: CGFloat(n / 2) * k, y: CGFloat(n / 2) * k, width: k, height: k)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(medio.insetBy(dx: -0.75, dy: -0.75))
        ctx.restoreGState()
        ctx.addPath(circulo)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
    }
}
