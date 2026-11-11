import Combine
import Foundation

// Todas las opciones de Alero, guardadas en UserDefaults. Las pantallas de ajustes las cambian y cada servicio
// escucha las que le tocan (`$scrollSuave.sink…`). Main thread: el tap del scroll recibe una copia aparte.

final class Ajustes: ObservableObject {
    static let shared = Ajustes()
    private let guardado = UserDefaults.standard

    // Notch
    @Published var notchActivo: Bool { didSet { guardar(notchActivo, "notch.activo") } }
    @Published var notchMusica: Bool { didSet { guardar(notchMusica, "notch.musica") } }
    @Published var notchCalendario: Bool { didSet { guardar(notchCalendario, "notch.calendario") } }
    /// Los calendarios que la persona apagó (por su identificador de macOS). Se guardan los apagados y no los
    /// prendidos, así un calendario nuevo aparece sin tener que venir a prenderlo.
    @Published var calendariosOcultos: [String] { didSet { guardar(calendariosOcultos, "notch.calendariosOcultos") } }
    /// Reemplaza los carteles de volumen y brillo de macOS por los del notch. Necesita Accesibilidad.
    @Published var notchTeclas: Bool { didSet { guardar(notchTeclas, "notch.teclas") } }
    @Published var notchEstante: Bool { didSet { guardar(notchEstante, "notch.estante") } }
    @Published var notchAtajos: Bool { didSet { guardar(notchAtajos, "notch.atajos") } }
    /// Segundos con el mouse encima antes de abrir. 0 = abre solo con clic.
    @Published var notchDemora: Double { didSet { guardar(notchDemora, "notch.demora") } }
    /// En qué pantalla aparece el notch.
    @Published var notchPantalla: PantallaNotch { didSet { guardar(notchPantalla.rawValue, "notch.pantalla") } }
    /// En pantallas sin notch físico (monitores externos), dibujar una cápsula negra arriba para verlo y abrirlo.
    @Published var notchCapsula: Bool { didSet { guardar(notchCapsula, "notch.capsula") } }
    /// Tamaño del notch abierto, en puntos.
    @Published var notchAncho: Double { didSet { guardar(notchAncho, "notch.ancho") } }
    @Published var notchAlto: Double { didSet { guardar(notchAlto, "notch.alto") } }
    /// Notch abierto: los íconos de la barra de arriba, a la izquierda y a la derecha de la cámara, en orden.
    @Published var notchBarraIzquierda: [ElementoBarra] {
        didSet { guardar(notchBarraIzquierda.map(\.clave), "notch.barraIzquierda") }
    }
    @Published var notchBarraDerecha: [ElementoBarra] { didSet { guardar(notchBarraDerecha.map(\.clave), "notch.barraDerecha") } }
    /// Las dos tarjetas del espacio Inicio.
    @Published var notchInicioIzquierda: TarjetaNotch { didSet { guardar(notchInicioIzquierda.rawValue, "notch.inicioIzquierda") } }
    @Published var notchInicioDerecha: TarjetaNotch { didSet { guardar(notchInicioDerecha.rawValue, "notch.inicioDerecha") } }
    /// El fondo del notch abierto y, en vidrio, cuánto se ve a través (0 casi negro, 1 lo más transparente).
    @Published var notchEstilo: EstiloNotch { didSet { guardar(notchEstilo.rawValue, "notch.estilo") } }
    @Published var notchVidrio: Double { didSet { guardar(notchVidrio, "notch.vidrio") } }
    /// Avisos chicos del notch cerrado: salida de sonido conectada, cargador y descargas terminadas.
    @Published var avisoSalida: Bool { didSet { guardar(avisoSalida, "aviso.salida") } }
    @Published var avisoCorriente: Bool { didSet { guardar(avisoCorriente, "aviso.corriente") } }
    @Published var avisoDescargas: Bool { didSet { guardar(avisoDescargas, "aviso.descargas") } }
    /// Qué atajos aparecen al deslizar, en orden (la mitad a cada lado de la cámara).
    @Published var notchAtajosElegidos: [AtajoNotch] { didSet { guardar(notchAtajosElegidos.map(\.rawValue), "notch.atajosElegidos") } }

