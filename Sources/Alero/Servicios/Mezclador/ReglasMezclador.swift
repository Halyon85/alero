import CoreAudio
import Foundation

// Las cuentas del mezclador por app, sin Core Audio vivo (se prueban con `swift test`): la curva del deslizador, la
// compensación del bug de Apple en el mixdown, a qué canales de la salida va el estéreo de la app, la mezcla que corre
// en el hilo de audio, a qué app pertenece un proceso y qué hacer si el motor dejó de andar.

enum ReglasMezclador {
    // MARK: - Volumen

    /// Del deslizador (0…1) a la ganancia que se aplica. Cuadrática, como la perilla de un equipo: la mitad del
    /// deslizador suena a la mitad (−12 dB) y no a "casi igual" (con una recta, 50 % es apenas −6 dB).
    static func ganancia(deslizador: Float, silencio: Bool) -> Float {
        guard !silencio else { return 0 }
        let v = min(max(deslizador, 0), 1)
        return v * v
    }

    /// Al 100 % y sin silencio no se crea nada para la app (costo cero, el audio no se toca).
    static func esNeutro(deslizador: Float, silencio: Bool) -> Bool {
        !silencio && deslizador >= 0.995
    }

    /// El mixdown estéreo de un tap divide el nivel por la cantidad de pares de canales de la salida (bug de Apple
    /// FB13479345): en una tele de 8 canales la app llegaría al 25 %. Se devuelve el nivel multiplicando por
    /// canales/2, con tope 4 (más que eso no existe en la práctica y evita saturar si macOS lo arregla a medias).
    static func compensacion(canales: Int) -> Float {
        min(max(Float(canales) / 2, 1), 4)
    }

    // MARK: - A qué canales va el sonido

    /// Un canal de la salida: en qué buffer (stream) está y cuál es dentro de él.
    struct Lugar: Equatable {
        let buffer: Int
        let canal: Int
    }

    /// Dónde va cada lado del estéreo de la app. Si los dos lados caen en el mismo canal, la salida es mono (un
    /// auricular de llamada) y se mezclan los dos: copiar el estéreo crudo ahí hace que suene lento y una octava abajo.
    struct MapaSalida: Equatable {
        let izquierda: Lugar
        let derecha: Lugar
        /// Canales del stream que lleva el lado izquierdo (para la compensación del mixdown).
        let canalesDelStream: Int

        var mono: Bool { izquierda == derecha }

        /// `canales`: cuántos canales tiene cada stream de salida. `par`: el par estéreo preferido de la salida,
        /// contado desde 1 como lo da Core Audio (nil o inválido = los dos primeros). Nil si no hay canales.
        static func armar(canales: [Int], par: (UInt32, UInt32)?) -> MapaSalida? {
            let total = canales.reduce(0, +)
            guard total > 0 else { return nil }
            func valido(_ n: UInt32) -> Bool { n >= 1 && Int(n) <= total }
            var izquierdo = 1
            var derecho = min(2, total)
            if let par, valido(par.0), valido(par.1) { izquierdo = Int(par.0); derecho = Int(par.1) }
            guard let i = lugar(izquierdo - 1, en: canales), let d = lugar(derecho - 1, en: canales) else { return nil }
            return MapaSalida(izquierda: i, derecha: d, canalesDelStream: canales[i.buffer])
        }

        /// Pasa un número de canal "corrido" (0 = el primero del primer stream) a su buffer y su lugar.
        private static func lugar(_ indice: Int, en canales: [Int]) -> Lugar? {
            var resto = indice
            for (buffer, cantidad) in canales.enumerated() {
                if resto < cantidad { return Lugar(buffer: buffer, canal: resto) }
                resto -= cantidad
            }
            return nil
        }
    }

    // MARK: - La mezcla (hilo de audio)

