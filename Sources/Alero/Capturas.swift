import AppKit
import SwiftUI

// `Alero --capturas <carpeta>`: dibuja cada estado del notch, las páginas de ajustes, las pantallas de las capturas
// de pantalla (`MuestrasCaptura`) y las de Mantenimiento y el modo limpieza (`MuestrasMantenimiento`) a PNG, con
// datos de ejemplo.
// Sirve para revisar el diseño sin abrir el notch de verdad ni pedir permisos. No toca ajustes ni archivos de la
// persona (salvo la carpeta que se le pasa).

@MainActor
enum Capturas {
    static func hacer(en carpeta: String) {
        let destino = URL(fileURLWithPath: carpeta, isDirectory: true)
        do { try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true) } catch {
            print("No se pudo crear \(carpeta): \(error.localizedDescription)")
            return
        }
        let estado = EstadoNotch()
        let ejemplo = Pista(titulo: "Mañana de domingo", artista: "Trío del Barrio", album: "", duracion: 222,
                            transcurrido: 84, marca: Date(), sonando: true)
        Musica.shared.simular(ejemplo, caratula: caratulaDeEjemplo(), color: Color(nsColor: NSColor(hex: 0xF6C36B)))
        Mezclador.shared.simular([
            AppAudio(id: "com.google.Chrome", pid: -1, bundle: "com.google.Chrome", nombre: "Google Chrome", volumen: 0.4,
                     silencio: false, sonando: true, fallo: false),
            AppAudio(id: "com.apple.Music", pid: -1, bundle: "com.apple.Music", nombre: T("Música", "Music"), volumen: 1,
                     silencio: false, sonando: true, fallo: false),
            AppAudio(id: "com.apple.Safari", pid: -1, bundle: "com.apple.Safari", nombre: "Safari", volumen: 0.7, silencio: true, sonando: true, fallo: false),
        ])
        Monitores.shared.simular([
            Monitor(id: 1, huella: "1552:41058:1", nombre: T("Pantalla de la MacBook", "MacBook display"), integrada: true, metodo: .integrada, nivel: 0.75),
            Monitor(id: 2, huella: "25001:12289:0", nombre: "Mi Monitor", integrada: false, metodo: .ddc, nivel: 0.5),
            Monitor(id: 3, huella: "1:2:3", nombre: T("Tele del living", "Living room TV"), integrada: false, metodo: .gamma, nivel: 0.8),
        ])