    // Sonido por app (macOS 14.4 o más nuevo)
    /// Volumen por app en la columna de sonido del notch. Apagado no se crea nada ni se escucha a Core Audio.
    @Published var mezcladorActivo: Bool { didSet { guardar(mezcladorActivo, "mezclador.activo") } }
    /// Recordar el volumen de cada app (por su identificador) para la próxima vez que suene.
    @Published var mezcladorRecordar: Bool {
        didSet {
            guardar(mezcladorRecordar, "mezclador.recordar")
            // Apagarlo borra lo recordado: no quedan datos de apps guardados sin que se usen.
            if !mezcladorRecordar { guardado.removeObject(forKey: "mezclador.volumenes") }
        }
    }

    // Pantallas
    /// Brillo de los monitores externos (DDC o atenuación por software) en el notch y con las teclas.
    @Published var brilloMonitores: Bool { didSet { guardar(brilloMonitores, "brillo.monitores") } }
    /// Las teclas de brillo cambian la pantalla donde está el puntero (si no, siempre la de la MacBook).
    @Published var brilloTeclasPuntero: Bool { didSet { guardar(brilloTeclasPuntero, "brillo.teclasPuntero") } }

    // Mouse y scroll (solo la rueda del mouse: el trackpad no se toca)
    @Published var scrollSuave: Bool { didSet { guardar(scrollSuave, "scroll.suave") } }
    /// 0 = planeo largo y lento, 100 = sigue a la rueda casi al instante.
    @Published var scrollRespuesta: Double { didSet { guardar(scrollRespuesta, "scroll.respuesta") } }
    /// Distancia en puntos por cada clic de la rueda.
    @Published var scrollPaso: Double { didSet { guardar(scrollPaso, "scroll.paso") } }
    @Published var scrollInvertir: Bool { didSet { guardar(scrollInvertir, "scroll.invertir") } }

    // Dock y ventanas (todas nacen apagadas: cambian cómo responde macOS y se prenden a pedido)
    /// Clic en el ícono de la app que ya está al frente: la minimiza u oculta; otro clic la vuelve a mostrar.
    @Published var dockMinimizar: Bool { didSet { guardar(dockMinimizar, "dock.minimizar") } }
    /// Con varias ventanas, el clic en el Dock pasa a la siguiente en vez de minimizar (01/11/2026).
    @Published var dockAlternarVentanas: Bool { didSet { guardar(dockAlternarVentanas, "dock.alternarVentanas") } }
    @Published var dockModo: ModoDock { didSet { guardar(dockModo.rawValue, "dock.modo") } }
    /// El botón verde agranda la ventana a la pantalla en vez de pasar a pantalla completa.
    @Published var botonVerde: Bool { didSet { guardar(botonVerde, "ventanas.botonVerde") } }
    /// Acomodar ventanas arrastrándolas a los bordes, llenar el resto y la barra entre ellas (`Mosaico`).
    @Published var mosaico: Bool { didSet { guardar(mosaico, "ventanas.mosaico") } }
    /// Con `mosaico` prendido: el selector de formas al dejar el mouse sobre el botón verde de una ventana.
    @Published var mosaicoSelector: Bool { didSet { guardar(mosaicoSelector, "ventanas.selector") } }

    // Botones del mouse
    @Published var botonesMouse: Bool { didSet { guardar(botonesMouse, "botones.activo") } }
    @Published var botonRueda: ConfigBoton { didSet { guardar(botonRueda.datos(), "botones.rueda") } }
    @Published var boton4: ConfigBoton { didSet { guardar(boton4.datos(), "botones.4") } }
    @Published var boton5: ConfigBoton { didSet { guardar(boton5.datos(), "botones.5") } }

    // Finder
    /// ⌘X marca los archivos elegidos y ⌘V los mueve a la carpeta abierta.
    @Published var finderCortar: Bool { didSet { guardar(finderCortar, "finder.cortar") } }