    /// Copia el sonido de la app (el último buffer de entrada con datos: el agregado pone primero el micrófono de la
    /// salida, si tiene, y el tap al final) a la salida, con la ganancia pasando de `desde` a `hasta` a lo largo del
    /// buffer (así un cambio del deslizador no hace "clic"). Todo lo demás de la salida queda en silencio: si no se
    /// escribe, suena lo que el sistema dejó en el buffer.
    ///
    /// Corre en el hilo de tiempo real de Core Audio: no reserva memoria, no usa candados y no llama a Objective-C.
    /// Asume muestras Float32 intercaladas (el motor revisa los formatos antes de arrancar). Si el mapa no coincide con
    /// los buffers (la salida cambió y el motor todavía no se rehizo), deja silencio en vez de escribir afuera.
    static func mezclar(entrada: UnsafeMutableAudioBufferListPointer?, salida: UnsafeMutableAudioBufferListPointer,
                        mapa: MapaSalida, desde: Float, hasta: Float) {
        for buffer in salida {
            if let datos = buffer.mData { memset(datos, 0, Int(buffer.mDataByteSize)) }
        }
        guard let entrada, let origen = entrada.last(where: { $0.mData != nil && $0.mNumberChannels > 0 }),
              let datosOrigen = origen.mData,
              mapa.izquierda.buffer < salida.count, mapa.derecha.buffer < salida.count else { return }
        let bufIzq = salida[mapa.izquierda.buffer]
        let bufDer = salida[mapa.derecha.buffer]
        guard let datosIzq = bufIzq.mData, let datosDer = bufDer.mData,
              mapa.izquierda.canal < Int(bufIzq.mNumberChannels), mapa.derecha.canal < Int(bufDer.mNumberChannels) else { return }

        let canalesEntrada = Int(origen.mNumberChannels)
        let canalesIzq = Int(bufIzq.mNumberChannels)
        let canalesDer = Int(bufDer.mNumberChannels)
        let tam = MemoryLayout<Float>.size
        let cuadrosEntrada = Int(origen.mDataByteSize) / (tam * canalesEntrada)
        let cuadros = min(cuadrosEntrada, Int(bufIzq.mDataByteSize) / (tam * canalesIzq), Int(bufDer.mDataByteSize) / (tam * canalesDer))
        guard cuadros > 0 else { return }

        let muestras = datosOrigen.assumingMemoryBound(to: Float.self)
        let izq = datosIzq.assumingMemoryBound(to: Float.self)
        let der = datosDer.assumingMemoryBound(to: Float.self)
        let paso = (hasta - desde) / Float(cuadros)
        for i in 0..<cuadros {
            let g = desde + paso * Float(i + 1)
            let l = muestras[i * canalesEntrada]
            let r = canalesEntrada > 1 ? muestras[i * canalesEntrada + 1] : l
            if mapa.mono {
                izq[i * canalesIzq + mapa.izquierda.canal] = (l + r) * 0.5 * g
            } else {
                izq[i * canalesIzq + mapa.izquierda.canal] = l * g
                der[i * canalesDer + mapa.derecha.canal] = r * g
            }
        }
    }

    // MARK: - A qué app pertenece un proceso

    /// La app "dueña" de un proceso de audio. Chrome, Safari y las apps Electron suenan desde procesos ayudantes que
    /// macOS lanza aparte: se busca la app responsable y, si no alcanza, se sube por los padres hasta una app normal
    /// (con ícono en el Dock). Nil = no es de ninguna app (servicios de macOS): no se muestra ni se toca.
    static func dueno(de pid: pid_t, responsable: (pid_t) -> pid_t?, padre: (pid_t) -> pid_t?, esApp: (pid_t) -> Bool) -> pid_t? {
        if esApp(pid) { return pid }
        if let r = responsable(pid), r > 1, esApp(r) { return r }
        var actual = pid
        for _ in 0..<8 {
            guard let p = padre(actual), p > 1, p != actual else { return nil }
            if esApp(p) { return p }
            actual = p
        }
        return nil
    }

    // MARK: - Motor colgado

    enum Vigilancia: Equatable {
        /// El motor sigue procesando audio.
        case bien
        /// No avanzó: se rehace una vez.
        case rehacer
        /// Ya se rehízo y tampoco anda: se suelta la app (vuelve a sonar normal, "falla abierta").
        case soltar
    }

    /// Después de dormir la Mac, el proceso de audio de un motor puede dejar de correr mientras el tap sigue
    /// silenciando a la app: queda muda hasta reiniciar. El motor cuenta sus ciclos; si entre dos miradas no avanzó,
    /// está colgado (con la app sonando o no: el agregado procesa silencio igual).
    static func vigilar(ciclosAntes: UInt64, ciclosAhora: UInt64, yaRehecho: Bool) -> Vigilancia {
        if ciclosAhora != ciclosAntes { return .bien }
        return yaRehecho ? .soltar : .rehacer
    }

    // MARK: - Volúmenes recordados

    /// Guarda el volumen de una app por su identificador. Solo se guarda lo que no está al 100 % (al 100 % no hay
    /// nada que recordar) y hasta `tope` apps, para que la lista no crezca sin fin.
    static func recordar(_ valor: Float, de bundle: String, en guardados: [String: Double], tope: Int = 200) -> [String: Double] {
        var nuevos = guardados
        if valor >= 0.995 {
            nuevos.removeValue(forKey: bundle)
        } else if nuevos[bundle] != nil || nuevos.count < tope {
            nuevos[bundle] = Double(min(max(valor, 0), 1))
        }
        return nuevos
    }
}
