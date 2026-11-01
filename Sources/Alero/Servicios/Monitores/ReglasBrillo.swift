import CoreGraphics
import Foundation

// Las cuentas del brillo de los monitores, sin tocar ninguna pantalla (se prueban con `swift test`): los paquetes de
// DDC/CI con su checksum, cómo se reconoce cada monitor, cuál es la pantalla del puntero y la curva de la atenuación
// por software (gamma).

/// DDC/CI: el protocolo con el que la Mac le habla al monitor por el cable (el mismo de los botones del monitor).
/// Cada orden viaja por I2C a la dirección 0x37 del monitor; "VCP 0x10" es el brillo.
enum ProtocoloDDC {
    static let direccionMonitor: UInt32 = 0x37
    /// "Sub-dirección" donde escucha el monitor (la de la Mac, 0x51, como origen del paquete).
    static let direccionOrigen: UInt32 = 0x51
    static let brillo: UInt8 = 0x10
    /// Tiempo mínimo entre dos órdenes al mismo monitor: más rápido, algunos se desconectan y vuelven.
    static let esperaEntreOrdenes: TimeInterval = 0.05

    /// XOR de todos los bytes, empezando por una semilla. Al mandar, la semilla es la dirección del monitor en 8 bits
    /// (0x6E) con la de origen (0x51); en la respuesta, 0x50 (la Mac como destino).
    static func checksum(_ bytes: [UInt8], semilla: UInt8) -> UInt8 {
        bytes.reduce(semilla, ^)
    }

    private static let semillaEnvio = UInt8(direccionMonitor << 1) ^ UInt8(direccionOrigen)

    /// "Poné el VCP en este valor": largo (0x80 | 4), orden 0x03, VCP, valor alto, valor bajo y checksum.
    static func pedidoEscritura(vcp: UInt8, valor: UInt16) -> [UInt8] {
        let cuerpo: [UInt8] = [0x84, 0x03, vcp, UInt8(valor >> 8), UInt8(valor & 0xFF)]
        return cuerpo + [checksum(cuerpo, semilla: semillaEnvio)]
    }

    /// "Decime cuánto vale el VCP": largo (0x80 | 2), orden 0x01, VCP y checksum.
    static func pedidoLectura(vcp: UInt8) -> [UInt8] {
        let cuerpo: [UInt8] = [0x82, 0x01, vcp]
        return cuerpo + [checksum(cuerpo, semilla: semillaEnvio)]
    }

    /// La respuesta a `pedidoLectura`: 11 bytes (origen 0x6E, largo 0x88, orden 0x02, resultado, VCP, tipo, máximo,
    /// actual y checksum). Nil si el checksum no da, el monitor contestó error o habló de otro VCP: hay adaptadores
    /// que devuelven bytes viejos o ceros, y tomar eso como verdad dejaría el deslizador en cualquier lado.
    static func leerRespuesta(_ bytes: [UInt8], vcp: UInt8) -> (actual: UInt16, maximo: UInt16)? {
        guard bytes.count >= 11, bytes[10] == checksum(Array(bytes[0..<10]), semilla: 0x50),
              bytes[1] == 0x88, bytes[2] == 0x02, bytes[3] == 0x00, bytes[4] == vcp else { return nil }
        let maximo = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let actual = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximo > 0 else { return nil }
        return (min(actual, maximo), maximo)
    }

    /// Del deslizador (0…1) al valor del monitor (0…máximo, casi siempre 100) y de vuelta.
    static func valor(de nivel: Float, maximo: UInt16) -> UInt16 {
        UInt16((min(max(nivel, 0), 1) * Float(maximo)).rounded())
    }

    static func nivel(de valor: UInt16, maximo: UInt16) -> Float {
        maximo == 0 ? 0 : min(Float(valor) / Float(maximo), 1)
    }
}