    // Capturas de pantalla
    /// Un atajo por modo; sin atajo (nil) ese modo solo se usa desde el menú o el notch.
    @Published var capturaAtajoArea: AtajoTeclado? { didSet { guardar(AtajoTeclado.datos(capturaAtajoArea), "captura.atajoArea") } }
    @Published var capturaAtajoVentana: AtajoTeclado? { didSet { guardar(AtajoTeclado.datos(capturaAtajoVentana), "captura.atajoVentana") } }
    @Published var capturaAtajoPantalla: AtajoTeclado? { didSet { guardar(AtajoTeclado.datos(capturaAtajoPantalla), "captura.atajoPantalla") } }
    /// Ruta de la carpeta elegida; vacía = el Escritorio.
    @Published var capturaCarpeta: String { didSet { guardar(capturaCarpeta, "captura.carpeta") } }
    @Published var capturaCopiar: Bool { didSet { guardar(capturaCopiar, "captura.copiar") } }
    @Published var capturaSonido: Bool { didSet { guardar(capturaSonido, "captura.sonido") } }
    @Published var capturaFormato: FormatoCaptura { didSet { guardar(capturaFormato.rawValue, "captura.formato") } }
    /// Elegir sobre una foto quieta de la pantalla (si no, sobre la pantalla en vivo).
    @Published var capturaCongelar: Bool { didSet { guardar(capturaCongelar, "captura.congelar") } }
    /// Lupa junto al puntero al elegir un área (solo con la pantalla congelada).
    @Published var capturaLupa: Bool { didSet { guardar(capturaLupa, "captura.lupa") } }

    // Café (mantener la Mac despierta)
    @Published var cafePausarAlBloquear: Bool { didSet { guardar(cafePausarAlBloquear, "cafe.pausarAlBloquear") } }
    @Published var cafeDejarApagarPantalla: Bool { didSet { guardar(cafeDejarApagarPantalla, "cafe.dejarApagarPantalla") } }
    /// Que tampoco se duerma con la tapa cerrada (pide la contraseña al prender el café, ver `CafeTapa`).
    @Published var cafeTapaCerrada: Bool { didSet { guardar(cafeTapaCerrada, "cafe.tapaCerrada") } }

    // Teleprompter
    /// Puntos por segundo que sube el texto.
    @Published var prompterVelocidad: Double { didSet { guardar(prompterVelocidad, "prompter.velocidad") } }
    @Published var prompterLetra: Double { didSet { guardar(prompterLetra, "prompter.letra") } }
    /// Velocidad fija o seguir la voz (ver `SeguidorVoz`), y en qué idioma se reconoce.
    @Published var prompterVoz: Bool { didSet { guardar(prompterVoz, "prompter.voz") } }
    @Published var prompterIdioma: String { didSet { guardar(prompterIdioma, "prompter.idioma") } }
    /// Mientras está abierto, el notch no aparece al compartir pantalla ni en grabaciones.
    @Published var prompterOcultar: Bool { didSet { guardar(prompterOcultar, "prompter.ocultar") } }

    // General
    /// El ícono de Alero en la barra de menú. Escondido, la app sigue andando (se abre otra vez desde Aplicaciones).
    @Published var iconoBarra: Bool { didSet { guardar(iconoBarra, "general.iconoBarra") } }

    // Modo limpieza (trabar el teclado)
    /// Segundos hasta que la traba se suelta sola (0 = sin tope). Ver `TopeTraba`.
    @Published var limpiezaTope: Int { didSet { guardar(limpiezaTope, "limpieza.tope") } }

