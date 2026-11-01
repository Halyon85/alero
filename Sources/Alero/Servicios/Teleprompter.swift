import Foundation

// El teleprompter: un guion que se lee en el notch, justo debajo de la cámara, así mirás a la gente y no a tus notas.
// Avanza a una velocidad fija después de una cuenta de 3 s; la rueda del mouse lo mueve a mano (y lo pausa). El
// desplazamiento no se guarda en cada cuadro: es "dónde estaba + velocidad × tiempo", así con el teleprompter
// pausado o cerrado no corre nada. En modo voz no hay velocidad: el guion sigue la palabra que vas leyendo (ver
// `SeguidorVoz`) y el texto sube para dejarla arriba. Main thread.

final class Teleprompter: ObservableObject {
    static let shared = Teleprompter()

    /// El guion. Se guarda al cambiar.
    @Published var texto: String {
        didSet {
            UserDefaults.standard.set(texto, forKey: "prompter.texto")
            palabrasCache = nil
        }
    }
    /// Modo voz: la palabra del guion que toca leer (índice en `palabras`).
    @Published private(set) var palabraActual = 0
    /// Un problema para mostrar en el teleprompter (falta un permiso, no hay español).
    @Published private(set) var aviso: String?
    @Published private(set) var corriendo = false
    /// 3, 2, 1 antes de arrancar; nil fuera de la cuenta.
    @Published private(set) var cuenta: Int?

    /// Dónde estaba (pt) cuando arrancó o se pausó, y cuándo arrancó.
    private var base: Double = 0
    private var desde = Date()
    /// El alto del texto dibujado (lo mide la vista). Se puede bajar hasta que la última línea quede arriba.
    var altoTexto: Double = 0
    var limite: Double { max(altoTexto - 40, 0) }
    private var cuentaPendiente: DispatchWorkItem?
    /// Se crea recién la primera vez que se usa el modo voz (el motor de audio no se arma si nunca se usa).
    private var seguidor: SeguidorVoz?
    private var palabrasCache: (normales: [String], rangos: [Range<String.Index>])?

    private var enVoz: Bool { Ajustes.shared.prompterVoz }

    /// Las palabras del guion (normalizadas) y dónde está cada una en el texto. Se arma una vez por guion.
    var palabras: (normales: [String], rangos: [Range<String.Index>]) {
        if let palabrasCache { return palabrasCache }
        var normales: [String] = []
        var rangos: [Range<String.Index>] = []
        var i = texto.startIndex
        while i < texto.endIndex {
            guard !texto[i].isWhitespace else { i = texto.index(after: i); continue }
            var fin = i
            while fin < texto.endIndex, !texto[fin].isWhitespace { fin = texto.index(after: fin) }
            let normal = ReglasPrompter.normal(texto[i..<fin])
            if !normal.isEmpty {
                normales.append(normal)
                rangos.append(i..<fin)
            }
            i = fin
        }
        palabrasCache = (normales, rangos)
        return (normales, rangos)
    }

    private init() {
        texto = UserDefaults.standard.string(forKey: "prompter.texto") ?? T(
            "Escribí acá tu guion. El teleprompter lo muestra justo debajo de la cámara, así mirás a la gente y no a tus notas.\n\nCon la rueda del mouse lo movés a mano. Mientras está abierto, el notch no aparece cuando compartís la pantalla.",
            "Write your script here. The teleprompter shows it right under the camera, so you look at your audience and not at your notes.\n\nUse the mouse wheel to move it by hand. While it's open, the notch doesn't show up when you share your screen.")
    }

    private var velocidad: Double { Ajustes.shared.prompterVelocidad }

    /// Cuánto subió el texto en este momento (pt). En modo voz, lo que hace falta para que la palabra que toca quede
    /// en la segunda línea (se calcula por la proporción del texto ya leído: no hace falta medir cada línea).
    func desplazamiento(_ ahora: Date = Date()) -> Double {
        if enVoz {
            let (_, rangos) = palabras
            guard palabraActual < rangos.count, !texto.isEmpty else { return min(base, limite) }
            let leido = Double(texto.distance(from: texto.startIndex, to: rangos[palabraActual].lowerBound)) / Double(texto.count)
            return min(max(leido * altoTexto - 30, 0), limite)
        }
        let actual = corriendo ? base + velocidad * ahora.timeIntervalSince(desde) : base
        return min(max(actual, 0), limite)
    }

    /// Velocidad fija: cuenta 3, 2, 1 y arranca. Voz: empieza a escuchar. Si ya corre, no hace nada.
    func empezar() {
        guard !corriendo, cuenta == nil else { return }
        aviso = nil
        if enVoz {
            if palabraActual >= palabras.normales.count { palabraActual = 0 }
            corriendo = true
            let voz = seguidor ?? SeguidorVoz()
            voz.alOir = { [weak self] dichas in self?.oir(dichas) }
            voz.alFallar = { [weak self] texto in
                self?.aviso = texto
                self?.pausar()
            }
            seguidor = voz
            voz.empezar(idioma: Ajustes.shared.prompterIdioma)
            return
        }
        if desplazamiento() >= limite { base = 0 }
        contar(3)
    }

    /// Lo que se reconoció: avanza la palabra marcada (nunca para atrás). Al final del guion se pausa solo.
    private func oir(_ dichas: [String]) {
        let guion = palabras.normales
        let nueva = ReglasPrompter.avanzar(palabraActual, guion: guion, dichas: dichas)
        guard nueva != palabraActual else { return }
        palabraActual = nueva
        if nueva >= guion.count { pausar() }
    }

    private func contar(_ numero: Int) {
        guard numero > 0 else {
            cuenta = nil
            desde = Date()
            corriendo = true
            return
        }
        cuenta = numero
        let tarea = DispatchWorkItem { [weak self] in self?.contar(numero - 1) }
        cuentaPendiente = tarea
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tarea)
    }

    func pausar() {
        cuentaPendiente?.cancel()
        cuenta = nil
        seguidor?.detener()
        guard corriendo else { return }
        base = desplazamiento()
        corriendo = false
    }

    func alternar() { corriendo || cuenta != nil ? pausar() : empezar() }

    func reiniciar() {
        pausar()
        base = 0
        palabraActual = 0
    }

    /// La rueda: mueve el texto a mano y lo pausa (como en otros teleprompters). Positivo baja en el guion.
    func desplazar(_ puntos: Double) {
        if enVoz {
            // En modo voz la rueda corre la palabra marcada (una cada 24 pt), sin dejar de escuchar.
            let paso = Int((puntos / 24).rounded())
            guard paso != 0 else { return }
            palabraActual = min(max(palabraActual + paso, 0), max(palabras.normales.count - 1, 0))
            return
        }
        pausar()
        base = min(max(base + puntos, 0), limite)
        objectWillChange.send()
    }

    /// Cambia entre velocidad fija y voz (pausa lo que esté corriendo).
    func cambiarModo() {
        pausar()
        aviso = nil
        Ajustes.shared.prompterVoz.toggle()
    }

    /// Cambia la velocidad sin saltar: lo recorrido hasta ahora queda como punto de partida.
    func cambiarVelocidad(_ nueva: Double) {
        if corriendo {
            base = desplazamiento()
            desde = Date()
        }
        Ajustes.shared.prompterVelocidad = min(max(nueva, 10), 150)
    }

    /// Al cerrarlo queda pausado donde estaba (al volver a abrirlo sigue de ahí).
    func cerrar() { pausar() }
}
