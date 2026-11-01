import CoreGraphics

// Las cuentas de "Acomodar ventanas" (ver `Mosaico`), sin pantallas ni Accesibilidad: en qué zona cae el puntero al
// arrastrar una ventana, qué rectángulo le toca a cada zona según dónde están las barras, qué queda libre, cómo se
// reacomoda el grupo al sumar una ventana, dónde van las barras y cómo se mueven si agrandás una ventana a mano.
// Todo en coordenadas de eventos (origen arriba a la izquierda). La pantalla se piensa como una grilla de 2×2: cada
// zona ocupa una, dos o las cuatro celdas. Las ventanas quedan pegadas (`separacion`); la barra va encima de la unión.
// Con las dos columnas partidas, la línea horizontal es una sola (de lado a lado) y en el cruce hay una perilla.

enum Celda: CaseIterable { case arribaIzquierda, arribaDerecha, abajoIzquierda, abajoDerecha }

enum Columna: Hashable { case izquierda, derecha }

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

    /// La columna de una mitad o de un cuarto (nil para la pantalla entera).
    var columna: Columna? {
        switch self {
        case .izquierda, .arribaIzquierda, .abajoIzquierda: return .izquierda
        case .derecha, .arribaDerecha, .abajoDerecha: return .derecha
        case .completa: return nil
        }
    }

    var esCuarto: Bool { celdas.count == 1 }
    var deArriba: Bool { self == .arribaIzquierda || self == .arribaDerecha }

    static func de(_ celda: Celda) -> ZonaMosaico {
        switch celda {
        case .arribaIzquierda: return .arribaIzquierda
        case .arribaDerecha: return .arribaDerecha
        case .abajoIzquierda: return .abajoIzquierda
        case .abajoDerecha: return .abajoDerecha
        }
    }

    static func mitad(_ columna: Columna) -> ZonaMosaico { columna == .izquierda ? .izquierda : .derecha }
}

/// Dónde están las barras de un grupo, como fracción del ancho y del alto visibles (0,5 = al medio). Cada columna
/// tiene su propia barra horizontal.
struct Divisiones: Equatable {
    var x: CGFloat = 0.5
    var yIzquierda: CGFloat = 0.5
    var yDerecha: CGFloat = 0.5

    func y(_ columna: Columna) -> CGFloat { columna == .izquierda ? yIzquierda : yDerecha }
}

enum TipoBarra: Hashable {
    case vertical
    /// La de una columna, o la de las dos juntas (nil) cuando las dos están partidas.
    case horizontal(Columna?)
    /// La perilla del cruce entre la vertical y la horizontal: se mueve en diagonal.
    case cruce
}

/// Una barra entre ventanas: la franja que se puede agarrar, centrada en la unión (de `ReglasMosaico.grosorBarra`).
struct BarraMosaico: Equatable {
    let tipo: TipoBarra
    let franja: CGRect
    var vertical: Bool { tipo == .vertical }
}

/// De qué lados una pantalla sigue en otra: por ahí el puntero se pasa a la de al lado y nunca toca el borde.
struct LadosCompartidos: Equatable {
    var izquierda = false
    var derecha = false
    var arriba = false
    var abajo = false

    static func de(_ p: PantallaCG, entre todas: [PantallaCG]) -> LadosCompartidos {
        var lados = LadosCompartidos()
        let m = p.marco
        for otra in todas where otra != p {
            let o = otra.marco
            let cruzaVertical = o.minY < m.maxY && o.maxY > m.minY
            let cruzaHorizontal = o.minX < m.maxX && o.maxX > m.minX
            if cruzaVertical && abs(o.maxX - m.minX) <= 2 { lados.izquierda = true }
            if cruzaVertical && abs(o.minX - m.maxX) <= 2 { lados.derecha = true }
            if cruzaHorizontal && abs(o.maxY - m.minY) <= 2 { lados.arriba = true }
            if cruzaHorizontal && abs(o.minY - m.maxY) <= 2 { lados.abajo = true }
        }
        return lados
    }
}

/// Dónde cae el puntero: la zona y si fue por un borde que da a otra pantalla (ahí hay que quedarse un momento).
struct ToqueMosaico: Equatable {
    let zona: ZonaMosaico
    let compartido: Bool
}