    private init() {
        // El clic en el Dock viene prendido: apagado de fábrica parecía que no andaba (01/11/2026).
        // Opciones de versiones anteriores que ya no existen: se borran para no dejar basura guardada.
        for vieja in ["notch.espaciosOrden", "notch.espaciosApagados", "notch.botones", "notch.fecha"] {
            guardado.removeObject(forKey: vieja)
        }
        guardado.register(defaults: [
            "notch.activo": true, "notch.musica": true, "notch.calendario": true, "notch.teclas": true,
            "notch.estante": true, "notch.atajos": true, "notch.demora": 0.3,
            "notch.pantalla": PantallaNotch.conNotch.rawValue, "notch.capsula": true,
            "notch.ancho": 660.0, "notch.alto": 174.0,
            "notch.atajosElegidos": AtajoNotch.porDefecto.map(\.rawValue),
            "notch.barraIzquierda": ReglasBarra.izquierdaDeFabrica.map(\.clave),
            "notch.barraDerecha": ReglasBarra.derechaDeFabrica.map(\.clave),
            "notch.inicioIzquierda": TarjetaNotch.musica.rawValue, "notch.inicioDerecha": TarjetaNotch.agenda.rawValue,
            "notch.estilo": EstiloNotch.negro.rawValue, "notch.vidrio": 0.6,
            "aviso.salida": true, "aviso.corriente": true, "aviso.descargas": true,
            "mezclador.activo": true, "mezclador.recordar": true, "brillo.monitores": true, "brillo.teclasPuntero": true,
            "scroll.suave": true, "scroll.respuesta": 65.0, "scroll.paso": 40.0, "scroll.invertir": false,
            "dock.minimizar": true, "dock.alternarVentanas": true, "dock.modo": ModoDock.minimizar.rawValue, "ventanas.botonVerde": false, "ventanas.mosaico": false, "ventanas.selector": true,
            "botones.activo": false, "botones.rueda": Ajustes.porDefecto(.rueda).datos(),
            "botones.4": Ajustes.porDefecto(.cuatro).datos(), "botones.5": Ajustes.porDefecto(.cinco).datos(),
            "finder.cortar": false,
            "captura.atajoArea": AtajoTeclado.datos(.capturaPorDefecto), "captura.atajoVentana": Data(),
            "captura.atajoPantalla": Data(), "captura.carpeta": "", "captura.copiar": true, "captura.sonido": true,
            "captura.formato": FormatoCaptura.png.rawValue, "captura.congelar": true, "captura.lupa": true,
            "cafe.pausarAlBloquear": true, "cafe.dejarApagarPantalla": false, "cafe.tapaCerrada": false,
            "limpieza.tope": TopeTraba.dos.rawValue, "general.iconoBarra": true,
            "prompter.velocidad": 40.0, "prompter.letra": 20.0, "prompter.ocultar": true,
            "prompter.voz": false, "prompter.idioma": "es-AR",
        ])
        notchActivo = guardado.bool(forKey: "notch.activo")
        notchMusica = guardado.bool(forKey: "notch.musica")
        notchCalendario = guardado.bool(forKey: "notch.calendario")
        calendariosOcultos = guardado.stringArray(forKey: "notch.calendariosOcultos") ?? []
        notchTeclas = guardado.bool(forKey: "notch.teclas")
        notchEstante = guardado.bool(forKey: "notch.estante")
        notchAtajos = guardado.bool(forKey: "notch.atajos")
        notchDemora = guardado.double(forKey: "notch.demora")
        notchPantalla = PantallaNotch(rawValue: guardado.string(forKey: "notch.pantalla") ?? "") ?? .conNotch
        notchCapsula = guardado.bool(forKey: "notch.capsula")
        notchAncho = guardado.double(forKey: "notch.ancho")
        notchAlto = guardado.double(forKey: "notch.alto")
        notchAtajosElegidos = (guardado.stringArray(forKey: "notch.atajosElegidos") ?? []).compactMap(AtajoNotch.init(rawValue:))
        notchBarraIzquierda = (guardado.stringArray(forKey: "notch.barraIzquierda") ?? []).compactMap(ElementoBarra.init(clave:))
        notchBarraDerecha = (guardado.stringArray(forKey: "notch.barraDerecha") ?? []).compactMap(ElementoBarra.init(clave:))
        notchInicioIzquierda = TarjetaNotch(rawValue: guardado.string(forKey: "notch.inicioIzquierda") ?? "") ?? .musica
        notchInicioDerecha = TarjetaNotch(rawValue: guardado.string(forKey: "notch.inicioDerecha") ?? "") ?? .agenda
        notchEstilo = EstiloNotch(rawValue: guardado.string(forKey: "notch.estilo") ?? "") ?? .negro
        notchVidrio = guardado.double(forKey: "notch.vidrio")
        avisoSalida = guardado.bool(forKey: "aviso.salida")
        avisoCorriente = guardado.bool(forKey: "aviso.corriente")
        avisoDescargas = guardado.bool(forKey: "aviso.descargas")
        mezcladorActivo = guardado.bool(forKey: "mezclador.activo")
        mezcladorRecordar = guardado.bool(forKey: "mezclador.recordar")
        brilloMonitores = guardado.bool(forKey: "brillo.monitores")
        brilloTeclasPuntero = guardado.bool(forKey: "brillo.teclasPuntero")
        scrollSuave = guardado.bool(forKey: "scroll.suave")
        scrollRespuesta = guardado.double(forKey: "scroll.respuesta")
        scrollPaso = guardado.double(forKey: "scroll.paso")
        scrollInvertir = guardado.bool(forKey: "scroll.invertir")
        dockMinimizar = guardado.bool(forKey: "dock.minimizar")
        dockAlternarVentanas = guardado.bool(forKey: "dock.alternarVentanas")
        dockModo = ModoDock(rawValue: guardado.string(forKey: "dock.modo") ?? "") ?? .minimizar
        botonVerde = guardado.bool(forKey: "ventanas.botonVerde")
        mosaico = guardado.bool(forKey: "ventanas.mosaico")
        mosaicoSelector = guardado.bool(forKey: "ventanas.selector")
        botonesMouse = guardado.bool(forKey: "botones.activo")
        botonRueda = ConfigBoton.leer(guardado.data(forKey: "botones.rueda"), siNo: Ajustes.porDefecto(.rueda))
        boton4 = ConfigBoton.leer(guardado.data(forKey: "botones.4"), siNo: Ajustes.porDefecto(.cuatro))
        boton5 = ConfigBoton.leer(guardado.data(forKey: "botones.5"), siNo: Ajustes.porDefecto(.cinco))
        finderCortar = guardado.bool(forKey: "finder.cortar")
        capturaAtajoArea = AtajoTeclado.leer(guardado.data(forKey: "captura.atajoArea"))
        capturaAtajoVentana = AtajoTeclado.leer(guardado.data(forKey: "captura.atajoVentana"))
        capturaAtajoPantalla = AtajoTeclado.leer(guardado.data(forKey: "captura.atajoPantalla"))
        capturaCarpeta = guardado.string(forKey: "captura.carpeta") ?? ""
        capturaCopiar = guardado.bool(forKey: "captura.copiar")
        capturaSonido = guardado.bool(forKey: "captura.sonido")
        capturaFormato = FormatoCaptura(rawValue: guardado.string(forKey: "captura.formato") ?? "") ?? .png
        capturaCongelar = guardado.bool(forKey: "captura.congelar")
        capturaLupa = guardado.bool(forKey: "captura.lupa")
        cafePausarAlBloquear = guardado.bool(forKey: "cafe.pausarAlBloquear")
        cafeDejarApagarPantalla = guardado.bool(forKey: "cafe.dejarApagarPantalla")
        cafeTapaCerrada = guardado.bool(forKey: "cafe.tapaCerrada")
        limpiezaTope = TopeTraba(rawValue: guardado.integer(forKey: "limpieza.tope"))?.rawValue ?? TopeTraba.dos.rawValue
        iconoBarra = guardado.bool(forKey: "general.iconoBarra")
        prompterVelocidad = guardado.double(forKey: "prompter.velocidad")
        prompterLetra = guardado.double(forKey: "prompter.letra")
        prompterOcultar = guardado.bool(forKey: "prompter.ocultar")
        prompterVoz = guardado.bool(forKey: "prompter.voz")
        prompterIdioma = guardado.string(forKey: "prompter.idioma") ?? "es-AR"
    }

