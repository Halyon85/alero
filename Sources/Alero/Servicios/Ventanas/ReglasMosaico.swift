import CoreGraphics

// Las cuentas de "Acomodar ventanas" (ver `Mosaico`), sin pantallas ni Accesibilidad: en qué zona cae el puntero al
// arrastrar una ventana, qué rectángulo le toca a cada zona según dónde están las barras divisorias, qué parte de la
// pantalla queda libre y dónde van las barras. Todo en coordenadas de eventos (origen arriba a la izquierda).
// La pantalla se piensa como una grilla de 2×2: cada zona ocupa una, dos o las cuatro celdas.

enum Celda: CaseIterable { case arribaIzquierda, arribaDerecha, abajoIzquierda, abajoDerecha }

/// Dónde se puede acomodar una ventana.
enum ZonaMosaico: CaseIterable {
    case izquierda, derecha, completa, arribaIzquierda, arribaDerecha, abajoIzquierda, abajoDerecha

    var celdas: Set<Celda> {
        switch self {
        case .izquierda: return [.arribaIzquierda, .abajoIzquierda]
        case .derecha: return [.arribaDerecha, .abajoDerecha]
        case .completa: return Set(Celda.allCases)
        case .arribaIzquierda: return [.arribaIzquierda]
        case .arribaDerecha: return [.arribaDerecha]
        case .abajoIzquierda: return [.abajoIzquierda]
        case .abajoDerecha: return [.abajoDerecha]
        }
    }

    static func de(_ celda: Celda) -> ZonaMosaico {
        switch celda {
        case .arribaIzquierda: return .arribaIzquierda
        case .arribaDerecha: return .arribaDerecha
        case .abajoIzquierda: return .abajoIzquierda
        case .abajoDerecha: return .abajoDerecha
        }
    }
}

/// Dónde están las barras de un grupo, como fracción del ancho y del alto visibles (0,5 = al medio).
struct Divisiones: Equatable {
    var x: CGFloat = 0.5
    var y: CGFloat = 0.5
}

/// Una barra divisoria: vertical (cambia `Divisiones.x`) u horizontal (cambia `.y`), con la línea que ocupa.
struct BarraMosaico: Equatable {
    let vertical: Bool
    /// La línea de la unión: en una vertical, ancho 0; en una horizontal, alto 0.
    let linea: CGRect
}

enum ReglasMosaico {
    /// A cuántos puntos del borde de la pantalla tiene que llegar el puntero para que cuente.
    static let borde: CGFloat = 6
    /// Qué tan cerca de una esquina (a lo largo del borde) cuenta como esquina en vez de mitad.
    static let esquina: CGFloat = 110
    /// Las barras no se corren más allá de esto: ninguna ventana queda más angosta que el 15 % de la pantalla.
    static let limite: ClosedRange<CGFloat> = 0.15...0.85

    /// La zona según dónde está el puntero en `pantalla`, o nil si no está contra un borde. Al costado: una mitad;
    /// cerca de una esquina (por el costado o por arriba): un cuarto; arriba en el medio: toda la pantalla. Abajo
    /// solo cuentan las esquinas (en el medio está el Dock).
    static func zona(en p: CGPoint, pantalla: PantallaCG) -> ZonaMosaico? {
        let m = pantalla.marco
        guard p.x >= m.minX - 1, p.x <= m.maxX + 1, p.y >= m.minY - 1, p.y <= m.maxY + 1 else { return nil }
        let izquierda = p.x <= m.minX + borde
        let derecha = p.x >= m.maxX - borde - 1
        let arriba = p.y <= m.minY + borde
        let abajo = p.y >= m.maxY - borde - 1
        let cercaArriba = p.y <= pantalla.visible.minY + esquina
        let cercaAbajo = p.y >= pantalla.visible.maxY - esquina
        let cercaIzquierda = p.x <= m.minX + esquina
        let cercaDerecha = p.x >= m.maxX - esquina
        if izquierda || derecha {
            if cercaArriba { return izquierda ? .arribaIzquierda : .arribaDerecha }
            if cercaAbajo { return izquierda ? .abajoIzquierda : .abajoDerecha }
            return izquierda ? .izquierda : .derecha
        }
        if arriba {
            if cercaIzquierda { return .arribaIzquierda }
            if cercaDerecha { return .arribaDerecha }
            return .completa
        }
        if abajo {
            if cercaIzquierda { return .abajoIzquierda }
            if cercaDerecha { return .abajoDerecha }
        }
        return nil
    }

