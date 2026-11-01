import AppKit
import Combine

// Capturas de pantalla, de punta a punta: los atajos de teclado, el permiso, la foto congelada, la superficie de
// selección y, al elegir, guardar el archivo, copiarlo al portapapeles y avisar en el notch con la miniatura.
// Lo llaman el atajo, el menú de la barra y el atajo del notch. Sin atajos grabados no queda nada corriendo. Main thread.

/// Una captura recién guardada, para el aviso del notch.
struct CapturaLista: Equatable {
    let url: URL
    let miniatura: NSImage
    let copiada: Bool
    /// Dónde quedó, para mostrarlo ("Escritorio"). `respaldo`: la carpeta elegida falló y quedó en el Escritorio.
    let carpeta: String
    let respaldo: Bool
}

final class Capturador: ObservableObject {
    static let shared = Capturador()

    /// Modos cuyo atajo macOS no dejó registrar (otra app ya usa esa combinación). Lo muestra Ajustes › Capturas.
    @Published private(set) var conflictos: Set<ModoCaptura> = []

    private var sesion: SesionCaptura?
    private var preparando = false
    /// Las fotos congeladas de la vuelta actual. Se sueltan apenas se recorta lo elegido.
    private var fotos: [MotorCaptura.Foto] = []
    /// La app que estaba al frente: vuelve al frente al terminar (Alero se activa mientras se elige).
    private var previa: NSRunningApplication?
    private var suscripciones = Set<AnyCancellable>()

    func arrancar() {
        let ajustes = Ajustes.shared
        Publishers.CombineLatest3(ajustes.$capturaAtajoArea, ajustes.$capturaAtajoVentana, ajustes.$capturaAtajoPantalla)
            .sink { [weak self] area, ventana, pantalla in
                self?.registrar([.area: area, .ventana: ventana, .pantalla: pantalla])
            }
            .store(in: &suscripciones)
    }

    private func registrar(_ atajos: [ModoCaptura: AtajoTeclado?]) {
        var fallidos = Set<ModoCaptura>()
        for modo in ModoCaptura.allCases {
            let atajo = atajos[modo] ?? nil
            let ok = AtajosGlobales.shared.poner(modo.numeroAtajo, atajo: atajo) { [weak self] in self?.empezar(modo) }
            if !ok { fallidos.insert(modo) }
        }
        conflictos = fallidos
    }

    /// Mientras el grabador de Ajustes escucha una combinación (si no, grabar ⇧⌘2 dispararía la captura).
    func pausarAtajos() { AtajosGlobales.shared.pausar() }

    func reanudarAtajos() {
        let fallidos = AtajosGlobales.shared.reanudar()
        conflictos = Set(ModoCaptura.allCases.filter { fallidos.contains($0.numeroAtajo) })
    }

    // MARK: - Carpeta

    static var escritorio: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    var carpeta: URL {
        let elegida = Ajustes.shared.capturaCarpeta
        return elegida.isEmpty ? Capturador.escritorio : URL(fileURLWithPath: elegida, isDirectory: true)
    }

    func abrirCarpeta() {
        let existe = FileManager.default.fileExists(atPath: carpeta.path)
        NSWorkspace.shared.open(existe ? carpeta : Capturador.escritorio)
    }

    // MARK: - Empezar

    /// Abre la superficie de selección en `modo`. Si ya está abierta, el mismo atajo la cierra y otro cambia de modo.
    func empezar(_ modo: ModoCaptura) {
        if let sesion {
            sesion.modo == modo ? sesion.cancelar() : sesion.cambiar(a: modo)
            return
        }
        guard !preparando else { return }
        guard Permisos.grabacionPantalla else { faltaPermiso(); return }
        preparando = true
        let frente = NSWorkspace.shared.frontmostApplication
        previa = frente?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frente
        let ventanas = MotorCaptura.ventanasVisibles()
        guard Ajustes.shared.capturaCongelar else {
            abrirSesion(modo, fotos: [], ventanas: ventanas)
            return
        }
        MotorCaptura.congelar(NSScreen.screens) { [weak self] resultado in
            guard let self else { return }
            switch resultado {
            case .success(let fotos): self.abrirSesion(modo, fotos: fotos, ventanas: ventanas)
            case .failure(let falla):
                self.preparando = false
                self.fallo(falla)
            }
        }
    }

    private func abrirSesion(_ modo: ModoCaptura, fotos: [MotorCaptura.Foto], ventanas: [VentanaCandidata]) {
        self.fotos = fotos
        let nueva = SesionCaptura(modo: modo, fotos: fotos, ventanas: ventanas, lupa: Ajustes.shared.capturaLupa) { [weak self] eleccion in
            self?.terminar(eleccion)
        }
        sesion = nueva
        preparando = false
        nueva.mostrar()
    }

    // MARK: - Terminar