    /// Las pestañas del notch abierto, en el orden en que se ven (siempre al menos una).
    var notchEspacios: [EspacioNotch] { ReglasBarra.espacios(izquierda: notchBarraIzquierda, derecha: notchBarraDerecha) }

    /// Lo que hace cada botón la primera vez: los laterales van atrás y adelante, como en casi todos los mouses.
    static func porDefecto(_ boton: BotonMouse) -> ConfigBoton {
        switch boton {
        case .rueda: return ConfigBoton(accion: .nada)
        case .cuatro: return ConfigBoton(accion: .atras)
        case .cinco: return ConfigBoton(accion: .adelante)
        }
    }

    func config(_ boton: BotonMouse) -> ConfigBoton {
        switch boton {
        case .rueda: return botonRueda
        case .cuatro: return boton4
        case .cinco: return boton5
        }
    }

    func cambiar(_ boton: BotonMouse, a config: ConfigBoton) {
        switch boton {
        case .rueda: botonRueda = config
        case .cuatro: boton4 = config
        case .cinco: boton5 = config
        }
    }

    func atajoCaptura(_ modo: ModoCaptura) -> AtajoTeclado? {
        switch modo {
        case .area: return capturaAtajoArea
        case .ventana: return capturaAtajoVentana
        case .pantalla: return capturaAtajoPantalla
        }
    }

    func cambiarAtajoCaptura(_ modo: ModoCaptura, a atajo: AtajoTeclado?) {
        switch modo {
        case .area: capturaAtajoArea = atajo
        case .ventana: capturaAtajoVentana = atajo
        case .pantalla: capturaAtajoPantalla = atajo
        }
    }

    // MARK: - Datos recordados (no son opciones: los escriben el mezclador y el brillo)

    /// Volumen recordado de una app (0…1), si no estaba al 100 %. Solo con `mezcladorRecordar`.
    func volumenRecordado(_ bundle: String) -> Float? {
        guard mezcladorRecordar, let valor = (guardado.dictionary(forKey: "mezclador.volumenes") as? [String: Double])?[bundle] else { return nil }
        return Float(valor)
    }

