import AppKit
import ScreenCaptureKit

// El que saca las fotos, con ScreenCaptureKit (la API pública de macOS 14; la vieja `CGWindowListCreateImage` está
// deprecada). Todas las capturas dejan afuera las ventanas de Alero (notch, editor, imágenes fijadas, la superficie
// de selección). Pide el permiso de Grabación de pantalla. Las respuestas llegan siempre en el hilo principal.

enum MotorCaptura {
    enum Falla: Error { case sinPermiso, noEncontrada, sistema(Error) }

    /// Una foto quieta de una pantalla, con lo que hace falta para recortarla después.
    struct Foto {
        let pantalla: CGDirectDisplayID
        let imagen: CGImage
        /// Píxeles por punto (2 en Retina).
        let escala: CGFloat
    }

    // MARK: - Pantallas

    /// Una foto de cada pantalla, todas a la vez (para elegir sobre la pantalla congelada).
    static func congelar(_ pantallas: [NSScreen], listo: @escaping (Result<[Foto], Falla>) -> Void) {
        contenido { resultado in
            switch resultado {
            case .failure(let falla): listo(.failure(falla))
            case .success(let contenido):
                let grupo = DispatchGroup()
                var fotos: [Foto] = []
                var primeraFalla: Falla?
                for pantalla in pantallas {
                    grupo.enter()
                    capturar(pantalla, recorte: nil, contenido: contenido) { r in
                        switch r {
                        case .success(let foto): fotos.append(foto)
                        case .failure(let falla): primeraFalla = primeraFalla ?? falla
                        }
                        grupo.leave()
                    }
                }
                grupo.notify(queue: .main) {
                    // Sin todas las pantallas no se puede elegir bien: falla entera (no a medias).
                    if let primeraFalla { listo(.failure(primeraFalla)) } else { listo(.success(fotos)) }
                }
            }
        }
    }

    /// Una pantalla en vivo, entera o solo `recorte` (coordenadas de AppKit). Para el modo sin congelar.
    static func capturar(_ pantalla: NSScreen, recorte: CGRect?, listo: @escaping (Result<Foto, Falla>) -> Void) {
        contenido { resultado in
            switch resultado {
            case .failure(let falla): listo(.failure(falla))
            case .success(let contenido): capturar(pantalla, recorte: recorte, contenido: contenido, listo: listo)
            }
        }
    }

    private static func capturar(_ pantalla: NSScreen, recorte: CGRect?, contenido: SCShareableContent,
                                 listo: @escaping (Result<Foto, Falla>) -> Void) {
        let numero = pantalla.numero
        guard let display = contenido.displays.first(where: { $0.displayID == numero }) else {
            listo(.failure(.noEncontrada))
            return
        }
        let escala = pantalla.backingScaleFactor
        let filtro = SCContentFilter(display: display, excludingApplications: propias(contenido), exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        let puntos: CGSize
        if let recorte {
            let local = GeometriaCaptura.local(recorte, enPantalla: pantalla.frame)
            config.sourceRect = local
            puntos = local.size
        } else {
            puntos = pantalla.frame.size
        }
        config.width = max(1, Int((puntos.width * escala).rounded()))
        config.height = max(1, Int((puntos.height * escala).rounded()))
        SCScreenshotManager.captureImage(contentFilter: filtro, configuration: config) { imagen, error in
            DispatchQueue.main.async {
                if let imagen { listo(.success(Foto(pantalla: numero, imagen: imagen, escala: escala))) } else {
                    listo(.failure(error.map(Falla.sistema) ?? .noEncontrada))
                }
            }
        }
    }

    // MARK: - Ventanas

    /// Las ventanas que se pueden elegir con un clic, de adelante hacia atrás (para resaltar la que está bajo el
    /// puntero). Es una foto del momento: alcanza porque la selección dura segundos.
    static func ventanasVisibles() -> [VentanaCandidata] {
        guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let altoPrincipal = NSScreen.screens.first?.frame.height ?? 0
        let propio = ProcessInfo.processInfo.processIdentifier
        return lista.compactMap { info in
            guard let numero = info[kCGWindowNumber as String] as? NSNumber,
                  let limites = info[kCGWindowBounds as String] as? NSDictionary,
                  let cuarzo = CGRect(dictionaryRepresentation: limites) else { return nil }
            let capa = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let alfa = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard GeometriaCaptura.esCapturable(capa: capa, alfa: alfa, marco: cuarzo, pid: pid, propio: propio) else { return nil }
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            return VentanaCandidata(id: numero.uint32Value, marco: Geometria.aEventos(cuarzo, altoPrincipal: altoPrincipal), app: app)
        }
    }

    /// Una ventana sola, aunque esté tapada por otras, a su resolución completa. Sin la sombra de macOS: si se pide,
    /// la sombra se la dibuja Alero después (la de ScreenCaptureKit achica la ventana para que entre la sombra).
    static func capturar(ventana id: CGWindowID, listo: @escaping (Result<Foto, Falla>) -> Void) {
        contenido { resultado in
            guard case .success(let contenido) = resultado else {
                if case .failure(let falla) = resultado { listo(.failure(falla)) }
                return
            }
            guard let ventana = contenido.windows.first(where: { $0.windowID == id }) else {
                listo(.failure(.noEncontrada))
                return
            }
            let filtro = SCContentFilter(desktopIndependentWindow: ventana)
            let escala = CGFloat(filtro.pointPixelScale)
            let config = SCStreamConfiguration()
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
            config.showsCursor = false
            config.captureResolution = .best
            config.width = max(1, Int((filtro.contentRect.width * escala).rounded()))
            config.height = max(1, Int((filtro.contentRect.height * escala).rounded()))
            SCScreenshotManager.captureImage(contentFilter: filtro, configuration: config) { imagen, error in
                DispatchQueue.main.async {
                    if let imagen { listo(.success(Foto(pantalla: 0, imagen: imagen, escala: escala))) } else {
                        listo(.failure(error.map(Falla.sistema) ?? .noEncontrada))
                    }
                }
            }
        }
    }

    // MARK: - Ayudas

    private static func contenido(_ listo: @escaping (Result<SCShareableContent, Falla>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { contenido, error in
            DispatchQueue.main.async {
                if let contenido { listo(.success(contenido)); return }
                // Sin permiso, macOS responde con un error de "usuario negó": se distingue para avisar bien.
                let nsError = error as NSError?
                let negado = nsError?.domain == SCStreamErrorDomain && nsError?.code == SCStreamError.userDeclined.rawValue
                listo(.failure(negado || !Permisos.grabacionPantalla ? .sinPermiso : .sistema(error ?? Falla.noEncontrada)))
            }
        }
    }

    /// Alero misma, para dejarla afuera de la foto.
    private static func propias(_ contenido: SCShareableContent) -> [SCRunningApplication] {
        let propio = ProcessInfo.processInfo.processIdentifier
        return contenido.applications.filter { $0.processID == propio }
    }
}