        EstadoMac.shared.simular(cpu: 0.23, usada: 11_400_000_000, presion: .normal, swap: 1_200_000_000)
        Agentes.shared.simular(claude: EstadoAgente(ultimo: Date(), proyecto: "Notch",
                                                    chat: .init(titulo: "Notch configurable", modelo: "claude-opus-5-5", contexto: 457_000,
                                                                ventana: 1_000_000, rama: "main")),
                               codex: EstadoAgente(ultimo: Date().addingTimeInterval(-720), proyecto: "halyon",
                                                   cupos: [.init(nombre: "semana", usado: 0.47, reinicia: Date().addingTimeInterval(3 * 86_400))],
                                                   chat: .init(modelo: "gpt-5.2-codex", contexto: 38_816, ventana: 258_400)))
        Teleprompter.shared.simular(T(
            "Hola a todos. Hoy les quiero mostrar algo que hicimos para que el notch de la Mac trabaje para vos.\n\nEl guion queda justo debajo de la cámara, así mirás a la gente y no a tus notas.",
            "Hi everyone. Today I want to show you something we made so your Mac's notch works for you.\n\nThe script sits right under the camera, so you look at people and not at your notes."))
        let estados: [(String, () -> Void)] = [
            ("1-cerrado-musica", { estado.forzar(.cerrado) }),
            ("2-aviso-reunion", { estado.forzar(.aviso, aviso: .reunion(titulo: "Llamada con cliente", minutos: 5)) }),
            ("3-aviso-auriculares", { estado.forzar(.aviso, aviso: .salida(tipo: .bluetooth, nombre: "AirPods Pro")) }),
            ("4-hud-volumen", { estado.forzar(.hud, hud: (.volumen, 0.62)) }),
            ("5-hud-brillo", { estado.forzar(.hud, hud: (.brillo, 0.75)) }),
            ("6-atajos", { estado.forzar(.atajos) }),
            ("7-abierto", { estado.forzar(.abierto) }),
            ("7b-abierto-sonido", { estado.forzar(.abierto, espacio: .sonido) }),
            ("7d-abierto-utilidades", { estado.forzar(.abierto, espacio: .utilidades) }),
            ("7g-abierto-limpiar", { estado.forzar(.abierto, espacio: .limpiar) }),
            ("7h-abierto-teleprompter", { estado.forzar(.abierto, espacio: .teleprompter) }),
            ("7i-abierto-terminal", { estado.forzar(.abierto, espacio: .terminal) }),
            ("7e-abierto-agentes", { estado.forzar(.abierto, espacio: .agentes) }),
            ("7f-abierto-estante", { estado.forzar(.abierto, espacio: .estante) }),
            ("8-estante-soltar", { estado.forzar(.estante) }),
            ("8b-teleprompter", { estado.forzar(.prompter) }),
            ("9-aviso-cortar", { estado.forzar(.aviso, aviso: .cortar(cantidad: 3)) }),
            ("10-aviso-pegar-error", { estado.forzar(.aviso, aviso: .pegar(movidos: 2, fallidos: 1, sinPermiso: true)) }),
            ("11-aviso-captura", { estado.forzar(.captura, captura: MuestrasCaptura.capturaDeEjemplo()) }),
            ("12-aviso-captura-error", { estado.forzar(.aviso, aviso: .capturaFallo(copiada: true)) }),
            ("13-aviso-permiso-grabacion", { estado.forzar(.aviso, aviso: .permiso(nombre: T("Grabación de pantalla", "Screen Recording"))) }),
        ]
        for (nombre, preparar) in estados {
            preparar()
            let vista = ZStack(alignment: .top) {
                Color(nsColor: NSColor(hex: 0x1E2127))
                Color(nsColor: NSColor(hex: 0x2A2D33)).frame(height: estado.medidas.alto)
                VistaNotch(estado: estado, aceptaArchivos: false)
            }
            .frame(width: 800, height: 260)
            .environment(\.enCapturas, true)
            guardar(vista, como: destino.appendingPathComponent("notch-\(nombre).png"))
        }
        // La columna de sonido entera (en el notch se desplaza si no entra).
        let columna = ColumnaSonido().environment(\.enCapturas, true).foregroundStyle(Tema.textoNotch)
            .frame(width: 214).padding(20).background(Tema.notch).environment(\.colorScheme, .dark)
        guardar(columna, como: destino.appendingPathComponent("notch-7z-columna-sonido.png"))
        // Las de Mantenimiento con datos de ejemplo van en `MuestrasMantenimiento`.
        for pagina in SeccionAlero.allCases where pagina.grupo != .mantenimiento || pagina == .teclado {
            for (sufijo, esquema) in [("claro", ColorScheme.light), ("oscuro", ColorScheme.dark)] {
                let panel = PanelAlero(navegacion: NavegacionAlero(pagina), desplazable: false)
                let vista = panel.environment(\.colorScheme, esquema).frame(width: 920, height: 1180)
                guardar(vista, como: destino.appendingPathComponent("ajustes-\(pagina.rawValue)-\(sufijo).png"))
            }
        }
        MuestrasCaptura.hacer(en: destino)
        MuestrasMantenimiento.hacer(guardar: { guardar($0, como: $1) }, en: destino)
        print("Capturas en \(destino.path)")
    }

    private static func guardar<V: View>(_ vista: V, como url: URL) {
        let render = ImageRenderer(content: vista)
        render.scale = 2
        guard let imagen = render.nsImage, let tiff = imagen.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("No se pudo dibujar \(url.lastPathComponent)")
            return
        }
        do { try png.write(to: url) } catch { print("No se pudo guardar \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    /// Carátula inventada (dos colores y un círculo) para no usar imágenes de nadie.
    private static func caratulaDeEjemplo() -> NSImage {
        NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSColor(hex: 0xD9653B).setFill()
            rect.fill()
            NSColor(hex: 0xF6C36B).setFill()
            NSBezierPath(ovalIn: NSRect(x: 80, y: -40, width: 170, height: 170)).fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 34, y: 130, width: 40, height: 40)).fill()
            return true
        }
    }
}
