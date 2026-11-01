import AppKit
import SwiftUI

// El editor rápido de una captura: herramientas arriba (recortar, flecha, rectángulo, resaltador, texto), colores,
// deshacer y, a la derecha, fijar, copiar y guardar. Se abre con un clic en la miniatura del notch. Al cerrarse
// suelta la imagen (nada queda en memoria). "Guardar" reemplaza el archivo de la captura por la versión editada.

final class VentanaEditor: NSObject, NSWindowDelegate {
    /// Los editores abiertos (se retienen acá hasta que se cierran).
    private static var abiertos: [VentanaEditor] = []

    private let ventana: NSWindow
    private let modelo: ModeloEditor

    static func abrir(_ url: URL) {
        if let abierto = abiertos.first(where: { $0.modelo.url == url }) {
            NSApp.activate(ignoringOtherApps: true)
            abierto.ventana.makeKeyAndOrderFront(nil)
            return
        }
        guard let leida = ImagenCaptura.leer(url) else {
            NSLog("Alero: no se pudo abrir la captura \(url.lastPathComponent) en el editor")
            NSSound.beep()
            return
        }
        let editor = VentanaEditor(modelo: ModeloEditor(imagen: leida.imagen, escala: leida.escala, url: url))
        abiertos.append(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.ventana.makeKeyAndOrderFront(nil)
    }

    private init(modelo: ModeloEditor) {
        self.modelo = modelo
        let pantalla = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = pantalla?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // A tamaño real si entra, si no lo más grande que entre en el 85 % de la pantalla.
        let imagen = CGSize(width: CGFloat(modelo.imagen.width) / modelo.escala, height: CGFloat(modelo.imagen.height) / modelo.escala)
        let ancho = min(max(imagen.width + 48, 720), visible.width * 0.85)
        let alto = min(max(imagen.height + 48 + VistaEditor.altoBarra, 460), visible.height * 0.85)
        ventana = VentanaConAtajos(contentRect: NSRect(x: 0, y: 0, width: ancho, height: alto),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        super.init()
        ventana.titlebarAppearsTransparent = true
        ventana.title = modelo.url?.deletingPathExtension().lastPathComponent ?? T("Captura", "Screenshot")
        ventana.isReleasedWhenClosed = false
        // Sin la animación de AppKit: cada editor cerrado dejaba ~20 MB en WindowServer (ver `VentanaAlero`).
        ventana.animationBehavior = .none
        ventana.minSize = NSSize(width: 720, height: 420)
        ventana.delegate = self
        ventana.contentView = NSHostingView(rootView: VistaEditor(modelo: modelo, cerrar: { [weak self] in self?.ventana.close() }))
        ventana.setFrameOrigin(NSPoint(x: visible.midX - ancho / 2, y: visible.midY - alto / 2))
    }

    func windowWillClose(_ aviso: Notification) {
        // Soltar la vista suelta el modelo y con él la imagen.
        ventana.contentView = nil
        ventana.delegate = nil
        VentanaEditor.abiertos.removeAll { $0 === self }
    }
}

/// ⌘W cierra aunque Alero no tenga menú (es una app de la barra de menú).
private final class VentanaConAtajos: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modificadoras = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modificadoras == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct VistaEditor: View {
    static let altoBarra: CGFloat = 80

    @ObservedObject var modelo: ModeloEditor
    let cerrar: () -> Void
    /// Confirmación corta junto a los botones ("Copiada", "Guardada" o el error).
    @State private var aviso: (texto: String, error: Bool)?
    @State private var tareaAviso: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            barra
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 12)
            Rectangle().fill(Tema.bordeSuave).frame(height: 1)
            Lienzo(modelo: modelo)
                .background(Tema.rellenoSuave)
        }
        .background(Tema.fondo)
        .foregroundStyle(Tema.texto)
        .focusEffectDisabled()
        .ignoresSafeArea()
    }

    private var barra: some View {
        HStack(spacing: 12) {
            herramientas
            colores
            BotonIcono(icono: "arrow.uturn.backward", etiqueta: T("Deshacer (⌘Z)", "Undo (⌘Z)"), activo: false) { modelo.deshacer() }
                .disabled(!modelo.puedeDeshacer)
                .opacity(modelo.puedeDeshacer ? 1 : 0.4)
                .keyboardShortcut("z", modifiers: .command)
            Spacer(minLength: 8)
            if let aviso {
                Label(aviso.texto, systemImage: aviso.error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.titulo(12))
                    .foregroundStyle(aviso.error ? Tema.error : Tema.exito)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            BotonSecundario(texto: T("Fijar", "Pin"), icono: "pin") { fijar() }
            BotonSecundario(texto: T("Copiar", "Copy"), icono: "doc.on.doc") {
                mostrar(modelo.copiar() ? (T("Copiada", "Copied"), false) : (T("No se pudo copiar", "Couldn't copy"), true))
            }
            .keyboardShortcut("c", modifiers: .command)
            BotonPrimario(texto: T("Guardar", "Save")) {
                mostrar(modelo.guardar() ? (T("Guardada", "Saved"), false) : (T("No se pudo guardar", "Couldn't save"), true))
            }
            .keyboardShortcut("s", modifiers: .command)
            .opacity(modelo.sinGuardar ? 1 : 0.55)
        }
        .animation(.easeOut(duration: 0.18), value: aviso?.texto)
    }

    private var herramientas: some View {
        HStack(spacing: 2) {
            ForEach(HerramientaEditor.allCases) { herramienta in
                BotonIcono(icono: herramienta.icono, etiqueta: herramienta.nombre, activo: modelo.herramienta == herramienta) {
                    withAnimation(Tema.expo) { modelo.herramienta = herramienta }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tema.relleno))
    }

    private var colores: some View {
        HStack(spacing: 6) {
            ForEach(ColorAnotacion.allCases) { color in
                let elegido = modelo.color == color
                Button { modelo.color = color } label: {
                    Circle().fill(Color(nsColor: color.nsColor))
                        .overlay(Circle().strokeBorder(Tema.apagado.opacity(0.45), lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay(Circle().strokeBorder(elegido ? Tema.titulo : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.nombre)
                .accessibilityLabel(color.nombre)
                .accessibilityAddTraits(elegido ? .isSelected : [])
            }
        }
    }

    private func fijar() {
        guard let final = modelo.exportar() else { mostrar((T("No se pudo fijar", "Couldn't pin"), true)); return }
        VentanaFijada.fijar(final, escala: modelo.escala)
    }

    private func mostrar(_ nuevo: (String, Bool)) {
        aviso = (nuevo.0, nuevo.1)
        tareaAviso?.cancel()
        let tarea = DispatchWorkItem { aviso = nil }
        tareaAviso = tarea
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: tarea)
    }
}

/// Botón cuadrado con ícono, resaltado cuando está elegido (herramientas y deshacer).
struct BotonIcono: View {
    let icono: String
    let etiqueta: String
    let activo: Bool
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: icono)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 28)
                .foregroundStyle(activo ? Tema.titulo : Tema.subtitulo)
                .background {
                    if activo {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tema.tarjeta)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(etiqueta)
        .accessibilityLabel(etiqueta)
        .accessibilityAddTraits(activo ? .isSelected : [])
    }
}
