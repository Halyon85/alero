import AppKit
import SwiftUI

// Botón que graba un atajo de teclado: se aprieta, espera la combinación y la guarda. ⎋ cancela y ⌫ lo borra.
// Escucha solo mientras graba y solo dentro de la ventana de ajustes (monitor local de AppKit, sin permisos).
// Mientras graba suelta los atajos de captura: si no, macOS se los daría a la captura y nunca llegarían acá.

struct GrabadorAtajo: View {
    @Binding var atajo: AtajoTeclado?
    @State private var grabando = false
    @State private var monitor: Any?
    /// Lo que se le dice a la persona si la combinación no sirve (por ejemplo, una letra sola).
    @State private var pista: String?

    var body: some View {
        Button(action: { grabando ? terminar() : empezar() }) {
            HStack(spacing: 6) {
                Image(systemName: grabando ? "record.circle" : "keyboard").font(.system(size: 12, weight: .medium))
                Text(texto).font(.titulo(13)).lineLimit(1).monospacedDigit()
            }
            .fixedSize()
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(grabando ? Tema.acentoVentana.opacity(0.14) : Tema.relleno))
            .overlay(Capsule().strokeBorder(grabando ? Tema.acentoVentana.opacity(0.6) : .clear, lineWidth: 1))
            .foregroundStyle(grabando ? Tema.acentoVentana : Tema.titulo)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: grabando)
        .accessibilityLabel(T("Atajo de teclado", "Keyboard shortcut"))
        .accessibilityValue(atajo?.texto ?? T("Sin grabar", "Not set"))
        .onDisappear(perform: terminar)
    }

    private var texto: String {
        if grabando { return pista ?? T("Apretá la combinación…", "Press the shortcut…") }
        return atajo?.texto ?? T("Grabar atajo", "Record shortcut")
    }

    private func empezar() {
        pista = nil
        grabando = true
        Capturador.shared.pausarAtajos()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { evento in
            recibir(evento)
            // La combinación no sigue a la ventana: si no, grabar ⌘W la cerraría.
            return nil
        }
    }

    private func terminar() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        let estabaGrabando = grabando
        monitor = nil
        grabando = false
        if estabaGrabando { Capturador.shared.reanudarAtajos() }
    }

    private func recibir(_ evento: NSEvent) {
        let modificadoras = evento.modifierFlags.intersection([.control, .option, .shift, .command])
        if modificadoras.isEmpty && evento.keyCode == 53 { terminar(); return }
        if modificadoras.isEmpty && (evento.keyCode == 51 || evento.keyCode == 117) {
            atajo = nil
            terminar()
            return
        }
        // Una letra sola (o con ⇧) escribiría en cualquier campo: hace falta ⌘, ⌃ o ⌥. Las F1…F20 sí van solas.
        if modificadoras.subtracting(.shift).isEmpty && !AtajoTeclado.esTeclaDeFuncion(evento.keyCode) {
            pista = T("Sumá ⌘, ⌃ o ⌥", "Add ⌘, ⌃ or ⌥")
            NSSound.beep()
            return
        }
        let flags = GrabadorAtajo.banderas(modificadoras)
        // La letra de la tecla sola (sin ⇧): así ⇧⌘1 se ve "⇧⌘1" y no "⇧⌘!", como en los menús de macOS.
        let tecla = AtajoTeclado.nombreTecla(codigo: evento.keyCode, caracteres: evento.characters(byApplyingModifiers: []))
        atajo = AtajoTeclado(codigo: evento.keyCode, modificadores: flags.rawValue, texto: AtajoTeclado.texto(flags: flags, tecla: tecla))
        terminar()
    }

    private static func banderas(_ modificadoras: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modificadoras.contains(.control) { flags.insert(.maskControl) }
        if modificadoras.contains(.option) { flags.insert(.maskAlternate) }
        if modificadoras.contains(.shift) { flags.insert(.maskShift) }
        if modificadoras.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
