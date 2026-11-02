import AppKit

// Las pantallas en las coordenadas de los eventos y de Accesibilidad (origen arriba a la izquierda de la pantalla
// principal, y hacia abajo). AppKit usa el origen abajo y hacia arriba: acá se hace la cuenta una sola vez.
// Se guarda una copia porque NSScreen solo se puede leer en el hilo principal y las escuchas corren en otro.

/// Una pantalla en coordenadas de eventos: el marco entero y la parte que dejan libre la barra de menú y el Dock.
struct PantallaCG: Equatable {
    var marco: CGRect
    var visible: CGRect
}

/// Dónde está el Dock: una franja al borde de una pantalla y si sus íconos van en fila (abajo) o en columna.
struct FranjaDock: Equatable {
    var zona: CGRect
    var horizontal: Bool
}

enum Geometria {
    /// Pasa un rectángulo de AppKit (origen abajo) a coordenadas de eventos (origen arriba).
    static func aEventos(_ r: CGRect, altoPrincipal: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: altoPrincipal - r.maxY, width: r.width, height: r.height)
    }

    /// Franjas que el Dock le reserva a cada pantalla (más de 8 pt entre el marco y la parte visible, abajo o a un
    /// costado). Con el Dock que se oculta solo no queda reserva y no hay franja: a propósito, porque en ese caso
    /// no hay forma barata de saber si el Dock está a la vista y un clic al pie de una ventana podría minimizarla.
    static func franjasDock(_ pantallas: [PantallaCG]) -> [FranjaDock] {
        var franjas: [FranjaDock] = []
        for p in pantallas {
            let abajo = p.marco.maxY - p.visible.maxY
            let izquierda = p.visible.minX - p.marco.minX
            let derecha = p.marco.maxX - p.visible.maxX
            if abajo > 8 {
                franjas.append(FranjaDock(zona: CGRect(x: p.marco.minX, y: p.visible.maxY, width: p.marco.width, height: abajo), horizontal: true))
            }
            if izquierda > 8 {
                franjas.append(FranjaDock(zona: CGRect(x: p.marco.minX, y: p.marco.minY, width: izquierda, height: p.marco.height), horizontal: false))
            }
            if derecha > 8 {
                franjas.append(FranjaDock(zona: CGRect(x: p.visible.maxX, y: p.marco.minY, width: derecha, height: p.marco.height), horizontal: false))
            }
        }
        return franjas
    }

    /// La pantalla que más se superpone con `r` (donde "vive" una ventana). Nil si no toca ninguna.
    static func pantalla(de r: CGRect, en pantallas: [PantallaCG]) -> PantallaCG? {
        let conArea = pantallas.map { p -> (PantallaCG, CGFloat) in
            let cruce = p.marco.intersection(r)
            return (p, cruce.isNull ? 0 : cruce.width * cruce.height)
        }
        guard let mejor = conArea.max(by: { $0.1 < $1.1 }), mejor.1 > 0 else { return nil }
        return mejor.0
    }

    /// Si dos marcos coinciden con una tolerancia (las apps redondean el tamaño a su grilla).
    static func parecidos(_ a: CGRect, _ b: CGRect, tolerancia: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerancia && abs(a.minY - b.minY) <= tolerancia
            && abs(a.width - b.width) <= tolerancia && abs(a.height - b.height) <= tolerancia
    }
}

final class Pantallas {
    static let shared = Pantallas()

    private let candado = NSLock()
    private var lista: [PantallaCG] = []
    private var observador: NSObjectProtocol?

    /// Main thread. Lee las pantallas y se vuelve a leer sola cuando cambian (monitor nuevo, Dock movido u oculto).
    func arrancar() {
        guard observador == nil else { return }
        leer()
        observador = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                            object: nil, queue: .main) { [weak self] _ in self?.leer() }
    }

    /// Cualquier hilo.
    var actuales: [PantallaCG] {
        candado.lock()
        defer { candado.unlock() }
        return lista
    }

    private func leer() {
        // La principal (la de la barra de menú) es siempre la primera: su alto fija el origen de los eventos.
        let alto = NSScreen.screens.first?.frame.height ?? 0
        let nuevas = NSScreen.screens.map {
            PantallaCG(marco: Geometria.aEventos($0.frame, altoPrincipal: alto), visible: Geometria.aEventos($0.visibleFrame, altoPrincipal: alto))
        }
        candado.lock()
        let cambio = lista != nuevas
        lista = nuevas
        candado.unlock()
        // Ya con la lista nueva: `Mosaico` reacomoda sus grupos (se movió el Dock, se cambió la resolución o se
        // desconectó un monitor).
        if cambio { NotificationCenter.default.post(name: Pantallas.cambiaron, object: nil) }
    }

    /// Se avisa en el hilo principal cuando cambia alguna pantalla, después de leerlas.
    static let cambiaron = Notification.Name("alero.pantallas.cambiaron")
}
