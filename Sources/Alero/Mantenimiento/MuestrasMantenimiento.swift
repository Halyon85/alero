import SwiftUI

// Muestras de Mantenimiento para `Alero --capturas`: cada página con datos de ejemplo (en claro y en oscuro) y la capa
// del modo limpieza, y el desinstalador del notch con varias apps. No lee el disco, no corre brew y no traba nada.

@MainActor
enum MuestrasMantenimiento {
    static func hacer(guardar: (AnyView, URL) -> Void, en destino: URL) {
        let casos: [(String, () -> PanelAlero)] = [
            ("limpiador", { PanelAlero(navegacion: NavegacionAlero(.limpiador), desplazable: false, limpiador: .muestra()) }),
            ("limpiador-inicio", { PanelAlero(navegacion: NavegacionAlero(.limpiador), desplazable: false) }),
            ("desinstalador-lista", { PanelAlero(navegacion: NavegacionAlero(.desinstalador), desplazable: false,
                                                         desinstalador: .muestraLista()) }),
            ("desinstalador-app", { PanelAlero(navegacion: NavegacionAlero(.desinstalador), desplazable: false,
                                                       desinstalador: .muestra()) }),
            ("homebrew", { PanelAlero(navegacion: NavegacionAlero(.homebrew), desplazable: false, homebrew: .muestra()) }),
        ]
        for (nombre, panel) in casos {
            for (sufijo, esquema) in [("claro", ColorScheme.light), ("oscuro", ColorScheme.dark)] {
                let vista = panel().environment(\.colorScheme, esquema).frame(width: 920, height: 1180)
                guardar(AnyView(vista), destino.appendingPathComponent("mantenimiento-\(nombre)-\(sufijo).png"))
            }
        }
        // El desinstalador del notch (Utilidades, columna derecha), con varias apps elegidas.
        let notch: [(String, ModeloDesinstalador)] = [
            ("vacio", ModeloDesinstalador.muestraLista()), ("marcadas", .muestraListaMarcada()), ("una", .muestra()), ("varias", .muestraVarias()),
            ("varias-abiertas", .muestraVariasAbiertas()), ("varias-terminado", .muestraVariasTerminado()),
        ]
        for (nombre, modelo) in notch {
            let vista = DesinstaladorNotch(modelo: modelo).environment(\.enCapturas, true).foregroundStyle(Tema.textoNotch)
                .frame(width: 380, height: 140).padding(16).background(Tema.notch).environment(\.colorScheme, .dark)
            guardar(AnyView(vista), destino.appendingPathComponent("notch-desinstalador-\(nombre).png"))
        }
        let estado = EstadoTraba()
        estado.escs = 2
        estado.fin = Date().addingTimeInterval(105)
        guardar(AnyView(VistaTraba(estado: estado, salir: {}).frame(width: 1440, height: 900)),
                destino.appendingPathComponent("traba-teclado.png"))
    }
}
