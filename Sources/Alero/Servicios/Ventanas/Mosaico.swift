import AppKit
import Combine

// Acomodar ventanas (Herramientas › Ventanas). Con la llave prendida:
// - arrastrás una ventana contra un costado, una esquina o arriba y queda en esa mitad, ese cuarto o en toda la
//   pantalla (mientras la llevás, una vista previa muestra exactamente dónde va a quedar). En un borde que da a otra
//   pantalla el puntero se pasaría de largo: ahí cuenta una franja más ancha, quedándose un momento;
// - en lo que queda libre, "¿Qué va acá?" ofrece todas las apps abiertas (también minimizadas, ocultas o sin
//   ventana) y un buscador que también encuentra las instaladas que no están abiertas. Cancelarlo con la X o Esc
//   devuelve la primera ventana a como estaba;
// - una ventana nueva en un cuarto de una columna ocupada por una mitad parte la columna (entra una tercera app);
// - las ventanas quedan pegadas y sobre la unión hay una barra siempre a la vista: arrastrándola, todas se
//   reacomodan mientras la movés; doble clic la centra. Con cuatro, en el cruce hay una perilla que va en diagonal.
//   Pasando el mouse por la pastilla aparecen "Cambiar" (de lado), "Al medio" y "Salir" (todas vuelven a como
//   estaban). Si estirás una ventana desde su borde o su esquina, las demás la siguen en vivo;
// - sacar una ventana del grupo (arrastrándola) la devuelve a su tamaño de antes, y si de un grupo queda una sola
//   (cerraste o minimizaste la otra), esa también vuelve a como estaba.
// El mouse se mira con escuchas globales de AppKit, que solo leen: nunca frenan ni cambian un clic. Lo de
// Accesibilidad va en `AX.cola`; el resto, en el hilo principal. Las cuentas están en `ReglasMosaico` y las
// ventanitas (vista previa, "¿Qué va acá?" y barras) en `PanelesMosaico`. Una ventana sale de su grupo si la movés a
// mano, la cerrás, la minimizás o la ocultás.

final class Mosaico {
    static let shared = Mosaico()

    /// Una ventana acomodada por Alero.
    struct Miembro {
        let id: CGWindowID
        let pid: pid_t
        let ventana: AXUIElement
        var zona: ZonaMosaico
        /// Cómo quedó de verdad (algunas apps redondean el tamaño): sirve para notar si la movieron a mano.
        var quedo: CGRect
        /// Cómo estaba antes de que Alero la acomodara (para devolverla al cancelar o al sacarla).
        let antes: CGRect
    }

    /// Las ventanas acomodadas en una pantalla y dónde están sus barras.
    struct Grupo {
        var pantalla: PantallaCG
        var divisiones = Divisiones()
        var miembros: [Miembro] = []
        var ocupadas: [ZonaMosaico] { miembros.map(\.zona) }
        var barras: [BarraMosaico] { ReglasMosaico.barras(ocupadas: ocupadas, en: pantalla.visible, divisiones: divisiones) }
    }

    /// Una ventana que se está llevando con el mouse.
    private struct Arrastre {
        let id: CGWindowID
        let pid: pid_t
        let inicial: CGRect
        var actual: CGRect
        var moviendo = false
        /// La zona que muestra la vista previa (la que vale al soltar).
        var toque: ToqueMosaico?
        var pantalla: PantallaCG?
    }

    private var suscripciones = Set<AnyCancellable>()
    private var monitor: Any?
    private var arrastre: Arrastre?
    private var ultimaMirada: CFTimeInterval = 0
    private var esperaBorde: DispatchWorkItem?
    private var grupos: [Grupo] = []
    private var reloj: Timer?
    private let paneles = PanelesMosaico()
    // Mientras se arrastra una barra, se manda a mover una tanda por vez; si llegan más, queda la última.
    private var aplicando = false
    private var pendiente: (pantalla: PantallaCG, corregir: Bool, vivo: Bool, excepto: CGWindowID?)?
    /// Una ventana del grupo que la persona está estirando desde su borde (las demás la siguen en vivo).
    private var estirada: (id: CGWindowID, pantalla: PantallaCG)?

    /// La llama `Delegado` al arrancar, una vez.
    func arrancar() {
        Pantallas.shared.arrancar()
        Ajustes.shared.$mosaico.removeDuplicates()
            .sink { [weak self] prender in self?.prender(prender) }
            .store(in: &suscripciones)
    }