enum ReglasMosaico {
    /// A cuántos puntos del borde de la pantalla tiene que llegar el puntero para que cuente.
    static let borde: CGFloat = 6
    /// En un borde que da a otra pantalla, la franja de adentro donde cuenta (quedándose un momento).
    static let bandaCompartida: CGFloat = 40
    /// Qué tan cerca de una esquina (a lo largo del borde) cuenta como esquina en vez de mitad.
    static let esquina: CGFloat = 110
    /// El hueco entre dos ventanas acomodadas: ninguno, quedan pegadas.
    static let separacion: CGFloat = 0
    /// Lo ancho de la franja que se agarra sobre la unión: tapa también los bordes con que macOS agranda cada
    /// ventana, así el clic lo toma la barra y no la ventana.
    static let grosorBarra: CGFloat = 12
    /// El lado de la perilla del cruce.
    static let tamanoCruce: CGFloat = 30
    /// Las barras no se corren más allá de esto: ninguna ventana queda más angosta que el 15 % de la pantalla.
    static let limite: ClosedRange<CGFloat> = 0.15...0.85

    /// La zona según dónde está el puntero en `pantalla`, o nil si no está contra un borde. Al costado: una mitad;
    /// cerca de una esquina (por el costado o por arriba): un cuarto; arriba en el medio: toda la pantalla. Abajo
    /// solo cuentan las esquinas (en el medio está el Dock). En los lados que dan a otra pantalla la franja es más ancha.
    static func zona(en p: CGPoint, pantalla: PantallaCG, compartidos: LadosCompartidos = LadosCompartidos()) -> ToqueMosaico? {
        let m = pantalla.marco
        guard p.x >= m.minX - 1, p.x <= m.maxX + 1, p.y >= m.minY - 1, p.y <= m.maxY + 1 else { return nil }
        let izquierda = p.x <= m.minX + (compartidos.izquierda ? bandaCompartida : borde)
        let derecha = p.x >= m.maxX - (compartidos.derecha ? bandaCompartida : borde) - 1
        let arriba = p.y <= m.minY + (compartidos.arriba ? bandaCompartida : borde)
        let abajo = p.y >= m.maxY - (compartidos.abajo ? bandaCompartida : borde) - 1
        let cercaArriba = p.y <= pantalla.visible.minY + esquina
        let cercaAbajo = p.y >= pantalla.visible.maxY - esquina
        let cercaIzquierda = p.x <= m.minX + esquina
        let cercaDerecha = p.x >= m.maxX - esquina
        if izquierda || derecha {
            let compartido = izquierda ? compartidos.izquierda : compartidos.derecha
            if cercaArriba { return ToqueMosaico(zona: izquierda ? .arribaIzquierda : .arribaDerecha, compartido: compartido) }
            if cercaAbajo { return ToqueMosaico(zona: izquierda ? .abajoIzquierda : .abajoDerecha, compartido: compartido) }
            return ToqueMosaico(zona: izquierda ? .izquierda : .derecha, compartido: compartido)
        }
        if arriba {
            if cercaIzquierda { return ToqueMosaico(zona: .arribaIzquierda, compartido: compartidos.arriba) }
            if cercaDerecha { return ToqueMosaico(zona: .arribaDerecha, compartido: compartidos.arriba) }
            return ToqueMosaico(zona: .completa, compartido: compartidos.arriba)
        }
        if abajo {
            if cercaIzquierda { return ToqueMosaico(zona: .abajoIzquierda, compartido: compartidos.abajo) }
            if cercaDerecha { return ToqueMosaico(zona: .abajoDerecha, compartido: compartidos.abajo) }
        }
        return nil
    }

