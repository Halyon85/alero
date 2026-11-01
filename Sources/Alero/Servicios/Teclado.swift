import Carbon.HIToolbox
import CoreGraphics

// Mandar una combinación de teclas como si se apretara en el teclado de verdad (para los botones del mouse y para
// devolverle a Finder un ⌘X o ⌘V que no era para Alero). Va marcada para que las escuchas de Alero no la tomen.

enum Teclado {
    /// Las cuatro teclas modificadoras que guarda un atajo (el resto de las banderas de macOS no se copian).
    static let modificadores: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// Se manda en la etapa del teclado físico (`cghidEventTap`): así la ven también los atajos de macOS y de otras
    /// apps. Sin texto Unicode a propósito: con texto, las apps no reconocen el atajo de su menú.
    static func enviar(codigo: CGKeyCode, flags: CGEventFlags) {
        let fuente = CGEventSource(stateID: .hidSystemState)
        for bajando in [true, false] {
            guard let evento = CGEvent(keyboardEventSource: fuente, virtualKey: codigo, keyDown: bajando) else { continue }
            evento.flags = flags.intersection(modificadores)
            MarcaPropia.marcar(evento)
            evento.post(tap: .cghidEventTap)
        }
    }

    /// La tecla física que escribe `caracter` en la distribución de teclado actual y lo que escribe esa tecla sola.
    /// Hace falta para los atajos con corchetes: si en el teclado de la persona "[" pide ⇧ o ⌥ (latinoamericano,
    /// español, alemán…), macOS pasa ⌘[ a la tecla que tiene el corchete y la muestra con lo que escribe sola (en el
    /// latinoamericano, ⌘[ aparece como ⌘{). Main thread (lo pide el sistema de teclados de macOS).
    static func teclaQueEscribe(_ caracter: String) -> (codigo: CGKeyCode, base: String)? {
        guard let fuente = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let crudo = TISGetInputSourceProperty(fuente, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let datos = Unmanaged<CFData>.fromOpaque(crudo).takeUnretainedValue() as Data
        return datos.withUnsafeBytes { bytes -> (CGKeyCode, String)? in
            guard let distribucion = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            func escribe(_ codigo: UInt16, _ modificadoras: Int) -> String {
                var muerta: UInt32 = 0
                var largo = 0
                var letras = [UniChar](repeating: 0, count: 4)
                let estado = UInt32((modificadoras >> 8) & 0xFF)
                UCKeyTranslate(distribucion, codigo, UInt16(kUCKeyActionDown), estado, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &muerta, letras.count, &largo, &letras)
                return String(utf16CodeUnits: letras, count: largo)
            }
            // Primero sin modificadoras: si la tecla existe así, esa gana aunque otra lo escriba con ⇧ o ⌥.
            for modificadoras in [0, shiftKey, optionKey, shiftKey | optionKey] {
                for codigo in UInt16(0)..<128 where escribe(codigo, modificadoras) == caracter {
                    return (CGKeyCode(codigo), escribe(codigo, 0))
                }
            }
            return nil
        }
    }
}
