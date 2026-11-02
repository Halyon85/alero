import AppKit
import Combine
import os

/// Lo que hace "Acomodar ventanas", para entender una falla sin adivinar (Consola o
/// `log show --predicate 'subsystem == "team.halyon.alero" && category == "ventanas"' --last 10m`).
private let registro = Logger(subsystem: "team.halyon.alero", category: "ventanas")

// Acomodar ventanas (Herramientas › Ventanas). Con la llave prendida:
// - arrastrás una ventana contra un costado, una esquina o arriba y queda en esa mitad, ese cuarto o en toda la
//   pantalla (mientras la llevás, una vista previa muestra exactamente dónde va a quedar). En un borde que da a otra
//   pantalla el puntero se pasaría de largo: ahí cuenta una franja más ancha, quedándose un momento;
// - en lo que queda libre, "¿Qué va acá?" ofrece todas las apps abiertas (también minimizadas, ocultas o sin
//   ventana) y un buscador que también encuentra las instaladas que no están abiertas. Cancelarlo (la X, Esc o un
//   clic afuera) devuelve la primera ventana a como estaba;
// - una ventana nueva en un cuarto de una columna ocupada por una mitad parte la columna (entra una tercera app);
// - las ventanas quedan pegadas y sobre la unión hay una barra siempre a la vista. Mientras la arrastrás, cada
//   ventana queda tapada por una cortina (vidrio con el ícono de su app) que va a su lugar nuevo al instante, y las
//   ventanas de verdad se mueven una sola vez al soltar (como el iPad): mover las apps en vivo deja huecos y va a
//   los saltos, porque cada una tarda distinto en redibujarse. Doble clic la centra. Con cuatro, en el cruce hay una
//   perilla que va en diagonal. Un clic en la pastilla abre "Cambiar" (de lado), "Al medio", "Sumar app" y "Salir"
//   (todas vuelven a como estaban). Si estirás una ventana desde su borde o su esquina, las demás se tapan y la siguen;
// - con el selector prendido, dejar el mouse un momento sobre el botón verde de una ventana muestra las formas
//   (completa, mitades, mitad y dos cuartos, cuatro cuartos): tocás dónde va esa ventana y lo demás sigue esa forma;
// - las ventanas acomodadas quedan acopladas: si minimizás una (o ocultás su app), se minimizan todas a la vez y el
//   grupo queda dormido; cuando volvés cualquiera, vuelven todas a su lugar. macOS avisa recién cuando terminó de
//   minimizar una (por eso las demás iban después): el clic en el botón amarillo y en la ventana minimizada del Dock
//   se miran al apretar, y al soltar se van (o vuelven) todas juntas. Para Cmd+M y lo demás avisa cada app por
//   Accesibilidad (`AXObserver`), y ocultar o mostrar una app lo avisa macOS (`NSWorkspace`). La revisión de cada
//   0,3 s queda de respaldo;
// - una ventana sale del grupo si la arrastrás afuera (vuelve a su tamaño de antes), la cerrás, la llevás a otro
//   escritorio o la quitás desde el menú ("Quitar app": vuelve a como estaba). Las que quedan se agrandan para no
//   dejar huecos, y si queda una sola, el acomodo se termina y esa también vuelve a como estaba. Si se pasa a otro
//   escritorio con todo el grupo, el grupo espera a que vuelvas. Si una app se corre sola unos puntos (WhatsApp lo
//   hace al cambiar de tamaño), no sale: vuelve a su lugar;
// - Alero se acuerda de cuánto se deja achicar cada app (lo ve cuando una queda más grande que su lugar) y corre las
//   barras para que entren todas; si dos no entran en una columna, la que se acaba de sumar pasa a la otra.
// El mouse se mira con escuchas globales de AppKit, que solo leen: nunca frenan ni cambian un clic. Lo de
// Accesibilidad va en `AX.cola`; el resto, en el hilo principal. Las cuentas están en `ReglasMosaico` y las
// ventanitas (vista previa, "¿Qué va acá?" y barras) en `PanelesMosaico`.

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
        /// La forma elegida en el selector del botón verde (lo que se ofrece después la sigue). Nil si se arrastró.
        var plantilla: [ZonaMosaico]?
        /// Se minimizó una (o se ocultó su app) y se minimizaron todas: el grupo espera a que vuelva cualquiera.
        var dormido = false
        /// Cuándo se despertó: mientras vuelven de la animación de macOS no se las toma por minimizadas.
        var despiertoDesde: CFTimeInterval = 0
        /// Cuándo se durmió: mientras se van (la animación de macOS las sigue mostrando) no se las toma por vueltas.
        var dormidoDesde: CFTimeInterval = 0
        /// Todas sus ventanas están en otro escritorio (o en una app a pantalla completa): se espera a que vuelvan.
        var fuera = false
        /// La que se acaba de sumar en un cuarto: si no entra en su columna, todavía puede pasar a la otra (una vez).
        var mudable: CGWindowID?
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
    private var grupos: [Grupo] = [] {
        didSet { sincronizarEscuchas() }
    }
    private var reloj: Timer?
    private let paneles = PanelesMosaico()
    /// Se está preguntando a Accesibilidad qué pasó con ventanas que dejaron de verse.
    private var mirandoIdas = false
    /// Cuánto se deja achicar cada app, como mínimo (lo que se vio al acomodarla). Se olvida cuando la app se cierra.
    private var minimos: [pid_t: CGSize] = [:]
    /// Las ventanas que tienen pedido el aviso de minimizar y volver (para no pedirlo de nuevo en cada cambio).
    private var escuchadas: Set<CGWindowID> = []
    /// Un observador de Accesibilidad por app con ventanas acomodadas, y a qué ventanas escucha. Solo en `AX.cola`.
    private var observadores: [pid_t: AXObserver] = [:]
    private var avisando: [CGWindowID: (pid: pid_t, ventana: AXUIElement)] = [:]
    // Se manda a mover una tanda por vez; lo que llega mientras tanto queda en espera, lo último por pantalla.
    private var aplicando = false
    private var pendientes: [Pendiente] = []
    private struct Pendiente {
        let pantalla: PantallaCG
        var pasadas: Int
        var excepto: CGWindowID?
        var quitarCortinas: Bool
    }
    /// Cada clic lleva un número: lo que averigua `AX.cola` de un clic viejo se descarta.
    private var clic = 0
    /// El clic de ahora, si fue en el botón amarillo de una ventana acomodada o en el Dock con un grupo dormido.
    private var clicActual: Clic?
    private struct Clic {
        let numero: Int
        let abajo: CGPoint
        var arriba: CGPoint?
        var soltadoEn: CFTimeInterval = 0
        /// Lo que averiguó `AX.cola` (puede llegar antes o después de soltar).
        var accion: AccionClic?
    }
    private enum AccionClic {
        /// El botón amarillo de una ventana acomodada: al soltar adentro, se duermen todas.
        case dormir(PantallaCG, id: CGWindowID, boton: CGRect)
        /// Una ventana minimizada (o el ícono de una app) de un grupo dormido en el Dock: vuelven todas.
        case despertar(PantallaCG)
    }
    /// La última app que dejó de estar al frente y cuándo: si enseguida se oculta, la ocultó la persona (Cmd+H).
    private var ultimaDesactivada: (pid: pid_t, cuando: CFTimeInterval)?
    private var avisos: [NSObjectProtocol] = []
    /// Una ventana del grupo que la persona está estirando desde su borde (las demás se tapan y la siguen).
    private var estirada: (id: CGWindowID, pantalla: PantallaCG)?
    /// La ventana cuyo botón verde tiene el mouse encima (esperando para mostrar el selector).
    private var verde: CGWindowID?
    private var esperaVerde: DispatchWorkItem?
    private var ultimoMovimiento: CFTimeInterval = 0

    /// La llama `Delegado` al arrancar, una vez.
    func arrancar() {
        Pantallas.shared.arrancar()
        Ajustes.shared.$mosaico.combineLatest(Ajustes.shared.$mosaicoSelector)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] prender, selector in self?.prender(prender, selector: selector) }
            .store(in: &suscripciones)
        // Sin grupos no hacen nada: quedan puestos.
        let espacio = NSWorkspace.shared.notificationCenter
        func app(_ n: Notification) -> NSRunningApplication? { n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
        avisos = [
            espacio.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let app = app(n) { self?.seOculto(app) }
            },
            espacio.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let app = app(n) { self?.seMostro(app) }
            },
            espacio.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let app = app(n) { self?.seCerro(app.processIdentifier) }
            },
            espacio.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let app = app(n) { self?.ultimaDesactivada = (app.processIdentifier, CACurrentMediaTime()) }
            },
            NotificationCenter.default.addObserver(forName: Pantallas.cambiaron, object: nil, queue: .main) { [weak self] _ in
                self?.cambiaronLasPantallas()
            },
        ]
    }

    private func prender(_ prender: Bool, selector: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard prender else {
            MosaicoDeMacOS.devolver()
            arrastre = nil
            grupos = []
            minimos = [:]
            vigilar()
            paneles.cerrarTodo()
            return
        }
        MosaicoDeMacOS.apagar()
        // El movimiento del mouse solo se mira para el selector del botón verde.
        var eventos: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if selector { eventos.insert(.mouseMoved) } else { paneles.ocultarSelector() }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: eventos) { [weak self] evento in
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
        case .leftMouseUp:
            soltarClic(en: p)
            estirada == nil ? soltar() : soltarEstirada()
        case .mouseMoved: mirarVerde(p)
        default: break
        }
    }

    // MARK: - Llevar una ventana a un borde

    /// Un clic en otra app cancela "¿Qué va acá?" (como la X) y, si fue en la barra de arriba de una ventana,
    /// puede ser el comienzo de un arrastre (se confirma en `seguir`, cuando la ventana se corre sin cambiar de tamaño).
    /// Si fue en el botón amarillo de una ventana acomodada o en el Dock con un grupo dormido, se averigua ya, para
    /// que al soltar se vayan o vuelvan todas juntas (`soltarClic`).
    private func empezar(en p: CGPoint) {
        paneles.cancelarAsistente()
        paneles.ocultarMenu()
        paneles.ocultarSelector()
        arrastre = nil
        clic += 1
        clicActual = Clic(numero: clic, abajo: p)
        if grupos.contains(where: \.dormido) { mirarDock(p) }
        guard let v = VentanasVisibles.bajo(p), p.y - v.marco.minY <= 60 else { return }
        arrastre = Arrastre(id: v.id, pid: v.pid, inicial: v.marco, actual: v.marco)
        if p.x - v.marco.minX <= 110, let g = grupos.first(where: { g in !g.dormido && g.miembros.contains { $0.id == v.id } }) {
            mirarAmarillo(p, v, en: g.pantalla)
        }
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
    /// persona arrastrándola o desde el selector (si cancela "¿Qué va acá?" enseguida, vuelve a como estaba).
    /// `plantilla`: la forma elegida en el selector; una ventana nueva arrastrada a mano la borra (ya no se sigue).
    private func sumar(_ miembro: Miembro, en pantalla: PantallaCG, nuevo: Bool, plantilla: [ZonaMosaico]? = nil) {
        let i: Int
        if let existente = grupos.firstIndex(where: { $0.pantalla == pantalla }) {
            i = existente
            // Uno dormido (sus ventanas minimizadas) se olvida: la nueva arranca un acomodo nuevo.
            if grupos[i].dormido { grupos[i] = Grupo(pantalla: pantalla) }
        } else {
            grupos.append(Grupo(pantalla: pantalla))
            i = grupos.count - 1
        }
        if let plantilla { grupos[i].plantilla = plantilla } else if nuevo { grupos[i].plantilla = nil }
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
        let ocupadas = grupos[i].ocupadas
        registro.notice("Se suma una ventana en \(String(describing: miembro.zona), privacy: .public): \(String(describing: ocupadas), privacy: .public)")
        grupos[i].fuera = false
        grupos[i].mudable = miembro.zona.esCuarto ? miembro.id : nil
        let unificadas = ReglasMosaico.unificar(grupos[i].divisiones, ocupadas: grupos[i].ocupadas)
        if unificadas != grupos[i].divisiones { grupos[i].divisiones = unificadas; cambio = true }
        // Con lo que ya se sabe de cada app: si no entra, ya va a la otra columna.
        if ajustar(i) { cambio = true }
        if cambio || !Geometria.parecidos(miembro.quedo, destino(miembro, en: grupos[i]), tolerancia: 3) { aplicar(pantalla) }
        vigilar()
        ofrecerLibre(grupos[i], deshacer: nuevo && quedan.isEmpty ? miembro : nil)
    }

    /// Una ventana del grupo que se empezó a arrastrar sale y vuelve a su tamaño de antes (sigue en la mano); las
    /// demás se agrandan para no dejar huecos.
    private func sacarAlArrastrar(_ id: CGWindowID) {
        guard let grupo = grupos.first(where: { g in g.miembros.contains { $0.id == id } }),
              let m = grupo.miembros.first(where: { $0.id == id }) else { return }
        var tamano = m.antes.size
        AX.cola.async {
            if let valor = AXValueCreate(.cgSize, &tamano) { AX.poner(m.ventana, kAXSizeAttribute, valor) }
        }
        quitarDelGrupo(id, en: grupo.pantalla, devolver: false)
    }

    /// Saca una ventana de su grupo. Las que quedan se agrandan (`ReglasMosaico.quitar`); si queda una sola, el
    /// acomodo se termina y vuelve a como estaba. `devolver`: la que sale también vuelve a como estaba ("Quitar app"),
    /// primero, y después las que quedan se traen adelante: si no, la que sale (la última tocada, y quizás grande)
    /// las tapaba y parecía que se había quitado la otra. `porCierre`: la que sale se cerró (con la X o cerrando la
    /// app): las que quedan pasan al frente (son las que se quieren usar), y si queda una sola, ocupa toda la pantalla.
    private func quitarDelGrupo(_ id: CGWindowID, en pantalla: PantallaCG, devolver: Bool, porCierre: Bool = false) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }),
              let k = grupos[i].miembros.firstIndex(where: { $0.id == id }) else { return }
        let quitado = grupos[i].miembros.remove(at: k)
        let dormido = grupos[i].dormido
        if grupos[i].miembros.count <= 1 {
            let restantes = grupos[i].miembros
            grupos.remove(at: i)
            vigilar()
            mostrarBarras(visibles: VentanasVisibles.todas())
            let llenar = porCierre && !dormido
            AX.cola.async {
                if devolver { Mosaico.colocar(quitado.ventana, pid: quitado.pid, en: quitado.antes) { _ in } }
                for m in restantes {
                    Mosaico.colocar(m.ventana, pid: m.pid, en: llenar ? pantalla.visible : m.antes) { _ in }
                    if devolver { Mosaico.traerAdelante(m.ventana, pid: m.pid) }
                }
            }
            if llenar { alFrente(restantes) }
            return
        }
        let zonas = ReglasMosaico.quitar(quitado.zona, quedan: grupos[i].miembros.map(\.zona))
        for (j, zona) in zonas.enumerated() { grupos[i].miembros[j].zona = zona }
        // Uno dormido se acomoda cuando vuelva (sus ventanas están minimizadas: ni cortinas ni moverlas).
        if dormido { return }
        ajustar(i)
        let quedan = grupos[i].miembros
        if porCierre { alFrente(quedan) }
        if devolver {
            AX.cola.async {
                Mosaico.ponerMarco(quitado.ventana, pid: quitado.pid, quitado.antes)
                for m in quedan { Mosaico.traerAdelante(m.ventana, pid: m.pid) }
            }
        }
        cubrir(grupos[i])
        aplicar(pantalla, quitarCortinas: true)
    }

    /// Trae al frente estas ventanas, sobre las de otras apps, y deja activa la que estaba más adelante (si se cerró
    /// una de un grupo, macOS activa otra ventana de la misma app o cualquier otra, y tapaba a las que quedaban). Cada
    /// app pasa al frente de atrás hacia adelante, así la última queda arriba de todo.
    private func alFrente(_ miembros: [Miembro]) {
        let orden = VentanasVisibles.todas().map(\.id)
        let deAtrasAAdelante = miembros.sorted { (orden.firstIndex(of: $0.id) ?? .max) > (orden.firstIndex(of: $1.id) ?? .max) }
        guard !deAtrasAAdelante.isEmpty else { return }
        AX.cola.async {
            for m in deAtrasAAdelante {
                AX.poner(m.ventana, kAXMainAttribute, kCFBooleanTrue)
                AXUIElementPerformAction(m.ventana, kAXRaiseAction as CFString)
                // Alero nunca está al frente y macOS no le deja activar otra app de prepo: se le pide por Accesibilidad.
                AX.poner(AX.app(m.pid), kAXFrontmostAttribute, kCFBooleanTrue)
            }
        }
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
        guard arrastre == nil, estirada == nil, !paneles.arrastrandoBarra, !aplicando, !mirandoIdas else { return }
        let visibles = VentanasVisibles.todas()
        var marcos: [CGWindowID: CGRect] = [:]
        for v in visibles { marcos[v.id] = v.marco }
        // Con el botón apretado la persona puede estar estirando una ventana: se mira cuando la suelta.
        if NSEvent.pressedMouseButtons == 0 {
            // Un grupo dormido con alguna ventana otra vez a la vista: vuelven todas. Uno que estaba en otro
            // escritorio y se ve de nuevo: sigue como siempre.
            // No en el segundo y medio después de dormirlo: mientras se van, macOS las sigue mostrando, y se las
            // tomaba por vueltas (se abrían y se cerraban sin parar).
            let ahora = CACurrentMediaTime()
            for g in grupos where g.dormido && ahora - g.dormidoDesde > 1.5 && g.miembros.contains(where: { marcos[$0.id] != nil }) {
                despertar(g.pantalla, por: "se volvió a ver")
            }
            for i in grupos.indices where grupos[i].fuera && grupos[i].miembros.contains(where: { marcos[$0.id] != nil }) {
                grupos[i].fuera = false
            }
            // Las que dejaron de verse en un grupo despierto: ¿se cerraron, se minimizaron o están en otro escritorio?
            // Las de una app oculta no: eso lo avisa macOS (`seOculto`) y vuelven solas cuando se muestra la app.
            let idas = grupos.filter { !$0.dormido && !$0.fuera && ahora - $0.despiertoDesde > 1.5 }
                .flatMap { g in
                    g.miembros.filter { marcos[$0.id] == nil && NSRunningApplication(processIdentifier: $0.pid)?.isHidden != true }
                        .map { (miembro: $0, pantalla: g.pantalla) }
                }
            if !idas.isEmpty {
                mirarIdas(idas)
                return
            }
            var aplicarEn: [PantallaCG] = []
            for i in grupos.indices where !grupos[i].dormido && !grupos[i].fuera {
                var g = grupos[i]
                for j in g.miembros.indices {
                    let m = g.miembros[j]
                    guard let marco = marcos[m.id], !Geometria.parecidos(marco, m.quedo, tolerancia: 6) else { continue }
                    if let nuevas = ReglasMosaico.divisiones(siCambio: m.zona, a: marco, ocupadas: g.ocupadas,
                                                             en: g.pantalla.visible, divisiones: g.divisiones) {
                        // La estiraron desde un borde de adentro: las demás la siguen.
                        g.divisiones = nuevas
                        g.miembros[j].quedo = marco
                    }
                    // Si se corrió sola (o cambió por afuera), vuelve a su lugar.
                    if !aplicarEn.contains(g.pantalla) { aplicarEn.append(g.pantalla) }
                }
                grupos[i] = g
            }
            aplicarEn.forEach { aplicar($0) }
        }
        mostrarBarras(visibles: visibles)
        vigilar()
    }

    // MARK: - Ventanas que dejan de verse

    /// Qué pasó con una ventana acomodada que dejó de verse. `noSe`: la app no contestó a tiempo.
    enum Ida: Equatable { case cerrada, minimizada, otroLado, noSe }

    /// Pregunta qué pasó con las ventanas que dejaron de verse y hace lo que dice `decidir`. Si una app no contesta a
    /// tiempo, se vuelve a mirar en la próxima revisión (antes se la tomaba por cerrada y salía del grupo).
    private func mirarIdas(_ idas: [(miembro: Miembro, pantalla: PantallaCG)]) {
        mirandoIdas = true
        let terminadas = Set(idas.filter { NSRunningApplication(processIdentifier: $0.miembro.pid)?.isTerminated ?? true }.map(\.miembro.id))
        var pantallas: [PantallaCG] = []
        for ida in idas where !pantallas.contains(ida.pantalla) { pantallas.append(ida.pantalla) }
        AX.cola.async { [weak self] in
            var estados: [CGWindowID: Ida] = [:]
            for ida in idas {
                let m = ida.miembro
                estados[m.id] = terminadas.contains(m.id) || !VentanasVisibles.existe(m.id) ? .cerrada : Mosaico.estado(m.ventana)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.mirandoIdas = false
                for pantalla in pantallas {
                    guard let g = self.grupos.first(where: { $0.pantalla == pantalla }) else { continue }
                    let que = Mosaico.decidir(g.miembros.map(\.id), estados: estados)
                    registro.notice("Dejaron de verse: \(String(describing: estados), privacy: .public) → salen \(que.quitar.count), duerme \(que.dormir), fuera \(que.fuera)")
                    for id in que.quitar { self.quitarDelGrupo(id, en: pantalla, devolver: false, porCierre: estados[id] == .cerrada) }
                    if que.dormir { self.dormir(pantalla, por: "la revisión la vio minimizada") }
                    if que.fuera, let i = self.grupos.firstIndex(where: { $0.pantalla == pantalla }) { self.grupos[i].fuera = true }
                }
            }
        }
    }

    /// Qué hacer con un grupo según qué pasó con las que dejaron de verse (las que no están en `estados` se ven):
    /// las cerradas salen; si alguna se minimizó, se duerme. Las que están en otro escritorio o a pantalla completa
    /// salen si alguna sigue a la vista (la llevaron a otro lado); si no se ve ninguna, se cambió de escritorio con
    /// el grupo entero y se lo deja esperando (`fuera`), sin desarmarlo. Con alguna sin contestar, no se hace nada más.
    static func decidir(_ ids: [CGWindowID], estados: [CGWindowID: Ida]) -> (quitar: [CGWindowID], dormir: Bool, fuera: Bool) {
        let cerradas = ids.filter { estados[$0] == .cerrada }
        let quedan = ids.filter { estados[$0] != .cerrada }
        if quedan.contains(where: { estados[$0] == .minimizada }) { return (cerradas, true, false) }
        let otroLado = quedan.filter { estados[$0] == .otroLado }
        guard !otroLado.isEmpty else { return (cerradas, false, false) }
        if quedan.contains(where: { estados[$0] == nil }) { return (cerradas + otroLado, false, false) }
        return (cerradas, false, otroLado.count == quedan.count)
    }

    /// En `AX.cola`: si una ventana que no se ve está minimizada, en otro lado o ya no existe.
    static func estado(_ ventana: AXUIElement) -> Ida {
        var crudo: CFTypeRef?
        switch AXUIElementCopyAttributeValue(ventana, kAXMinimizedAttribute as CFString, &crudo) {
        case .success: return (crudo as? NSNumber)?.boolValue == true ? .minimizada : .otroLado
        case .invalidUIElement: return .cerrada
        case .cannotComplete: return .noSe
        default: return .otroLado
        }
    }

    // MARK: - Acopladas: se minimizan y vuelven juntas

    /// Pide a cada app con ventanas acomodadas que avise al instante cuando minimiza o devuelve una (un observador
    /// por app; los avisos llegan al hilo principal), y deja de escuchar las ventanas que ya no están en ningún
    /// grupo y las apps sin ninguna. Se llama sola cada vez que cambian los grupos (solo trabaja si cambiaron sus
    /// ventanas).
    private func sincronizarEscuchas() {
        let miembros = grupos.flatMap(\.miembros)
        let ids = Set(miembros.map(\.id))
        guard ids != escuchadas else { return }
        escuchadas = ids
        var pedidas: [CGWindowID: (pid: pid_t, ventana: AXUIElement)] = [:]
        for m in miembros { pedidas[m.id] = (m.pid, m.ventana) }
        let dueno = Unmanaged.passUnretained(self).toOpaque()
        AX.cola.async { [weak self] in
            guard let self else { return }
            let avisos = [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification].map { $0 as CFString }
            for (id, v) in self.avisando where pedidas[id] == nil {
                if let observador = self.observadores[v.pid] { avisos.forEach { AXObserverRemoveNotification(observador, v.ventana, $0) } }
            }
            for (id, v) in pedidas where self.avisando[id] == nil {
                if self.observadores[v.pid] == nil {
                    var nuevo: AXObserver?
                    guard AXObserverCreate(v.pid, Mosaico.avisoAX, &nuevo) == .success, let nuevo else { continue }
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(nuevo), .commonModes)
                    self.observadores[v.pid] = nuevo
                }
                if let observador = self.observadores[v.pid] { avisos.forEach { AXObserverAddNotification(observador, v.ventana, $0, dueno) } }
            }
            self.avisando = pedidas
            let pids = Set(pedidas.values.map(\.pid))
            for (pid, observador) in self.observadores where !pids.contains(pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observador), .commonModes)
                self.observadores[pid] = nil
            }
        }
    }

    /// El aviso de una app (en el hilo principal): una ventana se minimizó o volvió.
    private static let avisoAX: AXObserverCallback = { _, elemento, aviso, dueno in
        guard let dueno else { return }
        let mosaico = Unmanaged<Mosaico>.fromOpaque(dueno).takeUnretainedValue()
        mosaico.avisaron(elemento, minimizada: (aviso as String) == kAXWindowMiniaturizedNotification)
    }

    private func avisaron(_ elemento: AXUIElement, minimizada: Bool) {
        // Se busca por el elemento, sin preguntarle nada a la app (estamos en el hilo principal); si no, por número.
        let id = grupos.lazy.flatMap(\.miembros).first { CFEqual($0.ventana, elemento) }?.id ?? Mosaico.id(de: elemento)
        guard let grupo = grupos.first(where: { g in g.miembros.contains { $0.id == id } }) else { return }
        // Las que minimiza o devuelve Alero también avisan: con el grupo ya dormido (o despierto) no hacen nada. Las
        // que llegan justo después de despertarlo son de las que se minimizaron antes y terminaron tarde.
        if minimizada && !grupo.dormido && CACurrentMediaTime() - grupo.despiertoDesde > 1.5 { dormir(grupo.pantalla, por: "aviso de la app") }
        if !minimizada && grupo.dormido { despertar(grupo.pantalla, por: "aviso de la app") }
    }

    /// El mouse se apretó cerca del semáforo de una ventana acomodada: si es su botón amarillo, se anota.
    private func mirarAmarillo(_ p: CGPoint, _ v: VentanaVisible, en pantalla: PantallaCG) {
        let numero = clic
        AX.cola.async { [weak self] in
            guard let elemento = AX.elemento(en: p), AX.pid(elemento) == v.pid,
                  // Trampa de Chrome y Electron (ver `AX.app`): a la app entera no se le pregunta nada.
                  !CFEqual(elemento, AX.app(v.pid)),
                  AX.texto(elemento, kAXSubroleAttribute) == kAXMinimizeButtonSubrole,
                  let boton = AX.marco(elemento) else { return }
            DispatchQueue.main.async { self?.resolver(numero, .dormir(pantalla, id: v.id, boton: boton)) }
        }
    }

    /// El mouse se apretó en el Dock con un grupo dormido: si es una de sus ventanas minimizadas (o el ícono de una
    /// de sus apps), se anota.
    private func mirarDock(_ p: CGPoint) {
        guard let franja = Geometria.franjasDock(Pantallas.shared.actuales).first(where: { $0.zona.contains(p) }) else { return }
        let dormidos = grupos.filter(\.dormido).map { (pantalla: $0.pantalla, miembros: $0.miembros) }
        let numero = clic
        AX.cola.async { [weak self] in
            guard let pantalla = Mosaico.grupoDelDock(p, horizontal: franja.horizontal, dormidos: dormidos) else { return }
            DispatchQueue.main.async { self?.resolver(numero, .despertar(pantalla)) }
        }
    }

    /// Al soltar el mouse: sobre el botón amarillo que se apretó, las demás se minimizan ya, a la vez que esa (macOS
    /// avisaría recién cuando termine de irse); en el Dock, vuelven todas juntas. Si `AX.cola` todavía no contestó,
    /// se hace cuando conteste (`resolver`).
    private func soltarClic(en p: CGPoint) {
        guard var c = clicActual else { return }
        c.arriba = p
        c.soltadoEn = CACurrentMediaTime()
        clicActual = c
        if c.accion != nil { hacer(c) }
    }

    /// Llegó lo que averiguó `AX.cola` de un clic: si ya se soltó (hace poco), se hace; si no, espera a que se suelte.
    private func resolver(_ numero: Int, _ accion: AccionClic) {
        guard var c = clicActual, c.numero == numero else { return }
        c.accion = accion
        clicActual = c
        // Si contesta muy tarde, ya llegó el aviso de macOS: no hace falta.
        if c.arriba != nil, CACurrentMediaTime() - c.soltadoEn < 0.6 { hacer(c) }
    }

    private func hacer(_ c: Clic) {
        clicActual = nil
        guard let arriba = c.arriba else { return }
        switch c.accion {
        case .dormir(let pantalla, let id, let boton):
            if boton.insetBy(dx: -3, dy: -3).contains(arriba) { dormir(pantalla, excepto: [id], por: "botón amarillo") }
        case .despertar(let pantalla):
            if hypot(arriba.x - c.abajo.x, arriba.y - c.abajo.y) < 8 { despertar(pantalla, por: "clic en el Dock") }
        case nil:
            break
        }
    }

    /// El clic en el ícono del Dock (`VentanasApp`, en `AX.cola`) va a minimizar o devolver las ventanas de una app:
    /// si alguna está acomodada, las demás del grupo la acompañan ya, sin esperar el aviso de macOS (llega cuando
    /// termina la animación, y por eso iban de a una). Hilo principal.
    func acompanar(_ pid: pid_t, minimizar: Bool) {
        if minimizar, let g = grupos.first(where: { g in !g.dormido && g.miembros.contains { $0.pid == pid } }) {
            dormir(g.pantalla, excepto: Set(g.miembros.filter { $0.pid == pid }.map(\.id)), por: "clic en el ícono")
        }
        if !minimizar, let g = grupos.first(where: { g in g.dormido && g.miembros.contains { $0.pid == pid } }) {
            despertar(g.pantalla, por: "clic en el ícono")
        }
    }

    /// En `AX.cola`: el grupo dormido al que vuelve un clic en el Dock, o nil. Una ventana minimizada se reconoce por
    /// su título; el ícono de una app cuenta si esa app no tiene ninguna ventana sin minimizar (si tiene, el clic
    /// solo la trae al frente y no devuelve nada).
    static func grupoDelDock(_ p: CGPoint, horizontal: Bool, dormidos: [(pantalla: PantallaCG, miembros: [Miembro])]) -> PantallaCG? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let lista = AX.elementos(AX.app(dock.processIdentifier), kAXChildrenAttribute)
                .first(where: { AX.texto($0, kAXRoleAttribute) == kAXListRole }) else { return nil }
        let iconos = AX.elementos(lista, kAXChildrenAttribute)
        guard let i = ClicDock.indiceIcono(iconos.map { AX.marco($0) ?? .null }, punto: p, horizontal: horizontal) else { return nil }
        let icono = iconos[i]
        switch AX.texto(icono, kAXSubroleAttribute) {
        case "AXMinimizedWindowDockItem":
            guard let titulo = AX.texto(icono, kAXTitleAttribute), !titulo.isEmpty else { return nil }
            return dormidos.first { g in g.miembros.contains { AX.texto($0.ventana, kAXTitleAttribute) == titulo } }?.pantalla
        case "AXApplicationDockItem":
            guard let url: URL = AX.valor(icono, kAXURLAttribute) else { return nil }
            let ruta = url.standardizedFileURL.resolvingSymlinksInPath().path
            return dormidos.first { g in
                g.miembros.contains { m in
                    guard NSRunningApplication(processIdentifier: m.pid)?.bundleURL?.standardizedFileURL
                        .resolvingSymlinksInPath().path == ruta else { return false }
                    return AX.elementos(AX.app(m.pid), kAXWindowsAttribute).allSatisfy { AX.booleano($0, kAXMinimizedAttribute) == true }
                }
            }?.pantalla
        default:
            return nil
        }
    }

    /// Se minimizó una del grupo (o la persona ocultó su app): las demás se minimizan con ella y el grupo queda
    /// dormido, con todo guardado. No se minimizan `excepto` (la que ya se está yendo) ni las de apps ocultas
    /// (vuelven cuando se muestra la app).
    private func dormir(_ pantalla: PantallaCG, excepto: Set<CGWindowID> = [], por motivo: String) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }), !grupos[i].dormido else { return }
        let cuantas = grupos[i].miembros.count
        registro.notice("Se duerme el grupo (\(motivo, privacy: .public)): \(cuantas) ventanas")
        grupos[i].dormido = true
        grupos[i].dormidoDesde = CACurrentMediaTime()
        paneles.cerrarAsistente()
        paneles.ocultarMenu()
        mostrarBarras(visibles: VentanasVisibles.todas())
        let aMinimizar = grupos[i].miembros.filter { !excepto.contains($0.id) && NSRunningApplication(processIdentifier: $0.pid)?.isHidden != true }
        // En paralelo (una app por hilo) y fuera de `AX.cola`, así se van todas a la vez: en la cola esperarían a lo
        // que esté haciendo el clic del Dock con su propia app.
        DispatchQueue.global(qos: .userInteractive).async {
            DispatchQueue.concurrentPerform(iterations: aMinimizar.count) { k in
                let m = aMinimizar[k]
                if AX.booleano(m.ventana, kAXMinimizedAttribute) != true { AX.poner(m.ventana, kAXMinimizedAttribute, kCFBooleanTrue) }
            }
        }
    }

    /// Volvió una del grupo dormido (desde el Dock, o se mostró su app): vuelven todas y, cuando termina la animación
    /// de macOS, cada una a su lugar y adelante (`reponer`).
    private func despertar(_ pantalla: PantallaCG, por motivo: String) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }), grupos[i].dormido else { return }
        registro.notice("Se despierta el grupo (\(motivo, privacy: .public))")
        grupos[i].dormido = false
        grupos[i].fuera = false
        grupos[i].despiertoDesde = CACurrentMediaTime()
        let miembros = grupos[i].miembros
        for m in miembros {
            if let app = NSRunningApplication(processIdentifier: m.pid), app.isHidden { app.unhide() }
        }
        // Fuera de `AX.cola` y una app por hilo: devolver una ventana no contesta hasta que termina su animación, y en
        // la cola cada una esperaba a la anterior (y a la que devuelve el clic del Dock): volvían de a una.
        let desde = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            DispatchQueue.concurrentPerform(iterations: miembros.count) { k in
                let m = miembros[k]
                if AX.booleano(m.ventana, kAXMinimizedAttribute) == true { AX.poner(m.ventana, kAXMinimizedAttribute, kCFBooleanFalse) }
            }
            // Cuando volvieron todas y terminó la animación de macOS (dura casi medio segundo; hay apps que contestan
            // antes de terminarla), cada una a su lugar.
            let espera = max(0.15, 0.45 - (CACurrentMediaTime() - desde))
            DispatchQueue.main.asyncAfter(deadline: .now() + espera) { self?.reponer(pantalla) }
        }
    }

    /// Después de despertar, si no se volvió a dormir mientras tanto: todas adelante y cada una a su lugar.
    private func reponer(_ pantalla: PantallaCG) {
        guard let g = grupos.first(where: { $0.pantalla == pantalla }), !g.dormido else { return }
        let miembros = g.miembros
        AX.cola.async {
            for m in miembros { AXUIElementPerformAction(m.ventana, kAXRaiseAction as CFString) }
        }
        aplicar(pantalla)
    }

    /// macOS avisa que se ocultó una app. Si la ocultó la persona (estaba al frente: Cmd+H o su menú), su grupo se
    /// duerme como al minimizar. Si se ocultó con "Ocultar las demás" desde otra app, sus ventanas acomodadas quedan
    /// esperando en su lugar y vuelven al mostrarla.
    private func seOculto(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard let g = grupos.first(where: { g in !g.dormido && g.miembros.contains { $0.pid == pid } }) else { return }
        let propia = app.isActive || ultimaDesactivada.map { $0.pid == pid && CACurrentMediaTime() - $0.cuando < 1 } == true
        if propia { dormir(g.pantalla, por: "se ocultó la app") }
    }

    private func seMostro(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if let g = grupos.first(where: { g in g.dormido && g.miembros.contains { $0.pid == pid } }) { despertar(g.pantalla, por: "se mostró la app") }
    }

    /// Se cerró una app: sus ventanas salen de los grupos al instante y se olvida cuánto se dejaba achicar.
    private func seCerro(_ pid: pid_t) {
        minimos[pid] = nil
        for g in grupos {
            for m in g.miembros where m.pid == pid { quitarDelGrupo(m.id, en: g.pantalla, devolver: false, porCierre: true) }
        }
    }

    /// Cambió alguna pantalla (se movió o se ocultó el Dock, otra resolución, un monitor menos): cada grupo pasa a su
    /// pantalla de ahora y se reacomoda. El de un monitor que ya no está se suelta sin mover nada: macOS ya llevó sus
    /// ventanas a otra pantalla.
    private func cambiaronLasPantallas() {
        let actuales = Pantallas.shared.actuales
        var reacomodar: [PantallaCG] = []
        for i in grupos.indices.reversed() where !actuales.contains(grupos[i].pantalla) {
            if let nueva = Geometria.pantalla(de: grupos[i].pantalla.marco, en: actuales),
               !grupos.contains(where: { $0.pantalla == nueva }) {
                grupos[i].pantalla = nueva
                reacomodar.append(nueva)
            } else {
                grupos.remove(at: i)
            }
        }
        reacomodar.forEach { aplicar($0) }
        mostrarBarras(visibles: VentanasVisibles.todas())
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
        for grupo in grupos where !grupo.dormido {
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
                    sumar: grupo.miembros.count < 4 ? { [weak self] in self?.sumarApp(pantalla) } : nil,
                    apps: grupo.miembros.map { PanelesMosaico.AppDelGrupo(id: $0.id, pid: $0.pid) },
                    quitar: { [weak self] id in self?.quitarDelGrupo(id, en: pantalla, devolver: true) },
                    salir: { [weak self] in self?.salir(pantalla) }))
            }
        }
        paneles.mostrarBarras(pedidos)
    }

    // MARK: - ¿Qué va acá?

    /// Ofrece en lo que quedó libre todas las apps abiertas que no están acomodadas (y el buscador de las demás).
    /// `deshacer`: la ventana que se acaba de acomodar sola (cancelar con la X o Esc la devuelve a como estaba).
    private func ofrecerLibre(_ grupo: Grupo, deshacer: Miembro?) {
        guard let libre = ReglasMosaico.libre(ocupadas: grupo.ocupadas, plantilla: grupo.plantilla) else {
            paneles.cerrarAsistente()
            return
        }
        ofrecer(en: libre, grupo: grupo, deshacer: deshacer)
    }

    /// "Sumar app" de la barra: ofrece una app más en lo libre o partiendo la columna más ancha.
    private func sumarApp(_ pantalla: PantallaCG) {
        guard let grupo = grupos.first(where: { $0.pantalla == pantalla }),
              let zona = ReglasMosaico.dondeSumar(ocupadas: grupo.ocupadas, divisiones: grupo.divisiones, minimos: minimosPorZona(grupo),
                                                  alto: pantalla.visible.height) else { return }
        ofrecer(en: zona, grupo: grupo, deshacer: nil)
    }

    private func ofrecer(en libre: ZonaMosaico, grupo: Grupo, deshacer: Miembro?) {
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
            esperarVentana(c.pid, en: zona, pantalla: pantalla, abierta: true)
        }
    }

    /// Una app instalada que no estaba abierta: se abre y su primera ventana va al lugar libre.
    private func abrirYPoner(_ url: URL, en zona: ZonaMosaico, pantalla: PantallaCG) {
        let configuracion = NSWorkspace.OpenConfiguration()
        configuracion.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuracion) { [weak self] app, _ in
            guard let pid = app?.processIdentifier else { return }
            DispatchQueue.main.async { self?.esperarVentana(pid, en: zona, pantalla: pantalla, abierta: true) }
        }
    }

    /// Espera hasta 6 s a que una app que se está abriendo muestre una ventana y la acomoda. `abierta`: la ventana
    /// la abrió Alero (no tenía un tamaño propio de antes).
    private func esperarVentana(_ pid: pid_t, en zona: ZonaMosaico, pantalla: PantallaCG, abierta: Bool, intento: Int = 0) {
        let destino = marco(zona, en: pantalla)
        AX.cola.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let ventana = AppsAbiertas.ventanaNueva(pid) {
                self?.colocarNueva(ventana, pid: pid, en: zona, destino: destino, pantalla: pantalla, abierta: abierta)
            } else if intento < 20 {
                DispatchQueue.main.async { self?.esperarVentana(pid, en: zona, pantalla: pantalla, abierta: abierta, intento: intento + 1) }
            }
        }
    }

    /// En `AX.cola`: trae la ventana adelante, la pone en `destino` (el rectángulo de la zona, calculado antes en el
    /// hilo principal) y la suma al grupo. `abierta`: la abrió Alero, así que "como estaba" es la pantalla entera (no
    /// la ventanita con que abre la app: al salir del acomodo quedaba un cuadrado chico).
    private func colocarNueva(_ ventana: AXUIElement, pid: pid_t, en zona: ZonaMosaico, destino: CGRect, pantalla: PantallaCG,
                              abierta: Bool = false) {
        guard let id = Mosaico.id(de: ventana) else { return }
        let antes = abierta ? pantalla.visible : (AX.marco(ventana) ?? destino)
        Mosaico.traerAdelante(ventana, pid: pid)
        Mosaico.colocar(ventana, pid: pid, en: destino) { [weak self] quedo in
            DispatchQueue.main.async {
                self?.sumar(Miembro(id: id, pid: pid, ventana: ventana, zona: zona, quedo: quedo, antes: antes), en: pantalla, nuevo: false)
            }
        }
    }

    // MARK: - Selector del botón verde

    /// El mouse se movió (como mucho cada 50 ms): si quedó sobre la zona del botón verde de una ventana, se espera
    /// un momento y se confirma con Accesibilidad que es el botón. Si se fue, el selector se esconde un momento
    /// después (salvo que el mouse entre al selector mismo, que lo mantiene).
    private func mirarVerde(_ p: CGPoint) {
        let ahora = CACurrentMediaTime()
        guard ahora - ultimoMovimiento > 0.05, arrastre == nil else { return }
        ultimoMovimiento = ahora
        guard let v = VentanasVisibles.bajo(p), BotonVerde.enZonaDelVerde(p, ventana: v.marco) else {
            esperaVerde?.cancel()
            verde = nil
            paneles.ocultarSelectorPronto()
            return
        }
        guard verde != v.id else { return }
        verde = v.id
        esperaVerde?.cancel()
        let espera = DispatchWorkItem { [weak self] in self?.confirmarVerde(v) }
        esperaVerde = espera
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: espera)
    }

    private func confirmarVerde(_ v: VentanaVisible) {
        let p = Mosaico.puntero()
        guard verde == v.id, BotonVerde.enZonaDelVerde(p, ventana: v.marco) else { return }
        AX.cola.async { [weak self] in
            guard let elemento = AX.elemento(en: p), AX.pid(elemento) == v.pid,
                  let subrol = AX.texto(elemento, kAXSubroleAttribute),
                  subrol == kAXZoomButtonSubrole || subrol == kAXFullScreenButtonSubrole,
                  let boton = AX.marco(elemento), let ventana = AX.elemento(elemento, kAXWindowAttribute),
                  AX.sePuedeCambiar(ventana, kAXSizeAttribute) else { return }
            DispatchQueue.main.async {
                guard let self, self.verde == v.id else { return }
                self.paneles.mostrarSelector(debajoDe: boton) { zona, forma in
                    self.ponerDesdeSelector(ventana, v, en: zona, forma: forma)
                }
            }
        }
    }

    /// Una zona elegida en el selector: la ventana va ahí (si estaba en un grupo, sale primero), el grupo toma la
    /// forma elegida como plantilla y se ofrece lo que sigue.
    private func ponerDesdeSelector(_ ventana: AXUIElement, _ v: VentanaVisible, en zona: ZonaMosaico, forma: FormaMosaico) {
        guard let pantalla = Geometria.pantalla(de: v.marco, en: Pantallas.shared.actuales) else { return }
        for i in grupos.indices { grupos[i].miembros.removeAll { $0.id == v.id } }
        grupos.removeAll { $0.miembros.isEmpty }
        let destino = marco(zona, en: pantalla)
        AX.cola.async { [weak self] in
            Mosaico.colocar(ventana, pid: v.pid, en: destino) { quedo in
                DispatchQueue.main.async {
                    self?.sumar(Miembro(id: v.id, pid: v.pid, ventana: ventana, zona: zona, quedo: quedo, antes: v.marco),
                                en: pantalla, nuevo: true, plantilla: forma.zonas)
                }
            }
        }
    }

    // MARK: - Barras

    /// Se arrastra una barra: se corre la división, la barra y las cortinas van al lugar nuevo al instante, y al
    /// soltar las ventanas de verdad se mueven una sola vez (con una pasada que corrige si alguna app no se dejó
    /// achicar); las cortinas se van cuando ya están en su lugar.
    private func moverBarra(_ tipo: TipoBarra, en pantalla: PantallaCG, hasta p: CGPoint, final: Bool) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        let movidas = ReglasMosaico.mover(grupos[i].divisiones, tipo, hasta: p, en: pantalla.visible)
        // La barra no pasa de donde se dejan achicar las apps (si igual no entran, se mueve libre).
        let r = ReglasMosaico.respetar(movidas, minimos: minimosPorZona(grupos[i]), ocupadas: grupos[i].ocupadas, en: pantalla.visible)
        grupos[i].divisiones = r.entra ? r.divisiones : movidas
        reubicarBarras(pantalla)
        cubrir(grupos[i])
        if final { aplicar(pantalla, quitarCortinas: true) }
    }

    /// Tapa cada ventana del grupo (menos `excepto`) con su cortina, en el lugar que le toca con las divisiones de ahora.
    private func cubrir(_ grupo: Grupo, excepto: CGWindowID? = nil) {
        paneles.mostrarCortinas(grupo.miembros.filter { $0.id != excepto }.map { m in
            PanelesMosaico.Cortina(id: m.id, pid: m.pid, marco: destino(m, en: grupo))
        })
    }

    private func centrarBarra(_ tipo: TipoBarra, en pantalla: PantallaCG) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        grupos[i].divisiones = ReglasMosaico.centrar(grupos[i].divisiones, tipo)
        ajustar(i)
        reubicarBarras(pantalla)
        cubrir(grupos[i])
        aplicar(pantalla, quitarCortinas: true)
    }

    /// "Cambiar": las ventanas de un lado de la barra pasan al otro (y viceversa).
    private func cambiarDeLado(_ tipo: TipoBarra, en pantalla: PantallaCG) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        for j in grupos[i].miembros.indices {
            grupos[i].miembros[j].zona = ReglasMosaico.intercambiar(grupos[i].miembros[j].zona, tipo)
        }
        ajustar(i)
        cubrir(grupos[i])
        aplicar(pantalla, quitarCortinas: true)
    }

    /// "Salir": se termina el acomodo de esa pantalla y cada ventana vuelve a como estaba antes.
    private func salir(_ pantalla: PantallaCG) {
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }) else { return }
        let miembros = grupos[i].miembros
        grupos.remove(at: i)
        vigilar()
        mostrarBarras(visibles: VentanasVisibles.todas())
        AX.cola.async {
            for m in miembros { Mosaico.colocar(m.ventana, pid: m.pid, en: m.antes) { _ in } }
        }
    }

    // MARK: - Estirar una ventana desde su borde

    /// Mientras la persona estira una ventana del grupo desde su borde o su esquina (un arrastre que no empezó en
    /// la barra de arriba), las demás se tapan con su cortina y la siguen al instante; al soltar se mueven de verdad.
    private func seguirEstirando() {
        guard !grupos.isEmpty, !aplicando else { return }
        let ahora = CACurrentMediaTime()
        guard ahora - ultimaMirada > 0.016 else { return }
        ultimaMirada = ahora
        var marcos: [CGWindowID: CGRect] = [:]
        for v in VentanasVisibles.todas() { marcos[v.id] = v.marco }
        for i in grupos.indices where !grupos[i].dormido {
            let g = grupos[i]
            for (j, m) in g.miembros.enumerated() {
                if let estirada, estirada.id != m.id { continue }
                guard let marco = marcos[m.id], !Geometria.parecidos(marco, m.quedo, tolerancia: 2),
                      let nuevas = ReglasMosaico.divisiones(siCambio: m.zona, a: marco, ocupadas: g.ocupadas,
                                                            en: g.pantalla.visible, divisiones: g.divisiones) else { continue }
                estirada = (m.id, g.pantalla)
                grupos[i].divisiones = nuevas
                grupos[i].miembros[j].quedo = marco
                reubicarBarras(g.pantalla)
                cubrir(grupos[i], excepto: m.id)
                return
            }
        }
    }

    /// Al soltar la ventana estirada: las demás se mueven de verdad y se van las cortinas.
    private func soltarEstirada() {
        guard let estirada else { return }
        self.estirada = nil
        aplicar(estirada.pantalla, quitarCortinas: true)
    }

    /// Lo que se manda a mover de una ventana: dónde va (`destino`: su zona agrandada a su mínimo y adentro de la
    /// pantalla) y su zona tal cual (`pedido`: si queda más grande, la app no se deja achicar tanto).
    struct Tarea {
        let miembro: Miembro
        let pedido: CGRect
        let destino: CGRect
        let achica: Bool
    }

    /// El lugar de una ventana del grupo con las divisiones de ahora: su zona, agrandada a lo que se sabe que es su
    /// mínimo, sin salirse de la pantalla.
    private func destino(_ m: Miembro, en g: Grupo) -> CGRect {
        ReglasMosaico.dentro(ReglasMosaico.marco(m.zona, en: g.pantalla.visible, divisiones: g.divisiones),
                             minimo: minimos[m.pid] ?? .zero, en: g.pantalla.visible)
    }

    private func minimosPorZona(_ g: Grupo) -> [ZonaMosaico: CGSize] {
        var lista: [ZonaMosaico: CGSize] = [:]
        for m in g.miembros { if let minimo = minimos[m.pid] { lista[m.zona] = minimo } }
        return lista
    }

    /// Corre las barras del grupo `i` para que cada ventana tenga su mínimo. Si se acaba de sumar una (`mudable`) y en
    /// una columna dos no entran cómodas (una app alta como WhatsApp), una pasa a la otra columna
    /// (`ReglasMosaico.aMudar`), una sola vez. Si cambió algo.
    @discardableResult
    private func ajustar(_ i: Int) -> Bool {
        let g = grupos[i]
        let v = g.pantalla.visible
        let minimos = minimosPorZona(g)
        let r = ReglasMosaico.respetar(g.divisiones, minimos: minimos, ocupadas: g.ocupadas, en: v)
        if g.mudable != nil, let zona = ReglasMosaico.aMudar(minimos: minimos, ocupadas: g.ocupadas, alto: v.height),
           let k = g.ocupadas.firstIndex(of: zona), let zonas = ReglasMosaico.mudar(k, ocupadas: g.ocupadas) {
            registro.notice("Se muda de columna una ventana: \(String(describing: g.ocupadas), privacy: .public) → \(String(describing: zonas), privacy: .public)")
            grupos[i].mudable = nil
            for (j, zona) in zonas.enumerated() { grupos[i].miembros[j].zona = zona }
            let unificadas = ReglasMosaico.unificar(g.divisiones, ocupadas: zonas)
            grupos[i].divisiones = ReglasMosaico.respetar(unificadas, minimos: minimosPorZona(grupos[i]), ocupadas: zonas, en: v).divisiones
            return true
        }
        guard r.divisiones != g.divisiones else { return false }
        grupos[i].divisiones = r.divisiones
        return true
    }

    /// Si una ventana quedó más chica o corrida sin que la frene un mínimo (la app tiene un tamaño máximo o va de a
    /// saltos, como la Terminal), la barra se corre hasta donde quedó y las demás la siguen. Si cambió algo.
    private func seguirALaQueQuedo(_ i: Int, tanda: [Tarea], quedaron: [CGWindowID: CGRect]) -> Bool {
        let g = grupos[i]
        for t in tanda {
            guard let quedo = quedaron[t.miembro.id], !Geometria.parecidos(quedo, t.destino, tolerancia: 3),
                  quedo.width <= t.destino.width + 4, quedo.height <= t.destino.height + 4,
                  let zona = g.miembros.first(where: { $0.id == t.miembro.id })?.zona,
                  let nuevas = ReglasMosaico.divisiones(siCambio: zona, a: quedo, ocupadas: g.ocupadas,
                                                        en: g.pantalla.visible, divisiones: g.divisiones) else { continue }
            grupos[i].divisiones = nuevas
            return true
        }
        return false
    }

    /// Pone cada ventana del grupo en su lugar (menos `excepto`) con `mover`, en `AX.cola`. Al terminar
    /// (`terminarAplicar`) se anota cuánto no se dejó achicar cada app y, si hace falta, se corren las barras (o se
    /// muda la recién sumada) y se vuelve a pasar, hasta `pasadas` veces más. `quitarCortinas`: al terminar todo, se
    /// van las cortinas (ya están las ventanas en su lugar). Una tanda por vez: lo que llega mientras, espera
    /// (`pendientes`, lo último de cada pantalla). Un grupo dormido no se toca.
    private func aplicar(_ pantalla: PantallaCG, pasadas: Int = 2, excepto: CGWindowID? = nil, quitarCortinas: Bool = false) {
        if aplicando {
            if let k = pendientes.firstIndex(where: { $0.pantalla == pantalla }) {
                pendientes[k].pasadas = max(pendientes[k].pasadas, pasadas)
                pendientes[k].excepto = excepto
                pendientes[k].quitarCortinas = pendientes[k].quitarCortinas || quitarCortinas
            } else {
                pendientes.append(Pendiente(pantalla: pantalla, pasadas: pasadas, excepto: excepto, quitarCortinas: quitarCortinas))
            }
            return
        }
        guard let grupo = grupos.first(where: { $0.pantalla == pantalla }), !grupo.dormido else {
            if quitarCortinas { paneles.quitarCortinas() }
            seguirConPendientes()
            return
        }
        aplicando = true
        let v = pantalla.visible
        let tanda = grupo.miembros.filter { $0.id != excepto }.map { m -> Tarea in
            let lugar = destino(m, en: grupo)
            return Tarea(miembro: m, pedido: ReglasMosaico.marco(m.zona, en: v, divisiones: grupo.divisiones), destino: lugar,
                         achica: lugar.width * lugar.height < m.quedo.width * m.quedo.height)
        }
        AX.cola.async { [weak self] in
            Mosaico.mover(tanda) { quedaron in
                DispatchQueue.main.async {
                    self?.terminarAplicar(pantalla, tanda: tanda, quedaron: quedaron, pasadas: pasadas, excepto: excepto,
                                          quitarCortinas: quitarCortinas)
                }
            }
        }
    }

    private func terminarAplicar(_ pantalla: PantallaCG, tanda: [Tarea], quedaron: [CGWindowID: CGRect], pasadas: Int,
                                 excepto: CGWindowID?, quitarCortinas: Bool) {
        aplicando = false
        guard let i = grupos.firstIndex(where: { $0.pantalla == pantalla }), !grupos[i].dormido else {
            if quitarCortinas { paneles.quitarCortinas() }
            seguirConPendientes()
            return
        }
        for t in tanda {
            guard let quedo = quedaron[t.miembro.id], let j = grupos[i].miembros.firstIndex(where: { $0.id == t.miembro.id }) else { continue }
            grupos[i].miembros[j].quedo = quedo
            let antes = minimos[t.miembro.pid] ?? .zero
            let minimo = ReglasMosaico.minimo(quedo: quedo, pedido: t.pedido, antes: antes, en: pantalla.visible)
            if minimo != antes {
                minimos[t.miembro.pid] = minimo
                let app = NSRunningApplication(processIdentifier: t.miembro.pid)?.localizedName ?? "?"
                registro.notice("\(app, privacy: .public) no se deja achicar a menos de \(Int(minimo.width))×\(Int(minimo.height))")
            }
        }
        for t in tanda where !(quedaron[t.miembro.id].map { Geometria.parecidos($0, t.destino, tolerancia: 3) } ?? false) {
            let quedo = quedaron[t.miembro.id].map { "\($0)" } ?? "sin respuesta"
            registro.notice("No quedó en su lugar: pedido \("\(t.destino)", privacy: .public), quedó \(quedo, privacy: .public)")
        }
        // Si mientras tanto se pidió otra pasada para esta pantalla, esa ya trae lo último.
        if let k = pendientes.firstIndex(where: { $0.pantalla == pantalla }) {
            pendientes[k].quitarCortinas = pendientes[k].quitarCortinas || quitarCortinas
            seguirConPendientes()
            return
        }
        let mudable = grupos[i].mudable
        if pasadas > 0, ajustar(i) || seguirALaQueQuedo(i, tanda: tanda, quedaron: quedaron) {
            reubicarBarras(pantalla)
            if quitarCortinas { cubrir(grupos[i], excepto: excepto) }
            // Si la recién sumada se mudó de columna, hay que conocer a sus vecinas nuevas: vuelven las pasadas.
            let mudo = mudable != nil && grupos[i].mudable == nil
            aplicar(pantalla, pasadas: mudo ? 2 : pasadas - 1, excepto: excepto, quitarCortinas: quitarCortinas)
            return
        }
        grupos[i].mudable = nil
        if quitarCortinas { paneles.quitarCortinas() }
        mostrarBarras(visibles: VentanasVisibles.todas())
        seguirConPendientes()
    }

    private func seguirConPendientes() {
        guard !aplicando, !pendientes.isEmpty else { return }
        let p = pendientes.removeFirst()
        aplicar(p.pantalla, pasadas: p.pasadas, excepto: p.excepto, quitarCortinas: p.quitarCortinas)
    }

    /// En `AX.cola`: mueve una tanda y lee cómo quedó cada ventana. A las que no quedaron en su lugar se las vuelve a
    /// mirar a los 0,15 s (algunas apps terminan un momento después) y, si siguen mal, se insiste una vez: una app
    /// ocupada (Chrome con un video) puede no contestar a tiempo y perder el pedido. `listo` recibe cómo quedaron.
    static func mover(_ tanda: [Tarea], listo: @escaping ([CGWindowID: CGRect]) -> Void) {
        var quedaron = poner(tanda)
        func mal(_ lista: [Tarea]) -> [Tarea] {
            lista.filter { t in quedaron[t.miembro.id].map { !Geometria.parecidos($0, t.destino, tolerancia: 3) } ?? true }
        }
        let primeras = mal(tanda)
        guard !primeras.isEmpty else { return listo(quedaron) }
        AX.cola.asyncAfter(deadline: .now() + 0.15) {
            quedaron.merge(leer(primeras)) { $1 }
            let segundas = mal(primeras)
            guard !segundas.isEmpty else { return listo(quedaron) }
            quedaron.merge(poner(segundas)) { $1 }
            AX.cola.asyncAfter(deadline: .now() + 0.15) {
                quedaron.merge(leer(mal(segundas))) { $1 }
                listo(quedaron)
            }
        }
    }

    /// Primero las que se achican y después las que se agrandan, así no se pisan; cada parte en paralelo (una app
    /// por hilo). Devuelve cómo quedó cada una.
    private static func poner(_ tanda: [Tarea]) -> [CGWindowID: CGRect] {
        var quedaron: [CGWindowID: CGRect] = [:]
        let candado = NSLock()
        for achican in [true, false] {
            let parte = tanda.filter { $0.achica == achican }
            DispatchQueue.concurrentPerform(iterations: parte.count) { k in
                let t = parte[k]
                ponerMarco(t.miembro.ventana, pid: t.miembro.pid, t.destino)
                let quedo = AX.marco(t.miembro.ventana)
                candado.lock()
                quedaron[t.miembro.id] = quedo
                candado.unlock()
            }
        }
        return quedaron
    }

    private static func leer(_ tanda: [Tarea]) -> [CGWindowID: CGRect] {
        var marcos: [CGWindowID: CGRect] = [:]
        let candado = NSLock()
        DispatchQueue.concurrentPerform(iterations: tanda.count) { k in
            let marco = AX.marco(tanda[k].miembro.ventana)
            candado.lock()
            marcos[tanda[k].miembro.id] = marco
            candado.unlock()
        }
        return marcos
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
    /// Solo las que tocan alguna pantalla: hay apps que guardan una ventana escondida lejos (por ejemplo, en -20000).
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

    /// Si la ventana sigue existiendo aunque no se vea (minimizada, en otro escritorio o de una app oculta). Una
    /// cerrada ya no está en la lista del servidor de ventanas.
    static func existe(_ id: CGWindowID) -> Bool {
        (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.isEmpty == false
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