    /// El rectángulo de una zona dentro de la parte visible de la pantalla, con las barras en `d`. Contra los bordes
    /// de la pantalla llega justo; entre ventanas deja medio hueco de cada lado.
    static func marco(_ zona: ZonaMosaico, en v: CGRect, divisiones d: Divisiones = Divisiones()) -> CGRect {
        guard let columna = zona.columna else { return v }
        let medio = separacion / 2
        let corteX = (v.minX + v.width * d.x).rounded()
        let col = columna == .izquierda
            ? CGRect(x: v.minX, y: v.minY, width: corteX - medio - v.minX, height: v.height)
            : CGRect(x: corteX + medio, y: v.minY, width: v.maxX - corteX - medio, height: v.height)
        guard zona.esCuarto else { return col }
        let corteY = (v.minY + v.height * d.y(columna)).rounded()
        return zona.deArriba
            ? CGRect(x: col.minX, y: v.minY, width: col.width, height: corteY - medio - v.minY)
            : CGRect(x: col.minX, y: corteY + medio, width: col.width, height: v.maxY - corteY - medio)
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

    /// Si dos zonas se pisan (comparten alguna celda).
    static func sePisan(_ a: ZonaMosaico, _ b: ZonaMosaico) -> Bool { !a.celdas.isDisjoint(with: b.celdas) }

    /// Al soltar una ventana en `nueva`, qué pasa con cada una de las que ya estaban: sigue igual, pasa a otra zona
    /// o sale (nil). Si la nueva va a un cuarto de una columna que ocupaba una mitad, esa mitad se corre al otro
    /// cuarto de la columna (así entra una tercera app sin perder ninguna). Las demás que pisa, salen.
    static func acomodar(_ nueva: ZonaMosaico, entre ocupadas: [ZonaMosaico]) -> [ZonaMosaico?] {
        ocupadas.map { zona in
            guard sePisan(zona, nueva) else { return zona }
            if nueva.esCuarto, let columna = nueva.columna, zona == .mitad(columna) {
                return nueva.deArriba ? (columna == .izquierda ? .abajoIzquierda : .abajoDerecha)
                                      : (columna == .izquierda ? .arribaIzquierda : .arribaDerecha)
            }
            return nil
        }
    }

    /// Las barras entre las ventanas de un grupo: una vertical si hay ventanas a los dos lados; una horizontal en
    /// cada columna que tiene una ventana arriba y otra abajo (una sola de lado a lado si son las dos, con la
    /// perilla del cruce).
    static func barras(ocupadas: [ZonaMosaico], en v: CGRect, divisiones d: Divisiones) -> [BarraMosaico] {
        guard !ocupadas.contains(.completa) else { return [] }
        let medio = grosorBarra / 2
        let columnas = Set(ocupadas.compactMap(\.columna))
        let corteX = (v.minX + v.width * d.x).rounded()
        var barras: [BarraMosaico] = []
        let vertical = columnas.count == 2
        if vertical {
            barras.append(BarraMosaico(tipo: .vertical, franja: CGRect(x: corteX - medio, y: v.minY, width: grosorBarra, height: v.height)))
        }
        let partidas = [Columna.izquierda, .derecha].filter { partida($0, ocupadas) }
        if partidas.count == 2 {
            let corteY = (v.minY + v.height * d.yIzquierda).rounded()
            barras.append(BarraMosaico(tipo: .horizontal(nil), franja: CGRect(x: v.minX, y: corteY - medio, width: v.width, height: grosorBarra)))
            barras.append(BarraMosaico(tipo: .cruce, franja: CGRect(x: corteX - tamanoCruce / 2, y: corteY - tamanoCruce / 2,
                                                                   width: tamanoCruce, height: tamanoCruce)))
        } else {
            for columna in partidas {
                let col = marco(.mitad(columna), en: v, divisiones: d)
                let corteY = (v.minY + v.height * d.y(columna)).rounded()
                barras.append(BarraMosaico(tipo: .horizontal(columna),
                                           franja: CGRect(x: col.minX, y: corteY - medio, width: col.width, height: grosorBarra)))
            }
        }
        return barras
    }

    /// Si una columna tiene una ventana arriba y otra abajo.
    static func partida(_ columna: Columna, _ ocupadas: [ZonaMosaico]) -> Bool {
        columna == .izquierda ? ocupadas.contains(.arribaIzquierda) && ocupadas.contains(.abajoIzquierda)
                              : ocupadas.contains(.arribaDerecha) && ocupadas.contains(.abajoDerecha)
    }

    /// Con las dos columnas partidas la línea horizontal es una sola: las dos alturas pasan a ser la de la izquierda.
    static func unificar(_ d: Divisiones, ocupadas: [ZonaMosaico]) -> Divisiones {
        guard partida(.izquierda, ocupadas) && partida(.derecha, ocupadas) else { return d }
        var nuevas = d
        nuevas.yDerecha = d.yIzquierda
        return nuevas
    }

    /// Las divisiones con una barra llevada hasta `p` (sin pasarse de `limite`).
    static func mover(_ d: Divisiones, _ tipo: TipoBarra, hasta p: CGPoint, en v: CGRect) -> Divisiones {
        var nuevas = d
        let x = limitar((p.x - v.minX) / v.width)
        let y = limitar((p.y - v.minY) / v.height)
        switch tipo {
        case .vertical: nuevas.x = x
        case .horizontal(.izquierda): nuevas.yIzquierda = y
        case .horizontal(.derecha): nuevas.yDerecha = y
        case .horizontal(nil): nuevas.yIzquierda = y; nuevas.yDerecha = y
        case .cruce: nuevas.x = x; nuevas.yIzquierda = y; nuevas.yDerecha = y
        }
        return nuevas
    }

    /// Las divisiones con una barra otra vez al medio (doble clic o "Al medio").
    static func centrar(_ d: Divisiones, _ tipo: TipoBarra) -> Divisiones {
        var nuevas = d
        switch tipo {
        case .vertical: nuevas.x = 0.5
        case .horizontal(.izquierda): nuevas.yIzquierda = 0.5
        case .horizontal(.derecha): nuevas.yDerecha = 0.5
        case .horizontal(nil): nuevas.yIzquierda = 0.5; nuevas.yDerecha = 0.5
        case .cruce: nuevas = Divisiones()
        }
        return nuevas
    }

    /// "Cambiar" en una barra: las ventanas de un lado pasan al otro (izquierda ↔ derecha en la vertical; arriba ↔
    /// abajo en una horizontal, en su columna o en las dos). En el cruce no hay cambio.
    static func intercambiar(_ zona: ZonaMosaico, _ tipo: TipoBarra) -> ZonaMosaico {
        switch tipo {
        case .vertical:
            switch zona {
            case .izquierda: return .derecha
            case .derecha: return .izquierda
            case .arribaIzquierda: return .arribaDerecha
            case .arribaDerecha: return .arribaIzquierda
            case .abajoIzquierda: return .abajoDerecha
            case .abajoDerecha: return .abajoIzquierda
            case .completa: return .completa
            }
        case .horizontal(let columna):
            guard columna == nil || zona.columna == columna else { return zona }
            switch zona {
            case .arribaIzquierda: return .abajoIzquierda
            case .abajoIzquierda: return .arribaIzquierda
            case .arribaDerecha: return .abajoDerecha
            case .abajoDerecha: return .arribaDerecha
            default: return zona
            }
        case .cruce:
            return zona
        }
    }

    /// Si una ventana del grupo se agrandó o se achicó desde un borde de adentro (el que da a otra ventana, a mano o
    /// porque la app no se deja achicar más), las divisiones nuevas para que las demás la sigan. Nil si sus bordes
    /// de adentro siguen donde estaban.
    static func divisiones(siCambio zona: ZonaMosaico, a r: CGRect, ocupadas: [ZonaMosaico], en v: CGRect,
                           divisiones d: Divisiones) -> Divisiones? {
        guard let columna = zona.columna else { return nil }
        let esperado = marco(zona, en: v, divisiones: d)
        let medio = separacion / 2
        let tipos = Set(barras(ocupadas: ocupadas, en: v, divisiones: d).map(\.tipo))
        let lineaUnica = tipos.contains(.horizontal(nil))
        var nuevas = d
        if tipos.contains(.vertical) {
            if columna == .izquierda, abs(r.maxX - esperado.maxX) > 4 { nuevas.x = limitar((r.maxX + medio - v.minX) / v.width) }
            if columna == .derecha, abs(r.minX - esperado.minX) > 4 { nuevas.x = limitar((r.minX - medio - v.minX) / v.width) }
        }
        if zona.esCuarto, tipos.contains(.horizontal(columna)) || lineaUnica {
            let borde = zona.deArriba ? r.maxY + medio : r.minY - medio
            let antes = zona.deArriba ? esperado.maxY : esperado.minY
            if abs((zona.deArriba ? r.maxY : r.minY) - antes) > 4 {
                let y = limitar((borde - v.minY) / v.height)
                if lineaUnica {
                    nuevas.yIzquierda = y
                    nuevas.yDerecha = y
                } else if columna == .izquierda {
                    nuevas.yIzquierda = y
                } else {
                    nuevas.yDerecha = y
                }
            }
        }
        return nuevas == d ? nil : nuevas
    }

    static func limitar(_ f: CGFloat) -> CGFloat { min(max(f, limite.lowerBound), limite.upperBound) }
}