/// Cómo se reconoce un monitor entre conexiones: fabricante, modelo y número de serie (del EDID). El número de
/// pantalla de macOS no sirve: al reconectar, otro monitor puede heredar el número y quedarse con un brillo ajeno.
struct IdentidadMonitor: Equatable {
    let fabricante: UInt32
    let modelo: UInt32
    let serie: UInt32

    var huella: String { "\(fabricante):\(modelo):\(serie)" }

    /// El fabricante viene a veces como tres letras ("XMI", "GSM"): se pasa al número del EDID (5 bits por letra).
    static func fabricante(letras: String) -> UInt32? {
        let valores = letras.uppercased().unicodeScalars.map { Int($0.value) - 64 }
        guard valores.count == 3, valores.allSatisfy({ (1...26).contains($0) }) else { return nil }
        return UInt32(valores[0] << 10 | valores[1] << 5 | valores[2])
    }

    /// Une cada pantalla con su canal DDC. Primero los que coinciden en fabricante, modelo y serie; después los que
    /// coinciden en fabricante y modelo (dos monitores iguales sin serie quedan en el orden en que aparecen). Si al
    /// final sobra exactamente una pantalla y un canal, se unen (pasa con adaptadores que no copian el EDID).
    /// Devuelve, para cada pantalla emparejada, el índice de su canal.
    static func emparejar(pantallas: [IdentidadMonitor], canales: [IdentidadMonitor]) -> [Int: Int] {
        var resultado: [Int: Int] = [:]
        var libres = Set(canales.indices)
        for exigirSerie in [true, false] {
            for (p, pantalla) in pantallas.enumerated() where resultado[p] == nil {
                let candidato = canales.indices.first { c in
                    let canal = canales[c]
                    guard libres.contains(c), canal.fabricante == pantalla.fabricante, canal.modelo == pantalla.modelo else { return false }
                    return !exigirSerie || (pantalla.serie != 0 && canal.serie == pantalla.serie)
                }
                if let candidato { resultado[p] = candidato; libres.remove(candidato) }
            }
        }
        let sinCanal = pantallas.indices.filter { resultado[$0] == nil }
        if sinCanal.count == 1, libres.count == 1, let canal = libres.first { resultado[sinCanal[0]] = canal }
        return resultado
    }
}

enum ReglasBrillo {
    /// La pantalla donde está el puntero (coordenadas globales de CoreGraphics, origen arriba a la izquierda). Un
    /// punto justo en el borde derecho o de abajo no cae "dentro" de ningún rectángulo: va a la más cercana.
    static func pantallaDelPuntero(_ punto: CGPoint, en pantallas: [(id: CGDirectDisplayID, marco: CGRect)]) -> CGDirectDisplayID? {
        if let dentro = pantallas.first(where: { $0.marco.contains(punto) }) { return dentro.id }
        return pantallas.min { distancia(punto, $0.marco) < distancia(punto, $1.marco) }?.id
    }

    private static func distancia(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Por software no se puede bajar a negro (la pantalla quedaría inservible): el deslizador va del 15 % al 100 %.
    static let pisoGamma: Float = 0.15

    /// Del deslizador (0…1) a cuánto se multiplica la curva de colores.
    static func factorGamma(_ nivel: Float) -> Float {
        pisoGamma + (1 - pisoGamma) * min(max(nivel, 0), 1)
    }

    /// La curva de la pantalla multiplicada por el factor. Siempre sobre la curva original, nunca sobre una ya
    /// atenuada (si no, cada reconexión oscurecería un poco más hasta llegar a negro).
    static func escalar(_ tabla: [CGGammaValue], factor: Float) -> [CGGammaValue] {
        tabla.map { $0 * CGGammaValue(min(max(factor, 0), 1)) }
    }

    /// Al reconectar un monitor que iba por gamma se le devuelve su brillo, pero nunca menos del 25 %: frente a una
    /// pantalla negra, desenchufar el cable es lo único que le queda a la persona.
    static func nivelAlReconectar(_ recordado: Float?) -> Float {
        max(recordado ?? 1, 0.25)
    }
}