    /// El rectángulo de una zona dentro de la parte visible de la pantalla, con las barras en `d`.
    static func marco(_ zona: ZonaMosaico, en visible: CGRect, divisiones d: Divisiones = Divisiones()) -> CGRect {
        let corteX = (visible.minX + visible.width * d.x).rounded()
        let corteY = (visible.minY + visible.height * d.y).rounded()
        let izquierda = CGRect(x: visible.minX, y: visible.minY, width: corteX - visible.minX, height: visible.height)
        let derecha = CGRect(x: corteX, y: visible.minY, width: visible.maxX - corteX, height: visible.height)
        let arriba = corteY - visible.minY
        let abajo = visible.maxY - corteY
        switch zona {
        case .completa: return visible
        case .izquierda: return izquierda
        case .derecha: return derecha
        case .arribaIzquierda: return CGRect(x: izquierda.minX, y: visible.minY, width: izquierda.width, height: arriba)
        case .arribaDerecha: return CGRect(x: derecha.minX, y: visible.minY, width: derecha.width, height: arriba)
        case .abajoIzquierda: return CGRect(x: izquierda.minX, y: corteY, width: izquierda.width, height: abajo)
        case .abajoDerecha: return CGRect(x: derecha.minX, y: corteY, width: derecha.width, height: abajo)
        }
    }

    /// Lo que queda libre con esas zonas ocupadas, como una sola zona para ofrecer otra app: una mitad entera si
    /// está libre; si no, la primera esquina libre (de arriba a la izquierda, en el sentido del reloj). Nil si no
    /// hay nada ocupado, si está todo lleno o si una ocupa la pantalla entera.
    static func libre(ocupadas: [ZonaMosaico]) -> ZonaMosaico? {
        guard !ocupadas.isEmpty, !ocupadas.contains(.completa) else { return nil }
        let usadas = ocupadas.reduce(into: Set<Celda>()) { $0.formUnion($1.celdas) }
        let libres = Set(Celda.allCases).subtracting(usadas)
        for mitad in [ZonaMosaico.derecha, .izquierda] where mitad.celdas.isSubset(of: libres) { return mitad }
        for celda in [Celda.arribaIzquierda, .arribaDerecha, .abajoDerecha, .abajoIzquierda] where libres.contains(celda) {
            return .de(celda)
        }
        return nil
    }

    /// Si dos zonas se pisan (comparten alguna celda): al poner una ventana nueva, las que tapa salen del grupo.
    static func sePisan(_ a: ZonaMosaico, _ b: ZonaMosaico) -> Bool { !a.celdas.isDisjoint(with: b.celdas) }

    /// Las barras que hay entre las ventanas de un grupo: una vertical si hay ventanas a los dos lados, y una
    /// horizontal en cada columna que tiene una ventana arriba y otra abajo.
    static func barras(ocupadas: [ZonaMosaico], en visible: CGRect, divisiones d: Divisiones) -> [BarraMosaico] {
        guard !ocupadas.contains(.completa) else { return [] }
        let usadas = ocupadas.map(\.celdas)
        let tieneIzquierda = usadas.contains { $0.contains(.arribaIzquierda) || $0.contains(.abajoIzquierda) }
        let tieneDerecha = usadas.contains { $0.contains(.arribaDerecha) || $0.contains(.abajoDerecha) }
        let corteX = (visible.minX + visible.width * d.x).rounded()
        let corteY = (visible.minY + visible.height * d.y).rounded()
        var barras: [BarraMosaico] = []
        if tieneIzquierda && tieneDerecha {
            barras.append(BarraMosaico(vertical: true, linea: CGRect(x: corteX, y: visible.minY, width: 0, height: visible.height)))
        }
        // Una columna está partida si tiene su celda de arriba y la de abajo en ventanas distintas (dos cuartos).
        for (arriba, abajo, desde, hasta) in [(ZonaMosaico.arribaIzquierda, ZonaMosaico.abajoIzquierda, visible.minX, corteX),
                                              (.arribaDerecha, .abajoDerecha, corteX, visible.maxX)]
        where ocupadas.contains(arriba) && ocupadas.contains(abajo) {
            barras.append(BarraMosaico(vertical: false, linea: CGRect(x: desde, y: corteY, width: hasta - desde, height: 0)))
        }
        return barras
    }

    /// La fracción nueva de una barra al arrastrarla hasta `p`, sin pasarse de `limite`.
    static func fraccion(_ barra: BarraMosaico, hasta p: CGPoint, en visible: CGRect) -> CGFloat {
        let crudo = barra.vertical ? (p.x - visible.minX) / visible.width : (p.y - visible.minY) / visible.height
        return min(max(crudo, limite.lowerBound), limite.upperBound)
    }
}