    var hayVolumenesRecordados: Bool {
        mezcladorRecordar && !((guardado.dictionary(forKey: "mezclador.volumenes") as? [String: Double]) ?? [:]).isEmpty
    }

    func recordarVolumen(_ valor: Float, de bundle: String) {
        guard mezcladorRecordar else { return }
        let actuales = (guardado.dictionary(forKey: "mezclador.volumenes") as? [String: Double]) ?? [:]
        guardado.set(ReglasMezclador.recordar(valor, de: bundle, en: actuales), forKey: "mezclador.volumenes")
    }

    /// Lo aprendido de cada monitor (por su huella vendor:modelo:serie): si su DDC no anda y va por gamma, y el último
    /// brillo por gamma (para devolverlo al reconectarlo).
    func datoMonitor(_ clave: String, de huella: String) -> Any? {
        (guardado.dictionary(forKey: "brillo." + clave) ?? [:])[huella]
    }

    func guardarDatoMonitor(_ valor: Any?, _ clave: String, de huella: String) {
        var actuales = guardado.dictionary(forKey: "brillo." + clave) ?? [:]
        actuales[huella] = valor
        guardado.set(actuales, forKey: "brillo." + clave)
    }

    private func guardar(_ valor: Any, _ clave: String) {
        guardado.set(valor, forKey: clave)
    }
}

enum PantallaNotch: String, CaseIterable, Identifiable {
    /// La pantalla de la MacBook (la que tiene notch); si no hay, la principal.
    case conNotch
    /// La pantalla principal (la que tiene la barra de menú en Ajustes del Sistema › Pantallas).
    case principal
    /// Un notch en cada pantalla.
    case todas
    /// Sigue al mouse: aparece en la pantalla donde está el puntero.
    case mouse

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .conNotch: return T("La de la MacBook", "The MacBook's")
        case .principal: return T("La principal", "Main display")
        case .todas: return T("Todas", "All")
        case .mouse: return T("Sigue al mouse", "Follows the pointer")
        }
    }
}

enum AtajoNotch: String, CaseIterable, Identifiable {
    case cafe, estante, captura, prompter, salida, silencio, iconoBarra, ajustes

    static let porDefecto: [AtajoNotch] = [.cafe, .estante, .captura, .salida, .silencio, .iconoBarra]

    var id: String { rawValue }

    var nombre: String {
        switch self {
        case .cafe: return T("Café", "Coffee")
        case .estante: return T("Estante", "Shelf")
        case .captura: return T("Captura de pantalla", "Screenshot")
        case .prompter: return T("Teleprompter", "Teleprompter")
        case .salida: return T("Salida de sonido", "Sound output")
        case .silencio: return T("Silencio", "Mute")
        case .iconoBarra: return T("Ícono de la barra", "Menu bar icon")
        case .ajustes: return T("Ajustes de Alero", "Alero settings")
        }
    }

    /// Qué hace, para la página Atajos.
    var detalle: String {
        switch self {
        case .cafe: return T("Prende o apaga el café (la Mac no se duerme).", "Turns coffee on or off (the Mac stays awake).")
        case .estante: return T("Abre el estante con tus archivos.", "Opens the shelf with your files.")
        case .captura: return T("Captura un área de la pantalla.", "Captures an area of the screen.")
        case .prompter: return T("Abre tu guion debajo de la cámara.", "Opens your script under the camera.")
        case .salida: return T("Pasa a la próxima salida de sonido.", "Switches to the next sound output.")
        case .silencio: return T("Silencia o vuelve a prender el sonido.", "Mutes or unmutes the sound.")
        case .iconoBarra: return T("Muestra o esconde el ícono de Alero en la barra de menú.", "Shows or hides Alero's menu bar icon.")
        case .ajustes: return T("Abre la ventana de Alero para configurarla (útil con el ícono de la barra escondido).",
                                "Opens the Alero window to set it up (handy with the menu bar icon hidden).")
        }
    }

    var icono: String {
        switch self {
        case .cafe: return "cup.and.saucer.fill"
        case .estante: return "tray.full.fill"
        case .captura: return "camera.viewfinder"
        case .prompter: return "text.alignleft"
        case .salida: return "hifispeaker.fill"
        case .silencio: return "speaker.slash.fill"
        case .iconoBarra: return "menubar.rectangle"
        case .ajustes: return "gearshape.fill"
        }
    }
}