    private func terminar(_ eleccion: EleccionCaptura?) {
        sesion = nil
        let fotos = self.fotos
        self.fotos = []
        guard let eleccion else { devolverFoco(); return }
        switch eleccion {
        case .area(let rect, let numero):
            guard let pantalla = NSScreen.screens.first(where: { $0.numero == numero }) else { devolverFoco(); return }
            devolverFoco()
            guard let foto = fotos.first(where: { $0.pantalla == numero }) else {
                MotorCaptura.capturar(pantalla, recorte: rect) { [weak self] in self?.recibir($0, sombra: false) }
                return
            }
            let local = GeometriaCaptura.local(rect, enPantalla: pantalla.frame)
            let pixeles = GeometriaCaptura.pixeles(local, escala: foto.escala, ancho: foto.imagen.width, alto: foto.imagen.height)
            guard let parte = ImagenCaptura.copia(foto.imagen, recorte: pixeles) else { fallo(.noEncontrada); return }
            procesar(parte, escala: foto.escala)
        case .pantalla(let numero):
            devolverFoco()
            if let foto = fotos.first(where: { $0.pantalla == numero }) {
                procesar(foto.imagen, escala: foto.escala)
            } else if let pantalla = NSScreen.screens.first(where: { $0.numero == numero }) {
                MotorCaptura.capturar(pantalla, recorte: nil) { [weak self] in self?.recibir($0, sombra: false) }
            }
        case .ventana(let ventana, let sombra):
            devolverFoco()
            // A propósito: se espera un instante a que la app vuelva al frente y redibuje su ventana como activa
            // (mientras se elegía, la activa era Alero y la ventana se veía apagada).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MotorCaptura.capturar(ventana: ventana.id) { self?.recibir($0, sombra: sombra) }
            }
        }
    }

    private func recibir(_ resultado: Result<MotorCaptura.Foto, MotorCaptura.Falla>, sombra: Bool) {
        switch resultado {
        case .failure(let falla): fallo(falla)
        case .success(let foto):
            let final = sombra ? (ImagenCaptura.conSombra(foto.imagen, escala: foto.escala) ?? foto.imagen) : foto.imagen
            procesar(final, escala: foto.escala)
        }
    }

    private func devolverFoco() {
        guard let previa, !previa.isTerminated else { return }
        self.previa = nil
        NSApp.yieldActivation(to: previa)
        previa.activate(options: [])
    }

    // MARK: - Guardar, copiar y avisar

    /// Codifica y guarda fuera del hilo principal; la imagen grande se suelta al terminar.
    private func procesar(_ imagen: CGImage, escala: CGFloat) {
        let ajustes = Ajustes.shared
        if ajustes.capturaSonido { ImagenCaptura.sonar() }
        let formato = ajustes.capturaFormato
        let copiar = ajustes.capturaCopiar
        let carpeta = self.carpeta
        let nombre = NombreCaptura.nombre(fecha: Date(), formato: formato, castellano: Idioma.castellano)
        DispatchQueue.global(qos: .userInitiated).async {
            let archivo = ImagenCaptura.codificar(imagen, formato: formato, escala: escala)
            let png = copiar ? (formato == .png ? archivo : ImagenCaptura.codificar(imagen, formato: .png, escala: escala)) : nil
            let guardado = archivo.flatMap { Capturador.escribir($0, nombre: nombre, en: carpeta) }
            let miniatura = (archivo ?? png).flatMap { ImagenCaptura.miniatura(de: $0, escala: escala) }
            DispatchQueue.main.async {
                if let png { ImagenCaptura.copiar(png: png) }
                Capturador.avisar(guardado: guardado, miniatura: miniatura, copiada: png != nil)
            }
        }
    }

    /// Escribe en la carpeta elegida; si no se puede (la borraron, sin permiso), en el Escritorio. Nil si ninguna
    /// anduvo. Dos capturas en el mismo segundo no se pisan ("… 2.png"). Fuera del hilo principal.
    private static func escribir(_ datos: Data, nombre: String, en carpeta: URL) -> (url: URL, respaldo: Bool)? {
        for (destino, respaldo) in [(carpeta, false), (escritorio, true)] where !(respaldo && destino == carpeta) {
            let libre = MoverArchivos.nombreLibre(nombre) { FileManager.default.fileExists(atPath: destino.appendingPathComponent($0).path) }
            let url = destino.appendingPathComponent(libre)
            do {
                try datos.write(to: url, options: .withoutOverwriting)
                return (url, respaldo)
            } catch {
                NSLog("Alero: no se pudo guardar la captura en \(destino.path): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private static func avisar(guardado: (url: URL, respaldo: Bool)?, miniatura: NSImage?, copiada: Bool) {
        guard Ajustes.shared.notchActivo else {
            if guardado == nil { NSSound.beep() }
            return
        }
        let estado = ControladorNotch.shared.estado
        guard let guardado, let miniatura else {
            estado.mostrar(.capturaFallo(copiada: copiada), durante: 4)
            return
        }
        let carpeta = FileManager.default.displayName(atPath: guardado.url.deletingLastPathComponent().path)
        estado.mostrarCaptura(CapturaLista(url: guardado.url, miniatura: miniatura, copiada: copiada,
                                           carpeta: carpeta, respaldo: guardado.respaldo))
    }

    // MARK: - Problemas

    /// Sin Grabación de pantalla: la primera vez, el cartel de macOS; después, el aviso y la página de Ajustes
    /// que explica dónde darlo (macOS no vuelve a mostrar su cartel).
    private func faltaPermiso() {
        if Ajustes.shared.notchActivo {
            ControladorNotch.shared.estado.mostrar(.permiso(nombre: T("Grabación de pantalla", "Screen Recording")))
        }
        let clave = "captura.pidioPermiso"
        if UserDefaults.standard.bool(forKey: clave) {
            VentanaAlero.shared.mostrar(.capturas)
        } else {
            UserDefaults.standard.set(true, forKey: clave)
            Permisos.pedirGrabacionPantalla()
        }
    }

    private func fallo(_ falla: MotorCaptura.Falla) {
        if case .sinPermiso = falla { faltaPermiso(); return }
        if case .sistema(let error) = falla { NSLog("Alero: la captura falló: \(error.localizedDescription)") }
        devolverFoco()
        if Ajustes.shared.notchActivo {
            ControladorNotch.shared.estado.mostrar(.capturaFallo(copiada: false), durante: 4)
        } else {
            NSSound.beep()
        }
    }
}