    private func prender(_ prender: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard prender else {
            MosaicoDeMacOS.devolver()
            arrastre = nil
            grupos = []
            vigilar()
            paneles.cerrarTodo()
            return
        }
        MosaicoDeMacOS.apagar()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] evento in
            self?.recibir(evento)
        }
    }

    /// El puntero en coordenadas de eventos (origen arriba a la izquierda de la pantalla principal).
    static func puntero() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    private func recibir(_ evento: NSEvent) {
        let p = Mosaico.puntero()
        switch evento.type {
        case .leftMouseDown: empezar(en: p)
        case .leftMouseDragged: arrastre == nil ? seguirEstirando() : seguir(en: p)
        case .leftMouseUp: estirada == nil ? soltar() : soltarEstirada()
        default: break
        }
    }

    // MARK: - Llevar una ventana a un borde

    /// Un clic en otra app cierra "¿Qué va acá?" (sin deshacer nada) y, si fue en la barra de arriba de una ventana,
    /// puede ser el comienzo de un arrastre (se confirma en `seguir`, cuando la ventana se corre sin cambiar de tamaño).
    private func empezar(en p: CGPoint) {
        paneles.cerrarAsistente()
        arrastre = nil
        guard let v = VentanasVisibles.bajo(p), p.y - v.marco.minY <= 60 else { return }
        arrastre = Arrastre(id: v.id, pid: v.pid, inicial: v.marco, actual: v.marco)
    }

    private func seguir(en p: CGPoint) {
        guard var a = arrastre else { return }
        if !a.moviendo {
            // Preguntarle al servidor de ventanas en cada movimiento es caro: como mucho cada 50 ms.
            let ahora = CACurrentMediaTime()
            guard ahora - ultimaMirada > 0.05 else { return }
            ultimaMirada = ahora
            guard let marco = VentanasVisibles.marco(de: a.id) else { arrastre = nil; return }
            a.actual = marco
            let corrida = hypot(marco.minX - a.inicial.minX, marco.minY - a.inicial.minY) > 4
            let mismoTamano = abs(marco.width - a.inicial.width) < 2 && abs(marco.height - a.inicial.height) < 2
            guard corrida else { arrastre = a; return }
            // Se agranda desde un borde, no se mueve: no es para acá.
            guard mismoTamano else { arrastre = nil; return }
            a.moviendo = true
            sacarAlArrastrar(a.id)
        }
        let todas = Pantallas.shared.actuales
        let pantalla = todas.first { $0.marco.insetBy(dx: -2, dy: -2).contains(p) }
        let toque = pantalla.flatMap { ReglasMosaico.zona(en: p, pantalla: $0, compartidos: LadosCompartidos.de($0, entre: todas)) }
        if toque == nil || pantalla != a.pantalla { esperaBorde?.cancel() }
        if toque != a.toque || pantalla != a.pantalla {
            if let toque, let pantalla, toque.compartido {
                // Junto a otra pantalla hay que quedarse un momento: si no, se mostraría cada vez que la cruzás.
                a.toque = nil
                a.pantalla = pantalla
                paneles.ocultarVistaPrevia()
                esperar(toque, en: pantalla)
            } else {
                a.toque = toque
                a.pantalla = pantalla
                if let toque, let pantalla { paneles.mostrarVistaPrevia(marco(toque.zona, en: pantalla)) } else { paneles.ocultarVistaPrevia() }
            }
        }
        arrastre = a
    }

    private func esperar(_ toque: ToqueMosaico, en pantalla: PantallaCG) {
        esperaBorde?.cancel()
        let espera = DispatchWorkItem { [weak self] in
            guard let self, var a = self.arrastre, a.moviendo else { return }
            let ahora = ReglasMosaico.zona(en: Mosaico.puntero(), pantalla: pantalla,
                                           compartidos: LadosCompartidos.de(pantalla, entre: Pantallas.shared.actuales))
            guard ahora == toque else { return }
            a.toque = toque
            self.arrastre = a
            self.paneles.mostrarVistaPrevia(self.marco(toque.zona, en: pantalla))
        }
        esperaBorde = espera
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: espera)
    }

    private func soltar() {
        esperaBorde?.cancel()
        paneles.ocultarVistaPrevia()
        guard let a = arrastre, a.moviendo, let toque = a.toque, let pantalla = a.pantalla else { arrastre = nil; return }
        arrastre = nil
        let destino = marco(toque.zona, en: pantalla)
        // Se mira dónde quedó un instante después de soltar: la app termina de moverla sola.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let suelta = VentanasVisibles.marco(de: a.id) ?? a.actual
            AX.cola.async {
                guard let ventana = Mosaico.ventanaAX(pid: a.pid, id: a.id, marco: suelta) else { return }
                Mosaico.colocar(ventana, pid: a.pid, en: destino) { quedo in
                    DispatchQueue.main.async {
                        self?.sumar(Miembro(id: a.id, pid: a.pid, ventana: ventana, zona: toque.zona, quedo: quedo, antes: a.inicial),
                                    en: pantalla, nuevo: true)
                    }
                }
            }
        }
    }

    /// El rectángulo de una zona en una pantalla, con las barras donde las dejó su grupo (si tiene).
    private func marco(_ zona: ZonaMosaico, en pantalla: PantallaCG) -> CGRect {
        let divisiones = grupos.first { $0.pantalla == pantalla }?.divisiones ?? Divisiones()
        return ReglasMosaico.marco(zona, en: pantalla.visible, divisiones: divisiones)
    }

    // MARK: - Grupos

    /// Suma una ventana recién acomodada a su grupo: las que pisa salen, y si cae en un cuarto de una columna que
    /// ocupaba una mitad, esa pasa al otro cuarto. Después ofrece lo que quedó libre. `nuevo`: la acomodó la
    /// persona arrastrándola (si cancela "¿Qué va acá?" enseguida, vuelve a como estaba).
    private func sumar(_ miembro: Miembro, en pantalla: PantallaCG, nuevo: Bool) {
        let i: Int
        if let existente = grupos.firstIndex(where: { $0.pantalla == pantalla }) {
            i = existente
        } else {
            grupos.append(Grupo(pantalla: pantalla))
            i = grupos.count - 1
        }
        let otros = grupos[i].miembros.filter { $0.id != miembro.id }
        let zonas = ReglasMosaico.acomodar(miembro.zona, entre: otros.map(\.zona))
        var quedan: [Miembro] = []
        var cambio = false
        for (otro, zona) in zip(otros, zonas) {
            guard let zona else { continue }
            var movido = otro
            if zona != otro.zona { movido.zona = zona; cambio = true }
            quedan.append(movido)
        }
        grupos[i].miembros = quedan + [miembro]
        let unificadas = ReglasMosaico.unificar(grupos[i].divisiones, ocupadas: grupos[i].ocupadas)
        if unificadas != grupos[i].divisiones { grupos[i].divisiones = unificadas; cambio = true }
        if cambio { aplicar(pantalla) }
        vigilar()
        ofrecerLibre(grupos[i], deshacer: nuevo && quedan.isEmpty ? miembro : nil)
    }

    /// Una ventana del grupo que se empezó a arrastrar sale y vuelve a su tamaño de antes (sigue en la mano).
    private func sacarAlArrastrar(_ id: CGWindowID) {
        for i in grupos.indices {
            guard let m = grupos[i].miembros.first(where: { $0.id == id }) else { continue }
            grupos[i].miembros.removeAll { $0.id == id }
            var tamano = m.antes.size
            AX.cola.async {
                if let valor = AXValueCreate(.cgSize, &tamano) { AX.poner(m.ventana, kAXSizeAttribute, valor) }
            }
        }
        grupos.removeAll { $0.miembros.isEmpty }
        vigilar()
    }

    /// Cada 0,3 s, mientras haya grupos: las barras se muestran donde se ven las dos ventanas; las que ya no están a
    /// la vista o se movieron a mano salen; y si una se estiró desde su borde de adentro, las demás la siguen.
    private func vigilar() {
        if grupos.isEmpty {
            reloj?.invalidate()
            reloj = nil
            paneles.mostrarBarras([])
            return
        }
        guard reloj == nil else { return }
        reloj = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.revisar() }
    }

    private func revisar() {
        guard arrastre == nil, !paneles.arrastrandoBarra, !aplicando else { return }
        let visibles = VentanasVisibles.todas()
        var marcos: [CGWindowID: CGRect] = [:]
        for v in visibles { marcos[v.id] = v.marco }
        // Con el botón apretado la persona puede estar estirando una ventana: se mira cuando la suelta.
        var aplicarEn: [PantallaCG] = []
        if NSEvent.pressedMouseButtons == 0 {
            for i in grupos.indices {
                var g = grupos[i]
                let antes = g.miembros.count
                var desaparecio = false
                g.miembros.removeAll { m in
                    guard let marco = marcos[m.id] else { desaparecio = true; return true }
                    if Geometria.parecidos(marco, m.quedo, tolerancia: 6) { return false }
                    // Se corrió sin cambiar de tamaño: la movieron a mano.
                    return abs(marco.width - m.quedo.width) < 2 && abs(marco.height - m.quedo.height) < 2
                }
                // Cerraste o minimizaste una y quedó una sola: ya no hay nada que acomodar, vuelve a como estaba.
                if antes >= 2, desaparecio, g.miembros.count == 1 {
                    let sola = g.miembros[0]
                    g.miembros = []
                    AX.cola.async { Mosaico.colocar(sola.ventana, pid: sola.pid, en: sola.antes) { _ in } }
                }
                for j in g.miembros.indices {
                    let m = g.miembros[j]
                    guard let marco = marcos[m.id], !Geometria.parecidos(marco, m.quedo, tolerancia: 6) else { continue }
                    if let nuevas = ReglasMosaico.divisiones(siCambio: m.zona, a: marco, ocupadas: g.ocupadas,
                                                             en: g.pantalla.visible, divisiones: g.divisiones) {
                        g.divisiones = nuevas
                        if !aplicarEn.contains(g.pantalla) { aplicarEn.append(g.pantalla) }
                    }
                    // Cambió por afuera (o la app se negó): se la toma como está.
                    g.miembros[j].quedo = marco
                }
                grupos[i] = g
            }
            grupos.removeAll { $0.miembros.isEmpty }
        }
        aplicarEn.forEach { aplicar($0) }
        mostrarBarras(visibles: visibles)
        vigilar()
    }

    private func clave(_ tipo: TipoBarra, en pantalla: PantallaCG) -> String { "\(pantalla.marco)-\(tipo)" }

    /// Mueve las barras de un grupo adonde están sus divisiones, sin volver a mirar si se ven (mientras se arrastra).
    private func reubicarBarras(_ pantalla: PantallaCG) {
        guard let grupo = grupos.first(where: { $0.pantalla == pantalla }) else { return }
        for barra in grupo.barras { paneles.reubicar(clave(barra.tipo, en: pantalla), a: barra.franja) }
    }

    /// Una barra se ve si las ventanas de los dos lados están adelante (sin otra encima), mirando en tres alturas.
    private func mostrarBarras(visibles: [VentanaVisible]) {
        var pedidos: [PanelesMosaico.Pedido] = []
        for grupo in grupos {
            let ids = Set(grupo.miembros.map(\.id))
            // Con el cruce en el medio, las pastillas de las líneas van a los costados (no debajo de la perilla).
            let conCruce = grupo.barras.contains { $0.tipo == .cruce }
            for barra in grupo.barras {
                let f = barra.franja
                let aLaVista = [0.25, 0.5, 0.75].allSatisfy { (t: CGFloat) -> Bool in
                    let lados: [CGPoint]
                    switch barra.tipo {
                    case .vertical: lados = [CGPoint(x: f.minX - 8, y: f.minY + f.height * t), CGPoint(x: f.maxX + 8, y: f.minY + f.height * t)]
                    case .horizontal: lados = [CGPoint(x: f.minX + f.width * t, y: f.minY - 8), CGPoint(x: f.minX + f.width * t, y: f.maxY + 8)]
                    case .cruce: lados = [CGPoint(x: f.minX - 8, y: f.minY - 8), CGPoint(x: f.maxX + 8, y: f.maxY + 8)]
                    }
                    return lados.allSatisfy { VentanasVisibles.primera(en: $0, de: visibles).map { ids.contains($0.id) } == true }
                }
                guard aLaVista else { continue }
                let pantalla = grupo.pantalla
                let tipo = barra.tipo
                pedidos.append(PanelesMosaico.Pedido(
                    clave: clave(tipo, en: pantalla), barra: barra,
                    pastillas: conCruce && tipo != .cruce ? [0.25, 0.75] : [0.5],
                    mover: { [weak self] p, final in self?.moverBarra(tipo, en: pantalla, hasta: p, final: final) },
                    centrar: { [weak self] in self?.centrarBarra(tipo, en: pantalla) },
                    cambiar: tipo == .cruce ? nil : { [weak self] in self?.cambiarDeLado(tipo, en: pantalla) },
                    salir: { [weak self] in self?.salir(pantalla) }))
            }
        }
        paneles.mostrarBarras(pedidos)
    }

    // MARK: - ¿Qué va acá?

    /// Ofrece en lo que quedó libre todas las apps abiertas que no están acomodadas (y el buscador de las demás).
    /// `deshacer`: la ventana que se acaba de acomodar sola (cancelar con la X o Esc la devuelve a como estaba).
    private func ofrecerLibre(_ grupo: Grupo, deshacer: Miembro?) {
        guard let libre = ReglasMosaico.libre(ocupadas: grupo.ocupadas) else { paneles.cerrarAsistente(); return }
        let acomodadas = Set(grupos.flatMap { $0.miembros.map(\.id) })
        let apps = AppsAbiertas.ahora()
        let pantalla = grupo.pantalla
        let destino = marco(libre, en: pantalla)
        AX.cola.async { [weak self] in
            let candidatas = AppsAbiertas.candidatas(apps, excepto: acomodadas)
            DispatchQueue.main.async {
                guard let self else { return }
                self.paneles.mostrarAsistente(en: destino, candidatas: candidatas, abiertas: Set(apps.map(\.nombre))) { elegida in
                    self.poner(elegida, en: libre, pantalla: pantalla)
                } abrir: { url in
                    self.abrirYPoner(url, en: libre, pantalla: pantalla)
                } cancelar: {
                    if let deshacer { self.devolver(deshacer, en: pantalla) }
                }
            }
        }
    }

    /// La ventana vuelve a como estaba antes de acomodarla y sale de su grupo.
    private func devolver(_ m: Miembro, en pantalla: PantallaCG) {
        if let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) { grupos[i].miembros.removeAll { $0.id == m.id } }
        grupos.removeAll { $0.miembros.isEmpty }
        vigilar()
        AX.cola.async { Mosaico.colocar(m.ventana, pid: m.pid, en: m.antes) { _ in } }
    }

    private func poner(_ c: AppsAbiertas.Candidata, en zona: ZonaMosaico, pantalla: PantallaCG) {
        let app = NSRunningApplication(processIdentifier: c.pid)
        if c.estado == .oculta { app?.unhide() }
        if c.estado == .sinVentana {
            // Abrirla de nuevo le pide una ventana (como un clic en su ícono del Dock); se espera a que aparezca.
            if let url = app?.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
        }
        if c.estado == .minimizada, let ventana = c.ventana {
            AX.cola.async { AX.poner(ventana, kAXMinimizedAttribute, kCFBooleanFalse) }
        }
        let espera: TimeInterval = c.estado == .minimizada ? 0.45 : (c.estado == .oculta ? 0.2 : 0)
        if let ventana = c.ventana {
            let destino = marco(zona, en: pantalla)
            AX.cola.asyncAfter(deadline: .now() + espera) { [weak self] in
                self?.colocarNueva(ventana, pid: c.pid, en: zona, destino: destino, pantalla: pantalla)
            }
        } else {
            esperarVentana(c.pid, en: zona, pantalla: pantalla)
        }
    }

    /// Una app instalada que no estaba abierta: se abre y su primera ventana va al lugar libre.
    private func abrirYPoner(_ url: URL, en zona: ZonaMosaico, pantalla: PantallaCG) {
        let configuracion = NSWorkspace.OpenConfiguration()
        configuracion.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuracion) { [weak self] app, _ in
            guard let pid = app?.processIdentifier else { return }
            DispatchQueue.main.async { self?.esperarVentana(pid, en: zona, pantalla: pantalla) }
        }
    }

    /// Espera hasta 6 s a que una app que se está abriendo muestre una ventana y la acomoda.
    private func esperarVentana(_ pid: pid_t, en zona: ZonaMosaico, pantalla: PantallaCG, intento: Int = 0) {
        let destino = marco(zona, en: pantalla)
        AX.cola.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let ventana = AppsAbiertas.ventanaNueva(pid) {
                self?.colocarNueva(ventana, pid: pid, en: zona, destino: destino, pantalla: pantalla)
            } else if intento < 20 {
                DispatchQueue.main.async { self?.esperarVentana(pid, en: zona, pantalla: pantalla, intento: intento + 1) }
            }
        }
    }

    /// En `AX.cola`: trae la ventana adelante, la pone en `destino` (el rectángulo de la zona, calculado antes en el
    /// hilo principal) y la suma al grupo.
    private func colocarNueva(_ ventana: AXUIElement, pid: pid_t, en zona: ZonaMosaico, destino: CGRect, pantalla: PantallaCG) {
        guard let id = Mosaico.id(de: ventana) else { return }
        let antes = AX.marco(ventana) ?? destino
        Mosaico.traerAdelante(ventana, pid: pid)
        Mosaico.colocar(ventana, pid: pid, en: destino) { [weak self] quedo in
            DispatchQueue.main.async {
                self?.sumar(Miembro(id: id, pid: pid, ventana: ventana, zona: zona, quedo: quedo, antes: antes), en: pantalla, nuevo: false)
            }
        }
    }

    // MARK: - Barras

    /// Se arrastra una barra: se corre la división, la barra va a la división nueva y todas las ventanas del grupo se
    /// reacomodan en vivo. Al soltar, una pasada más que corrige si alguna app no se dejó achicar.
    private func moverBarra(_ tipo: TipoBarra, en pantalla: PantallaCG, hasta p: CGPoint, final: Bool) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        grupos[i].divisiones = ReglasMosaico.mover(grupos[i].divisiones, tipo, hasta: p, en: pantalla.visible)
        reubicarBarras(pantalla)
        aplicar(pantalla, corregir: true, vivo: !final)
    }

    private func centrarBarra(_ tipo: TipoBarra, en pantalla: PantallaCG) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        grupos[i].divisiones = ReglasMosaico.centrar(grupos[i].divisiones, tipo)
        reubicarBarras(pantalla)
        aplicar(pantalla)
    }

    /// "Cambiar": las ventanas de un lado de la barra pasan al otro (y viceversa).
    private func cambiarDeLado(_ tipo: TipoBarra, en pantalla: PantallaCG) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        for j in grupos[i].miembros.indices {
            grupos[i].miembros[j].zona = ReglasMosaico.intercambiar(grupos[i].miembros[j].zona, tipo)
        }
        aplicar(pantalla)
    }

    /// "Salir": se termina el acomodo de esa pantalla y cada ventana vuelve a como estaba antes.
    private func salir(_ pantalla: PantallaCG) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        let miembros = grupos[i].miembros
        grupos.remove(at: i)
        vigilar()
        mostrarBarras(visibles: VentanasVisibles.todas())
        AX.cola.async {
            DispatchQueue.concurrentPerform(iterations: miembros.count) { k in
                Mosaico.ponerMarco(miembros[k].ventana, pid: miembros[k].pid, miembros[k].antes)
            }
        }
    }

    // MARK: - Estirar una ventana desde su borde

    /// Mientras la persona estira una ventana del grupo desde su borde o su esquina (un arrastre que no empezó en
    /// la barra de arriba), las demás la siguen en vivo. Como mucho cada 30 ms.
    private func seguirEstirando() {
        guard !grupos.isEmpty, !aplicando else { return }
        let ahora = CACurrentMediaTime()
        guard ahora - ultimaMirada > 0.03 else { return }
        ultimaMirada = ahora
        var marcos: [CGWindowID: CGRect] = [:]
        for v in VentanasVisibles.todas() { marcos[v.id] = v.marco }
        for i in grupos.indices {
            let g = grupos[i]
            for (j, m) in g.miembros.enumerated() {
                if let estirada, estirada.id != m.id { continue }
                guard let marco = marcos[m.id], !Geometria.parecidos(marco, m.quedo, tolerancia: 3),
                      let nuevas = ReglasMosaico.divisiones(siCambio: m.zona, a: marco, ocupadas: g.ocupadas,
                                                            en: g.pantalla.visible, divisiones: g.divisiones) else { continue }
                estirada = (m.id, g.pantalla)
                grupos[i].divisiones = nuevas
                grupos[i].miembros[j].quedo = marco
                reubicarBarras(g.pantalla)
                aplicar(g.pantalla, corregir: false, vivo: true, excepto: m.id)
                return
            }
        }
    }

    /// Al soltar la ventana estirada: una pasada final para que todas queden justas en sus lugares.
    private func soltarEstirada() {
        guard let estirada else { return }
        self.estirada = nil
        aplicar(estirada.pantalla)
    }

    /// Pone cada ventana del grupo en su zona (menos `excepto`, la que la persona está estirando).
    /// - Primero las que se achican y después las que se agrandan, así no se pisan; cada tanda en paralelo, una app
    ///   por hilo (si fueran de a una, la última recién se movería al soltar).
    /// - `vivo`: mientras se arrastra, sin el truco de la "interfaz mejorada" (es lento y frenaría todo).
    /// - `corregir`: si una app no se dejó achicar tanto, la barra se corre hasta donde quedó y las demás se
    ///   acomodan a eso (una sola vez), así nunca se pisan.
    private func aplicar(_ pantalla: PantallaCG, corregir: Bool = true, vivo: Bool = false, excepto: CGWindowID? = nil) {
        if aplicando { pendiente = (pantalla, corregir, vivo, excepto); return }
        guard let grupo = grupos.first(where: { $0.pantalla == pantalla }) else { return }
        aplicando = true
        let tanda = grupo.miembros.filter { $0.id != excepto }.map { m -> (Miembro, CGRect, Bool) in
            let destino = ReglasMosaico.marco(m.zona, en: pantalla.visible, divisiones: grupo.divisiones)
            return (m, destino, destino.width * destino.height < m.quedo.width * m.quedo.height)
        }
        AX.cola.async { [weak self] in
            var quedaron: [CGWindowID: CGRect] = [:]
            let candado = NSLock()
            for achican in [true, false] {
                let parte = tanda.filter { $0.2 == achican }
                DispatchQueue.concurrentPerform(iterations: parte.count) { k in
                    let (m, destino, _) = parte[k]
                    if vivo { AX.ponerMarco(m.ventana, destino) } else { Mosaico.ponerMarco(m.ventana, pid: m.pid, destino) }
                    let quedo = AX.marco(m.ventana)
                    candado.lock()
                    quedaron[m.id] = quedo
                    candado.unlock()
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.aplicando = false
                guard let i = self.grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
                var ajustadas: Divisiones?
                for (m, destino, _) in tanda {
                    guard let quedo = quedaron[m.id], let j = self.grupos[i].miembros.firstIndex(where: { $0.id == m.id }) else { continue }
                    self.grupos[i].miembros[j].quedo = quedo
                    if corregir, ajustadas == nil, !Geometria.parecidos(quedo, destino, tolerancia: 3) {
                        ajustadas = ReglasMosaico.divisiones(siCambio: m.zona, a: quedo, ocupadas: self.grupos[i].ocupadas,
                                                             en: pantalla.visible, divisiones: self.grupos[i].divisiones)
                    }
                }
                if let otro = self.pendiente {
                    self.pendiente = nil
                    self.aplicar(otro.pantalla, corregir: otro.corregir, vivo: otro.vivo, excepto: otro.excepto)
                } else if let ajustadas {
                    self.grupos[i].divisiones = ajustadas
                    self.reubicarBarras(pantalla)
                    self.aplicar(pantalla, corregir: false, vivo: vivo, excepto: excepto)
                } else if !vivo {
                    self.mostrarBarras(visibles: VentanasVisibles.todas())
                }
            }
        }
    }

    // MARK: - Accesibilidad (en `AX.cola`)

    /// La ventana de Accesibilidad de `pid` con ese número (o, si no se puede saber, la que está en `marco`).
    static func ventanaAX(pid: pid_t, id: CGWindowID, marco: CGRect) -> AXUIElement? {
        let ventanas = AX.elementos(AX.app(pid), kAXWindowsAttribute).filter {
            AX.booleano($0, "AXFullScreen") != true && AX.sePuedeCambiar($0, kAXSizeAttribute)
        }
        return ventanas.first { Mosaico.id(de: $0) == id }
            ?? ventanas.first { AX.marco($0).map { Geometria.parecidos($0, marco, tolerancia: 8) } == true }
    }

    /// El número de ventana del servidor de ventanas de un elemento de Accesibilidad (función privada de macOS que
    /// usan los gestores de ventanas; no hay otra forma de cruzar las dos listas).
    static func id(de ventana: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(ventana, &id) == .success && id != 0 ? id : nil
    }

    /// Mueve y agranda una ventana. Las apps con la "interfaz mejorada" de Accesibilidad prendida ignoran el tamaño:
    /// se apaga un momento y se vuelve a prender (como en `Maximizar`).
    static func ponerMarco(_ ventana: AXUIElement, pid: pid_t, _ marco: CGRect) {
        let app = AX.app(pid)
        let mejorada = AX.booleano(app, "AXEnhancedUserInterface") == true
        if mejorada { AX.poner(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        AX.ponerMarco(ventana, marco)
        if mejorada { AX.poner(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    /// Como `ponerMarco`, pero mira a los 0,15 s si quedó y, si la app la corrigió, insiste hasta dos veces.
    /// `listo` recibe cómo quedó de verdad.
    static func colocar(_ ventana: AXUIElement, pid: pid_t, en marco: CGRect, intento: Int = 0, listo: @escaping (CGRect) -> Void) {
        ponerMarco(ventana, pid: pid, marco)
        AX.cola.asyncAfter(deadline: .now() + 0.15) {
            let ahora = AX.marco(ventana) ?? marco
            if !Geometria.parecidos(ahora, marco) && intento < 2 {
                colocar(ventana, pid: pid, en: marco, intento: intento + 1, listo: listo)
            } else {
                listo(ahora)
            }
        }
    }

    static func traerAdelante(_ ventana: AXUIElement, pid: pid_t) {
        AX.poner(ventana, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(ventana, kAXRaiseAction as CFString)
        DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ elemento: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Apps

/// Lo que ofrece "¿Qué va acá?": cada ventana de cada app abierta (a la vista, minimizada u oculta), las apps
/// abiertas sin ninguna ventana (al elegirlas se les pide una) y, buscando, las instaladas que no están abiertas.
enum AppsAbiertas {
    struct App {
        let pid: pid_t
        let nombre: String
        let oculta: Bool
    }

    enum Estado { case aLaVista, minimizada, oculta, sinVentana }

    struct Candidata: Identifiable {
        let id: String
        let pid: pid_t
        let app: String
        let titulo: String
        let estado: Estado
        /// Nil si la app no tiene ventanas.
        let ventana: AXUIElement?
    }

    /// Una app instalada (para el buscador).
    struct Instalada: Identifiable, Equatable {
        let url: URL
        let nombre: String
        var id: String { url.path }
    }

    /// Las apps comunes abiertas (con ícono en el Dock), menos Alero. Hilo principal.
    static func ahora() -> [App] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { App(pid: $0.processIdentifier, nombre: $0.localizedName ?? "", oculta: $0.isHidden) }
    }

    /// Las candidatas, sin las ventanas ya acomodadas: primero las que están a la vista (de adelante hacia atrás),
    /// después las minimizadas y ocultas, al final las apps sin ventana. Como mucho 24. En `AX.cola`.
    static func candidatas(_ apps: [App], excepto acomodadas: Set<CGWindowID>) -> [Candidata] {
        var orden: [CGWindowID: Int] = [:]
        for (i, v) in VentanasVisibles.todas().enumerated() where orden[v.id] == nil { orden[v.id] = i }
        var lista: [(Candidata, Int)] = []
        for app in apps {
            let elemento = AX.app(app.pid)
            // Una app trabada no puede frenar la lista: cada pregunta espera como mucho 0,3 s.
            AXUIElementSetMessagingTimeout(elemento, 0.3)
            let ventanas = AX.elementos(elemento, kAXWindowsAttribute).filter { v in
                AX.texto(v, kAXSubroleAttribute) == kAXStandardWindowSubrole && AX.booleano(v, "AXFullScreen") != true
                    && AX.sePuedeCambiar(v, kAXSizeAttribute)
            }
            for v in ventanas {
                guard let id = Mosaico.id(de: v), !acomodadas.contains(id) else { continue }
                let minimizada = AX.booleano(v, kAXMinimizedAttribute) == true
                let estado: Estado = minimizada ? .minimizada : (app.oculta ? .oculta : .aLaVista)
                let puesto = orden[id] ?? (estado == .aLaVista ? 500 : 1000)
                lista.append((Candidata(id: "\(app.pid)-\(id)", pid: app.pid, app: app.nombre,
                                        titulo: AX.texto(v, kAXTitleAttribute) ?? "", estado: estado, ventana: v), puesto))
            }
            if ventanas.isEmpty {
                lista.append((Candidata(id: "\(app.pid)", pid: app.pid, app: app.nombre, titulo: "", estado: .sinVentana, ventana: nil), 2000))
            }
        }
        return lista.sorted { $0.1 < $1.1 }.prefix(24).map(\.0)
    }

    /// La ventana que acaba de abrir una app a la que se le pidió una (la del frente, o la primera común).
    static func ventanaNueva(_ pid: pid_t) -> AXUIElement? {
        let app = AX.app(pid)
        if let enfocada = AX.elemento(app, kAXFocusedWindowAttribute), AX.sePuedeCambiar(enfocada, kAXSizeAttribute) { return enfocada }
        return AX.elementos(app, kAXWindowsAttribute).first { AX.texto($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
    }

    /// Las apps de Aplicaciones (también las de Apple y las de Utilidades) y de ~/Aplicaciones, por nombre.
    /// Solo se leen los nombres de las carpetas: es rápido. Cualquier hilo.
    static func instaladas() -> [Instalada] {
        let casa = FileManager.default.homeDirectoryForCurrentUser.path
        let carpetas = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                        casa + "/Applications"]
        var vistas = Set<String>()
        var lista: [Instalada] = []
        for carpeta in carpetas {
            let nombres = (try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? []
            for archivo in nombres where archivo.hasSuffix(".app") {
                let nombre = String(archivo.dropLast(4))
                guard vistas.insert(nombre).inserted else { continue }
                lista.append(Instalada(url: URL(fileURLWithPath: carpeta).appendingPathComponent(archivo), nombre: nombre))
            }
        }
        return lista.sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }
}

// MARK: - Ventanas a la vista

/// Una ventana común de otra app, según el servidor de ventanas.
struct VentanaVisible: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let marco: CGRect
    let app: String
}

/// La lista de ventanas del servidor de ventanas (sin Accesibilidad: es barata). Cualquier hilo.
enum VentanasVisibles {
    /// Las ventanas comunes a la vista en este escritorio, de adelante hacia atrás, sin las de Alero ni del Dock.
    /// Solo las que tocan alguna pantalla: hay apps que guardan una ventana escondida lejos (Dixity, en -20000).
    static func todas() -> [VentanaVisible] {
        let pantallas = Pantallas.shared.actuales
        return lista().compactMap { comun($0) }.filter { v in pantallas.contains { $0.marco.intersects(v.marco) } }
    }

    /// La ventana común que está más adelante en `p`, o nil si lo de más adelante es otra cosa (un menú, la barra
    /// de menús). Las ventanas de Alero no cuentan: la del notch es invisible, no recibe clics y ocupa una franja
    /// ancha arriba de cada pantalla (justo donde están las barras de título de las ventanas grandes).
    static func bajo(_ p: CGPoint) -> VentanaVisible? {
        for info in lista() {
            guard let marco = marcoDeVentana(info), marco.contains(p) else { continue }
            let alfa = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alfa == 0 { continue }
            if (info[kCGWindowOwnerPID as String] as? NSNumber).map({ Int64($0.int32Value) == MarcaPropia.proceso }) == true { continue }
            // La ventana transparente del Dock en macOS 26 (ver `BotonVerde.ventanaCandidata`) no tapa nada.
            if info[kCGWindowOwnerName as String] as? String == "Dock" { continue }
            return comun(info)
        }
        return nil
    }

    /// La primera ventana de una lista ya leída que tiene `p` (para mirar varios puntos sin volver a preguntar).
    static func primera(en p: CGPoint, de visibles: [VentanaVisible]) -> VentanaVisible? {
        visibles.first { $0.marco.contains(p) }
    }

    static func marco(de id: CGWindowID) -> CGRect? {
        guard let lista = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = lista.first else { return nil }
        return marcoDeVentana(info)
    }

    private static func lista() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// Solo ventanas comunes (capa 0) de buen tamaño y de otra app.
    private static func comun(_ info: [String: Any]) -> VentanaVisible? {
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, Int64(pid) != MarcaPropia.proceso,
              let marco = marcoDeVentana(info), marco.width >= 120, marco.height >= 80,
              ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { return nil }
        let app = info[kCGWindowOwnerName as String] as? String ?? ""
        if app == "Dock" { return nil }
        return VentanaVisible(id: id, pid: pid, marco: marco, app: app)
    }
}

// MARK: - El acomodo propio de macOS

/// El acomodo de ventanas de macOS 15 y más nuevos, prendido de fábrica: arrastrarlas a los costados
/// (`EnableTilingByEdgeDrag`) o a la barra de menús (`EnableTopTilingByEdgeDrag`). Con los dos a la vez, cada uno
/// muestra su vista previa y acomoda a su manera: por eso `Mosaico` lo apaga al prenderse y lo devuelve como estaba al
/// apagarse. El de mantener ⌥ no se pisa con Alero y no se toca.
enum MosaicoDeMacOS {
    private static let dominio = "com.apple.WindowManager" as CFString
    private static let claves = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]
    /// Cómo estaban las dos opciones antes de que Alero las apagara (en los ajustes de Alero).
    private static let antes = "ventanas.macOSAntes"

    /// Si alguna de las dos sigue prendida (la página lo avisa).
    static var prendido: Bool {
        guard #available(macOS 15, *) else { return false }
        CFPreferencesAppSynchronize(dominio)
        return claves.contains(where: valor)
    }

    /// Al prender "Acomodar ventanas" (y al abrir Alero con eso prendido): anota cómo estaban, la primera vez, y las apaga.
    static func apagar() {
        guard #available(macOS 15, *) else { return }
        CFPreferencesAppSynchronize(dominio)
        if UserDefaults.standard.dictionary(forKey: antes) == nil {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: claves.map { ($0, valor($0)) }), forKey: antes)
        }
        claves.forEach { escribir($0, false) }
    }

    /// Al apagar "Acomodar ventanas": las deja como estaban antes de que Alero las tocara.
    static func devolver() {
        guard let guardado = UserDefaults.standard.dictionary(forKey: antes) as? [String: Bool] else { return }
        for (clave, valor) in guardado where claves.contains(clave) { escribir(clave, valor) }
        UserDefaults.standard.removeObject(forKey: antes)
    }

    static func abrirAjustes() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Sin la clave guardada, macOS la toma como prendida.
    private static func valor(_ clave: String) -> Bool {
        CFPreferencesCopyAppValue(clave as CFString, dominio) as? Bool ?? true
    }

    private static func escribir(_ clave: String, _ valor: Bool) {
        CFPreferencesSetAppValue(clave as CFString, valor as CFBoolean, dominio)
        CFPreferencesAppSynchronize(dominio)
    }
}
