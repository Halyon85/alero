import AVFoundation
import Foundation
import Speech

// El teleprompter que sigue la voz: escucha el micrófono, reconoce lo que decís (en español, en la Mac cuando el idioma
// lo permite) y avanza la palabra marcada en el guion. Solo escucha mientras el teleprompter corre en modo voz: al
// pausar o cerrar se apaga el micrófono. Pide los permisos de micrófono y de reconocimiento de voz la primera vez.
// La forma de seguir el guion es propia (01/11/2026).
// Main thread (el audio y los resultados llegan en otros hilos y se pasan acá).

/// Cómo se sigue el guion, sin audio (se prueba con `swift test`).
enum ReglasPrompter {
    /// La palabra sin mayúsculas, tildes ni signos: "¿Cómo," → "como".
    static func normal(_ palabra: Substring) -> String {
        palabra.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Las palabras del guion, normalizadas (las que quedan vacías, como "—", no cuentan).
    static func palabras(_ texto: String) -> [String] {
        texto.split(whereSeparator: { $0.isWhitespace }).map(normal).filter { !$0.isEmpty }
    }

    /// Dónde queda el guion después de oír `dichas` (las últimas palabras reconocidas): busca la última dicha en las
    /// próximas 12 del guion. Una palabra corta ("de", "la") solo cuenta si la anterior también coincide: si no, el
    /// guion saltaría a cualquier "de". Nunca vuelve para atrás.
    static func avanzar(_ posicion: Int, guion: [String], dichas: [String]) -> Int {
        guard let ultima = dichas.last, !ultima.isEmpty else { return posicion }
        let fin = min(posicion + 12, guion.count)
        guard posicion < fin else { return posicion }
        for k in posicion..<fin where guion[k] == ultima {
            if ultima.count <= 3 {
                guard dichas.count >= 2, k > 0, guion[k - 1] == dichas[dichas.count - 2] else { continue }
            }
            return k + 1
        }
        return posicion
    }
}

final class SeguidorVoz {
    /// Se llama con las últimas palabras reconocidas (normalizadas), en el hilo principal.
    var alOir: (([String]) -> Void)?
    /// Se llama si falta un permiso o el idioma no está, con un texto para mostrar.
    var alFallar: ((String) -> Void)?

    private let motor = AVAudioEngine()
    private var reconocedor: SFSpeechRecognizer?
    private var pedido: SFSpeechAudioBufferRecognitionRequest?
    private var tarea: SFSpeechRecognitionTask?
    private(set) var escuchando = false

    /// Pide los permisos (la primera vez) y empieza a escuchar en `idioma` ("es-AR", "es-ES"…).
    func empezar(idioma: String) {
        guard !escuchando else { return }
        SFSpeechRecognizer.requestAuthorization { estado in
            DispatchQueue.main.async {
                guard estado == .authorized else {
                    self.alFallar?(T("Falta el permiso de reconocimiento de voz (Ajustes del Sistema › Privacidad).",
                                     "Speech recognition permission is missing (System Settings › Privacy)."))
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { concedido in
                    DispatchQueue.main.async {
                        guard concedido else {
                            self.alFallar?(T("Falta el permiso del micrófono.", "Microphone permission is missing."))
                            return
                        }
                        self.arrancar(idioma: idioma)
                    }
                }
            }
        }
    }

    func detener() {
        escuchando = false
        tarea?.cancel()
        tarea = nil
        pedido?.endAudio()
        pedido = nil
        if motor.isRunning {
            motor.stop()
            motor.inputNode.removeTap(onBus: 0)
        }
    }

    private func arrancar(idioma: String) {
        guard let reconocedor = SFSpeechRecognizer(locale: Locale(identifier: idioma)), reconocedor.isAvailable else {
            alFallar?(T("El reconocimiento de voz en español no está disponible ahora.", "Spanish speech recognition isn't available right now."))
            return
        }
        self.reconocedor = reconocedor
        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        entrada.removeTap(onBus: 0)
        entrada.installTap(onBus: 0, bufferSize: 1024, format: formato) { [weak self] buffer, _ in
            self?.pedido?.append(buffer)
        }
        do {
            motor.prepare()
            try motor.start()
        } catch {
            entrada.removeTap(onBus: 0)
            alFallar?(T("No se pudo usar el micrófono: \(error.localizedDescription)", "Couldn't use the microphone: \(error.localizedDescription)"))
            return
        }
        escuchando = true
        nuevaTarea()
    }

    /// macOS corta cada reconocimiento después de un rato (alrededor de un minuto): al cortarse, se arranca otro.
    private func nuevaTarea() {
        guard escuchando, let reconocedor else { return }
        let nuevo = SFSpeechAudioBufferRecognitionRequest()
        nuevo.shouldReportPartialResults = true
        // En la Mac si se puede: la voz no sale a internet.
        if reconocedor.supportsOnDeviceRecognition { nuevo.requiresOnDeviceRecognition = true }
        pedido = nuevo
        tarea = reconocedor.recognitionTask(with: nuevo) { [weak self] resultado, error in
            let dichas = resultado.map { ReglasPrompter.palabras($0.bestTranscription.formattedString) } ?? []
            let termino = error != nil || resultado?.isFinal == true
            DispatchQueue.main.async {
                guard let self, self.escuchando else { return }
                if !dichas.isEmpty { self.alOir?(Array(dichas.suffix(4))) }
                if termino {
                    self.pedido?.endAudio()
                    // Un respiro antes de volver a escuchar: si el error se repite (sin voz), no queda en un bucle.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.nuevaTarea() }
                }
            }
        }
    }
}
