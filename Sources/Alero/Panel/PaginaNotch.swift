import SwiftUI

// Alero › Notch: dónde aparece el notch, cómo se abre, cuánto mide abierto, su fondo, qué funciones usa (música,
// calendario, estante) y los avisos chicos a los costados de la cámara. Lo de adentro del notch abierto (barra,
// Inicio y botones al deslizar) va en `PaginaNotchAbierto`.

struct PaginaNotch: View {
    @ObservedObject private var ajustes = Ajustes.shared

    private struct Demora: Identifiable, Hashable {
        let segundos: Double
        var id: Double { segundos }
        static let todas = [Demora(segundos: 0.1), Demora(segundos: 0.3), Demora(segundos: 0.6), Demora(segundos: 0)]
        var nombre: String {
            switch segundos {
            case 0: return T("Solo con clic", "Click only")
            case 0.1: return T("Al toque", "Instantly")
            default: return String(format: "%.1f s", segundos).replacingOccurrences(of: ".", with: Idioma.castellano ? "," : ".")
            }
        }
    }

    var body: some View {
        TituloPagina(titulo: T("Notch", "Notch"),
                     subtitulo: T("Qué aparece en el notch, dónde y cómo se abre.", "What shows up in the notch, where, and how it opens."))
        if ajustes.notchTeclas && ajustes.notchActivo { AvisoAccesibilidad() }

        Tarjeta(titulo: T("Dónde aparece", "Where it shows up")) {
            FilaLlave(titulo: T("Usar el notch", "Use the notch"),
                      detalle: T("Apagado, Alero queda solo en la barra de menú.", "When off, Alero stays in the menu bar only."),
                      valor: $ajustes.notchActivo)
            Fila(titulo: T("Pantalla", "Display"),
                 detalle: T("\"Sigue al mouse\" lo lleva a la pantalla donde está el puntero.",
                            "\"Follows the pointer\" moves it to the display the pointer is on.")) {
                Segmentos(valor: $ajustes.notchPantalla, opciones: PantallaNotch.allCases) { $0.nombre }
            }
            FilaLlave(titulo: T("Cápsula en monitores sin notch", "Capsule on displays without a notch"),
                      detalle: T("Dibuja un notch arriba al centro para verlo y abrirlo.", "Draws a notch at the top center so you can see and open it."),
                      valor: $ajustes.notchCapsula)
            Fila(titulo: T("Abrir al pasar el mouse", "Open on hover"),
                 detalle: T("Cuánto esperar con el mouse encima.", "How long to wait with the pointer on it."), divisor: false) {
                Segmentos(valor: Binding(get: { Demora(segundos: ajustes.notchDemora) }, set: { ajustes.notchDemora = $0.segundos }),
                          opciones: Demora.todas) { $0.nombre }
            }
        }

        Tarjeta(titulo: T("Tamaño abierto", "Open size")) {
            Fila(titulo: T("Ancho", "Width"), detalle: "\(Int(ajustes.notchAncho)) pt") {
                Slider(value: $ajustes.notchAncho, in: Diseno.anchosPosibles, step: 10).frame(width: 220).tint(Tema.acentoVentana)
            }
            Fila(titulo: T("Alto", "Height"), detalle: "\(Int(ajustes.notchAlto)) pt", divisor: false) {
                HStack(spacing: 10) {
                    Slider(value: $ajustes.notchAlto, in: Diseno.altosPosibles, step: 2).frame(width: 220).tint(Tema.acentoVentana)
                    BotonSecundario(texto: T("Original", "Reset")) {
                        ajustes.notchAncho = 660
                        ajustes.notchAlto = 174
                    }
                }
            }
        }

        Tarjeta(titulo: T("Fondo del notch abierto", "Open notch background")) {
            Fila(titulo: T("Estilo", "Style"),
                 detalle: T("El vidrio deja ver un poco lo que hay detrás. Con \"Reducir transparencia\" de macOS queda negro.",
                            "Glass lets what's behind show through. With macOS \"Reduce transparency\" it stays black."),
                 divisor: ajustes.notchEstilo == .vidrio) {
                Segmentos(valor: $ajustes.notchEstilo, opciones: EstiloNotch.allCases) { $0.nombre }
            }
            if ajustes.notchEstilo == .vidrio {
                Fila(titulo: T("Transparencia", "Transparency"), detalle: "\(Int((ajustes.notchVidrio * 100).rounded())) %", divisor: false) {
                    Slider(value: $ajustes.notchVidrio, in: 0.1...1).frame(width: 220).tint(Tema.acentoVentana)
                }
            }
        }

        Tarjeta(titulo: T("Funciones", "Features")) {
            FilaLlave(titulo: T("Música", "Music"),
                      detalle: T("Lo que suena en cualquier app, con carátula y controles.", "What's playing in any app, with artwork and controls."),
                      valor: $ajustes.notchMusica)
            FilaLlave(titulo: T("Calendario", "Calendar"),
                      detalle: T("Tus próximas reuniones y un aviso 5 minutos antes.", "Your next meetings and a heads-up 5 minutes before."),
                      valor: $ajustes.notchCalendario)
            FilaLlave(titulo: T("Estante", "Shelf"),
                      detalle: T("Aparece cuando acercás un archivo al notch.", "Shows up when you bring a file to the notch."),
                      divisor: false, valor: $ajustes.notchEstante)
        }

        Tarjeta(titulo: T("Avisos a los costados de la cámara", "Notices beside the camera")) {
            FilaLlave(titulo: T("Volumen y brillo", "Volume & brightness"),
                      detalle: T("Al tocar esas teclas, el nivel aparece en el notch en vez del cartel de macOS. Pide Accesibilidad.",
                                 "When you press those keys, the level shows in the notch instead of the macOS overlay. Needs Accessibility."),
                      valor: $ajustes.notchTeclas)
            FilaLlave(titulo: T("Auriculares y parlantes", "Headphones & speakers"),
                      detalle: T("Cuando se conecta una salida de sonido (AirPods, parlante, monitor).", "When a sound output connects (AirPods, speaker, display)."),
                      valor: $ajustes.avisoSalida)
            FilaLlave(titulo: T("Cargador", "Charger"),
                      detalle: T("Al enchufar o desenchufar, con el porcentaje de batería.", "When you plug in or unplug, with the battery percentage."),
                      valor: $ajustes.avisoCorriente)
            FilaLlave(titulo: T("Descargas", "Downloads"),
                      detalle: T("Cuando termina una descarga en la carpeta Descargas.", "When a download finishes in the Downloads folder."),
                      divisor: false, valor: $ajustes.avisoDescargas)
        }
    }
}
